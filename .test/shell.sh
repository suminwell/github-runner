#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in Darwin) PLATFORM=macos ;; *) PLATFORM=linux ;; esac
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-shell.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
export FAKE_FIXTURE=$FIXTURE
cleanup() {
    if declare -F stop_worker >/dev/null; then
        stop_record "$ROOT/conf/manager.pid" 2>/dev/null || :
        [ ! -f "$FIXTURE/follower.pid" ] || stop_record "$FIXTURE/follower.pid" 2>/dev/null || :
        for id in 1 1.2 1.3 2 3 4 5 6 7; do stop_worker "$id" 2>/dev/null || :; done
        for record in "$FIXTURE/watchdog-records/"*.pid; do stop_record "$record" 2>/dev/null || :; done
    fi
    if [ "${TEST_FAILED:-1}" = 0 ]; then rm -rf "$FIXTURE"; else printf "Retained fixture: %s\n" "$FIXTURE"; fi
}
trap cleanup EXIT
assert() { if ! "$@" >/dev/null; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
# Exercise the public entry point using fake installers, without touching the host.
(
    bootstrap=$FIXTURE/bootstrap
    mkdir -p "$bootstrap/commands" "$bootstrap/source tree/linux" "$bootstrap/source tree/macos" "$bootstrap/temporary"
    export BOOTSTRAP_SOURCE="$bootstrap/source tree" BOOTSTRAP_MARKER="$bootstrap/result" BOOTSTRAP_URL_LOG="$bootstrap/url"
    BOOTSTRAP_SOURCE=$(cd "$BOOTSTRAP_SOURCE" && pwd)
    export LOCAL_RUNNER_HOME="$bootstrap/custom home" TMPDIR="$bootstrap/temporary"
    export PATH="$bootstrap/commands:$PATH"
    unset LOCAL_RUNNER_SOURCE_DIR LOCAL_RUNNER_BASE_URL
    printf '#!/bin/sh\nprintf "%%s\\n" "$BOOTSTRAP_OS"\n' > "$bootstrap/commands/uname"
    cat > "$bootstrap/commands/curl" <<'CURL'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in -o) destination=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
printf '%s\n' "$url" > "$BOOTSTRAP_URL_LOG"
case "$url" in */linux/install.sh) target=linux ;; */macos/install.sh) target=macos ;; *) exit 90 ;; esac
cp "$BOOTSTRAP_SOURCE/$target/install.sh" "$destination"
[ "${BOOTSTRAP_FAIL:-0}" != 1 ] || exit 22
CURL
    chmod +x "$bootstrap/commands/"*
    cp "$REPO/install.sh" "$BOOTSTRAP_SOURCE/install.sh"
    for target in linux macos; do
        printf '#!/bin/sh\nprintf "%%s\\n" %s > "$BOOTSTRAP_MARKER"\n' "$target" > "$BOOTSTRAP_SOURCE/$target/install.sh"
        cat >> "$BOOTSTRAP_SOURCE/$target/install.sh" <<'INSTALL'
