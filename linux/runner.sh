#!/bin/bash
# One persistent organization runner, launched by service.sh.
. "${1:?installation root required}/bin/service.sh"
worker_loop() {
    local id=$1 log_file=${2:-} login process_id
    safe_id "$id" || return 1
    login=$("$JQ" -r --arg id "$id" '.[$id].login // empty' "$STATE/organizations.json")
    safe_org "$login" || return 1
    stop_record "$STATE/children/$id.pid"
    trap 'stop_record "$STATE/children/$id.pid"' EXIT
    trap 'exit 0' TERM INT
    cd "$ROOT/runner/$login/app" || return 1
    while [ ! -f "$ROOT/conf/stopped" ]; do
        # Reopen the manager's log each round so output follows log rotation.
        [ -z "$log_file" ] || exec >> "$log_file" 2>&1
        clean_exec /bin/bash ./run.sh >/dev/null 2>&1 &
        process_id=$!
        record_pid "$STATE/children/$id.pid" "$process_id" || :
        wait "$process_id" || :
        rm -f "$STATE/children/$id.pid"
        sleep "$RESTART" & wait $! || :
    done
}
umask 077
# The log path comes from the manager: pending work_dir changes must not apply here.
init control || exit 1
worker_loop "${2:?organization ID required}" "${3:-}"
