#!/bin/bash
# Windows host-task bridge and foreground WSL keepalive. No runner credentials cross this bridge.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command=${1:-status}
shift || :
if [ "$command" = hold ]; then
    # A foreground wsl.exe process keeps the distribution alive; systemd owns the runners.
    # Do not enable/start services here: a saved ghr stop must survive Windows reboots.
    [ -f "$ROOT/conf/settings.json" ] && [ ! -f "$ROOT/conf/stopped" ] || exit 0
    exec 8> "$ROOT/conf/wsl-host.lock"
    flock -n 8 || exit 0
    while [ -f "$ROOT/conf/settings.json" ] && [ ! -f "$ROOT/conf/stopped" ]; do sleep 5; done
    exit 0
fi
JQ=$(cat "$ROOT/conf/jq-path")
metadata=$ROOT/conf/wsl-host.json
case "$command" in
    setup)
        [ "$#" -eq 0 ] || exit 2
        if [ -f "$metadata" ]; then
            powershell=$("$JQ" -er .powershell "$metadata")
            distro=$("$JQ" -er .distribution "$metadata")
        else
            powershell=$(command -v powershell.exe || :)
            distro=${WSL_DISTRO_NAME:-}
        fi
        if [ -z "$powershell" ] || [ -z "$distro" ] || ! command -v wslpath >/dev/null; then
            echo 'Run ghr wsl setup inside the target WSL distribution with Windows interoperability and powershell.exe on PATH enabled.' >&2
            exit 1
        fi
        script=$(wslpath -w "$ROOT/bin/wsl.ps1")
        "$powershell" -NoProfile -ExecutionPolicy Bypass -File "$script" -Action Install -Distribution "$distro" -LinuxUser "$(id -un)" -InstallRoot "$ROOT"
        ;;
    describe)
        [ "$#" -eq 0 ] || exit 2
        stopped=false; [ ! -f "$ROOT/conf/stopped" ] || stopped=true
        "$JQ" -e --arg root "$ROOT" --arg user "$(id -un)" --argjson uid "$(id -u)" --argjson stopped "$stopped" \
            'select(.platform=="linux" and .owner_uid==$uid) | {root:$root,user:$user,uid:$uid,arch:.arch,stopped:$stopped}' "$ROOT/conf/settings.json"
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
        powershell=$("$JQ" -er .powershell "$metadata")
        distro=$("$JQ" -er .distribution "$metadata")
        user=$("$JQ" -er .user "$metadata")
        script=$(wslpath -w "$ROOT/bin/wsl.ps1")
        if ! "$powershell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" \
            -Action "$command" -Distribution "$distro" -LinuxUser "$user" -InstallRoot "$ROOT"; then
            printf 'WSL host task %s failed. Check Windows interoperability and run ghr wsl setup inside this distribution to repair the task.\n' "$command" >&2
            exit 1
        fi
        ;;
    *) echo 'Usage: wsl.sh setup|hold|describe|link|start|stop|remove|status' >&2; exit 2 ;;
esac