printf '%s\n' "${1:-auto}" "$LOCAL_RUNNER_HOME" "${LOCAL_RUNNER_SOURCE_DIR:-remote}" >> "$BOOTSTRAP_MARKER"
exit "${BOOTSTRAP_STATUS:-0}"
INSTALL
    done
    for BOOTSTRAP_OS in Linux Darwin; do
        export BOOTSTRAP_OS
        target=linux; [ "$BOOTSTRAP_OS" != Darwin ] || target=macos
        LOCAL_RUNNER_SOURCE_DIR=$BOOTSTRAP_SOURCE sh "$REPO/install.sh" arm64
        assert test "$(head -n 1 "$BOOTSTRAP_MARKER")" = "$target"
        assert test "$(sed -n '2p' "$BOOTSTRAP_MARKER")" = arm64
        assert test "$(sed -n '3p' "$BOOTSTRAP_MARKER")" = "$LOCAL_RUNNER_HOME"
        (cd "$FIXTURE" && sh "$BOOTSTRAP_SOURCE/install.sh" x64)
        assert test "$(sed -n '4p' "$BOOTSTRAP_MARKER")" = "$BOOTSTRAP_SOURCE"
        export LOCAL_RUNNER_BASE_URL=https://example.invalid/pinned
        cat "$REPO/install.sh" | sh -s -- x64
        assert test "$(cat "$BOOTSTRAP_URL_LOG")" = "$LOCAL_RUNNER_BASE_URL/$target/install.sh"
        assert test "$(sed -n '4p' "$BOOTSTRAP_MARKER")" = remote
        unset LOCAL_RUNNER_BASE_URL
    done
    export LOCAL_RUNNER_BASE_URL=https://example.invalid/pinned
    rm "$BOOTSTRAP_MARKER"
    if BOOTSTRAP_FAIL=1 sh "$REPO/install.sh"; then echo 'Executed a failed download' >&2; exit 1; fi
    assert test ! -f "$BOOTSTRAP_MARKER"
    result=0; BOOTSTRAP_STATUS=17 sh "$REPO/install.sh" || result=$?
    assert test "$result" = 17
    if BOOTSTRAP_OS=FreeBSD sh "$REPO/install.sh" 2>/dev/null; then echo 'Accepted unsupported OS' >&2; exit 1; fi
    rmdir "$TMPDIR"
)
# Run installer helpers against temporary files; never install a host service.
(
    sed '/^install_main()/,$d' "$REPO/$PLATFORM/install.sh" > "$FIXTURE/installer-helpers.sh"
    . "$FIXTURE/installer-helpers.sh"
    # Apple silicon is reported as arm64 even from a Rosetta (x86_64) shell.
    x86=x64; [ "$PLATFORM" != macos ] || [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || :)" != 1 ] || x86=arm64
    uname() { printf '%s\n' "$machine"; }
    for machine in x86_64 amd64; do detect_architecture; assert test "$arch" = "$x86"; done
    for machine in arm64 aarch64; do detect_architecture; assert test "$arch" = arm64; done
    machine=riscv64
    if detect_architecture 2>/dev/null; then echo 'Accepted unsupported architecture' >&2; exit 1; fi
    unset -f uname
    # Validate generated service definitions with the real host tools when present.
    root="$FIXTURE/unit root %h \$HOME"
    mkdir -p "$root/bin"
    if [ "$PLATFORM" = linux ]; then
        systemd_unit "$(id -un)" "$HOME" "$PATH" "$root" > "$FIXTURE/unit-check.service"
        assert grep -Fqx "WorkingDirectory=$FIXTURE/unit root %%h \$HOME" "$FIXTURE/unit-check.service"
        if command -v systemd-analyze >/dev/null 2>&1; then
            systemd-analyze verify "$FIXTURE/unit-check.service" || { echo 'systemd rejected the generated unit' >&2; exit 1; }
        fi
    else
        launchd_plist com.example.check "$(id -un)" "$HOME" "$PATH" "$root" > "$FIXTURE/unit-check.plist"
        assert plutil -lint "$FIXTURE/unit-check.plist"
        assert test "$(plutil -extract WorkingDirectory raw -o - "$FIXTURE/unit-check.plist")" = "$root"
    fi
)
# Half of 6 CPUs: up to 3 runners per organization, whatever machine runs the tests.
export LOCAL_RUNNER_CPU_COUNT=6
for arch in x64 arm64; do
    export LOCAL_RUNNER_ROOT=$FIXTURE/$arch
    ROOT=$LOCAL_RUNNER_ROOT
    mkdir -p "$ROOT/bin" "$ROOT/conf" "$ROOT/bin/.cache/package"
    cp "$REPO/$PLATFORM/service.sh" "$ROOT/bin/service.sh"
    cp "$REPO/$PLATFORM/runner.sh" "$ROOT/bin/runner.sh"
    cp "$REPO/$PLATFORM/ghr.sh" "$ROOT/bin/ghr.sh"
    printf '%s\n' "$(command -v jq)" > "$ROOT/conf/jq-path"
    printf '/usr/bin/false\n' > "$ROOT/conf/gh-path"
    printf 'secret-test-token\n' > "$ROOT/conf/github-token"
    jq -n --arg arch "$arch" '{arch:$arch,poll_seconds:10,restart_seconds:1,organizations:[]}' > "$ROOT/conf/settings.json"
    printf 'fixture\n' > "$ROOT/bin/.cache/package/.complete"
    printf '{}\n' > "$FIXTURE/remote.json"
    printf '100\n' > "$FIXTURE/next-id"
    printf '[[{"state":"active","organization":{"id":1,"login":"alpha"}}]]\n' > "$FIXTURE/memberships.json"
    cat > "$ROOT/bin/.cache/package/config.sh" <<'CONFIG'
#!/bin/bash
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in --url) login=${2##*/}; shift 2 ;; --name) name=$2; shift 2 ;; --labels) labels=$2; shift 2 ;; --work) work=$2; shift 2 ;; --token) token=$2; shift 2 ;; *) shift ;; esac
done
[ -z "${GH_TOKEN:-}" ] || exit 90
case "$login" in
    leaky) printf '%s%s\n' "$(printf '%0290d' 0 | tr 0 x)" "$token"; exit 1 ;;
    hang) trap '' TERM; (trap '' TERM; sleep 60; echo leaked) & printf '%s\n' "$!" > "$FAKE_FIXTURE/hang-child"; sleep 60; exit 0 ;;
esac
[ "$labels" = "${name%-*},$name" ] || exit 91
if [ "$login" = race ] && [ ! -f "$FAKE_FIXTURE/raced" ]; then
    touch "$FAKE_FIXTURE/raced"
    jq --arg name "$name" '.race=[{id:997,name:$name,busy:false}]' "$FAKE_FIXTURE/remote.json" > "$FAKE_FIXTURE/remote.new"
    mv "$FAKE_FIXTURE/remote.new" "$FAKE_FIXTURE/remote.json"
    exit 1
