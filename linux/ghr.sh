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
ghr wsl setup: 在WSL内配置或修复Windows未登录时的自动启动
HELP
}
privileged() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
# Another installation on this host may share the Docker mode image, so it is kept.
docker_hint() {
    local image
    image=$("$JQ" -r 'select(.runtime=="docker") | .docker_image // empty' "$ROOT/conf/settings.json" 2>/dev/null) || return 0
    [ -z "$image" ] || printf 'Docker image %s and Docker itself were kept; remove the image with docker rmi %s when unused.\n' "$image" "$image"
}
wsl_host() { [ ! -f "$ROOT/bin/wsl.sh" ] || /bin/bash "$ROOT/bin/wsl.sh" "$1"; }
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
    jq_update "$ROOT/conf/settings.json" --arg path "$destination" '.command_path=$path'
}
service_identity() {
    OWNER_UID=$("$JQ" -er '.owner_uid' "$ROOT/conf/settings.json") || return 1
    safe_id "$OWNER_UID" || return 1
    if [ "$OS" = linux ]; then SERVICE_NAME=local-github-runner-$OWNER_UID-$ARCH.service; DEFINITION=/etc/systemd/system/$SERVICE_NAME;
    else SERVICE_NAME=com.suminwell.github-runner.$OWNER_UID.$ARCH; DEFINITION=/Library/LaunchDaemons/$SERVICE_NAME.plist; fi
}
systemd_property() (
    property_unit=$1; property_name=$2
    property_output=$(privileged systemctl show "$property_unit" -p "$property_name" --all) || {
        printf 'Cannot read systemd property %s for %s.\n' "$property_name" "$property_unit" >&2; exit 1;
    }
    case "$property_output" in
        "$property_name="*) printf '%s\n' "${property_output#*=}" ;;
        *) printf 'Missing systemd property %s for %s.\n' "$property_name" "$property_unit" >&2; exit 1 ;;
    esac
)
native_service() {
    local action=$1 installed_root command_path state
    service_identity || return 1
    if [ "$OS" = linux ]; then
        if [ -f "$DEFINITION" ]; then
            installed_root=$(systemd_property "$SERVICE_NAME" WorkingDirectory) || return 1
            [ "$installed_root" = "$ROOT" ] || { printf 'Another installation owns %s\n' "$SERVICE_NAME" >&2; return 1; }
            if [ "$action" = start ]; then privileged systemctl enable "$SERVICE_NAME" && privileged systemctl start "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; return $?; fi
            privileged systemctl disable "$SERVICE_NAME" && privileged systemctl stop "$SERVICE_NAME" || {
                printf 'Failed to stop %s; operation incomplete.\n' "$SERVICE_NAME" >&2; return 1;
            }
            state=$(systemd_property "$SERVICE_NAME" ActiveState) || return 1
            case "$state" in inactive|failed) ;; *) printf 'Service %s did not stop (state: %s).\n' "$SERVICE_NAME" "$state" >&2; return 1 ;; esac
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
    stop_record "$STATE/manager.pid"
    wait_for_lock || { printf 'Manager is still running.\n' >&2; return 1; }
    trap 'if [ "$OS" = macos ]; then rm -f "$STATE/service.lock"; fi' EXIT
    stop_records "$STATE"/workers/*.pid "$STATE"/children/*.pid "$STATE"/timeouts/*.pid
}
stop_installation() {
    native_service stop || return 1
    printf 'stopped\n' | atomic "$ROOT/conf/stopped" || return 1
    stop_processes || return 1
    wsl_host stop || return 1
    printf 'Runner stopped; automatic startup disabled. Run ghr start to resume.\n'
}
release_control_lock() {
    if [ "$OS" = macos ]; then rm -f "$STATE/service.lock"; else exec 9>&-; fi
    trap - EXIT
}
start_installation() {
    # A start on an already-running manager must not activate pending configuration.
    if record_alive "$STATE/manager.pid"; then wsl_host start || return 1; printf 'Runner already running. Use ghr restart to apply configuration.\n'; return 0; fi
    rm -f "$ROOT/conf/stopped" || return 1
    native_service start || { printf 'stopped\n' | atomic "$ROOT/conf/stopped"; return 1; }
    wsl_host start || return 1
    printf 'Runner started; automatic startup enabled.\n'
}
configure_directory() {
    local requested=${1:-.} absolute program_root
    case "$requested" in ''|*'
'*) printf 'A nonempty directory path without newlines is required.\n' >&2; return 1 ;; esac
    mkdir -p "$requested" || return 1
    absolute=$(cd "$requested" && pwd -P) || return 1
    program_root=$(cd "$ROOT" && pwd -P) || return 1
    case "$absolute" in "$program_root/bin"|"$program_root/bin/"*|"$program_root/conf"|"$program_root/conf/"*|"$program_root/runner"|"$program_root/runner/"*) printf 'Data must be outside the program and state directories.\n' >&2; return 1 ;; esac
    mkdir -p "$absolute/data" "$absolute/logs" || return 1
    jq_update "$ROOT/conf/settings.json" --arg directory "$absolute" '.work_dir=$directory' || return 1
    printf 'Work directory saved: %s\nRun ghr restart (or stop then start) to apply. Existing data and logs are not moved.\n' "$absolute"
}
show_logs() {
    local active=$WORK_DIR file
    [ ! -f "$STATE/active-work-dir" ] || active=$(cat "$STATE/active-work-dir")
    file=$active/logs/service.log
    if [ "${1:-}" = -f ]; then
        [ -f "$file" ] || touch "$file"
        tail -n 200 -F "$file"
    elif [ -f "$file" ]; then tail -n 200 "$file";
    else printf 'No logs yet.\n'; fi
}
unregister_untracked_runners() {
    # A registration can finish before save_entry. Its official metadata remains the
    # ownership evidence until the entire uninstall succeeds, including retry failures.
    local config directory runner_id name login organization id remote targets failed=0
    "$JQ" -e 'type=="object" and all(to_entries[]; (.key|test("^[1-9][0-9]*$")) and (.value|type=="object") and (.value.login|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")) and (.value.runner_id|type=="number" and .>0 and floor==.))' "$STATE/organizations.json" >/dev/null || { printf 'Invalid registration state; retained installation for repair.\n' >&2; return 1; }
    targets=$(mktemp "$STATE/unregister.XXXXXX") || return 1
    for config in "$ROOT"/runner/*/app/.runner; do
        [ -e "$config" ] || [ -L "$config" ] || continue
        directory=${config%/app/.runner}
        if [ -L "$ROOT/runner" ] || [ -L "$directory" ] || [ -L "$directory/app" ] || [ -L "$config" ]; then failed=1; break; fi
        runner_id=$("$JQ" -er '.agentId | select(type=="number" and .>0 and floor==.) | tostring' "$config") || { failed=1; break; }
        # A runner ID is scoped to its organization. The existing directory/state
        # pair supports older metadata; all other directories use the official URL.
        if "$JQ" -e '.gitHubUrl==null' "$config" >/dev/null && "$JQ" -e --arg login "${directory##*/}" --argjson runner_id "$runner_id" 'any(.[]; .login==$login and .runner_id==$runner_id)' "$STATE/organizations.json" >/dev/null; then continue; fi
        name=$("$JQ" -er '.agentName | select(type=="string")' "$config") || { failed=1; break; }
        if [ "$name" != "$PREFIX" ] && ! indexed_name "$name"; then failed=1; break; fi
        login=$("$JQ" -er '.gitHubUrl | capture("^https://github\\.com/(?<login>[A-Za-z0-9][A-Za-z0-9-]{0,38})/?$";"i") | .login' "$config") || { failed=1; break; }
        organization=$(api "orgs/$login") || { failed=1; break; }
        id=$(printf '%s' "$organization" | "$JQ" -er '.id | select(type=="number" and .>0 and floor==.) | tostring') || { failed=1; break; }
        login=$(printf '%s' "$organization" | "$JQ" -er '.login') || { failed=1; break; }
        safe_org "$login" || { failed=1; break; }
        if "$JQ" -e --arg id "$id" --argjson runner_id "$runner_id" '.[$id].runner_id==$runner_id' "$STATE/organizations.json" >/dev/null; then continue; fi
        remote=$(list_runners "$login") || { failed=1; break; }
        if ! printf '%s' "$remote" | "$JQ" -e --argjson id "$runner_id" 'any(.[]; .id==$id)' >/dev/null; then continue; fi
        printf '%s' "$remote" | "$JQ" -e --argjson id "$runner_id" --arg name "$name" '[.[]|select(.id==$id)] | length==1 and .[0].name==$name' >/dev/null || { failed=1; break; }
        if ! grep -Fqx "$login"$'\t'"$runner_id" "$targets"; then printf '%s\t%s\n' "$login" "$runner_id" >> "$targets"; fi
    done
    if [ "$failed" = 0 ]; then
        while IFS=$'\t' read -r login runner_id; do
            api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null || { failed=1; break; }
        done < "$targets"
    fi
    rm -f "$targets"
    [ "$failed" = 0 ] || { printf 'Cannot verify or unregister a local registration; retained metadata and credentials for retry.\n' >&2; return 1; }
}
unregister_runners() {
    local id login runner_id organization remote failed=0
    unregister_untracked_runners || return 1
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
        jq_update "$STATE/organizations.json" --arg id "$id" 'del(.[$id])' || return 1
    done < <("$JQ" -r 'to_entries[]|[.key,.value.login,.value.runner_id]|@tsv' "$STATE/organizations.json")
    return "$failed"
}
uninstall() {
    local command_path hint
    stop_installation || return 1
    unregister_runners || { printf 'Uninstall incomplete. State and credentials retained; run ghr uninstall again.\n' >&2; return 1; }
    native_service remove || return 1
    wsl_host remove || return 1
    command_path=$("$JQ" -r '.command_path // empty' "$ROOT/conf/settings.json")
    hint=$(docker_hint)
    if [ -n "$command_path" ] && [ -e "$command_path" ]; then
        [ ! -L "$command_path" ] && grep -Fqx "# ghr: $ROOT" "$command_path" || { printf 'Command ownership changed; refusing removal.\n' >&2; return 1; }
        privileged rm -f "$command_path" || return 1
    fi
    rm -rf "$ROOT/runner" "$ROOT/bin" "$ROOT/conf" || return 1
    printf 'Runner uninstalled. Data and logs retained in their original directories. Configured directory: %s\n' "$WORK_DIR"
    [ -z "$hint" ] || printf '%s\n' "$hint"
}
command_main() {
    local command=${1:-help}; [ "$#" -eq 0 ] || shift
    case "$command" in
        wsl) [ "$#" -eq 1 ] && [ "$1" = setup ] || { usage >&2; return 2; }; wsl_host setup ;;
        --install-command) [ "$#" -eq 0 ] || return 2; install_cli ;;
        config)
            if [ "$#" -eq 0 ]; then configure_directory .;
            elif [ "$#" -le 2 ] && { [ "$1" = --dir ] || [ "$1" = -d ]; }; then configure_directory "${2:-.}";
            else usage >&2; return 2; fi ;;
        logs) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = -f ]; } || { usage >&2; return 2; }; show_logs "${1:-}" ;;
        status|start|stop|restart|uninstall|help|--help|-h)
            [ "$#" -eq 0 ] || { usage >&2; return 2; }
            case "$command" in status) local result=0; status || result=$?; wsl_host status || result=1; return "$result" ;; start) start_installation ;; stop) stop_installation ;; restart) stop_installation && release_control_lock && start_installation ;; uninstall) uninstall ;; *) usage ;; esac ;;
        *) usage >&2; return 2 ;;
    esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    command_result=0
    if [ -f "$ROOT/bin/account.sh" ]; then
        . "$ROOT/bin/account.sh"
        account_command "$@" || command_result=$?
    else
        if init control; then command_main "$@" || command_result=$?;
        else printf 'Cannot load runner configuration: %s/conf\n' "$ROOT" >&2; command_result=1; fi
    fi
    # A root-mode command runs parts of itself as ghrunner; only the outer one reports.
    [ "$command_result" = 0 ] || [ -n "${GHR_NESTED:-}" ] || printf 'ghr %s failed (exit %s); operation incomplete.\n' "${1:-help}" "$command_result" >&2
    exit "$command_result"
fi
