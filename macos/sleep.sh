#!/bin/bash
# Keeps the Mac awake, also with the lid closed, while this installation's manager runs.
# Idle-sleep assertions (caffeinate) do not survive closing the lid; only the system-wide
# SleepDisabled setting does, and it needs root, so launchd runs this file as root from a
# root-owned copy. It reads nothing from the installation but the manager's PID record.
#   sleep.sh run <manager.pid> <service name>   hold while the manager lives, release otherwise
#   sleep.sh release <service name>             release now (uninstall, prevent_sleep off)
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PMSET=${LOCAL_RUNNER_PMSET:-pmset}
OWNERS=${LOCAL_RUNNER_SLEEP_OWNERS:-/Library/Application Support/com.suminwell.github-runner/sleep}
INTERVAL=${LOCAL_RUNNER_SLEEP_INTERVAL:-5}
safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
disabled() { [ "$("$PMSET" -g 2>/dev/null | awk '$1=="SleepDisabled" {print $2}')" = 1 ]; }
owned() { [ -n "$(ls -A "$OWNERS" 2>/dev/null)" ]; }
alive() {
    local pid stamp
    { IFS= read -r pid && IFS= read -r stamp; } < "$1" 2>/dev/null || return 1
    [[ $pid =~ ^[0-9]+$ ]] && [ -n "$stamp" ] || return 1
    [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')" = "$stamp" ]
}
# Each installation that disabled sleep leaves a mark. A Mac whose sleep was already
# disabled by its owner has no mark, and that setting is never touched.
hold() {
    if [ ! -f "$OWNERS/$1" ]; then
        if disabled && ! owned; then return 0; fi
        mkdir -p "$OWNERS" && : > "$OWNERS/$1" || return 1
    fi
    disabled || "$PMSET" -a disablesleep 1
}
# Sleep comes back only when the last installation holding it lets go.
release() {
    [ -f "$OWNERS/$1" ] || return 0
    rm -f "$OWNERS/$1"
    owned || "$PMSET" -a disablesleep 0
}
case "${1:-}" in
    run)
        [ "$#" -eq 3 ] && safe_name "$3" || { echo 'Usage: sleep.sh run <manager.pid> <service name>' >&2; exit 2; }
        trap 'release "$3"; exit 0' TERM INT HUP
        while :; do
            if alive "$2"; then hold "$3"; else release "$3"; fi
            sleep "$INTERVAL" & wait $!
        done ;;
    release)
        [ "$#" -eq 2 ] && safe_name "$2" || { echo 'Usage: sleep.sh release <service name>' >&2; exit 2; }
        release "$2" ;;
    *) echo 'Usage: sleep.sh run <manager.pid> <service name> | release <service name>' >&2; exit 2 ;;
esac
