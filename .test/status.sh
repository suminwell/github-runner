#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/runner-status.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
for platform in linux macos; do
    export LOCAL_RUNNER_ROOT=$fixture/$platform
    ROOT=$LOCAL_RUNNER_ROOT
    mkdir -p "$ROOT/conf"
    command -v jq > "$ROOT/conf/jq-path"
    printf '/usr/bin/false\n' > "$ROOT/conf/gh-path"
    old_work=$fixture/"old work $platform"; new_work=$fixture/"new work $platform"
    jq -n --arg work "$new_work" '{arch:"arm64",work_dir:$work}' > "$ROOT/conf/settings.json"
    . "$repo/$platform/service.sh"
    init control
    record_pid "$ROOT/conf/manager.pid" "$$"
    record_pid "$ROOT/conf/children/1.pid" "$$"
    record_pid "$ROOT/conf/workers/2.pid" "$$"
    printf '%s\n' "$old_work" > "$ROOT/conf/active-work-dir"
    jq -n --arg name "$PREFIX-1" '{"1":{login:"alpha",runner_id:101,runner_name:$name},"2":{login:"beta",runner_id:102,runner_name:$name},"3":{login:"gamma",runner_id:103,runner_name:$name,active:false},"4":{login:"denied",runner_id:104,runner_name:$name}}' > "$ROOT/conf/organizations.json"
    deny=true
    list_runners() {
        case "$1" in
            alpha) jq -n --arg name "$PREFIX-1" '[{id:101,name:$name,status:"online",busy:true}]' ;;
            beta) jq -n --arg name "$PREFIX-1" '[{id:102,name:$name,status:"offline",busy:false}]' ;;
            gamma) jq -n --arg name "$PREFIX-1" '[{id:999,name:$name,status:"online",busy:false}]' ;;
            denied) if $deny; then return 1; else printf '[]\n'; fi ;;
            *) return 2 ;;
        esac
    }
    before=$(cat "$ROOT/conf/organizations.json")
    result=0; status > "$fixture/report" || result=$?
    assert test "$result" = 1
    assert grep -Fq "Manager: running (PID $$)" "$fixture/report"
    assert grep -Fxq "Install directory: $ROOT" "$fixture/report"
    assert grep -Fxq "Data directory: $old_work/data" "$fixture/report"
    assert grep -Fxq "Logs directory: $old_work/logs" "$fixture/report"
    assert grep -Fq "Configuration: pending; next start uses $new_work/data" "$fixture/report"
    assert grep -Eq '^alpha +[^ ]+ +online +true +running +[0-9]+$' "$fixture/report"
    assert grep -Eq '^beta +[^ ]+ +offline +false +restarting +[0-9]+$' "$fixture/report"
    assert grep -Eq '^gamma +[^ ]+ +missing +- +paused +-$' "$fixture/report"
    assert grep -Eq '^denied +[^ ]+ +unknown +\? +stopped +-$' "$fixture/report"
    assert grep -Fxq 'GitHub: 1 online, 1 offline, 1 missing, 1 unknown; 1 busy' "$fixture/report"
    assert grep -Fxq 'Local: 1 running, 1 restarting, 2 stopped/paused' "$fixture/report"
    assert test "$(cat "$ROOT/conf/organizations.json")" = "$before"
    deny=false
    rm "$ROOT/conf/manager.pid"
    touch "$ROOT/conf/stopped"
    status > "$fixture/report"
    assert grep -Fxq 'Manager: stopped (run ghr start to resume)' "$fixture/report"
    assert grep -Fq "$old_work (last run; manager stopped)" "$fixture/report"
    record_pid "$ROOT/conf/manager.pid" "$$"
    rm "$ROOT/conf/stopped"
    printf '%s\n' "$new_work" > "$ROOT/conf/active-work-dir"
    status > "$fixture/report"
    assert grep -Fxq "Data directory: $new_work/data" "$fixture/report"
    assert grep -Fxq 'Configuration: no pending directory change' "$fixture/report"
    printf '{}\n' > "$ROOT/conf/organizations.json"
    rm "$ROOT/conf/manager.pid" "$ROOT/conf/active-work-dir"
    status > "$fixture/report"
    assert grep -Fq 'configured; not started yet' "$fixture/report"
    assert grep -Fq 'No runners registered yet.' "$fixture/report"
    assert grep -Fxq 'Organizations: 0' "$fixture/report"
    printf 'PASS %s status: directories, pending config, process states and GitHub results\n' "$platform"
done
