#!/bin/bash
# One persistent organization runner, launched by service.sh.
. "${1:?installation root required}/bin/service.sh"
worker_loop() {
    local id=$1 login process_id
    safe_id "$id" || return 1
    login=$("$JQ" -r --arg id "$id" '.[$id].login // empty' "$ROOT/conf/organizations.json")
    safe_org "$login" || return 1
    stop_record "$ROOT/conf/children/$id.pid"
    trap 'stop_record "$ROOT/conf/children/$id.pid"' EXIT
    trap 'exit 0' TERM INT
    cd "$ROOT/runner/$login/app" || return 1
    while [ ! -f "$ROOT/conf/stopped" ]; do
        clean_exec /bin/bash ./run.sh >/dev/null 2>&1 &
        process_id=$!
        record_pid "$ROOT/conf/children/$id.pid" "$process_id" || :
        wait "$process_id" || :
        rm -f "$ROOT/conf/children/$id.pid"
        sleep "$RESTART" & wait $! || :
    done
}
umask 077
init || exit 1
worker_loop "${2:?organization ID required}"
