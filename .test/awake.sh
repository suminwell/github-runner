#!/bin/bash
# macOS awake guard: holds SleepDisabled only while the manager lives, never takes over an
# owner's own setting, shares it between installations, and releases on any stop.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-sleep.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
success=false; pids=()
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; done
    if $success; then rm -rf "$FIXTURE"; else printf 'Retained fixture: %s\n' "$FIXTURE"; fi
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { "$@" || fail "$*"; }
# A pmset that keeps SleepDisabled in a file and logs every change it is asked for.
cat > "$FIXTURE/pmset" <<'PMSET'
#!/bin/bash
case "$*" in
    -g) printf 'System-wide power settings:\n SleepDisabled\t\t%s\n' "$(cat "$PMSET_STATE")" ;;
    '-a disablesleep 1'|'-a disablesleep 0') printf '%s\n' "${3}" > "$PMSET_STATE"; printf '%s\n' "$*" >> "$PMSET_STATE.calls" ;;
    *) exit 1 ;;
esac
PMSET
chmod +x "$FIXTURE/pmset"
export LOCAL_RUNNER_PMSET=$FIXTURE/pmset PMSET_STATE=$FIXTURE/sleep-disabled
export LOCAL_RUNNER_AWAKE_OWNERS=$FIXTURE/owners LOCAL_RUNNER_AWAKE_INTERVAL=0.2
GUARD=$REPO/macos/awake.sh
state() { cat "$PMSET_STATE"; }
state_is() { [ "$(state)" = "$1" ]; }
calls() { cat "$PMSET_STATE.calls" 2>/dev/null || :; }
# A manager stand-in with the same PID record format as service.sh.
manager() {
    sleep 300 & local pid=$!; pids+=("$pid")
    printf '%s\n%s\n' "$pid" "$(LC_ALL=C ps -p "$pid" -o lstart= | awk '{$1=$1; print}')" > "$FIXTURE/$1.pid"
    eval "$1=$pid"
}
until_true() { local i=0; until "$@"; do i=$((i+1)); [ "$i" -lt 50 ] || return 1; sleep 0.1; done; }
guard() { /bin/bash "$GUARD" run "$FIXTURE/$1.pid" "$2" & pids+=("$!"); eval "$3=$!"; }
# 1. Sleep comes back only after the manager is gone, however it stopped.
printf '0\n' > "$PMSET_STATE"
manager alpha
guard alpha svc.a guard_a
until_true state_is 1 || fail 'sleep not disabled while the manager runs'
assert test -f "$FIXTURE/owners/svc.a"
kill -9 "$alpha"; wait "$alpha" 2>/dev/null || :
until_true state_is 0 || fail 'sleep not restored after the manager was killed'
assert test ! -e "$FIXTURE/owners/svc.a"
# A PID record whose start time does not match is not this manager.
sleep 300 & pids+=("$!"); printf '%s\nMon Jan  1 00:00:00 2001\n' "$!" > "$FIXTURE/alpha.pid"
sleep 1; assert test "$(state)" = 0
# Stopping the guard (uninstall, reinstall, shutdown) releases as well.
manager alpha
until_true state_is 1 || fail 'sleep not disabled after the manager returned'
kill -TERM "$guard_a"; wait "$guard_a" 2>/dev/null || :
assert test "$(state)" = 0
assert test ! -e "$FIXTURE/owners/svc.a"
# 2. A Mac whose owner already disabled sleep is left exactly as it was.
printf '1\n' > "$PMSET_STATE"; : > "$PMSET_STATE.calls"
guard alpha svc.a guard_a
sleep 1
kill -TERM "$guard_a"; wait "$guard_a" 2>/dev/null || :
assert test "$(state)" = 1
assert test -z "$(calls)"
assert test ! -e "$FIXTURE/owners/svc.a"
# 3. Two installations share it: sleep returns only when the last one lets go.
printf '0\n' > "$PMSET_STATE"
manager beta
guard alpha svc.a guard_a; guard beta svc.b guard_b
until_true test -f "$FIXTURE/owners/svc.a" -a -f "$FIXTURE/owners/svc.b" || fail 'both installations hold sleep'
kill -9 "$alpha"; wait "$alpha" 2>/dev/null || :
until_true test ! -e "$FIXTURE/owners/svc.a" || fail 'first installation did not let go'
sleep 0.5; assert test "$(state)" = 1
# A guard killed outright leaves its hold; the uninstall release still returns sleep.
kill -9 "$guard_b"; wait "$guard_b" 2>/dev/null || :
assert test "$(state)" = 1
/bin/bash "$GUARD" release svc.b
assert test "$(state)" = 0
kill -TERM "$guard_a"; wait "$guard_a" 2>/dev/null || :
# Release without a hold changes nothing; names cannot reach outside the owners directory.
: > "$PMSET_STATE.calls"
/bin/bash "$GUARD" release svc.none
assert test -z "$(calls)"
if /bin/bash "$GUARD" release ../escape 2>/dev/null; then fail 'accepted a path as a service name'; fi
# 4. ghr status reports the guard for this installation.
export LOCAL_RUNNER_ROOT=$FIXTURE/root LOCAL_RUNNER_LAUNCH_DAEMONS=$FIXTURE/daemons LOCAL_RUNNER_AWAKE_HELPERS=$FIXTURE/helpers
mkdir -p "$LOCAL_RUNNER_ROOT/conf" "$LOCAL_RUNNER_LAUNCH_DAEMONS" "$LOCAL_RUNNER_AWAKE_HELPERS"
command -v jq > "$LOCAL_RUNNER_ROOT/conf/jq-path"; printf '/usr/bin/false\n' > "$LOCAL_RUNNER_ROOT/conf/gh-path"
printf '{"arch":"arm64","owner_uid":501}\n' > "$LOCAL_RUNNER_ROOT/conf/settings.json"
. "$REPO/macos/service.sh"
init control
name=com.suminwell.github-runner.501.arm64
assert test "$(sleep_prevention stopped)" = 'not set up; run the installer again'
: > "$LOCAL_RUNNER_LAUNCH_DAEMONS/$name.awake.plist"
assert test "$(sleep_prevention stopped)" = 'released while the manager is stopped'
: > "$FIXTURE/owners/$name"
assert test "$(sleep_prevention running)" = 'on; stays awake with the lid closed'
printf '{"arch":"arm64","owner_uid":501,"prevent_sleep":false}\n' > "$LOCAL_RUNNER_ROOT/conf/settings.json"
assert test "$(sleep_prevention running)" = 'off (LOCAL_RUNNER_PREVENT_SLEEP=no)'
# 5. Uninstall stops the guard, gives sleep back and deletes both guard files.
. "$REPO/macos/ghr.sh"
privileged() { "$@"; }
launchctl() { printf '%s\n' "$*" >> "$FIXTURE/launchctl"; }
SERVICE_NAME=$name
cp "$GUARD" "$LOCAL_RUNNER_AWAKE_HELPERS/$name.awake.sh"
printf '1\n' > "$PMSET_STATE"
remove_awake_guard
assert grep -qx "bootout system/$name.awake" "$FIXTURE/launchctl"
assert test "$(state)" = 0
assert test ! -e "$FIXTURE/owners/$name" -a ! -e "$LOCAL_RUNNER_AWAKE_HELPERS/$name.awake.sh" -a ! -e "$LOCAL_RUNNER_LAUNCH_DAEMONS/$name.awake.plist"
remove_awake_guard
remove_awake_guard
success=true
printf 'PASS macOS awake guard: lifecycle-bound, owner setting kept, shared between installations, status\n'