fi
if jq -e --arg login "$login" --arg name "$name" 'any(.[$login][]?; .name==$name)' "$FAKE_FIXTURE/remote.json" >/dev/null; then exit 1; fi
id=$(cat "$FAKE_FIXTURE/next-id")
printf '%s\n' "$((id+1))" > "$FAKE_FIXTURE/next-id"
jq -n --argjson id "$id" --arg name "$name" --arg work "$work" --arg login "$login" '{agentId:$id,agentName:$name,work:$work,gitHubUrl:("https://github.com/"+$login)}' > .runner
jq --arg login "$login" --arg name "$name" --argjson id "$id" '.[$login] = ((.[$login] // []) + [{id:$id,name:$name,busy:false,status:"online"}])' "$FAKE_FIXTURE/remote.json" > "$FAKE_FIXTURE/remote.new"
mv "$FAKE_FIXTURE/remote.new" "$FAKE_FIXTURE/remote.json"
[ "$login" != partial ] || exit 1
CONFIG
    cat > "$ROOT/bin/.cache/package/run.sh" <<'RUN'
#!/bin/bash
[ -z "${GH_TOKEN:-}" ] || exit 92
printf 'run\n' >> "$FAKE_FIXTURE/listener-runs"
sleep 0.2
RUN
    . "$ROOT/bin/ghr.sh"
    init
    printf '{"keep":1}\n' > "$FIXTURE/jq-update.json"
    if jq_update "$FIXTURE/jq-update.json" '.keep |= error("boom")' 2>/dev/null; then echo 'jq_update accepted a failed filter' >&2; exit 1; fi
    if jq_update "$FIXTURE/jq-update.json" 'empty'; then echo 'jq_update accepted empty output' >&2; exit 1; fi
    assert jq -e '.keep==1' "$FIXTURE/jq-update.json"
    jq_update "$FIXTURE/jq-update.json" '.keep=2'
    assert jq -e '.keep==2' "$FIXTURE/jq-update.json"
    # External calls are bounded, and gh failures are reported without the token.
    started=$(date +%s)
    if with_timeout 1 sleep 30; then echo 'with_timeout did not stop a hung command' >&2; exit 1; fi
    assert test "$(( $(date +%s) - started ))" -lt 10
    # The deadline covers the whole process tree of a wrapped function, and the output pipe closes.
    started=$(date +%s)
    if output=$(with_timeout 1 clean_exec /bin/bash -c 'sleep 5; printf "child_completed\n"' 2>&1); then echo 'Timed-out command reported success' >&2; exit 1; else status=$?; fi
    assert test "$status" = 124
    assert test "$(( $(date +%s) - started ))" -lt 4
    case "$output" in *child_completed*) echo 'A timed-out child kept running' >&2; exit 1 ;; esac
    # Descendants that ignore TERM are forced after the grace period.
    started=$(date +%s)
    if output=$(with_timeout 1 /bin/bash -c 'trap "" TERM; (trap "" TERM; sleep 30; echo leaked) & echo "$!" > "$1"; wait' _ "$FIXTURE/stubborn-child" 2>&1); then echo 'Timed-out command reported success' >&2; exit 1; fi
    assert test "$(( $(date +%s) - started ))" -lt 7
    case "$output" in *leaked*) echo 'A TERM-ignoring descendant survived' >&2; exit 1 ;; esac
    for attempt in $(seq 1 20); do kill -0 "$(cat "$FIXTURE/stubborn-child")" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$(cat "$FIXTURE/stubborn-child")" 2>/dev/null; then echo 'A TERM-ignoring descendant is still alive' >&2; exit 1; fi
    # A finished command's background stragglers are removed, so the caller's pipe closes at once.
    started=$(date +%s)
    output=$(with_timeout 10 /bin/bash -c '(sleep 30) & echo "$!" > "$1"; echo finished' _ "$FIXTURE/straggler")
    assert test "$output" = finished
    assert test "$(( $(date +%s) - started ))" -lt 4
    for attempt in $(seq 1 20); do kill -0 "$(cat "$FIXTURE/straggler")" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$(cat "$FIXTURE/straggler")" 2>/dev/null; then echo 'A straggler outlived its finished command' >&2; exit 1; fi
    # No watchdog is left behind, and the manager lock descriptor is never inherited.
    exec 9> "$FIXTURE/fd9.lock"
    assert with_timeout 30 /bin/bash -c '[ ! -e /dev/fd/9 ]'
    exec 9>&-
    started=$(date +%s); wait
    assert test "$(( $(date +%s) - started ))" -lt 3
    assert test -z "$(ls "$ROOT/conf/timeouts")"
    printf '#!/bin/sh\necho "HTTP 403: Must have admin rights (https://api.github.com/x)" >&2\nexit 1\n' > "$FIXTURE/failing-gh"
    chmod +x "$FIXTURE/failing-gh"
    real_gh=$GH; GH=$FIXTURE/failing-gh
    if api 'orgs/denied/actions/runners?per_page=1' 2> "$FIXTURE/api-error" >/dev/null; then echo 'api ignored a gh failure' >&2; exit 1; fi
    GH=$real_gh
    assert grep -q 'gh api orgs/denied/actions/runners failed (exit 1): HTTP 403: Must have admin rights' "$FIXTURE/api-error"
    if grep -q secret-test-token "$FIXTURE/api-error"; then echo 'api leaked the token' >&2; exit 1; fi
    # Rapid failures race watchdog initialization and cancellation. Track real sleeper
    # PIDs/start times so orphaned timers are detected, even after they lose their parent.
    (
        export REAL_SLEEP=$(command -v sleep) FAKE_WATCHDOG_DIR=$FIXTURE/watchdog-records
        mkdir -p "$FIXTURE/watchdog-bin" "$FAKE_WATCHDOG_DIR"
        cat > "$FIXTURE/watchdog-bin/sleep" <<'SLEEP'
#!/bin/sh
# The same identity the platform's service.sh records: Linux boot ticks, macOS lstart.
if [ -r "/proc/$$/stat" ]; then stat=$(cat "/proc/$$/stat"); stat=${stat##*) }; set -- $stat; mark=${20}
else mark=$(ps -p "$$" -o lstart= | awk '{$1=$1; print}'); fi
printf '%s\n%s\n' "$$" "$mark" > "$FAKE_WATCHDOG_DIR/$$.pid"
exec "$REAL_SLEEP" "$@"
SLEEP
        chmod +x "$FIXTURE/watchdog-bin/sleep"
        export PATH=$FIXTURE/watchdog-bin:$PATH
        GH=$FIXTURE/failing-gh
        for attempt in $(seq 1 32); do
            if api 'orgs/denied/actions/runners?per_page=1' 2> "$FIXTURE/api-error" >/dev/null; then exit 1; else status=$?; fi
            assert test "$status" = 1
            assert grep -q 'gh api orgs/denied/actions/runners failed (exit 1): HTTP 403: Must have admin rights' "$FIXTURE/api-error"
            assert test "$(wc -l < "$FIXTURE/api-error" | tr -d ' ')" = 1
            assert with_timeout 30 true
        done
        "$REAL_SLEEP" 0.2
        for record in "$FAKE_WATCHDOG_DIR/"*.pid; do
            if record_alive "$record"; then echo 'A cancelled watchdog left its sleeper running' >&2; exit 1; fi
        done
    )
    # Stopping waits for a graceful exit, and forces processes that ignore TERM.
    bash -c 'trap "sleep 1; echo graceful > \"$1\"; exit 0" TERM; while :; do sleep 0.1; done' _ "$FIXTURE/graceful" &
    record_pid "$FIXTURE/graceful.pid" "$!"
    stop_record "$FIXTURE/graceful.pid"
    assert test "$(cat "$FIXTURE/graceful")" = graceful
    bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
    stubborn=$!; record_pid "$FIXTURE/stubborn.pid" "$stubborn"; cp "$FIXTURE/stubborn.pid" "$FIXTURE/stubborn.check"
    previous_grace=$STOP_GRACE; STOP_GRACE=1; stop_record "$FIXTURE/stubborn.pid"; STOP_GRACE=$previous_grace
    if record_alive "$FIXTURE/stubborn.check"; then echo 'A process ignoring TERM survived stop' >&2; exit 1; fi
    api() {
        local endpoint=$1 login runner_id
        case "$endpoint" in
            orgs/denied/*) return 1 ;;
            organizations/*) runner_id=${endpoint##*/}; jq -c --arg id "$runner_id" '{id:($id|tonumber),login:.[$id].login}' "$ROOT/conf/organizations.json" ;;
            user/memberships/*) [ ! -f "$FIXTURE/fail-discovery" ] || return 1; cat "$FIXTURE/memberships.json" ;;
            */registration-token) printf '{"token":"%s"}\n' "$(cat "$FIXTURE/registration-token" 2>/dev/null || printf temporary)" ;;
            *'/runners?'*) login=${endpoint#orgs/}; login=${login%%/*}; jq -c --arg login "$login" '(.[$login] // []) as $r | [{runners:$r[:1]},{runners:$r[1:]}]' "$FIXTURE/remote.json" ;;
            */actions/runners/*)
                [ ! -f "$FIXTURE/fail-delete" ] || return 1
                login=${endpoint#orgs/}; login=${login%%/*}; runner_id=${endpoint##*/}
                jq --arg login "$login" --argjson id "$runner_id" '.[$login] = [.[$login][] | select(.id!=$id)]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"
                mv "$FIXTURE/remote.new" "$FIXTURE/remote.json" ;;
            orgs/*) login=${endpoint#orgs/}; jq -ce --arg login "$login" 'first(to_entries[] | select(.value.login==$login) | {id:(.key|split(".")[0]|tonumber),login:.value.login})' "$ROOT/conf/organizations.json" ;;
            *) echo "Unexpected endpoint $endpoint" >&2; return 1 ;;
        esac
    }
    export GH_TOKEN=should-not-reach-runner
    # Directories follow organization and runner name: runner/<login>/<name>, jobs/<login>/<name>.
    runner_name() { jq -r --arg id "$1" '.[$id].runner_name' "$ROOT/conf/organizations.json"; }
    # Registration output is redacted before truncation: a token straddling the cut never leaks.
    fake_token=FAKEtokenABCDEFGHIJKLMNOPQRSTUVWXYZa
    assert test "${#fake_token}" = 36
    printf '%s\n' "$fake_token" > "$FIXTURE/registration-token"
    if configure_runner leaky "$PREFIX-1" >/dev/null; then echo 'Failed registration reported success' >&2; exit 1; fi
    rm -f "$FIXTURE/registration-token"
    assert grep -F "Organization leaky: runner configuration as $PREFIX-1 failed" "$ROOT/logs/service.log"
    assert grep -F 'xxx***' "$ROOT/logs/service.log"
    if grep -F "${fake_token:0:10}" "$ROOT/logs/service.log"; then echo 'A partial token reached the log' >&2; exit 1; fi
    # A hung registration is bounded through the real wrapper, including TERM-ignoring children.
    started=$(date +%s)
    if RUNNER_CONFIG_TIMEOUT=1 configure_runner hang "$PREFIX-1" >/dev/null; then echo 'Hung registration reported success' >&2; exit 1; fi
    assert test "$(( $(date +%s) - started ))" -lt 8
    assert grep -F "Organization hang: runner configuration as $PREFIX-1 failed (exit 124)" "$ROOT/logs/service.log"
    for attempt in $(seq 1 20); do kill -0 "$(cat "$FIXTURE/hang-child")" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$(cat "$FIXTURE/hang-child")" 2>/dev/null; then echo 'A hung registration child survived' >&2; exit 1; fi
    rm -rf "$ROOT/runner/leaky" "$ROOT/runner/hang"
    reconcile
    assert jq -e '."1".login=="alpha" and ."1".runner_id==100' "$ROOT/conf/organizations.json"
    assert jq -e --arg name "$PREFIX-1" '.alpha[0].name==$name' "$FIXTURE/remote.json"
    assert jq -e --arg name "$PREFIX-1" '."1".runner_name==$name' "$ROOT/conf/organizations.json"
    assert jq -e --arg work "$ROOT/jobs/alpha/$PREFIX-1" '.work==$work' "$ROOT/runner/alpha/$PREFIX-1/app/.runner"
    reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 101
    touch "$FIXTURE/fail-discovery"
    if reconcile; then echo 'Discovery failure not propagated' >&2; exit 1; fi
    assert jq -e 'has("1")' "$ROOT/conf/organizations.json"
    rm "$FIXTURE/fail-discovery"
    # Remote deletion and lost local configuration each recover the owned runner.
    printf '{}\n' > "$FIXTURE/remote.json"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 102
    rm "$ROOT/runner/alpha/$(runner_name 1)/app/.runner"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 103
    # Rename keeps old data and defers while the runner is busy.
    alpha_jobs=$ROOT/jobs/alpha/$(runner_name 1)
    mkdir -p "$alpha_jobs/repo"; printf keep > "$alpha_jobs/repo/keep"
    printf '[[{"state":"active","organization":{"id":1,"login":"renamed"}}]]\n' > "$FIXTURE/memberships.json"
    jq '.renamed=.alpha|del(.alpha)|.renamed[0].busy=true' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="alpha"' "$ROOT/conf/organizations.json"
    jq '.renamed[0].busy=false' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="renamed"' "$ROOT/conf/organizations.json"
    assert test -f "$alpha_jobs/repo/keep"
    assert test -d "$ROOT/jobs/renamed/$(runner_name 1)"
    assert test ! -e "$ROOT/runner/alpha"
    assert test -f "$ROOT/runner/renamed/$(runner_name 1)/app/run.sh"
    # Lost state after successful registration recovers the existing identity.
    printf '{}\n' > "$ROOT/conf/organizations.json"; previous=$(cat "$FIXTURE/next-id"); reconcile
    assert test "$(cat "$FIXTURE/next-id")" = "$previous"
    # Each organization/OS/architecture has an independent sequence; all pages count.
    other=x64; [ "$arch" != x64 ] || other=arm64
    jq --arg name "local-$PLATFORM-$other-50" '.beta=[{id:999,name:$name,busy:false}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 2 beta
    assert jq -e '.beta|length==2' "$FIXTURE/remote.json"
    assert jq -e --arg name "$PREFIX-1" '.beta[-1].name==$name' "$FIXTURE/remote.json"
    jq --arg p "$PREFIX" '.collision=[{id:998,name:($p+"-1"),busy:false},{id:990,name:($p+"-3"),busy:false},{id:991,name:($p+"-10"),busy:false,status:"offline"},{id:992,name:($p+"-99-extra"),busy:false},{id:993,name:"unrelated-100",busy:false}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-11" '.collision[-1].name==$name and .collision[0].id==998' "$FIXTURE/remote.json"
    previous=$(cat "$FIXTURE/next-id"); reconcile_one 3 collision
    assert test "$(cat "$FIXTURE/next-id")" = "$previous"
    # A competing installation gets the candidate first; retry with the next index.
    rm -f "$FIXTURE/raced"
    reconcile_one 5 race
    assert jq -e --arg name "$PREFIX-2" '.race[-1].name==$name and .race[0].id==997' "$FIXTURE/remote.json"
    # Registration may report failure after it persisted credentials: recover the ID.
    reconcile_one 6 partial
    assert jq -e --arg name "$PREFIX-1" '."6".runner_name==$name' "$ROOT/conf/organizations.json"
    # If another installation takes a deleted registration's number, allocate anew.
    jq --arg name "$PREFIX-11" '.collision |= map(if .name==$name then .id=995 else . end)' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-12" '.collision[-1].name==$name and any(.collision[]; .id==995)' "$FIXTURE/remote.json"
    if reconcile_one 4 ../escape; then echo 'Accepted unsafe organization' >&2; exit 1; fi
    # Exercise the actual persistent wrapper and verify repeated child restarts.
    rm -f "$FIXTURE/listener-runs"
    unset LOCAL_RUNNER_ROOT
    ensure_worker 1 renamed
    for attempt in $(seq 1 100); do
        if [ -f "$FIXTURE/listener-runs" ]; then count=$(wc -l < "$FIXTURE/listener-runs"); else count=0; fi
        [ "$count" -lt 2 ] || break
        sleep 0.1
    done
    assert test "$(wc -l < "$FIXTURE/listener-runs")" -ge 2
    assert record_alive "$ROOT/conf/workers/1.pid"
    stop_worker 1
    assert test ! -f "$ROOT/conf/workers/1.pid"
    # A one-shot reconcile never launches workers; the supervisor starts each organization
    # as soon as it is reconciled instead of after the whole pass.
    rm -f "$ROOT/conf/retry/1"
    reconcile
    assert test ! -f "$ROOT/conf/workers/1.pid"
    SUPERVISING=1 reconcile
    assert record_alive "$ROOT/conf/workers/1.pid"
    stop_worker 1; rm -f "$ROOT/conf/retry/1"
    assert test ! -f "$ROOT/conf/workers/1.pid"
    # runner_count: each organization gets that many runners, each with its own number,
    # program directory and jobs directory under the organization.
    jq '.runner_count=3' "$ROOT/conf/settings.json" > "$ROOT/conf/settings.new"; mv "$ROOT/conf/settings.new" "$ROOT/conf/settings.json"
    reconcile
    assert jq -e '."1.2".login=="renamed" and ."1.3".login=="renamed"' "$ROOT/conf/organizations.json"
    assert jq -e --arg p "$PREFIX" '[."1",."1.2",."1.3" | .runner_name] | (unique|length)==3 and all(.[]; test("^"+$p+"-[1-9][0-9]*$"))' "$ROOT/conf/organizations.json"
    assert jq -e '.renamed|length==3' "$FIXTURE/remote.json"
    for id in 1.2 1.3; do
        assert jq -e --arg work "$ROOT/jobs/renamed/$(runner_name "$id")" '.work==$work' "$ROOT/runner/renamed/$(runner_name "$id")/app/.runner"
    done
    previous=$(cat "$FIXTURE/next-id"); reconcile
    assert test "$(cat "$FIXTURE/next-id")" = "$previous"
    SUPERVISING=1 reconcile
    assert record_alive "$ROOT/conf/workers/1.2.pid"
    assert record_alive "$ROOT/conf/workers/1.3.pid"
    for id in 1 1.2 1.3; do stop_worker "$id"; rm -f "$ROOT/conf/retry/$id"; done
    # Lowering the count removes the extra runners and their directories once idle; a busy
    # one finishes its job first.
    second=$(runner_name 1.2) third=$(runner_name 1.3)
    mkdir -p "$ROOT/jobs/renamed/$second/repo"
    busy_id=$(jq -r '."1.3".runner_id' "$ROOT/conf/organizations.json")
    jq --argjson id "$busy_id" '.renamed |= map(if .id==$id then .busy=true else . end)' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    jq '.runner_count=1' "$ROOT/conf/settings.json" > "$ROOT/conf/settings.new"; mv "$ROOT/conf/settings.new" "$ROOT/conf/settings.json"
    reconcile
    assert jq -e 'has("1") and (has("1.2")|not) and has("1.3")' "$ROOT/conf/organizations.json"
    assert test ! -e "$ROOT/runner/renamed/$second" -a ! -e "$ROOT/jobs/renamed/$second"
    assert test -d "$ROOT/runner/renamed/$third" -a -d "$ROOT/jobs/renamed/$third"
    jq '.renamed |= map(.busy=false)' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e 'keys|all(test("^[0-9]+$"))' "$ROOT/conf/organizations.json"
    assert jq -e --argjson id "$(jq '."1".runner_id' "$ROOT/conf/organizations.json")" '.renamed|length==1 and .[0].id==$id' "$FIXTURE/remote.json"
    assert test ! -e "$ROOT/runner/renamed/$third" -a ! -e "$ROOT/jobs/renamed/$third"
    assert test -d "$ROOT/runner/renamed/$(runner_name 1)"
    assert grep -F 'runner count lowered' "$ROOT/logs/service.log"
    # An organization without runner permission backs off instead of failing every poll.
    printf '[[{"state":"active","organization":{"id":1,"login":"renamed"}},{"state":"active","organization":{"id":8,"login":"denied"}}]]\n' > "$FIXTURE/memberships.json"
    reconcile
    assert test "$(sed -n 2p "$ROOT/conf/backoff/8")" = 1
    reconcile
    assert test "$(sed -n 2p "$ROOT/conf/backoff/8")" = 1
    printf '0\n1\n' > "$ROOT/conf/backoff/8"; reconcile
    assert test "$(sed -n 2p "$ROOT/conf/backoff/8")" = 2
    assert test "$(( $(head -n 1 "$ROOT/conf/backoff/8") - $(date +%s) ))" -ge 15
    printf '[[]]\n' > "$FIXTURE/memberships.json"; reconcile
    assert jq -e 'all(.[]; .active==false)' "$ROOT/conf/organizations.json"
    assert test ! -e "$ROOT/conf/backoff/1"
    # Deactivation is logged once, not on every poll.
    assert test "$(grep -c 'Stopped collision;' "$ROOT/logs/service.log")" = 1
    assert test -f "$alpha_jobs/repo/keep"
    if grep -q 'secret-test-token\|should-not-reach-runner' "$ROOT/logs/service.log"; then echo 'Credential leaked to log' >&2; exit 1; fi
    # Real CLI, processes and file switching; only the OS service manager is faked.
    privileged() { "$@"; }
    native_service() {
        printf '%s\n' "$1" >> "$FIXTURE/native-actions"
        if [ "$1" = start ]; then /bin/bash "$ROOT/bin/service.sh" > "$FIXTURE/supervisor-output" 2>&1 & fi
    }
    command_path=$FIXTURE/commands-$arch/ghr
    install_cli "$command_path"
    assert "$command_path" help
    assert command_main status
    jq '."1".active=true' "$ROOT/conf/organizations.json" > "$ROOT/conf/state.new"; mv "$ROOT/conf/state.new" "$ROOT/conf/organizations.json"
    rm -f "$ROOT/conf/paused/1"
    command_main start
    for attempt in $(seq 1 100); do record_alive "$ROOT/conf/manager.pid" && break; sleep 0.1; done
    assert record_alive "$ROOT/conf/manager.pid"
    # ghr config: full option names only; a new data directory must exist and be empty.
    assert test "$("$command_path" config --data-dir)" = "$ROOT"
    assert grep -Eqx "data-dir +$ROOT" <<< "$("$command_path" config)"
    new_work=$FIXTURE/"new work $arch"
    for arguments in "-d|$new_work" "--dir|$new_work" "--data-dir=$new_work|" "--runner-count|2" "--data-dir|$new_work|extra"; do
        IFS='|' read -r -a parts <<< "$arguments"
        if "$command_path" config "${parts[@]}" > /dev/null 2>&1; then echo "Accepted ghr config ${parts[*]}" >&2; exit 1; fi
    done
    if "$command_path" config --data-dir "$new_work" > /dev/null 2>&1; then echo 'Accepted a missing data directory' >&2; exit 1; fi
    assert test ! -e "$new_work"
    mkdir -p "$new_work"; touch "$new_work/.other"
    if "$command_path" config --data-dir "$new_work" > /dev/null 2>&1; then echo 'Accepted a non-empty data directory' >&2; exit 1; fi
    rm "$new_work/.other"
    (cd "$new_work" && "$command_path" config --data-dir .)
    assert jq -e --arg work "$new_work" '.work_dir==$work' "$ROOT/conf/settings.json"
    assert test -d "$new_work/jobs" -a -d "$new_work/logs"
    if "$command_path" config --data-dir "$new_work" > /dev/null 2>&1; then echo 'Accepted the current data directory again' >&2; exit 1; fi
    # ghr runner: one more or one fewer per organization, from 1 to half the CPUs, without a
    # restart; the running manager picks the new count up at once.
    assert test "$("$command_path" runner)" = 'Runners per organization: 1 (maximum 3: 6 CPUs / 2)'
    if "$command_path" runner -s 2> "$FIXTURE/runner-error"; then echo 'Removed the last runner' >&2; exit 1; fi
    assert grep -Fq 'keeps at least 1' "$FIXTURE/runner-error"
    output=$("$command_path" runner --add); assert grep -Fq 'registers the new runners within a few seconds' <<< "$output"
    output=$("$command_path" runner -a); assert grep -Fqx 'Runners per organization: 2 -> 3' <<< "$output"
    assert jq -e '.runner_count==3' "$ROOT/conf/settings.json"
    if "$command_path" runner --add 2> "$FIXTURE/runner-error"; then echo 'Exceeded half the CPUs' >&2; exit 1; fi
    assert grep -Fq 'Cannot add a runner: 3 per organization is the maximum on this machine (6 CPUs / 2).' "$FIXTURE/runner-error"
    assert jq -e '.runner_count==3' "$ROOT/conf/settings.json"
    for arguments in "--count" "-x" "-a|-s" "add" "--add|1"; do
        IFS='|' read -r -a parts <<< "$arguments"
        if "$command_path" runner "${parts[@]}" > /dev/null 2>&1; then echo "Accepted ghr runner ${parts[*]}" >&2; exit 1; fi
    done
    # A count saved on a larger machine is capped by this one.
    assert test "$(LOCAL_RUNNER_CPU_COUNT=4 "$command_path" runner)" = 'Runners per organization: 2 (maximum 2: 4 CPUs / 2)'
    assert test "$(LOCAL_RUNNER_CPU_COUNT=1 runner_count)" = 1
    output=$("$command_path" runner --sub); assert grep -Fq 'removes the extra runners once they are idle' <<< "$output"
    "$command_path" runner -s > /dev/null
    assert jq -e '.runner_count==1' "$ROOT/conf/settings.json"
    assert test "$(cat "$ROOT/conf/active-work-dir")" = "$ROOT"
    (command_main restart)
    for attempt in $(seq 1 100); do
        if [ "$(cat "$ROOT/conf/active-work-dir" 2>/dev/null || :)" = "$new_work" ] && jq -e --arg work "$new_work/jobs/renamed/$(runner_name 1)" '.workFolder==$work' "$ROOT/runner/renamed/$(runner_name 1)/app/.runner" >/dev/null; then break; fi
        sleep 0.1
    done
    assert test "$(cat "$ROOT/conf/active-work-dir")" = "$new_work"
    assert jq -e --arg work "$new_work/jobs/renamed/$(runner_name 1)" '.workFolder==$work' "$ROOT/runner/renamed/$(runner_name 1)/app/.runner"
    # An in-flight timeout may outlive the manager; stop must also sweep its saved record.
    sleep 60 & timeout_orphan=$!
    record_pid "$ROOT/conf/timeouts/orphan.pid" "$timeout_orphan"
    (command_main stop)
    if kill -0 "$timeout_orphan" 2>/dev/null; then echo 'Stop left a recorded timeout process running' >&2; exit 1; fi
    assert test ! -e "$ROOT/conf/timeouts/orphan.pid"
    assert test -f "$ROOT/conf/stopped"
    if record_alive "$ROOT/conf/manager.pid"; then echo 'Stop left the manager running' >&2; exit 1; fi
    assert test -f "$alpha_jobs/repo/keep"
    "$command_path" logs -f > "$FIXTURE/followed-$arch" 2>&1 & follower=$!
    record_pid "$FIXTURE/follower.pid" "$follower"
    printf 'follow-marker\n' >> "$new_work/logs/service.log"
    for attempt in $(seq 1 100); do grep -q follow-marker "$FIXTURE/followed-$arch" && break; sleep 0.1; done
    assert grep -q follow-marker "$FIXTURE/followed-$arch"
    mv "$new_work/logs/service.log" "$new_work/logs/service.log.rotated"
    printf 'rotation-marker\n' > "$new_work/logs/service.log"
    for attempt in $(seq 1 150); do grep -q rotation-marker "$FIXTURE/followed-$arch" && break; sleep 0.1; done
    assert grep -q rotation-marker "$FIXTURE/followed-$arch"
    stop_record "$FIXTURE/follower.pid"
    touch "$FIXTURE/fail-delete"
    if (command_main uninstall); then echo 'Uninstall ignored remote failure' >&2; exit 1; fi
    assert test -f "$ROOT/conf/github-token"
    assert test -f "$command_path"
    rm "$FIXTURE/fail-delete"
    (command_main uninstall)
    assert test ! -e "$ROOT/conf"
    assert test ! -e "$ROOT/runner"
    assert test ! -e "$command_path"
    assert test -f "$alpha_jobs/repo/keep"
    assert test -f "$new_work/logs/service.log"
    assert jq -e '.renamed|length==0' "$FIXTURE/remote.json"
    assert jq -e '.beta|any(.[]; .id==999)' "$FIXTURE/remote.json"
    printf 'PASS %s/%s: discovery, numbered registration, pagination, race retry, recovery, runner count, worker restart, cleanup\n' "$PLATFORM" "$arch"
done

TEST_FAILED=0
