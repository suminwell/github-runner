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
ghr config [--data-dir]: 显示jobs和logs的父目录
ghr config --data-dir <PATH>: 设置jobs和logs的父目录，路径必须是已存在的空目录，重启后生效
ghr runner: 显示每个组织的runner个数及本机上限（CPU核数的一半）
ghr runner -a|--add: 每个组织增加一个runner，无需重启，超过上限时报错
ghr runner -s|--sub: 每个组织减少一个runner，最少保留1个，多出的runner空闲后移除
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
    jq_update "$ROOT/conf/settings.json" --arg path "$destination" '.command_path=$path'
}
service_identity() {
    OWNER_UID=$("$JQ" -er '.owner_uid' "$ROOT/conf/settings.json") || return 1
    safe_id "$OWNER_UID" || return 1
    SERVICE_NAME=com.suminwell.github-runner.$OWNER_UID.$ARCH; DEFINITION=$LAUNCH_DAEMONS/$SERVICE_NAME.plist
}
native_service() {
    local action=$1
    service_identity || return 1
    if [ -f "$DEFINITION" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$DEFINITION")" = "$ROOT/bin/service.sh" ] || { printf 'Another installation owns %s\n' "$SERVICE_NAME" >&2; return 1; }
        if [ "$action" = start ]; then
            privileged launchctl enable "system/$SERVICE_NAME" || return 1
            if ! privileged launchctl print "system/$SERVICE_NAME" >/dev/null 2>&1; then privileged launchctl bootstrap system "$DEFINITION" || return 1; fi
            privileged launchctl kickstart "system/$SERVICE_NAME"; return $?
        fi
        privileged launchctl disable "system/$SERVICE_NAME" || return 1
        if privileged launchctl print "system/$SERVICE_NAME" >/dev/null 2>&1; then privileged launchctl bootout "system/$SERVICE_NAME" || return 1; fi
    elif [ "$action" = start ]; then printf 'Service definition missing; re-run the installer.\n' >&2; return 1; fi
    if [ "$action" = remove ]; then privileged rm -f "$DEFINITION" && remove_awake_guard || return 1; fi
}
# Stop the awake guard, give sleep back unless another installation still holds it, and
# delete the guard. Its own TERM handler releases too; the explicit release covers a guard
# that had already exited.
remove_awake_guard() {
    local name=$SERVICE_NAME.awake
    local script=$AWAKE_HELPERS/$name.sh definition=$LAUNCH_DAEMONS/$name.plist
    [ -f "$definition" ] || [ -f "$script" ] || return 0
    if privileged launchctl print "system/$name" >/dev/null 2>&1; then privileged launchctl bootout "system/$name" || return 1; fi
    if [ -f "$script" ]; then privileged /bin/bash "$script" release "$SERVICE_NAME" || return 1; fi
    privileged rm -f "$script" "$definition"
}
# The manager's shlock file is released when this command exits, as by the manager itself.
stop_processes() {
    stop_record "$ROOT/conf/manager.pid"
    wait_for_lock || { printf 'Manager is still running.\n' >&2; return 1; }
    trap 'rm -f "$ROOT/conf/service.lock"' EXIT
    stop_records "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid "$ROOT"/conf/timeouts/*.pid
}
stop_installation() {
    native_service stop || return 1
    printf 'stopped\n' | atomic "$ROOT/conf/stopped" || return 1
    stop_processes || return 1
    printf 'Runner stopped; automatic startup disabled. Run ghr start to resume.\n'
}
release_control_lock() { rm -f "$ROOT/conf/service.lock"; trap - EXIT; }
start_installation() {
    # A start on an already-running manager must not activate pending configuration.
    if record_alive "$ROOT/conf/manager.pid"; then printf 'Runner already running. Use ghr restart to apply configuration.\n'; return 0; fi
    rm -f "$ROOT/conf/stopped" || return 1
    native_service start || { printf 'stopped\n' | atomic "$ROOT/conf/stopped"; return 1; }
    printf 'Runner started; automatic startup enabled.\n'
}
# ghr config [--data-dir [<PATH>]]: full option names only. Sets CONFIG_VALUE (empty:
# show the setting).
config_arguments() {
    CONFIG_VALUE=
    [ "$#" -gt 0 ] || return 0
    [ "$1" = --data-dir ] && [ "$#" -le 2 ] || { usage >&2; return 2; }
    if [ "$#" = 2 ] && [ -z "$2" ]; then usage >&2; return 2; fi
    CONFIG_VALUE=${2:-}
}
show_config() { if [ "$#" = 0 ]; then printf '%-10s %s\n' data-dir "$WORK_DIR"; else printf '%s\n' "$WORK_DIR"; fi; }
# A new data directory must already exist and be empty: switching to a directory that
# holds other files would mix them with runner work data and logs.
config_directory() {
    local requested=$1 entries
    case "$requested" in *'
'*) printf 'Newlines are not supported in paths.\n' >&2; return 1 ;; esac
    [ -d "$requested" ] || { printf 'Data directory does not exist: %s\nCreate an empty directory first.\n' "$requested" >&2; return 1; }
    CONFIG_DIRECTORY=$(cd "$requested" && pwd -P) || return 1
    if [ "$CONFIG_DIRECTORY" = "$WORK_DIR" ]; then printf 'Already the data directory: %s\n' "$CONFIG_DIRECTORY" >&2; return 1; fi
    entries=$(ls -A -- "$CONFIG_DIRECTORY") || return 1
    [ -z "$entries" ] || { printf 'Data directory is not empty: %s\nChoose an empty directory.\n' "$CONFIG_DIRECTORY" >&2; return 1; }
}
config_saved() { printf 'Data directory saved: %s\nRun ghr restart (or stop then start) to apply. Existing data and logs are not moved.\n' "$CONFIG_DIRECTORY"; }
configure() {
    local program_root
    config_arguments "$@" || return $?
    if [ -z "$CONFIG_VALUE" ]; then show_config "$@"; return 0; fi
    config_directory "$CONFIG_VALUE" || return 1
    program_root=$(cd "$ROOT" && pwd -P) || return 1
    case "$CONFIG_DIRECTORY" in "$program_root/bin"|"$program_root/bin/"*|"$program_root/conf"|"$program_root/conf/"*|"$program_root/runner"|"$program_root/runner/"*) printf 'Data must be outside the program and state directories.\n' >&2; return 1 ;; esac
    mkdir -p "$CONFIG_DIRECTORY/jobs" "$CONFIG_DIRECTORY/logs" || return 1
    jq_update "$ROOT/conf/settings.json" --arg directory "$CONFIG_DIRECTORY" '.work_dir=$directory' || return 1
    config_saved
}
# ghr runner [-a|--add | -s|--sub]: one runner more or fewer for every organization, from
# 1 up to max_runners (half the CPUs). Sets RUNNER_CHANGE (empty: show the count).
runner_arguments() {
    RUNNER_CHANGE=
    case "$#:${1:-}" in
        0:) ;; 1:-a|1:--add) RUNNER_CHANGE=1 ;; 1:-s|1:--sub) RUNNER_CHANGE=-1 ;;
        *) usage >&2; return 2 ;;
    esac
}
show_runners() { printf 'Runners per organization: %s (maximum %s: %s CPUs / 2)\n' "$(runner_count)" "$(max_runners)" "$(cpu_count)"; }
# Sets RUNNER_FROM and RUNNER_TO, or explains why the change is refused.
runner_target() {
    local maximum
    RUNNER_FROM=$(runner_count) || return 1; maximum=$(max_runners) || return 1
    RUNNER_TO=$((RUNNER_FROM + RUNNER_CHANGE))
    if [ "$RUNNER_TO" -lt 1 ]; then printf 'Cannot remove a runner: every organization keeps at least 1.\n' >&2; return 1; fi
    if [ "$RUNNER_TO" -gt "$maximum" ]; then
        printf 'Cannot add a runner: %s per organization is the maximum on this machine (%s CPUs / 2).\n' "$maximum" "$(cpu_count)" >&2; return 1
    fi
}
runner_saved() {
    printf 'Runners per organization: %s -> %s\n' "$RUNNER_FROM" "$RUNNER_TO"
    if ! record_alive "$1"; then printf 'Applied when the runner starts (ghr start).\n'
    elif [ "$RUNNER_CHANGE" = 1 ]; then printf 'The running manager registers the new runners within a few seconds.\n'
    else printf 'The running manager removes the extra runners once they are idle; running jobs finish first.\n'; fi
}
manage_runners() {
    runner_arguments "$@" || return $?
    if [ -z "$RUNNER_CHANGE" ]; then show_runners; return 0; fi
    runner_target || return 1
    jq_update "$ROOT/conf/settings.json" --argjson count "$RUNNER_TO" '.runner_count=$count' || return 1
    runner_saved "$ROOT/conf/manager.pid"
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
unregister_untracked_runners() {
    # A registration can finish before save_entry. Its official metadata remains the
    # ownership evidence until the entire uninstall succeeds, including retry failures.
    local config directory runner_id name login organization id remote targets failed=0
    "$JQ" -e 'type=="object" and all(to_entries[]; (.key|test("^[1-9][0-9]*([.]([2-9]|[1-9][0-9]+))?$")) and (.value|type=="object") and (.value.login|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")) and (.value.runner_id|type=="number" and .>0 and floor==.))' "$ROOT/conf/organizations.json" >/dev/null || { printf 'Invalid registration state; retained installation for repair.\n' >&2; return 1; }
    targets=$(mktemp "$ROOT/conf/unregister.XXXXXX") || return 1
    for config in "$ROOT"/runner/*/*/app/.runner; do
        [ -e "$config" ] || [ -L "$config" ] || continue
        directory=${config%/app/.runner}
        if [ -L "$ROOT/runner" ] || [ -L "${directory%/*}" ] || [ -L "$directory" ] || [ -L "$directory/app" ] || [ -L "$config" ]; then failed=1; break; fi
        runner_id=$("$JQ" -er '.agentId | select(type=="number" and .>0 and floor==.) | tostring' "$config") || { failed=1; break; }
        # A runner ID is scoped to its organization, which the official URL identifies.
        name=$("$JQ" -er '.agentName | select(type=="string")' "$config") || { failed=1; break; }
        indexed_name "$name" || { failed=1; break; }
        login=$("$JQ" -er '.gitHubUrl | capture("^https://github\\.com/(?<login>[A-Za-z0-9][A-Za-z0-9-]{0,38})/?$";"i") | .login' "$config") || { failed=1; break; }
        organization=$(api "orgs/$login") || { failed=1; break; }
        id=$(printf '%s' "$organization" | "$JQ" -er '.id | select(type=="number" and .>0 and floor==.) | tostring') || { failed=1; break; }
        login=$(printf '%s' "$organization" | "$JQ" -er '.login') || { failed=1; break; }
        safe_org "$login" || { failed=1; break; }
        if "$JQ" -e --arg id "$id" --argjson runner_id "$runner_id" 'any(to_entries[]; (.key|split(".")[0])==$id and .value.runner_id==$runner_id)' "$ROOT/conf/organizations.json" >/dev/null; then continue; fi
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
        safe_key "$id" && safe_id "$runner_id" && safe_org "$login" || { failed=1; continue; }
        # Resolve by immutable ID so an organization rename cannot redirect cleanup.
        if ! organization=$(api "organizations/${id%%.*}"); then printf 'Cannot resolve organization %s; retained registration state.\n' "$login" >&2; failed=1; continue; fi
        login=$(printf '%s' "$organization" | "$JQ" -er --argjson id "${id%%.*}" 'select(.id==$id)|.login') || { failed=1; continue; }
        safe_org "$login" || { failed=1; continue; }
        if ! remote=$(list_runners "$login"); then printf 'Cannot query %s; retained registration state.\n' "$login" >&2; failed=1; continue; fi
        if printf '%s' "$remote" | "$JQ" -e --argjson id "$runner_id" 'any(.[]; .id==$id)' >/dev/null; then
            if ! api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null; then printf 'Cannot unregister %s/%s; retry uninstall.\n' "$login" "$runner_id" >&2; failed=1; continue; fi
        fi
        jq_update "$ROOT/conf/organizations.json" --arg id "$id" 'del(.[$id])' || return 1
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
    rm -rf "${ROOT:?}/runner" "${ROOT:?}/bin" "${ROOT:?}/conf" || return 1
    printf 'Runner uninstalled. Data and logs retained in their original directories. Configured directory: %s\n' "$WORK_DIR"
}
command_main() {
    local command=${1:-help}; [ "$#" -eq 0 ] || shift
    case "$command" in
        --install-command) [ "$#" -eq 0 ] || return 2; install_cli ;;
        config) configure "$@" ;;
        runner) manage_runners "$@" ;;
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
