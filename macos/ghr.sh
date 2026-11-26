#!/bin/bash
# User-facing management commands; runtime functions stay in service.sh.
GH_RUNNER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$GH_RUNNER_DIR/service.sh"
usage() {
    cat <<'HELP'
ghr status: 获取runner状态
ghr start: 启动runner
ghr stop: 停止runner
ghr restart: 重启runner
ghr logs [-f]: 查询日志，-f是跟踪最新日志
ghr config --dir [<PATH>]: 设置data和logs的父目录，默认为当前目录，重启后生效（--dir 可简写为 -d）
ghr uninstall: 卸载runner
HELP
}
privileged() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
cli_contents() {
    printf '#!/bin/bash\n# ghr: %s\nunset LOCAL_RUNNER_ROOT\n' "$ROOT"
    printf 'exec /bin/bash %q "$@"\n' "$ROOT/bin/ghr.sh"
}
install_cli() {
    local destination=${1:-/usr/local/bin/ghr} temporary
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ ! -L "$destination" ] && grep -Fqx "# ghr: $ROOT" "$destination" || { printf 'Another installation owns %s\n' "$destination" >&2; return 1; }
    fi
    temporary=$(mktemp "$ROOT/conf/command.XXXXXX") || return 1
    cli_contents > "$temporary"
    privileged mkdir -p "$(dirname "$destination")" && privileged install -m 755 "$temporary" "$destination" || { rm -f "$temporary"; return 1; }
    rm -f "$temporary"
    "$JQ" --arg path "$destination" '.command_path=$path' "$ROOT/conf/settings.json" | atomic "$ROOT/conf/settings.json"
}
service_identity() {
    OWNER_UID=$("$JQ" -er '.owner_uid' "$ROOT/conf/settings.json") || return 1
    safe_id "$OWNER_UID" || return 1
    if [ "$OS" = linux ]; then SERVICE_NAME=local-github-runner-$OWNER_UID-$ARCH.service; DEFINITION=/etc/systemd/system/$SERVICE_NAME;
    else SERVICE_NAME=com.suminwell.github-runner.$OWNER_UID.$ARCH; DEFINITION=/Library/LaunchDaemons/$SERVICE_NAME.plist; fi
}
native_service() {
    local action=$1 installed_root command_path
    service_identity || return 1
    if [ "$OS" = linux ]; then
        if [ -f "$DEFINITION" ]; then
            installed_root=$(systemctl show "$SERVICE_NAME" -p WorkingDirectory --value 2>/dev/null) || return 1
            [ "$installed_root" = "$ROOT" ] || { printf 'Another installation owns %s\n' "$SERVICE_NAME" >&2; return 1; }
            if [ "$action" = start ]; then privileged systemctl enable "$SERVICE_NAME" && privileged systemctl start "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; return $?; fi
            privileged systemctl disable --now "$SERVICE_NAME" || return 1
        elif [ "$action" = start ]; then printf 'Service definition missing; re-run the installer.\n' >&2; return 1
        elif systemctl is-active --quiet "$SERVICE_NAME"; then printf 'Service ownership cannot be verified.\n' >&2; return 1
        fi
        if [ "$action" = remove ]; then privileged rm -f "$DEFINITION" && privileged systemctl daemon-reload || return 1; fi
    else
        if [ -f "$DEFINITION" ]; then
            command_path=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$DEFINITION") || return 1
            [ "$command_path" = "$ROOT/bin/service.sh" ] || { printf 'Another installation owns %s\n' "$SERVICE_NAME" >&2; return 1; }
            if [ "$action" = start ]; then
                privileged launchctl enable "system/$SERVICE_NAME" || return 1
                if ! privileged launchctl print "system/$SERVICE_NAME" >/dev/null 2>&1; then privileged launchctl bootstrap system "$DEFINITION" || return 1; fi
                privileged launchctl kickstart "system/$SERVICE_NAME"; return $?
            fi
            privileged launchctl disable "system/$SERVICE_NAME" || return 1
            if privileged launchctl print "system/$SERVICE_NAME" >/dev/null 2>&1; then privileged launchctl bootout "system/$SERVICE_NAME" || return 1; fi
        elif [ "$action" = start ]; then printf 'Service definition missing; re-run the installer.\n' >&2; return 1; fi
        if [ "$action" = remove ]; then privileged rm -f "$DEFINITION" || return 1; fi
    fi
}
stop_processes() {
    local record
    stop_record "$ROOT/conf/manager.pid"
    acquire_lock || { printf 'Manager is still running.\n' >&2; return 1; }
    trap 'if [ "$OS" = macos ]; then rm -f "$ROOT/conf/service.lock"; fi' EXIT
    for record in "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid; do [ ! -f "$record" ] || stop_record "$record"; done
}
stop_installation() {
    native_service stop || return 1
    printf 'stopped\n' | atomic "$ROOT/conf/stopped" || return 1
    stop_processes || return 1
    printf 'Runner stopped; automatic startup disabled. Run ghr start to resume.\n'
}
release_control_lock() {
    if [ "$OS" = macos ]; then rm -f "$ROOT/conf/service.lock"; else exec 9>&-; fi
    trap - EXIT
}
start_installation() {
    # A start on an already-running manager must not activate pending configuration.
    if record_alive "$ROOT/conf/manager.pid"; then printf 'Runner already running. Use ghr restart to apply configuration.\n'; return 0; fi
    rm -f "$ROOT/conf/stopped" || return 1
    native_service start || { printf 'stopped\n' | atomic "$ROOT/conf/stopped"; return 1; }
    printf 'Runner started; automatic startup enabled.\n'
}
configure_directory() {
    local requested=${1:-.} absolute
    case "$requested" in ''|*'
'*) printf 'A nonempty directory path without newlines is required.\n' >&2; return 1 ;; esac
    mkdir -p "$requested" || return 1
    absolute=$(cd "$requested" && pwd -P) || return 1
    case "$absolute" in "$ROOT/bin"|"$ROOT/bin/"*|"$ROOT/conf"|"$ROOT/conf/"*|"$ROOT/runner"|"$ROOT/runner/"*) printf 'Data must be outside the program and state directories.\n' >&2; return 1 ;; esac
    mkdir -p "$absolute/data" "$absolute/logs" || return 1
    "$JQ" --arg directory "$absolute" '.work_dir=$directory' "$ROOT/conf/settings.json" | atomic "$ROOT/conf/settings.json" || return 1
    printf 'Work directory saved: %s\nRun ghr restart (or stop then start) to apply. Existing data and logs are not moved.\n' "$absolute"
}
show_logs() {
    local active=$WORK_DIR file
    [ ! -f "$ROOT/conf/active-work-dir" ] || active=$(cat "$ROOT/conf/active-work-dir")
    file=$active/logs/service.log
    if [ "${1:-}" = -f ]; then
        [ -f "$file" ] || touch "$file"
        tail -n 200 -F "$file"
    elif [ -f "$file" ]; then tail -n 200 "$file";
    else printf 'No logs yet.\n'; fi
}
unregister_runners() {
    local id login runner_id organization remote failed=0
    while IFS=$'\t' read -r id login runner_id; do
        safe_id "$id" && safe_id "$runner_id" && safe_org "$login" || { failed=1; continue; }
        # Resolve by immutable ID so an organization rename cannot redirect cleanup.
        if ! organization=$(api "organizations/$id"); then printf 'Cannot resolve organization %s; retained registration state.\n' "$login" >&2; failed=1; continue; fi
        login=$(printf '%s' "$organization" | "$JQ" -er --argjson id "$id" 'select(.id==$id)|.login') || { failed=1; continue; }
        safe_org "$login" || { failed=1; continue; }
        if ! remote=$(list_runners "$login"); then printf 'Cannot query %s; retained registration state.\n' "$login" >&2; failed=1; continue; fi
        if printf '%s' "$remote" | "$JQ" -e --argjson id "$runner_id" 'any(.[]; .id==$id)' >/dev/null; then
            if ! api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null; then printf 'Cannot unregister %s/%s; retry uninstall.\n' "$login" "$runner_id" >&2; failed=1; continue; fi
        fi
        "$JQ" --arg id "$id" 'del(.[$id])' "$ROOT/conf/organizations.json" | atomic "$ROOT/conf/organizations.json" || return 1
    done < <("$JQ" -r 'to_entries[]|[.key,.value.login,.value.runner_id]|@tsv' "$ROOT/conf/organizations.json")
    return "$failed"
}
uninstall() {
    local command_path
    stop_installation || return 1
    unregister_runners || { printf 'Uninstall incomplete. State and credentials retained; run ghr uninstall again.\n' >&2; return 1; }
    native_service remove || return 1
    command_path=$("$JQ" -r '.command_path // empty' "$ROOT/conf/settings.json")
    if [ -n "$command_path" ] && [ -e "$command_path" ]; then
        [ ! -L "$command_path" ] && grep -Fqx "# ghr: $ROOT" "$command_path" || { printf 'Command ownership changed; refusing removal.\n' >&2; return 1; }
        privileged rm -f "$command_path" || return 1
    fi
    rm -rf "$ROOT/runner" "$ROOT/bin" "$ROOT/conf" || return 1
    rm -f "$ROOT/bin/install.sh" "$ROOT/bin/service.sh" "$ROOT/bin/ghr.sh" || return 1
    printf 'Runner uninstalled. Data and logs retained in their original directories. Configured directory: %s\n' "$WORK_DIR"
}
command_main() {
    local command=${1:-help}; [ "$#" -eq 0 ] || shift
    case "$command" in
        --install-command) [ "$#" -eq 0 ] || return 2; install_cli ;;
        config)
            if [ "$#" -eq 0 ]; then configure_directory .;
            elif [ "$#" -le 2 ] && { [ "$1" = --dir ] || [ "$1" = -d ]; }; then configure_directory "${2:-.}";
            else usage >&2; return 2; fi ;;
        logs) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = -f ]; } || { usage >&2; return 2; }; show_logs "${1:-}" ;;
        status|start|stop|restart|uninstall|help|--help|-h)
            [ "$#" -eq 0 ] || { usage >&2; return 2; }
            case "$command" in status) status ;; start) start_installation ;; stop) stop_installation ;; restart) stop_installation && release_control_lock && start_installation ;; uninstall) uninstall ;; *) usage ;; esac ;;
        *) usage >&2; return 2 ;;
    esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    init control || exit 1
    command_main "$@"
fi
