#!/bin/bash
# Bash 3.2 compatible; no interpreter other than the system shell.
set -u
set -o pipefail
OS=linux
SERVICE_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
ROOT=${LOCAL_RUNNER_ROOT:-$(cd "$(dirname "$SERVICE_FILE")/.." && pwd)}
atomic() { local target=$1; cat > "$target.tmp.$$" && chmod 600 "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target"; }
log() {
    if [ -f "$LOG_DIR/service.log" ] && [ "$(wc -c < "$LOG_DIR/service.log")" -gt 5242880 ]; then
        mv -f "$LOG_DIR/service.log.2" "$LOG_DIR/service.log.3" 2>/dev/null || :
        mv -f "$LOG_DIR/service.log.1" "$LOG_DIR/service.log.2" 2>/dev/null || :
        mv -f "$LOG_DIR/service.log" "$LOG_DIR/service.log.1" 2>/dev/null || :
    fi
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_DIR/service.log"
}
init() {
    JQ=$(cat "$ROOT/conf/jq-path") || return 1
    GH=$(cat "$ROOT/conf/gh-path") || return 1
    ARCH=$("$JQ" -r '.arch' "$ROOT/conf/settings.json") || return 1
    case "$ARCH" in x64|arm64) ;; *) return 1 ;; esac
    PREFIX=local-$OS-$ARCH
    WORK_DIR=$("$JQ" -r --arg fallback "$ROOT" '.work_dir // $fallback' "$ROOT/conf/settings.json") || return 1
    DATA_DIR=$WORK_DIR/data; LOG_DIR=$WORK_DIR/logs
    POLL=$("$JQ" -r '.poll_seconds // 300 | if . < 10 then 10 else . end | floor' "$ROOT/conf/settings.json")
    RESTART=$("$JQ" -r '.restart_seconds // 30 | if . < 1 then 1 else . end | floor' "$ROOT/conf/settings.json")
    mkdir -p "$ROOT/bin/.cache" "$ROOT/conf/workers" "$ROOT/conf/children" "$ROOT/conf/paused" "$ROOT/conf/retry"
    [ "${1:-runtime}" = control ] || mkdir -p "$LOG_DIR"
    [ -f "$ROOT/conf/organizations.json" ] || printf '{}\n' | atomic "$ROOT/conf/organizations.json"
}
api() { GH_TOKEN=$(cat "$ROOT/conf/github-token") GH_HOST=github.com GH_PROMPT_DISABLED=1 "$GH" api --hostname github.com "$@" 2>/dev/null; }
clean_exec() { env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u GH_CONFIG_DIR -u RUNNER_MANUALLY_TRAP_SIG "$@"; }
safe_org() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; }
safe_id() { [[ $1 =~ ^[0-9]+$ ]]; }
stamp() { ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || :; }
record_pid() { local mark; mark=$(stamp "$2"); [ -n "$mark" ] || return 1; printf '%s\n%s\n' "$2" "$mark" | atomic "$1"; }
record_alive() {
    [ -f "$1" ] || return 1
    local process_id expected actual
    process_id=$(head -n 1 "$1")
    safe_id "$process_id" && [ "$process_id" -gt 1 ] || return 1
    expected=$(tail -n 1 "$1"); actual=$(stamp "$process_id")
    [ -n "$actual" ] && [ "$actual" = "$expected" ] || return 1
    case "$(ps -p "$process_id" -o stat= 2>/dev/null)" in *Z*) return 1 ;; esac
}
tree_records() {
    local process_id=$1 child mark
    for child in $(ps -axo pid=,ppid= | awk -v p="$process_id" '$2==p {print $1}'); do tree_records "$child"; done
    mark=$(stamp "$process_id")
    [ -z "$mark" ] || printf '%s|%s\n' "$process_id" "$mark"
}
stop_record() {
    local records process_id expected actual signal
    if record_alive "$1"; then
        records=$(tree_records "$(head -n 1 "$1")")
        for signal in TERM KILL; do
            while IFS='|' read -r process_id expected; do
                safe_id "$process_id" && [ "$process_id" -gt 1 ] && [ "$process_id" != "$$" ] || continue
                actual=$(stamp "$process_id")
                [ -z "$actual" ] || [ "$actual" != "$expected" ] || kill -"$signal" "$process_id" 2>/dev/null || :
            done <<< "$records"
            [ "$signal" != TERM ] || sleep 1
        done
    fi
    rm -f "$1"
}
stop_worker() { stop_record "$ROOT/conf/workers/$1.pid"; stop_record "$ROOT/conf/children/$1.pid"; }
wrapper() {
    local directory=$ROOT/runner/$2
    mkdir -p "$directory"
    cp "$ROOT/bin/runner.sh" "$directory/runner.sh"
    chmod 700 "$directory/runner.sh"
}
ensure_worker() {
    local id=$1 login=$2 now due process_id
    [ ! -f "$ROOT/conf/stopped" ] || return 0
    "$JQ" -e --arg id "$id" --arg prefix "$PREFIX" '.[$id] | (.active != false) and (.relocated != true) and ((.runner_name // "") | test("^"+$prefix+"-[1-9][0-9]*$"))' "$ROOT/conf/organizations.json" >/dev/null || return 0
    [ ! -f "$ROOT/conf/paused/$id" ] && [ -f "$ROOT/runner/$login/app/.runner" ] || return 0
    record_alive "$ROOT/conf/workers/$id.pid" && return 0
    now=$(date +%s); due=$(cat "$ROOT/conf/retry/$id" 2>/dev/null || printf 0)
    [ "$now" -ge "$due" ] || return 0
    stop_worker "$id"
    prepare_workspace "$login" || return 1
    wrapper "$id" "$login"
    (exec 9>&-; clean_exec /bin/bash "$ROOT/runner/$login/runner.sh" "$ROOT" "$id") >> "$LOG_DIR/service.log" 2>&1 &
    process_id=$!
    record_pid "$ROOT/conf/workers/$id.pid" "$process_id" || :
    printf '%s\n' "$((now + RESTART))" > "$ROOT/conf/retry/$id"
    log "Started $("$JQ" -r '.agentName // "runner"' "$ROOT/runner/$login/app/.runner") for $login (pid $process_id)"
}
ensure_workers() {
    local id login
    while IFS=$'\t' read -r id login; do
        safe_id "$id" && safe_org "$login" || continue
        ensure_worker "$id" "$login"
    done < <("$JQ" -r 'to_entries[] | [.key,.value.login] | @tsv' "$ROOT/conf/organizations.json")
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
mtime() { if [ "$(uname -s)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
ensure_package() {
    local release version runner_os filename url digest temporary age
    PACKAGE=$ROOT/bin/.cache/package
    if [ -f "$PACKAGE/.complete" ]; then
        age=$(( $(date +%s) - $(mtime "$PACKAGE/.complete") ))
        [ "$age" -ge 86400 ] || return 0
    fi
    release=$(api repos/actions/runner/releases/latest) || return 1
    version=$(printf '%s' "$release" | "$JQ" -r '.tag_name | ltrimstr("v")') || return 1
    runner_os=linux; [ "$OS" != macos ] || runner_os=osx
    filename=actions-runner-$runner_os-$ARCH-$version.tar.gz
    url=$(printf '%s' "$release" | "$JQ" -r --arg name "$filename" '.assets[] | select(.name==$name) | .browser_download_url')
    digest=$(printf '%s' "$release" | "$JQ" -r --arg name "$filename" '.assets[] | select(.name==$name) | .digest')
    [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]] || { log 'Runner release has no SHA-256 digest'; return 1; }
    temporary=$(mktemp -d "$ROOT/bin/.cache/download.XXXXXX") || return 1
    if ! curl -fsSL --connect-timeout 15 --max-time 600 "$url" -o "$temporary/runner.tgz"; then rm -rf "$temporary"; return 1; fi
    if [ "$(sha256 "$temporary/runner.tgz")" != "${digest#sha256:}" ]; then rm -rf "$temporary"; log 'Runner SHA-256 mismatch'; return 1; fi
    if ! tar -tzf "$temporary/runner.tgz" | awk '/^\/|(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad}'; then rm -rf "$temporary"; return 1; fi
    mkdir "$temporary/package"
    tar -xzf "$temporary/runner.tgz" -C "$temporary/package" || { rm -rf "$temporary"; return 1; }
    printf '%s\n' "$version" > "$temporary/package/.complete"
    rm -rf "$PACKAGE"
    mv "$temporary/package" "$PACKAGE" || return 1
    rm -rf "$temporary"
    log "Downloaded official Runner $version for $OS/$ARCH"
}
prepare_workspace() {
    local login=$1 config=$ROOT/runner/$1/app/.runner
    safe_org "$login" || return 1
    mkdir -p "$DATA_DIR/$login" || return 1
    "$JQ" --arg work "$DATA_DIR/$login" '.workFolder=$work' "$config" | atomic "$config"
}
configure_runner() {
    local login=$1 name=$2 directory=$ROOT/runner/$1/app token
    ensure_package || return 1
    if [ ! -f "$directory/run.sh" ]; then
        rm -rf "$directory.staging"
        mkdir -p "$ROOT/runner/$login"
        cp -R "$PACKAGE" "$directory.staging" || return 1
        rm -rf "$directory"
        mv "$directory.staging" "$directory" || return 1
    fi
    mkdir -p "$DATA_DIR/$login"
    token=$(api "orgs/$login/actions/runners/registration-token" --method POST | "$JQ" -er .token) || return 1
    (cd "$directory" && clean_exec /bin/bash ./config.sh --unattended --url "https://github.com/$login" --token "$token" --name "$name" --labels "$PREFIX,$name" --work "$DATA_DIR/$login") >/dev/null 2>&1 || return 1
    "$JQ" -er '.agentId' "$directory/.runner"
}
save_entry() { "$JQ" --arg id "$1" --arg login "$2" --argjson runner_id "$3" --arg name "$4" '.[$id]={login:$login,runner_id:$runner_id,runner_name:$name}' "$ROOT/conf/organizations.json" | atomic "$ROOT/conf/organizations.json"; }
list_runners() { api "orgs/$1/actions/runners?per_page=100" --paginate --slurp | "$JQ" -ce '[.[].runners[]]'; }
indexed_name() { [[ $1 =~ ^$PREFIX-[1-9][0-9]*$ ]]; }
next_name() {
    printf '%s' "$1" | "$JQ" -er --arg prefix "$PREFIX" '
        ([.[] | .name | ascii_downcase | capture("^"+$prefix+"-(?<index>[1-9][0-9]*)$")? | .index | tonumber] | max // 0) as $max |
        if $max >= 9007199254740991 then error("Runner index exhausted") else $prefix+"-"+(($max+1)|tostring) end'
}
reconcile_one() {
    local id=$1 login=$2 old_login runner_id remote registered busy local_id directory name preferred relocated attempt recovered
    safe_id "$id" && safe_org "$login" || return 1
    remote=$(list_runners "$login") || return 1
    old_login=$("$JQ" -r --arg id "$id" '.[$id].login // empty' "$ROOT/conf/organizations.json")
    runner_id=$("$JQ" -r --arg id "$id" '.[$id].runner_id // 0' "$ROOT/conf/organizations.json")
    preferred=$("$JQ" -r --arg id "$id" '.[$id].runner_name // empty' "$ROOT/conf/organizations.json")
    relocated=$("$JQ" -r --arg id "$id" '.[$id].relocated // false' "$ROOT/conf/organizations.json")
    directory=$ROOT/runner/$login/app
    local_id=0
    [ ! -f "$directory/.runner" ] || local_id=$("$JQ" -r '.agentId // 0' "$directory/.runner")
    # A local registration is proof of ownership after a crash before saving state.
    if [ -z "$old_login" ]; then
        recovered=$(printf '%s' "$remote" | "$JQ" -r --argjson id "$local_id" '.[]|select(.id==$id)|.name')
        if [ "$recovered" = "$PREFIX" ] || indexed_name "$recovered"; then runner_id=$local_id; old_login=$login; fi
    fi
    registered=$(printf '%s' "$remote" | "$JQ" -c --argjson id "$runner_id" '[.[]|select(.id==$id)][0] // null')
    name=$(printf '%s' "$registered" | "$JQ" -r '.name // empty')
    if indexed_name "$name"; then preferred=$name; fi
    busy=$(printf '%s' "$registered" | "$JQ" -r '.busy // false')
    if [ -n "$old_login" ] && { [ "$old_login" != "$login" ] || [ "$registered" = null ] || [ "$local_id" != "$runner_id" ] || ! indexed_name "$name" || [ "$relocated" = true ]; }; then
        [ "$busy" != true ] || return 0
        : > "$ROOT/conf/paused/$id"
        stop_worker "$id"
        if [ "$registered" != null ]; then
            api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null || return 1
            remote=$(printf '%s' "$remote" | "$JQ" -c --argjson id "$runner_id" '[.[]|select(.id!=$id)]')
        fi
        registered=null
    fi
    if [ "$registered" != null ]; then
        save_entry "$id" "$login" "$runner_id" "$name" || return 1
        rm -f "$ROOT/conf/paused/$id"; return 0
    fi
    for attempt in 1 2 3 4 5; do
        # Preserve this installation's number on repair, unless another machine took it.
        if indexed_name "$preferred" && ! printf '%s' "$remote" | "$JQ" -e --arg name "$preferred" 'any(.[]; (.name|ascii_downcase)==$name)' >/dev/null; then name=$preferred;
        else name=$(next_name "$remote") || return 1; fi
        mkdir -p "$ROOT/runner/$login"
        rm -f "$directory/.runner" "$directory/.credentials" "$directory/.credentials_rsaparams"
        if runner_id=$(configure_runner "$login" "$name"); then break; fi
        # Another installer may win between listing and registration. Never --replace.
        remote=$(list_runners "$login") || return 1
        local_id=0
        [ ! -f "$directory/.runner" ] || local_id=$("$JQ" -r '.agentId // 0' "$directory/.runner")
        if printf '%s' "$remote" | "$JQ" -e --argjson id "$local_id" --arg name "$name" 'any(.[]; .id==$id and .name==$name)' >/dev/null; then runner_id=$local_id; break; fi
        printf '%s' "$remote" | "$JQ" -e --arg name "$name" 'any(.[]; (.name|ascii_downcase)==$name)' >/dev/null || return 1
        runner_id=
    done
    safe_id "$runner_id" || return 1
    save_entry "$id" "$login" "$runner_id" "$name" || return 1
    log "Registered $name for $login"
    rm -f "$ROOT/conf/paused/$id"
}
reconcile() {
    local memberships desired id login
    memberships=$(api 'user/memberships/orgs?state=active&per_page=100' --paginate --slurp) || { log 'Discovery failed; retaining current runners'; return 1; }
    desired=$(printf '%s' "$memberships" | "$JQ" -ce --slurpfile cfg "$ROOT/conf/settings.json" '($cfg[0].organizations // [] | map(ascii_downcase)) as $allow | [ .[][] | select(.state=="active") | .organization | .login as $name | select(($allow|length)==0 or ($allow|index($name|ascii_downcase))!=null) | {id:(.id|tostring),login} ]') || return 1
    while IFS=$'\t' read -r id login; do reconcile_one "$id" "$login" || log "Organization $login: reconciliation failed; will retry"; done < <(printf '%s' "$desired" | "$JQ" -r '.[] | [.id,.login] | @tsv')
    while IFS=$'\t' read -r id login; do
        if ! printf '%s' "$desired" | "$JQ" -e --arg id "$id" 'any(.[]; .id==$id)' >/dev/null; then
            : > "$ROOT/conf/paused/$id"
            stop_worker "$id"
            "$JQ" --arg id "$id" '.[$id].active=false' "$ROOT/conf/organizations.json" | atomic "$ROOT/conf/organizations.json"
            log "Stopped $login; local data retained"
        fi
    done < <("$JQ" -r 'to_entries[] | [.key,.value.login] | @tsv' "$ROOT/conf/organizations.json")
}
acquire_lock() {
    if [ "$(uname -s)" = Darwin ]; then /usr/bin/shlock -p $$ -f "$ROOT/conf/service.lock" || return 1
    else exec 9> "$ROOT/conf/service.lock"; flock -n 9 || return 1; fi
}
shutdown() {
    local record
    trap - EXIT TERM INT
    for record in "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid; do [ ! -f "$record" ] || stop_record "$record"; done
    rm -f "$ROOT/conf/manager.pid"
    if [ "$(uname -s)" = Darwin ]; then rm -f "$ROOT/conf/service.lock"; fi
}
serve() {
    local next=0 now record
    [ ! -f "$ROOT/conf/stopped" ] || return 0
    exec 2>> "$LOG_DIR/service.log"
    acquire_lock || { printf 'Another manager is running.\n' >&2; return 1; }
    trap shutdown EXIT
    trap 'exit 0' TERM INT
    record_pid "$ROOT/conf/manager.pid" "$$" || return 1
    printf '%s\n' "$WORK_DIR" | atomic "$ROOT/conf/active-work-dir" || return 1
    for record in "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid; do [ ! -f "$record" ] || stop_record "$record"; done
    log "Started Shell supervisor $PREFIX"
    while [ ! -f "$ROOT/conf/stopped" ]; do
        ensure_workers
        now=$(date +%s)
        if [ "$now" -ge "$next" ]; then reconcile || :; next=$(( $(date +%s) + POLL )); fi
        ensure_workers
        sleep 5 & wait $! || :
    done
}
status() {
    local id login runner_id name remote local_status failed=0 count=0
    if record_alive "$ROOT/conf/manager.pid"; then printf 'Manager: running\n'; else printf 'Manager: stopped\n'; fi
    printf 'Configured work directory: %s\n' "$WORK_DIR"
    if [ -f "$ROOT/conf/active-work-dir" ]; then printf 'Last started work directory: %s\n' "$(cat "$ROOT/conf/active-work-dir")"; fi
    printf '%-24s %-30s %-10s %-6s %s\n' ORGANIZATION RUNNER GITHUB BUSY LOCAL
    while IFS=$'\t' read -r id login runner_id name; do
        count=$((count+1)); local_status=stopped
        record_alive "$ROOT/conf/workers/$id.pid" && local_status=running
        if remote=$(list_runners "$login"); then
            printf '%s' "$remote" | "$JQ" -r --argjson id "$runner_id" --arg login "$login" --arg name "$name" --arg local "$local_status" \
                '([.[]|select(.id==$id)][0] // {name:$name,status:"missing",busy:false}) | [$login,.name,.status,(.busy|tostring),$local] | @tsv'
        else printf '%s\t%s\tunknown\t?\t%s\n' "$login" "$name" "$local_status"; failed=1; fi
    done < <("$JQ" -r 'to_entries[]|[.key,.value.login,.value.runner_id,(.value.runner_name // "unknown")]|@tsv' "$ROOT/conf/organizations.json")
    [ "$count" -ne 0 ] || printf 'No runners registered yet.\n'
    return "$failed"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    init || exit 1
    case "${1:-serve}" in serve) serve ;; worker) /bin/bash "$ROOT/bin/runner.sh" "$ROOT" "${2:?organization ID required}" ;; prepare) ensure_package ;; status) status ;; once) reconcile ;; *) exit 1 ;; esac
fi
