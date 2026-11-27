#!/bin/bash
# Windows host-task bridge and foreground WSL keepalive. No runner credentials cross this bridge.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
STATE=$ROOT/conf
[ ! -f "$ROOT/conf/account.json" ] || STATE=$ROOT/conf/runtime
command=${1:-status}
shift || :
if [ "$command" = hold ]; then
    # A foreground wsl.exe process keeps the distribution alive; systemd owns the runners.
    # Do not enable/start services here: a saved ghr stop must survive Windows reboots.
    [ -f "$ROOT/conf/settings.json" ] && [ ! -f "$ROOT/conf/stopped" ] || exit 0
    exec 8> "$STATE/wsl-host.lock"
    flock -n 8 || exit 0
    while [ -f "$ROOT/conf/settings.json" ] && [ ! -f "$ROOT/conf/stopped" ]; do sleep 5; done
    exit 0
fi
JQ=$(cat "$ROOT/conf/jq-path")
metadata=$STATE/wsl-host.json
linux_user=$(id -un)
if [ -f "$ROOT/conf/account.json" ]; then
    . "$ROOT/bin/account.sh"
    account_load
    linux_user=$account_user
fi
host_powershell() {
    # Runtime metadata is job-writable. An administrator never executes its paths.
    if [ -f "$ROOT/conf/account.json" ] && [ "$(id -u)" = 0 ]; then
        command -v powershell.exe || cat "$ROOT/conf/wsl-powershell" 2>/dev/null
    else "$JQ" -er .powershell "$metadata"; fi
}
case "$command" in
    setup)
        [ "$#" -eq 0 ] || exit 2
        if [ -f "$metadata" ]; then
            powershell=$(host_powershell)
            distro=$("$JQ" -er .distribution "$metadata")
        else
            if [ -f "$ROOT/conf/account.json" ] && [ "$(id -u)" = 0 ]; then powershell=$(host_powershell || :);
            else powershell=$(command -v powershell.exe || :); fi
            distro=${WSL_DISTRO_NAME:-}
        fi
        if [ -z "$powershell" ] || [ -z "$distro" ] || ! command -v wslpath >/dev/null; then
            echo 'Run ghr wsl setup inside the target WSL distribution with Windows interoperability and powershell.exe on PATH enabled.' >&2
            exit 1
        fi
        if [ -f "$ROOT/conf/account.json" ] && [ "$(id -u)" = 0 ]; then
            # sudo may remove Windows directories from PATH on later commands.
            printf '%s\n' "$powershell" > "$ROOT/conf/wsl-powershell.tmp.$$"
            chmod 600 "$ROOT/conf/wsl-powershell.tmp.$$"
            mv -f "$ROOT/conf/wsl-powershell.tmp.$$" "$ROOT/conf/wsl-powershell"
        fi
        script=$(wslpath -w "$ROOT/bin/wsl.ps1")
        "$powershell" -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Install -Distribution "$distro" -LinuxUser "$linux_user" -InstallRoot "$ROOT"
        ;;
    describe)
        [ "$#" -eq 0 ] || exit 2
        stopped=false; [ ! -f "$ROOT/conf/stopped" ] || stopped=true
        "$JQ" -e --arg root "$ROOT" --arg user "$(id -un)" --argjson uid "$(id -u)" --argjson stopped "$stopped" \
            'select(.platform=="linux" and .owner_uid==$uid) | {root:$root,user:$user,uid:$uid,arch:.arch,stopped:$stopped,prevent_sleep:(.prevent_sleep != false)}' "$ROOT/conf/settings.json"
        ;;
    link)
        [ "$#" -eq 4 ] || exit 2
        case "$4" in LocalGitHubRunner-WSL-*) ;; *) exit 2 ;; esac
        powershell=$(wslpath -u "$3")
        "$JQ" -n --arg distro "$1" --arg user "$2" --arg powershell "$powershell" --arg task "$4" \
            '{distribution:$distro,user:$user,powershell:$powershell,task_name:$task}' > "$metadata.tmp.$$"
        chmod 600 "$metadata.tmp.$$"
        mv -f "$metadata.tmp.$$" "$metadata"
        ;;
    start|stop|remove|status)
        [ "$#" -eq 0 ] || exit 2
        if [ ! -f "$metadata" ]; then
            if [ "$command" = status ] && { [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] || uname -r | grep -qi microsoft; }; then
                printf 'WSL host task: not configured; run ghr wsl setup inside this distribution.\n'
            fi
            exit 0
        fi
        powershell=$(host_powershell)
        distro=$("$JQ" -er .distribution "$metadata")
        user=$("$JQ" -er .user "$metadata")
        [ ! -f "$ROOT/conf/account.json" ] || [ "$user" = "$account_user" ] || { echo 'WSL runner account mismatch.' >&2; exit 1; }
        script=$(wslpath -w "$ROOT/bin/wsl.ps1")
        if ! "$powershell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" \
            -Action "$command" -Distribution "$distro" -LinuxUser "$user" -InstallRoot "$ROOT"; then
            printf 'WSL host task %s failed. Check Windows interoperability and run ghr wsl setup inside this distribution to repair the task.\n' "$command" >&2
            exit 1
        fi
        ;;
    *) echo 'Usage: wsl.sh setup|hold|describe|link|start|stop|remove|status' >&2; exit 2 ;;
esac
