#!/bin/bash
# Bash 3.2 compatible; no interpreter other than the system shell.
set -u
set -o pipefail
OS=linux
SERVICE_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
ROOT=${LOCAL_RUNNER_ROOT:-$(cd "$(dirname "$SERVICE_FILE")/.." && pwd)}
STATE=$ROOT/conf
SYSTEMD_UNITS=${LOCAL_RUNNER_SYSTEMD_UNITS:-/etc/systemd/system}
SUDOERS_DIR=${LOCAL_RUNNER_SUDOERS_DIR:-/etc/sudoers.d}
JOB_SUDOERS_DIR=${LOCAL_RUNNER_DOCKER_SUDOERS_DIR:-/etc/github-runner/sudoers}
[ ! -f "$ROOT/conf/account.json" ] || STATE=$ROOT/conf/runtime
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
    STATE=$ROOT/conf
    RUNNER_UID=
    # Docker mode supplies the container's own jq; the host's may not run there.
    JQ=${LOCAL_RUNNER_JQ:-$(cat "$ROOT/conf/jq-path")} || return 1
    if [ -f "$ROOT/conf/account.json" ]; then
        STATE=$ROOT/conf/runtime
        RUNNER_UID=$("$JQ" -er .uid "$ROOT/conf/account.json") || return 1
        [ "$(id -u)" = "$RUNNER_UID" ] || { echo 'Use ghr or systemd to run this installation as its dedicated account.' >&2; return 1; }
    fi
    GH=$(cat "$ROOT/conf/gh-path") || return 1
    ARCH=$("$JQ" -r '.arch' "$ROOT/conf/settings.json") || return 1
    case "$ARCH" in x64|arm64) ;; *) return 1 ;; esac
    PREFIX=local-$OS-$ARCH
    WORK_DIR=$("$JQ" -r --arg fallback "$ROOT" '.work_dir // $fallback' "$ROOT/conf/settings.json") || return 1
    JOBS_DIR=$WORK_DIR/jobs; LOG_DIR=$WORK_DIR/logs
    # The runner programs live in the work directory the manager last ran with; a pending
    # ghr config --data-dir change moves them when the manager next starts.
    RUNNERS_DIR=$WORK_DIR/runners
    if [ -s "$STATE/active-work-dir" ]; then RUNNERS_DIR=$(cat "$STATE/active-work-dir")/runners; fi
    POLL=$("$JQ" -r '.poll_seconds // 300 | if . < 10 then 10 else . end | floor' "$ROOT/conf/settings.json")
    RESTART=$("$JQ" -r '.restart_seconds // 30 | if . < 1 then 1 else . end | floor' "$ROOT/conf/settings.json")
    # Below the 90 s systemd/launchd stop timeout, so a graceful stop is never cut short.
    STOP_GRACE=$("$JQ" -r '.stop_seconds // 30 | if . < 1 then 1 elif . > 60 then 60 else . end | floor' "$ROOT/conf/settings.json")
    mkdir -p "$ROOT/bin/.cache" "$STATE/workers" "$STATE/children" "$STATE/paused" "$STATE/retry" "$STATE/backoff" "$STATE/timeouts"
    [ "${1:-runtime}" = control ] || mkdir -p "$LOG_DIR"
    [ -f "$STATE/organizations.json" ] || printf '{}\n' | atomic "$STATE/organizations.json"
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
    if [ -n "$mark" ] && [ -d "$STATE/timeouts" ]; then
        record=$STATE/timeouts/$leader.pid
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
    error=$(mktemp "$STATE/api-error.XXXXXX") || return 1
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
# Each organization runs runner_count runners. Runner N of an organization is keyed by the
# organization ID (N = 1) or <ID>.N in the state; its program lives in
# runners/<login>/<runner name>/app and its jobs in jobs/<login>/<runner name>, both in the
# work directory.
safe_key() { [[ $1 =~ ^[0-9]+(\.([2-9]|[1-9][0-9]+))?$ ]]; }
# At most half the logical CPUs (at least 1), so an organization's runners leave room for
# each other; a count saved on a larger machine is capped here.
cpu_count() {
    # LOCAL_RUNNER_CPU_COUNT stands in for the machine in tests.
    if [ -n "${LOCAL_RUNNER_CPU_COUNT:-}" ]; then printf '%s\n' "$LOCAL_RUNNER_CPU_COUNT"; return 0; fi
    getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '2\n'
}
max_runners() {
    local cpus
    cpus=$(cpu_count | tr -d ' '); [[ $cpus =~ ^[1-9][0-9]*$ ]] || cpus=2
    if [ "$((cpus / 2))" -ge 1 ]; then printf '%s\n' "$((cpus / 2))"; else printf '1\n'; fi
}
runner_count() { "$JQ" -r --argjson maximum "$(max_runners)" '.runner_count // 1 | if type == "number" and . >= 1 then ([., $maximum] | min | floor) else 1 end' "$ROOT/conf/settings.json"; }
# Process start time in clock ticks since boot (/proc/<pid>/stat field 22). ps lstart is
# derived from the wall clock, so a clock step (NTP, VM time correction) changed it by a
# second and made live processes look gone: timeouts did not fire, workers were started
# twice and stops skipped them. This value never moves, and the Docker mode container
# reads the same one because it shares the host kernel and PID namespace.
stamp() {
    local stat
    # Without procfs (only the cross-platform tests run this file elsewhere) use ps lstart.
    [ -r /proc/self/stat ] || { TZ=UTC LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || :; return 0; }
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    # The command name may contain spaces or parentheses; fields resume after the last ")".
    stat=${stat##*) }
    set -f; set -- $stat; set +f
    printf '%s\n' "${20:-}"
}
record_pid() { local mark; mark=$(stamp "$2"); [ -n "$mark" ] || return 1; printf '%s\n%s\n' "$2" "$mark" | atomic "$1"; }
record_alive() {
    [ -f "$1" ] || return 1
    local process_id expected actual
    process_id=$(head -n 1 "$1")
    safe_id "$process_id" && [ "$process_id" -gt 1 ] || return 1
    runtime_process "$process_id" || return 1
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
runtime_process() {
    [ -z "${RUNNER_UID:-}" ] || [ "$(ps -p "$1" -o uid= 2>/dev/null | tr -d ' ')" = "$RUNNER_UID" ]
}
process_alive() {
    local actual
    runtime_process "$1" || return 1
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
stop_worker() { stop_records "$STATE/workers/$1.pid" "$STATE/children/$1.pid"; }
wrapper() {
    mkdir -p "$1" && cp "$ROOT/bin/runner.sh" "$1/runner.sh" && chmod 700 "$1/runner.sh"
}
ensure_worker() {
    local id=$1 login=$2 name directory now due process_id
    [ ! -f "$ROOT/conf/stopped" ] && [ ! -f "$STATE/paused/$id" ] || return 0
    name=$("$JQ" -r --arg id "$id" '.[$id] | select(.active != false) | .runner_name // empty' "$STATE/organizations.json")
    indexed_name "$name" || return 0
    directory=$RUNNERS_DIR/$login/$name
    [ -f "$directory/app/.runner" ] || return 0
    record_alive "$STATE/workers/$id.pid" && return 0
    now=$(date +%s); due=$(cat "$STATE/retry/$id" 2>/dev/null || printf 0)
    [ "$now" -ge "$due" ] || return 0
    stop_worker "$id"
    prepare_workspace "$login" "$name" || return 1
    wrapper "$directory" || return 1
    (exec 9>&-; clean_exec /bin/bash "$directory/runner.sh" "$ROOT" "$id" "$LOG_DIR/service.log") >> "$LOG_DIR/service.log" 2>&1 &
    process_id=$!
    record_pid "$STATE/workers/$id.pid" "$process_id" || :
    printf '%s\n' "$((now + RESTART))" > "$STATE/retry/$id"
    log "Started $name for $login (pid $process_id)"
}
ensure_workers() {
    local id login
    while IFS=$'\t' read -r id login; do
        safe_key "$id" && safe_org "$login" || continue
        ensure_worker "$id" "$login"
    done < <("$JQ" -r 'to_entries[] | [.key,.value.login] | @tsv' "$STATE/organizations.json")
}
sha256() { sha256sum "$1" | awk '{print $1}'; }
mtime() { stat -c %Y "$1"; }
# Connections to GitHub can drop mid-handshake (curl 35, "EOF"); retry before failing.
download() {
    local url=$1 output=$2 attempt
    for attempt in 1 2 3 4; do
        curl -fsSL --connect-timeout 15 --max-time 600 "$url" -o "$output" && return 0
        [ "$attempt" = 4 ] || { printf 'Download attempt %s failed; retrying in %ss: %s\n' "$attempt" "$((attempt * 5))" "$url" >&2; sleep "$((attempt * 5))"; }
    done
    return 1
}
verify_runtime() {
    local package=$ROOT/bin/.cache/package binary output result node_directory nodes=0
    for binary in "$package/bin/Runner.Listener" "$package"/externals/node*/bin/node; do
        if [ "$binary" != "$package/bin/Runner.Listener" ]; then
            node_directory=${binary%/bin/node}; node_directory=${node_directory##*/}
            # A glibc host must not try to launch the optional musl/Alpine bundle.
            [[ $node_directory =~ ^node[0-9]+$ ]] || continue
            nodes=$((nodes+1))
        fi
        [ -x "$binary" ] || { printf 'Runtime check failed: executable missing: %s\n' "$binary" >&2; return 1; }
        result=0
        output=$(cd "$package" && with_timeout 30 clean_exec "$binary" --version 2>&1) || result=$?
        if [ "$result" != 0 ]; then
            printf 'Runtime check failed: %s (exit %s)\n%s\n' "${binary#"$package/"}" "$result" "$output" >&2
            printf 'Runner service was not enabled by this installation. Fix system compatibility/dependencies and retry.\n' >&2
            return 1
        fi
    done
    [ "$nodes" -gt 0 ] || { printf 'Runtime check failed: no bundled Node.js runtime found.\n' >&2; return 1; }
    printf 'Runtime check passed: Runner.Listener and %s bundled Node.js runtime(s).\n' "$nodes"
}
ensure_package() {
    local release version filename url digest temporary age
    PACKAGE=$ROOT/bin/.cache/package
    if [ -f "$PACKAGE/.complete" ]; then
        age=$(( $(date +%s) - $(mtime "$PACKAGE/.complete") ))
        [ "$age" -ge 86400 ] || return 0
    fi
    release=$(api repos/actions/runner/releases/latest) || { sleep 5; release=$(api repos/actions/runner/releases/latest); } || { sleep 10; release=$(api repos/actions/runner/releases/latest); } || return 1
    version=$(printf '%s' "$release" | "$JQ" -r '.tag_name | ltrimstr("v")') || return 1
    filename=actions-runner-linux-$ARCH-$version.tar.gz
    url=$(printf '%s' "$release" | "$JQ" -r --arg name "$filename" '.assets[] | select(.name==$name) | .browser_download_url')
    digest=$(printf '%s' "$release" | "$JQ" -r --arg name "$filename" '.assets[] | select(.name==$name) | .digest')
    [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]] || { log 'Runner release has no SHA-256 digest'; return 1; }
    temporary=$(mktemp -d "$ROOT/bin/.cache/download.XXXXXX") || return 1
    if ! download "$url" "$temporary/runner.tgz"; then rm -rf "$temporary"; log "Runner download failed: $url"; return 1; fi
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
    local login=$1 name=$2
    safe_org "$login" && indexed_name "$name" || return 1
    mkdir -p "$JOBS_DIR/$login/$name" || return 1
    jq_update "$RUNNERS_DIR/$login/$name/app/.runner" --arg work "$JOBS_DIR/$login/$name" '.workFolder=$work'
}
configure_runner() {
    local login=$1 name=$2 directory=$RUNNERS_DIR/$1/$2/app token output status
    ensure_package || return 1
    if [ ! -f "$directory/run.sh" ]; then
        rm -rf "$directory.staging"
        mkdir -p "${directory%/app}"
        cp -R "$PACKAGE" "$directory.staging" || return 1
        rm -rf "$directory"
        mv "$directory.staging" "$directory" || return 1
    fi
    mkdir -p "$JOBS_DIR/$login/$name"
    token=$(api "orgs/$login/actions/runners/registration-token" --method POST | "$JQ" -er .token) || return 1
    output=$(cd "$directory" && with_timeout "${RUNNER_CONFIG_TIMEOUT:-180}" clean_exec /bin/bash ./config.sh --unattended --url "https://github.com/$login" --token "$token" --name "$name" --labels "$PREFIX,$name" --work "$JOBS_DIR/$login/$name" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        log "Organization $login: runner configuration as $name failed (exit $status): $(redacted_last_line "$output" "$token")"
        return 1
    fi
    "$JQ" -er '.agentId' "$directory/.runner"
}
save_entry() { jq_update "$STATE/organizations.json" --arg id "$1" --arg login "$2" --argjson runner_id "$3" --arg name "$4" '.[$id]={login:$login,runner_id:$runner_id,runner_name:$name}'; }
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
# A registration that finished before save_entry: a local runner directory that no state
# entry claims and whose ID and name GitHub still reports. Prints "<name> <ID>".
unclaimed_registration() {
    local login=$1 remote=$2 config name runner_id
    for config in "$RUNNERS_DIR/$login"/*/app/.runner; do
        [ -f "$config" ] || continue
        name=${config%/app/.runner}; name=${name##*/}
        indexed_name "$name" || continue
        ! "$JQ" -e --arg login "$login" --arg name "$name" 'any(.[]; .login==$login and .runner_name==$name)' "$STATE/organizations.json" >/dev/null || continue
        runner_id=$("$JQ" -r '.agentId // 0' "$config")
        printf '%s' "$remote" | "$JQ" -e --argjson id "$runner_id" --arg name "$name" 'any(.[]; .id==$id and .name==$name)' >/dev/null || continue
        printf '%s %s\n' "$name" "$runner_id"; return 0
    done
    return 1
}
reconcile_one() {
    local id=$1 login=$2 old_login runner_id remote registered busy local_id name preferred attempt adopted directory
    safe_key "$id" && safe_org "$login" || return 1
    remote=$(list_runners "$login") || return 1
    old_login=$("$JQ" -r --arg id "$id" '.[$id].login // empty' "$STATE/organizations.json")
    runner_id=$("$JQ" -r --arg id "$id" '.[$id].runner_id // 0' "$STATE/organizations.json")
    preferred=$("$JQ" -r --arg id "$id" '.[$id].runner_name // empty' "$STATE/organizations.json")
    # A local registration is proof of ownership after a crash before saving state.
    if [ -z "$old_login" ] && adopted=$(unclaimed_registration "$login" "$remote"); then
        preferred=${adopted% *}; runner_id=${adopted##* }; old_login=$login
    fi
    local_id=0
    if indexed_name "$preferred" && [ -f "$RUNNERS_DIR/$old_login/$preferred/app/.runner" ]; then
        local_id=$("$JQ" -r '.agentId // 0' "$RUNNERS_DIR/$old_login/$preferred/app/.runner")
    fi
    registered=$(printf '%s' "$remote" | "$JQ" -c --argjson id "$runner_id" '[.[]|select(.id==$id)][0] // null')
    name=$(printf '%s' "$registered" | "$JQ" -r '.name // empty')
    if indexed_name "$name"; then preferred=$name; fi
    busy=$(printf '%s' "$registered" | "$JQ" -r '.busy // false')
    if [ -n "$old_login" ] && { [ "$old_login" != "$login" ] || [ "$registered" = null ] || [ "$local_id" != "$runner_id" ] || ! indexed_name "$name"; }; then
        [ "$busy" != true ] || return 0
        : > "$STATE/paused/$id"
        stop_worker "$id"
        if [ "$registered" != null ]; then
            api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null || return 1
            remote=$(printf '%s' "$remote" | "$JQ" -c --argjson id "$runner_id" '[.[]|select(.id!=$id)]')
        fi
        # A renamed organization keeps its program directory; old jobs stay in place.
        if [ "$old_login" != "$login" ] && safe_org "$old_login" && indexed_name "$preferred" && [ -d "$RUNNERS_DIR/$old_login/$preferred" ] && [ ! -e "$RUNNERS_DIR/$login/$preferred" ]; then
            mkdir -p "$RUNNERS_DIR/$login" && mv "$RUNNERS_DIR/$old_login/$preferred" "$RUNNERS_DIR/$login/$preferred" || return 1
            rmdir "$RUNNERS_DIR/$old_login" 2>/dev/null || :
            log "Moved runner directory $old_login/$preferred to $login/$preferred"
        fi
        registered=null
    fi
    if [ "$registered" != null ]; then
        save_entry "$id" "$login" "$runner_id" "$name" || return 1
        rm -f "$STATE/paused/$id"; return 0
    fi
    for attempt in 1 2 3 4 5; do
        # Preserve this installation's number on repair, unless another machine took it.
        if indexed_name "$preferred" && ! printf '%s' "$remote" | "$JQ" -e --arg name "$preferred" 'any(.[]; (.name|ascii_downcase)==$name)' >/dev/null; then name=$preferred;
        else name=$(next_name "$remote") || return 1; fi
        directory=$RUNNERS_DIR/$login/$name
        # A new number reuses the previous program directory instead of copying the Runner again.
        if [ "$name" != "$preferred" ] && indexed_name "$preferred" && [ -d "$RUNNERS_DIR/$login/$preferred" ] && [ ! -e "$directory" ]; then
            mv "$RUNNERS_DIR/$login/$preferred" "$directory" || return 1
        fi
        rm -f "$directory/app/.runner" "$directory/app/.credentials" "$directory/app/.credentials_rsaparams"
        if runner_id=$(configure_runner "$login" "$name"); then break; fi
        # Another installer may win between listing and registration. Never --replace.
        remote=$(list_runners "$login") || return 1
        local_id=0
        [ ! -f "$directory/app/.runner" ] || local_id=$("$JQ" -r '.agentId // 0' "$directory/app/.runner")
        if printf '%s' "$remote" | "$JQ" -e --argjson id "$local_id" --arg name "$name" 'any(.[]; .id==$id and .name==$name)' >/dev/null; then runner_id=$local_id; break; fi
        printf '%s' "$remote" | "$JQ" -e --arg name "$name" 'any(.[]; (.name|ascii_downcase)==$name)' >/dev/null || return 1
        # The name belongs to another machine now; this directory never registered.
        rm -rf "$directory"
        runner_id=
    done
    safe_id "$runner_id" || return 1
    save_entry "$id" "$login" "$runner_id" "$name" || return 1
    log "Registered $name for $login"
    rm -f "$STATE/paused/$id"
}
# A runner beyond runner_count leaves once it is idle, so a running job is never cut off;
# its registration, program directory and jobs directory are removed.
retire_one() {
    local id=$1 login=$2 old_login runner_id name remote registered
    safe_key "$id" && safe_org "$login" && [[ $id == *.* ]] || return 1
    old_login=$("$JQ" -r --arg id "$id" '.[$id].login // empty' "$STATE/organizations.json")
    runner_id=$("$JQ" -r --arg id "$id" '.[$id].runner_id // 0' "$STATE/organizations.json")
    name=$("$JQ" -r --arg id "$id" '.[$id].runner_name // empty' "$STATE/organizations.json")
    safe_id "$runner_id" || return 1
    remote=$(list_runners "$login") || return 1
    registered=$(printf '%s' "$remote" | "$JQ" -c --argjson id "$runner_id" '[.[]|select(.id==$id)][0] // null')
    [ "$(printf '%s' "$registered" | "$JQ" -r '.busy // false')" != true ] || return 0
    : > "$STATE/paused/$id"
    stop_worker "$id"
    if [ "$registered" != null ]; then api "orgs/$login/actions/runners/$runner_id" --method DELETE >/dev/null || return 1; fi
    if indexed_name "$name"; then
        rm -rf "${RUNNERS_DIR:?}/$login/$name" "${JOBS_DIR:?}/$login/$name" || return 1
        if [ "$old_login" != "$login" ] && safe_org "$old_login"; then rm -rf "${RUNNERS_DIR:?}/$old_login/$name" || return 1; fi
    fi
    jq_update "$STATE/organizations.json" --arg id "$id" 'del(.[$id])' || return 1
    rm -f "$STATE/paused/$id" "$STATE/retry/$id"
    log "Removed ${name:-runner} from $login (runner count lowered)"
}
# Register, start and retire this organization's runners to match runner_count.
reconcile_organization() {
    local id=$1 login=$2 count=$3 slot=1 key
    while [ "$slot" -le "$count" ]; do
        key=$id; [ "$slot" = 1 ] || key=$id.$slot
        reconcile_one "$key" "$login" || return 1
        # Start each runner now; with many organizations and a slow network, waiting
        # for the whole pass would leave registered runners offline for minutes.
        [ -z "${SUPERVISING:-}" ] || ensure_worker "$key" "$login" || :
        slot=$((slot + 1))
    done
    while IFS= read -r key; do
        retire_one "$key" "$login" || return 1
    done < <("$JQ" -r --arg id "$id" --argjson count "$count" 'keys[] | select(startswith($id + ".") and ((split(".")[1] | tonumber) > $count))' "$STATE/organizations.json")
}
# Organizations without runner permission (or with persistent errors) are retried with
# exponential backoff, from poll_seconds up to one hour, instead of failing every poll.
backoff_due() {
    local due
    due=$(head -n 1 "$STATE/backoff/$1" 2>/dev/null || :)
    ! safe_id "${due:-x}" || [ "$(date +%s)" -ge "$due" ]
}
backoff_failure() {
    local id=$1 login=$2 count delay step=1
    count=$(sed -n 2p "$STATE/backoff/$id" 2>/dev/null || :)
    safe_id "${count:-x}" || count=0
    count=$((count + 1)); delay=$POLL
    while [ "$step" -lt "$count" ] && [ "$delay" -lt 3600 ]; do delay=$((delay * 2)); step=$((step + 1)); done
    [ "$delay" -le 3600 ] || delay=3600
    printf '%s\n%s\n' "$(( $(date +%s) + delay ))" "$count" | atomic "$STATE/backoff/$id"
    log "Organization $login: reconciliation failed (attempt $count); next retry in ${delay}s"
}
reconcile() {
    local memberships desired id login count
    count=$(runner_count) || count=1
    memberships=$(api 'user/memberships/orgs?state=active&per_page=100' --paginate --slurp) || { log 'Discovery failed; retaining current runners'; return 1; }
    desired=$(printf '%s' "$memberships" | "$JQ" -ce --slurpfile cfg "$ROOT/conf/settings.json" '($cfg[0].organizations // [] | map(ascii_downcase)) as $allow | [ .[][] | select(.state=="active") | .organization | .login as $name | select(($allow|length)==0 or ($allow|index($name|ascii_downcase))!=null) | {id:(.id|tostring),login} ]') || return 1
    while IFS=$'\t' read -r id login; do
        backoff_due "$id" || continue
        if reconcile_organization "$id" "$login" "$count"; then
            if [ -f "$STATE/backoff/$id" ]; then rm -f "$STATE/backoff/$id"; log "Organization $login: reconciliation recovered"; fi
        else backoff_failure "$id" "$login"; fi
    done < <(printf '%s' "$desired" | "$JQ" -r '.[] | [.id,.login] | @tsv')
    while IFS=$'\t' read -r id login; do
        if ! printf '%s' "$desired" | "$JQ" -e --arg id "${id%%.*}" 'any(.[]; .id==$id)' >/dev/null; then
            # Already deactivated: nothing to stop and nothing new to log.
            ! "$JQ" -e --arg id "$id" '.[$id].active == false' "$STATE/organizations.json" >/dev/null || continue
            rm -f "$STATE/backoff/${id%%.*}"
            : > "$STATE/paused/$id"
            stop_worker "$id"
            jq_update "$STATE/organizations.json" --arg id "$id" '.[$id].active=false'
            log "Stopped $login; local data retained"
        fi
    done < <("$JQ" -r 'to_entries[] | [.key,.value.login] | @tsv' "$STATE/organizations.json")
}
acquire_lock() {
    exec 9> "$STATE/service.lock"; flock -n 9
}
# A stopping manager's last children can hold the lock briefly after it exits.
wait_for_lock() {
    local attempt=0
    while [ "$attempt" -lt 30 ]; do acquire_lock && return 0; sleep 0.5; attempt=$((attempt + 1)); done
    return 1
}
shutdown() {
    trap - EXIT TERM INT
    stop_records "$STATE"/workers/*.pid "$STATE"/children/*.pid "$STATE"/timeouts/*.pid
    rm -f "$STATE/manager.pid"
}
# A ghr config --data-dir change takes the registered runners along. If they cannot move,
# reconciliation registers them again in the new directory under the same numbers.
move_runners() {
    local target=$WORK_DIR/runners
    # ghr config --data-dir prepares an empty runners directory there.
    [ "$RUNNERS_DIR" = "$target" ] || [ ! -d "$RUNNERS_DIR" ] || rmdir "$target" 2>/dev/null || :
    if [ "$RUNNERS_DIR" != "$target" ] && [ -d "$RUNNERS_DIR" ] && [ ! -L "$RUNNERS_DIR" ] && [ ! -e "$target" ]; then
        if mv "$RUNNERS_DIR" "$target" 2>/dev/null; then log "Moved runners from $RUNNERS_DIR to $target";
        else log "Cannot move $RUNNERS_DIR to $target; the runners register again there"; fi
    fi
    RUNNERS_DIR=$target
}
serve() {
    local next=0 now applied= count
    [ ! -f "$ROOT/conf/stopped" ] || return 0
    exec 2>> "$LOG_DIR/service.log"
    acquire_lock || { printf 'Another manager is running.\n' >&2; return 1; }
    trap shutdown EXIT
    trap 'exit 0' TERM INT
    record_pid "$STATE/manager.pid" "$$" || return 1
    move_runners
    printf '%s\n' "$WORK_DIR" | atomic "$STATE/active-work-dir" || return 1
    # Every work directory used is remembered, so uninstall can clean all of them.
    grep -Fqx -- "$WORK_DIR" "$STATE/work-dirs" 2>/dev/null || printf '%s\n' "$WORK_DIR" >> "$STATE/work-dirs"
    stop_records "$STATE"/workers/*.pid "$STATE"/children/*.pid "$STATE"/timeouts/*.pid
    log "Started Shell supervisor $PREFIX"
    SUPERVISING=1
    while [ ! -f "$ROOT/conf/stopped" ]; do
        # Reopen after log rotation so diagnostics land in the current file.
        exec 2>> "$LOG_DIR/service.log"
        ensure_workers
        now=$(date +%s)
        # ghr runner --add/--sub takes effect without waiting for the next poll.
        count=$(runner_count) || count=$applied
        if [ "$now" -ge "$next" ] || [ "$count" != "$applied" ]; then applied=$count; reconcile || :; next=$(( $(date +%s) + POLL )); fi
        ensure_workers
        sleep 5 & wait $! || :
    done
}
# Whether jobs can use the host Docker daemon and passwordless sudo, for ghr status.
docker_access_state() {
    local group
    if [ "$("$JQ" -r '.runtime // "native"' "$ROOT/conf/settings.json")" = docker ]; then printf 'on (Docker mode); root-equivalent on this host'; return 0; fi
    if [ "$("$JQ" -r '.docker_access != false' "$ROOT/conf/settings.json")" = false ]; then printf 'off (LOCAL_RUNNER_DOCKER_ACCESS=no)'; return 0; fi
    group=$("$JQ" -r '.docker_group // empty' "$ROOT/conf/settings.json")
    if [ -n "$group" ]; then printf 'on (group %s); root-equivalent on this host' "$group"
    else printf 'unavailable (no Docker socket with a dedicated group at install time)'; fi
}
job_sudo_state() {
    if [ "$("$JQ" -r '.job_sudo == true' "$ROOT/conf/settings.json")" != true ]; then
        if [ "$("$JQ" -r '.job_sudo_choice == false' "$ROOT/conf/settings.json")" = true ]; then printf 'off (LOCAL_RUNNER_SUDO=no)'
        elif [ "$("$JQ" -r '.runtime // "native"' "$ROOT/conf/settings.json")" = native ] && [ ! -f "$ROOT/conf/account.json" ]; then printf 'off (needs a root installation)'
        else printf 'off (sudo unavailable; run the installer again after installing it)'; fi
    elif [ "$("$JQ" -r '.runtime // "native"' "$ROOT/conf/settings.json")" = docker ]; then printf 'on; passwordless sudo inside the container'
    else printf 'on; passwordless sudo, which is root on this host'; fi
}
# What keeps this machine awake for the installation, for ghr status.
sleep_prevention() {
    local unit
    if [ "$("$JQ" -r '.prevent_sleep != false' "$ROOT/conf/settings.json")" = false ]; then printf 'off (LOCAL_RUNNER_PREVENT_SLEEP=no)'; return 0; fi
    if [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        printf 'kept by the Windows host task (see WSL host task)'; return 0
    fi
    unit=local-github-runner-$("$JQ" -r '.owner_uid // empty' "$ROOT/conf/settings.json")-$ARCH-awake.service
    if [ ! -f "$SYSTEMD_UNITS/$unit" ]; then
        if command -v systemd-inhibit >/dev/null 2>&1; then printf 'not set up; run the installer again'; else printf 'unavailable (no systemd-inhibit)'; fi
    elif systemctl is-active --quiet "$unit" 2>/dev/null; then printf 'on; sleep and lid-close suspend are blocked'
    elif [ "$1" = running ]; then printf 'starting'
    else printf 'released while the manager is stopped'; fi
}
status() {
    local id login runner_id name active remote row local_status local_pid remote_name remote_status busy
    local failed=0 count=0 online=0 offline=0 missing=0 unknown=0 jobs=0 listening=0 restarting=0
    local others other_name other_status other_busy other_count=0 other_online=0 other_offline=0 other_jobs=0
    local org entries local_ids remaining organizations=0
    local manager=stopped work=$WORK_DIR directory_state='configured; not started yet' work_prefix configured_prefix
    local -a items=() notes=()
    # Three tables: the installation overview, the organizations and their runners, then the counts.
    item() { items+=("$1" "$2"); }
    if record_alive "$STATE/manager.pid"; then manager=running; fi
    item Platform "$OS / $ARCH"
    if [ "$manager" = running ]; then item Manager "running (PID $(head -n 1 "$STATE/manager.pid"))"
    elif [ -f "$ROOT/conf/stopped" ]; then item Manager 'stopped (run ghr start to resume)'
    else item Manager stopped; fi
    if [ "$("$JQ" -r '.runtime // "native"' "$ROOT/conf/settings.json")" = docker ]; then
        item Runtime "Docker ($("$JQ" -r '.docker_image // "image not built"' "$ROOT/conf/settings.json")); jobs can control the host Docker daemon"
    fi
    [ ! -f "$ROOT/conf/account.json" ] || item 'Runner account' "ghrunner (UID $("$JQ" -r .owner_uid "$ROOT/conf/settings.json"))"
    item 'Sleep prevention' "$(sleep_prevention "$manager")"
    item 'Docker access' "$(docker_access_state)"
    item 'Job sudo' "$(job_sudo_state)"
    item 'Runners per organization' "$(runner_count)"
    item 'Install directory' "$ROOT"
    item 'Runners directory' "$RUNNERS_DIR"
    if [ -s "$STATE/active-work-dir" ]; then
        work=$(cat "$STATE/active-work-dir")
        directory_state='last run; manager stopped'
        [ "$manager" != running ] || directory_state=active
    fi
    work_prefix=$work; [ "$work" != / ] || work_prefix=
    configured_prefix=$WORK_DIR; [ "$WORK_DIR" != / ] || configured_prefix=
    item 'Work directory' "$work ($directory_state)"
    item 'Jobs directory' "$work_prefix/jobs"
    item 'Logs directory' "$work_prefix/logs"
    item 'Configured work directory' "$WORK_DIR"
    if [ "$work" != "$WORK_DIR" ]; then
        item Configuration "pending; next start uses $configured_prefix/jobs and $configured_prefix/logs"
        notes+=('Run ghr restart (or stop then start) to apply the pending directory change.')
    else item Configuration 'no pending directory change'; fi
    printf 'GitHub Runner status\n\n%-26s %s\n' ITEM VALUE
    printf '%-26s %s\n' "${items[@]}"
    items=()
    # A tree: each organization, then its runners (this installation's first). The branch
    # is printed apart from the padded columns, so multibyte line characters keep alignment.
    local row_format='%s %-32s %-9s %-5s %-11s %s\n' middle='|--' last='`--' branch
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) middle='├──'; last='└──' ;; esac
    printf '\n%-36s %-9s %-5s %-11s %s\n' 'ORGANIZATION / RUNNER' GITHUB BUSY LOCAL PID
    while IFS=$'\t' read -r org login; do
        organizations=$((organizations+1))
        entries=$("$JQ" -r --arg org "$org" '[to_entries[] | select((.key | split(".")[0]) == $org)] | sort_by(.key | split(".")[1] // "1" | tonumber)[] | [.key,.value.runner_id,(.value.runner_name // "unknown"),(.value.active != false)] | @tsv' "$STATE/organizations.json")
        local_ids=$("$JQ" -c --arg org "$org" '[to_entries[] | select((.key | split(".")[0]) == $org) | .value.runner_id]' "$STATE/organizations.json")
        others=; remote=
        if remote=$(list_runners "$login"); then
            # Every other runner of the organization: other machines, platforms or manual runners.
            others=$(printf '%s' "$remote" | "$JQ" -r --argjson ids "$local_ids" \
                '[.[]|select(.id as $id | $ids | index($id) | not)] | sort_by(.name|ascii_downcase)[] | [.name,(.status // "unknown"),(if .busy == null then "?" else (.busy|tostring) end)] | @tsv')
        else remote=; fi
        remaining=$(printf '%s\n' "$entries" | grep -c .)
        [ -z "$others" ] || remaining=$((remaining + $(printf '%s\n' "$others" | grep -c .)))
        printf '%s\n' "$login"
        while IFS=$'\t' read -r id runner_id name active; do
            [ -n "$id" ] || continue
            count=$((count+1)); local_status=stopped; local_pid=-
            if record_alive "$STATE/children/$id.pid"; then
                local_status=running; local_pid=$(head -n 1 "$STATE/children/$id.pid"); listening=$((listening+1))
            elif record_alive "$STATE/workers/$id.pid"; then
                local_status=restarting; local_pid=$(head -n 1 "$STATE/workers/$id.pid"); restarting=$((restarting+1))
            elif [ "$active" = false ] || [ -f "$STATE/paused/$id" ]; then local_status=paused; fi
            remote_name=$name; remote_status=unknown; busy='?'
            if [ -n "$remote" ] && row=$(printf '%s' "$remote" | "$JQ" -er --argjson id "$runner_id" --arg name "$name" \
                '([.[]|select(.id==$id)][0]) as $r | if $r == null then [$name,"missing","-"] else [($r.name // $name),($r.status // "unknown"),(if $r.busy == null then "?" else ($r.busy|tostring) end)] end | @tsv'); then
                IFS=$'\t' read -r remote_name remote_status busy <<< "$row"
            fi
            case "$remote_status" in
                online) online=$((online+1)) ;; offline) offline=$((offline+1)) ;; missing) missing=$((missing+1)) ;;
                *) remote_status=unknown; busy='?'; unknown=$((unknown+1)); failed=1 ;;
            esac
            [ "$busy" != true ] || jobs=$((jobs+1))
            remaining=$((remaining-1)); branch=$middle; [ "$remaining" != 0 ] || branch=$last
            printf "$row_format" "$branch" "$remote_name" "$remote_status" "$busy" "$local_status" "$local_pid"
        done <<< "$entries"
        while IFS=$'\t' read -r other_name other_status other_busy; do
            [ -n "$other_name" ] || continue
            other_count=$((other_count+1)); remaining=$((remaining-1))
            branch=$middle; [ "$remaining" != 0 ] || branch=$last
            case "$other_status" in online) other_online=$((other_online+1)) ;; offline) other_offline=$((other_offline+1)) ;; esac
            [ "$other_busy" != true ] || other_jobs=$((other_jobs+1))
            printf "$row_format" "$branch" "$other_name" "$other_status" "$other_busy" other -
        done <<< "$others"
    done < <("$JQ" -r '[to_entries[] | {org: (.key | split(".")[0]), slot: (.key | split(".")[1] // "1" | tonumber), login: .value.login}] | sort_by(.org, .slot) | unique_by(.org) | sort_by(.login)[] | [.org, .login] | @tsv' "$STATE/organizations.json")
    item Organizations "$organizations"
    item Runners "$count"
    item GitHub "$online online, $offline offline, $missing missing, $unknown unknown; $jobs busy"
    [ "$other_count" = 0 ] || item 'Other runners' "$other_count ($other_online online, $other_offline offline); $other_jobs busy"
    item Local "$listening running, $restarting restarting, $((count-listening-restarting)) stopped/paused"
    [ "$restarting" = 0 ] || notes+=('restarting: runner worker is alive; listener is not running yet.')
    [ "$failed" = 0 ] || notes+=('Some GitHub statuses could not be queried; unknown does not mean offline.')
    [ "$count" -ne 0 ] || printf 'No runners registered yet. Use ghr logs to check discovery and registration.\n'
    printf '\n%-26s %s\n' SUMMARY VALUE
    printf '%-26s %s\n' "${items[@]}"
    [ "${#notes[@]}" = 0 ] || printf '\n'
    [ "${#notes[@]}" = 0 ] || printf '%s\n' "${notes[@]}"
    return "$failed"
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    if [ "${1:-serve}" = verify ]; then init control || exit 1; else init || exit 1; fi
    case "${1:-serve}" in serve) serve ;; worker) /bin/bash "$ROOT/bin/runner.sh" "$ROOT" "${2:?organization ID required}" ;; prepare) ensure_package ;; verify) verify_runtime ;; status) status ;; once) reconcile ;; *) exit 1 ;; esac
fi
