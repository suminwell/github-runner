#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-systemd.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
success=false
manager=
cleanup() {
    if [ -n "$manager" ]; then kill "$manager" 2>/dev/null || :; wait "$manager" 2>/dev/null || :; fi
    if $success; then rm -rf "$FIXTURE"; else printf 'Retained fixture: %s\n' "$FIXTURE"; fi
}
trap cleanup EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
export LOCAL_RUNNER_ROOT="$FIXTURE/program with = sign"
ROOT=$LOCAL_RUNNER_ROOT
mkdir -p "$ROOT/bin" "$ROOT/conf" "$ROOT/runner/failed-registration/runner/app" "$FIXTURE/work/jobs" "$FIXTURE/work/logs" "$FIXTURE/commands"
cp "$REPO/linux/ghr.sh" "$REPO/linux/service.sh" "$ROOT/bin/"
command -v jq > "$ROOT/conf/jq-path"
printf '/bin/false\n' > "$ROOT/conf/gh-path"
jq -n --arg work "$FIXTURE/work" '{platform:"linux",arch:"x64",work_dir:$work,stop_seconds:1}' > "$ROOT/conf/settings.json"
. "$ROOT/bin/ghr.sh"
init control
# This test isolates the systemd boundary. Real Linux locks are exercised by the
# root container suite; do not acquire macOS shlock while simulating Linux here.
wait_for_lock() { :; }
service_identity() { SERVICE_NAME=local-github-runner-fixture.service; DEFINITION=$FIXTURE/unit.service; }
privileged() { "$@"; }
systemctl() {
    local argument property=${4:-}
    printf '%s\n' "$*" >> "$FIXTURE/systemctl-calls"
    # systemd 219 does not accept the modern show --value option.
    for argument in "$@"; do
        case "$argument" in --value|--now) printf 'systemctl: unrecognized option %s\n' "$argument" >&2; return 1 ;; esac
    done
    case "$1" in
        show)
            if [ -f "$FIXTURE/bus-error" ]; then echo 'Failed to connect to bus' >&2; return 1; fi
            case "$property" in
                WorkingDirectory) printf 'WorkingDirectory=%s\n' "$ROOT" ;;
                FragmentPath) printf 'FragmentPath=%s\n' "$FIXTURE/unit.service" ;;
                ActiveState) if [ -f "$FIXTURE/active" ]; then echo ActiveState=active; else echo ActiveState=inactive; fi ;;
                LoadState) echo LoadState=loaded ;;
                MainPID) printf 'MainPID=%s\n' "${manager:-0}" ;;
                *) echo "Unexpected property: $property" >&2; return 94 ;;
            esac ;;
        stop)
            [ ! -f "$FIXTURE/refuse-stop" ] || return 0
            [ -z "$manager" ] || kill "$manager" 2>/dev/null || :
            rm -f "$FIXTURE/active" ;;
        disable) touch "$FIXTURE/disabled" ;;
        is-active) [ -f "$FIXTURE/active" ] ;;
        daemon-reload|enable|start) : ;;
        *) echo "Unexpected systemctl call: $*" >&2; return 94 ;;
    esac
}
touch "$FIXTURE/unit.service" "$FIXTURE/active"
sleep 120 & manager=$!
record_pid "$ROOT/conf/manager.pid" "$manager"
result=0; command_main stop > "$FIXTURE/stop-output" 2>&1 || result=$?
release_control_lock
trap cleanup EXIT
if [ "$result" != 0 ]; then
    cat "$FIXTURE/stop-output" >&2
    printf 'FAIL: stop returned %s; output bytes=%s; manager still alive=' "$result" "$(wc -c < "$FIXTURE/stop-output" | tr -d ' ')" >&2
    if kill -0 "$manager" 2>/dev/null; then echo yes >&2; else echo no >&2; fi
    exit 1
fi
wait "$manager" 2>/dev/null || :; manager=
assert test -f "$ROOT/conf/stopped"
assert test -f "$FIXTURE/disabled"
command_main status > "$FIXTURE/status"
assert grep -q -E '^Manager +stopped' "$FIXTURE/status"
# An unreadable native state or a stop that did nothing must be an explicit failure.
touch "$FIXTURE/bus-error"
if native_service stop > "$FIXTURE/bus-output" 2>&1; then echo 'Ignored systemd query failure' >&2; exit 1; fi
assert grep -q 'Failed to connect to bus' "$FIXTURE/bus-output"
rm "$FIXTURE/bus-error"
touch "$FIXTURE/active" "$FIXTURE/refuse-stop"
if native_service stop > "$FIXTURE/refuse-output" 2>&1; then echo 'Reported success while native service remained active' >&2; exit 1; fi
assert test -s "$FIXTURE/refuse-output"
rm "$FIXTURE/active" "$FIXTURE/refuse-stop"
# A failed identity lookup previously exited silently too. This fixture has no
# owner_uid, so the standalone CLI must stop before any real native command.
result=0; /bin/bash "$ROOT/bin/ghr.sh" stop > "$FIXTURE/cli-error" 2>&1 || result=$?
assert test "$result" != 0
assert grep -q 'ghr stop failed' "$FIXTURE/cli-error"
install_cli "$FIXTURE/commands/ghr"
# The bound sleep inhibitor unit goes with the supervisor.
touch "$FIXTURE/unit-awake.service"
command_main uninstall
assert grep -qx 'stop local-github-runner-fixture-awake.service' "$FIXTURE/systemctl-calls"
assert test ! -e "$FIXTURE/unit-awake.service"
trap cleanup EXIT
assert test ! -e "$FIXTURE/commands/ghr"
assert test ! -d "$ROOT/conf"
assert test ! -e "$FIXTURE/unit.service"
assert test -d "$FIXTURE/work/jobs"
assert test -d "$FIXTURE/work/logs"
success=true
printf 'PASS legacy systemd stop/status/uninstall and explicit native failures\n'
