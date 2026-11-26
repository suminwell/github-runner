#!/bin/bash
# Bash 3.2 compatible; no interpreter other than the system shell.
set -u
set -o pipefail
OS=macos
SERVICE_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
ROOT=${LOCAL_RUNNER_ROOT:-$(cd "$(dirname "$SERVICE_FILE")/.." && pwd)}
atomic() { local target=$1; cat > "$target.tmp.$$" && chmod 600 "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target"; }
# Rewrite JSON in place only when jq succeeds; a failed or truncated run keeps the original.
jq_update() {
    local target=$1; shift
    if "$JQ" "$@" "$target" > "$target.tmp.$$" && [ -s "$target.tmp.$$" ] && chmod 600 "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target"; then return 0; fi
    rm -f "$target.tmp.$$"; return 1
}
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
    # Below the 90 s systemd/launchd stop timeout, so a graceful stop is never cut short.
    STOP_GRACE=$("$JQ" -r '.stop_seconds // 30 | if . < 1 then 1 elif . > 60 then 60 else . end | floor' "$ROOT/conf/settings.json")
    mkdir -p "$ROOT/bin/.cache" "$ROOT/conf/workers" "$ROOT/conf/children" "$ROOT/conf/paused" "$ROOT/conf/retry" "$ROOT/conf/backoff" "$ROOT/conf/timeouts"
    [ "${1:-runtime}" = control ] || mkdir -p "$LOG_DIR"
    [ -f "$ROOT/conf/organizations.json" ] || printf '{}\n' | atomic "$ROOT/conf/organizations.json"
}
# Run "$@" bounded by $1 seconds; returns its status, or 124 when the deadline fired.
# The command runs under a leader in its own process group, so the deadline (TERM, then
# KILL after a grace period) reaches every descendant, including reparented ones; only a
# process that creates its own session or group escapes. After the leader is reaped, any
# remaining group members (a timed-out tree, or a finished command's background
# stragglers) are terminated the same way, so nothing keeps the caller's output pipe or
# inherits the manager lock (fd 9). A live group keeps its ID from being reused as a PID,
# and the deadline signals the group only while the leader's PID and start time match.
# Only the command writes to the caller's stderr (passed in as fd 7). The plumbing runs
# with stderr discarded: the shell reports jobs that die from a signal ("Terminated")
# on its own stderr at a time of its choosing, and those notices must never mix into a
# captured error message.
with_timeout() { timeout_plumbing "$@" 7>&2 2>/dev/null; }
timeout_plumbing() {
    local seconds=$1 leader mark watchdog status waited monitor= record=
    shift
    case $- in *m*) monitor=1 ;; esac
    set -m
    (
        set +m
        exec 9>&-
        # Return the timeout status immediately; the parent gives descendants their
        # TERM grace period before forcing the rest of this group to exit.
        trap 'exit 124' TERM
        "$@" 2>&7 7>&- &
        child=$!
        exec 7>&-
        while :; do
            wait "$child"; status=$?
            kill -0 "$child" || break
        done
        # A wait interrupted by TERM reports the signal, not the result; ask again.
        [ "$status" -le 128 ] || { wait "$child"; status=$?; }
        exit "$status"
    ) &
    leader=$!
    mark=$(stamp "$leader")
    # The manager's shutdown and ghr stop find in-flight commands through these records.
    if [ -n "$mark" ] && [ -d "$ROOT/conf/timeouts" ]; then
        record=$ROOT/conf/timeouts/$leader.pid
        printf '%s\n%s\n' "$leader" "$mark" > "$record" || record=
    fi
    # Give the watchdog and its sleep a separate group so both can be cancelled together.
    (
        set +m
        exec 9>&- 7>&-
        sleep "$seconds" & wait "$!"
        [ -n "$mark" ] && process_alive "$leader" "$mark" || exit 0
        kill -TERM -- "-$leader"
    ) </dev/null >/dev/null &
    watchdog=$!
    [ -n "$monitor" ] || set +m
    wait "$leader"; status=$?
    if kill -0 -- "-$leader"; then
        kill -TERM -- "-$leader"
        waited=0
        while [ "$waited" -lt 20 ] && kill -0 -- "-$leader"; do sleep 0.1; waited=$((waited + 1)); done
        kill -KILL -- "-$leader"
    fi
    # Cancellation must not depend on a trap that may still be initializing. Kill the
    # watchdog itself, reap it, then sweep its group for a concurrently forked sleep.
    kill -KILL "$watchdog" || :
    wait "$watchdog" || :
    kill -KILL -- "-$watchdog" || :
    [ -z "$record" ] || rm -f "$record"
    return "$status"
}
# Last non-blank line of $1, with every occurrence of $2 masked before truncation, so a
# secret straddling the cut can never leave a partial prefix behind.
redacted_last_line() {
    local text=$1 secret=${2:-}
    [ -z "$secret" ] || text=${text//"$secret"/***}
    printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c 1-300
}
api() {
    local error status token
    token=$(cat "$ROOT/conf/github-token") || return 1
    error=$(mktemp "$ROOT/conf/api-error.XXXXXX") || return 1
    # The token reaches gh through the environment only, never through argv.
    GH_TOKEN=$token GH_HOST=github.com GH_PROMPT_DISABLED=1 with_timeout 120 "$GH" api --hostname github.com "$@" 2> "$error"
    status=$?
    # The manager's stderr is the service log.
    if [ "$status" -ne 0 ]; then
        printf '%s gh api %s failed (exit %s): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${1%%\?*}" "$status" "$(redacted_last_line "$(cat "$error")" "$token")" >&2
        # gh suggests "gh auth refresh", which does not change the token saved for this service.
        ! grep -q 'admin:org' "$error" || printf '%s The saved GitHub token lacks admin:org. Run the installer again: it requests the scope and saves the new token.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
    fi
    rm -f "$error"
    return "$status"
}
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
process_alive() {
    local actual
    actual=$(stamp "$1"); [ -n "$actual" ] && [ "$actual" = "$2" ] || return 1
    case "$(ps -p "$1" -o stat= 2>/dev/null)" in *Z*) return 1 ;; esac
}
signal_tree() {
    local process_id expected
    while IFS='|' read -r process_id expected; do
        safe_id "$process_id" && [ "$process_id" -gt 1 ] && [ "$process_id" != "$$" ] || continue
        ! process_alive "$process_id" "$expected" || kill -"$1" "$process_id" 2>/dev/null || :
    done <<< "$2"
}
tree_alive() {
    local process_id expected
    while IFS='|' read -r process_id expected; do
        safe_id "$process_id" && [ "$process_id" -gt 1 ] && [ "$process_id" != "$$" ] || continue
        ! process_alive "$process_id" "$expected" || return 0
    done <<< "$1"
    return 1
}
# Signal all recorded trees together, give the official runner STOP_GRACE seconds to
# cancel its job and report back, then force whatever is left.
stop_records() {
    local record records= waited=0
    for record in "$@"; do
        if record_alive "$record"; then records=$records$(tree_records "$(head -n 1 "$record")")$'\n'; fi
    done
    if [ -n "$records" ]; then
        signal_tree TERM "$records"
        while [ "$waited" -lt "$((STOP_GRACE * 2))" ] && tree_alive "$records"; do sleep 0.5; waited=$((waited + 1)); done
        signal_tree KILL "$records"
    fi
    for record in "$@"; do rm -f "$record"; done
}
stop_record() { stop_records "$1"; }
stop_worker() { stop_records "$ROOT/conf/workers/$1.pid" "$ROOT/conf/children/$1.pid"; }
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
    (exec 9>&-; clean_exec /bin/bash "$ROOT/runner/$login/runner.sh" "$ROOT" "$id" "$LOG_DIR/service.log") >> "$LOG_DIR/service.log" 2>&1 &
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
    jq_update "$config" --arg work "$DATA_DIR/$login" '.workFolder=$work'
}
configure_runner() {
    local login=$1 name=$2 directory=$ROOT/runner/$1/app token output status
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
    output=$(cd "$directory" && with_timeout "${RUNNER_CONFIG_TIMEOUT:-180}" clean_exec /bin/bash ./config.sh --unattended --url "https://github.com/$login" --token "$token" --name "$name" --labels "$PREFIX,$name" --work "$DATA_DIR/$login" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        log "Organization $login: runner configuration as $name failed (exit $status): $(redacted_last_line "$output" "$token")"
        return 1
    fi
    "$JQ" -er '.agentId' "$directory/.runner"
}
save_entry() { jq_update "$ROOT/conf/organizations.json" --arg id "$1" --arg login "$2" --argjson runner_id "$3" --arg name "$4" '.[$id]={login:$login,runner_id:$runner_id,runner_name:$name}'; }
list_runners() {
    local pages
    # A failed request may still print an error body; never parse it as a runner list.
    pages=$(api "orgs/$1/actions/runners?per_page=100" --paginate --slurp) || return 1
    printf '%s' "$pages" | "$JQ" -ce '[.[].runners[]]'
}
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
        # A renamed organization keeps its program directory; old work data stays in place.
        if [ "$old_login" != "$login" ] && safe_org "$old_login" && [ -d "$ROOT/runner/$old_login" ] && [ ! -e "$ROOT/runner/$login" ]; then
            mv "$ROOT/runner/$old_login" "$ROOT/runner/$login" || return 1
            log "Moved runner directory of $old_login to $login"
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
# Organizations without runner permission (or with persistent errors) are retried with
# exponential backoff, from poll_seconds up to one hour, instead of failing every poll.
backoff_due() {
    local due
    due=$(head -n 1 "$ROOT/conf/backoff/$1" 2>/dev/null || :)
    ! safe_id "${due:-x}" || [ "$(date +%s)" -ge "$due" ]
}
backoff_failure() {
    local id=$1 login=$2 count delay step=1
    count=$(sed -n 2p "$ROOT/conf/backoff/$id" 2>/dev/null || :)
    safe_id "${count:-x}" || count=0
    count=$((count + 1)); delay=$POLL
    while [ "$step" -lt "$count" ] && [ "$delay" -lt 3600 ]; do delay=$((delay * 2)); step=$((step + 1)); done
    [ "$delay" -le 3600 ] || delay=3600
    printf '%s\n%s\n' "$(( $(date +%s) + delay ))" "$count" | atomic "$ROOT/conf/backoff/$id"
    log "Organization $login: reconciliation failed (attempt $count); next retry in ${delay}s"
}
reconcile() {
    local memberships desired id login
    memberships=$(api 'user/memberships/orgs?state=active&per_page=100' --paginate --slurp) || { log 'Discovery failed; retaining current runners'; return 1; }
    desired=$(printf '%s' "$memberships" | "$JQ" -ce --slurpfile cfg "$ROOT/conf/settings.json" '($cfg[0].organizations // [] | map(ascii_downcase)) as $allow | [ .[][] | select(.state=="active") | .organization | .login as $name | select(($allow|length)==0 or ($allow|index($name|ascii_downcase))!=null) | {id:(.id|tostring),login} ]') || return 1
    while IFS=$'\t' read -r id login; do
        backoff_due "$id" || continue
        if reconcile_one "$id" "$login"; then
            if [ -f "$ROOT/conf/backoff/$id" ]; then rm -f "$ROOT/conf/backoff/$id"; log "Organization $login: reconciliation recovered"; fi
        else backoff_failure "$id" "$login"; fi
    done < <(printf '%s' "$desired" | "$JQ" -r '.[] | [.id,.login] | @tsv')
    while IFS=$'\t' read -r id login; do
        if ! printf '%s' "$desired" | "$JQ" -e --arg id "$id" 'any(.[]; .id==$id)' >/dev/null; then
            # Already deactivated: nothing to stop and nothing new to log.
            ! "$JQ" -e --arg id "$id" '.[$id].active == false' "$ROOT/conf/organizations.json" >/dev/null || continue
            rm -f "$ROOT/conf/backoff/$id"
            : > "$ROOT/conf/paused/$id"
            stop_worker "$id"
            jq_update "$ROOT/conf/organizations.json" --arg id "$id" '.[$id].active=false'
            log "Stopped $login; local data retained"
        fi
    done < <("$JQ" -r 'to_entries[] | [.key,.value.login] | @tsv' "$ROOT/conf/organizations.json")
}
acquire_lock() {
    if [ "$(uname -s)" = Darwin ]; then /usr/bin/shlock -p $$ -f "$ROOT/conf/service.lock" || return 1
    else exec 9> "$ROOT/conf/service.lock"; flock -n 9 || return 1; fi
}
# A stopping manager's last children can hold the lock briefly after it exits.
wait_for_lock() {
    local attempt=0
    while [ "$attempt" -lt 30 ]; do acquire_lock && return 0; sleep 0.5; attempt=$((attempt + 1)); done
    return 1
}
shutdown() {
    local record
    trap - EXIT TERM INT
    stop_records "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid "$ROOT"/conf/timeouts/*.pid
    rm -f "$ROOT/conf/manager.pid"
    if [ "$(uname -s)" = Darwin ]; then rm -f "$ROOT/conf/service.lock"; fi
}
serve() {
    local next=0 now
    [ ! -f "$ROOT/conf/stopped" ] || return 0
    exec 2>> "$LOG_DIR/service.log"
    acquire_lock || { printf 'Another manager is running.\n' >&2; return 1; }
    trap shutdown EXIT
    trap 'exit 0' TERM INT
    record_pid "$ROOT/conf/manager.pid" "$$" || return 1
    printf '%s\n' "$WORK_DIR" | atomic "$ROOT/conf/active-work-dir" || return 1
    stop_records "$ROOT"/conf/workers/*.pid "$ROOT"/conf/children/*.pid "$ROOT"/conf/timeouts/*.pid
    log "Started Shell supervisor $PREFIX"
    while [ ! -f "$ROOT/conf/stopped" ]; do
        # Reopen after log rotation so diagnostics land in the current file.
        exec 2>> "$LOG_DIR/service.log"
        ensure_workers
        now=$(date +%s)
        if [ "$now" -ge "$next" ]; then reconcile || :; next=$(( $(date +%s) + POLL )); fi
        ensure_workers
        sleep 5 & wait $! || :
    done
}
status() {
    local id login runner_id name active remote row local_status local_pid remote_name remote_status busy
    local failed=0 count=0 online=0 offline=0 missing=0 unknown=0 jobs=0 listening=0 restarting=0
    local others other_name other_status other_busy other_count=0 other_online=0 other_offline=0 other_jobs=0
    local manager=stopped work=$WORK_DIR directory_state='configured; not started yet' work_prefix configured_prefix
    if record_alive "$ROOT/conf/manager.pid"; then manager=running; fi
    printf 'GitHub Runner status\nPlatform: %s / %s\n' "$OS" "$ARCH"
    if [ "$manager" = running ]; then printf 'Manager: running (PID %s)\n' "$(head -n 1 "$ROOT/conf/manager.pid")";
    elif [ -f "$ROOT/conf/stopped" ]; then printf 'Manager: stopped (run ghr start to resume)\n';
    else printf 'Manager: stopped\n'; fi
    printf 'Install directory: %s\nRunner directory: %s/runner\n' "$ROOT" "$ROOT"
    if [ -s "$ROOT/conf/active-work-dir" ]; then
        work=$(cat "$ROOT/conf/active-work-dir")
        directory_state='last run; manager stopped'
        [ "$manager" != running ] || directory_state=active
    fi
    work_prefix=$work; [ "$work" != / ] || work_prefix=
    configured_prefix=$WORK_DIR; [ "$WORK_DIR" != / ] || configured_prefix=
    printf 'Work directory: %s (%s)\nData directory: %s/data\nLogs directory: %s/logs\n' "$work" "$directory_state" "$work_prefix" "$work_prefix"
    printf 'Configured work directory: %s\n' "$WORK_DIR"
    if [ "$work" != "$WORK_DIR" ]; then
        printf 'Configuration: pending; next start uses %s/data and %s/logs\n' "$configured_prefix" "$configured_prefix"
        printf 'Run ghr restart (or stop then start) to apply.\n'
    else printf 'Configuration: no pending directory change\n'; fi
    # A tree: each organization, then its runners (this installation's first). The branch
    # is printed apart from the padded columns, so multibyte line characters keep alignment.
    local row_format='%s %-32s %-9s %-5s %-11s %s\n' middle='|--' last='`--' other_total branch
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) middle='├──'; last='└──' ;; esac
    printf '\n%-36s %-9s %-5s %-11s %s\n' 'ORGANIZATION / RUNNER' GITHUB BUSY LOCAL PID
    while IFS=$'\t' read -r id login runner_id name active; do
        count=$((count+1)); local_status=stopped; local_pid=-
        if record_alive "$ROOT/conf/children/$id.pid"; then
            local_status=running; local_pid=$(head -n 1 "$ROOT/conf/children/$id.pid"); listening=$((listening+1))
        elif record_alive "$ROOT/conf/workers/$id.pid"; then
            local_status=restarting; local_pid=$(head -n 1 "$ROOT/conf/workers/$id.pid"); restarting=$((restarting+1))
        elif [ "$active" = false ] || [ -f "$ROOT/conf/paused/$id" ]; then local_status=paused; fi
        remote_name=$name; remote_status=unknown; busy='?'; others=
        if remote=$(list_runners "$login") && row=$(printf '%s' "$remote" | "$JQ" -er --argjson id "$runner_id" --arg name "$name" \
            '([.[]|select(.id==$id)][0]) as $r | if $r == null then [$name,"missing","-"] else [($r.name // $name),($r.status // "unknown"),(if $r.busy == null then "?" else ($r.busy|tostring) end)] end | @tsv'); then
            IFS=$'\t' read -r remote_name remote_status busy <<< "$row"
            # Every other runner of the organization: other machines, platforms or manual runners.
            others=$(printf '%s' "$remote" | "$JQ" -r --argjson id "$runner_id" \
                '[.[]|select(.id!=$id)] | sort_by(.name|ascii_downcase)[] | [.name,(.status // "unknown"),(if .busy == null then "?" else (.busy|tostring) end)] | @tsv')
        fi
        case "$remote_status" in
            online) online=$((online+1)) ;; offline) offline=$((offline+1)) ;; missing) missing=$((missing+1)) ;;
            *) remote_status=unknown; busy='?'; unknown=$((unknown+1)); failed=1 ;;
        esac
        [ "$busy" != true ] || jobs=$((jobs+1))
        other_total=0; [ -z "$others" ] || other_total=$(printf '%s\n' "$others" | grep -c .)
        branch=$middle; [ "$other_total" != 0 ] || branch=$last
        printf '%s\n' "$login"
        printf "$row_format" "$branch" "$remote_name" "$remote_status" "$busy" "$local_status" "$local_pid"
        while IFS=$'\t' read -r other_name other_status other_busy; do
            [ -n "$other_name" ] || continue
            other_count=$((other_count+1)); other_total=$((other_total-1))
            branch=$middle; [ "$other_total" != 0 ] || branch=$last
            case "$other_status" in online) other_online=$((other_online+1)) ;; offline) other_offline=$((other_offline+1)) ;; esac
            [ "$other_busy" != true ] || other_jobs=$((other_jobs+1))
            printf "$row_format" "$branch" "$other_name" "$other_status" "$other_busy" other -
        done <<< "$others"
    done < <("$JQ" -r 'to_entries|sort_by(.value.login)[]|[.key,.value.login,.value.runner_id,(.value.runner_name // "unknown"),(.value.active != false)]|@tsv' "$ROOT/conf/organizations.json")
    [ "$count" -ne 0 ] || printf 'No runners registered yet. Use ghr logs to check discovery and registration.\n'
    printf '\nOrganizations: %s\nGitHub: %s online, %s offline, %s missing, %s unknown; %s busy\n' "$count" "$online" "$offline" "$missing" "$unknown" "$jobs"
    [ "$other_count" = 0 ] || printf 'Other runners in these organizations: %s (%s online, %s offline); %s busy\n' "$other_count" "$other_online" "$other_offline" "$other_jobs"
    printf 'Local: %s running, %s restarting, %s stopped/paused\n' "$listening" "$restarting" "$((count-listening-restarting))"
    [ "$restarting" = 0 ] || printf 'restarting: organization worker is alive; listener is not running yet.\n'
    [ "$failed" = 0 ] || printf 'Some GitHub statuses could not be queried; unknown does not mean offline.\n'
    return "$failed"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    init || exit 1
    case "${1:-serve}" in serve) serve ;; worker) /bin/bash "$ROOT/bin/runner.sh" "$ROOT" "${2:?organization ID required}" ;; prepare) ensure_package ;; status) status ;; once) reconcile ;; *) exit 1 ;; esac
fi
