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
        for id in 1 2 3 4 5 6 7; do stop_worker "$id" 2>/dev/null || :; done
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
    platform=linux
    uname() { printf '%s\n' "$machine"; }
    for machine in x86_64 amd64; do detect_architecture; assert test "$arch" = x64; done
    for machine in arm64 aarch64; do detect_architecture; assert test "$arch" = arm64; done
    machine=riscv64
    if detect_architecture 2>/dev/null; then echo 'Accepted unsupported architecture' >&2; exit 1; fi
    unset -f uname
    for arch in x64 arm64; do
        root=$FIXTURE/upgrade-$arch
        mkdir -p "$root/$arch/conf" "$root/$arch/bin/alpha/runner" "$root/$arch/data/alpha/repo" "$root/$arch/logs"
        printf '{}\n' > "$root/$arch/conf/settings.json"
        printf '{"1":{"login":"alpha","runner_id":100,"runner_name":"local-linux-x64-3"}}\n' > "$root/$arch/conf/organizations.json"
        printf 'keep' > "$root/$arch/data/alpha/repo/.hidden"
        printf 'credential' > "$root/$arch/bin/alpha/runner/.credentials"
        printf '{"agentId":100}\n' > "$root/$arch/bin/alpha/runner/.runner"
        touch "$root/$arch/bin/install.sh" "$root/$arch/bin/service.sh"
        migrate_layout
        assert test ! -d "$root/$arch"
        assert test -f "$root/bin/service.sh"
        assert test "$(cat "$root/data/alpha/repo/.hidden")" = keep
        assert test "$(cat "$root/runner/alpha/app/.credentials")" = credential
        assert jq -e '.agentId==100' "$root/runner/alpha/app/.runner"
        assert jq -e '."1".runner_id==100 and ."1".runner_name=="local-linux-x64-3"' "$root/conf/organizations.json"
        migrate_layout
    done
    root=$FIXTURE/conflicting-layout; arch=x64
    mkdir -p "$root/$arch/conf" "$root/data"
    printf '{}\n' > "$root/$arch/conf/settings.json"
    if (migrate_layout) 2>/dev/null; then echo 'Merged conflicting layouts' >&2; exit 1; fi
    assert test -f "$root/$arch/conf/settings.json"
)
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
    case "$1" in --url) login=${2##*/}; shift 2 ;; --name) name=$2; shift 2 ;; --labels) labels=$2; shift 2 ;; --work) work=$2; shift 2 ;; *) shift ;; esac
done
[ -z "${GH_TOKEN:-}" ] || exit 90
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
jq -n --argjson id "$id" --arg name "$name" --arg work "$work" '{agentId:$id,agentName:$name,work:$work}' > .runner
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
    api() {
        local endpoint=$1 login runner_id
        case "$endpoint" in
            organizations/*) runner_id=${endpoint##*/}; jq -c --arg id "$runner_id" '{id:($id|tonumber),login:.[$id].login}' "$ROOT/conf/organizations.json" ;;
            user/memberships/*) [ ! -f "$FIXTURE/fail-discovery" ] || return 1; cat "$FIXTURE/memberships.json" ;;
            */registration-token) printf '{"token":"temporary"}\n' ;;
            *'/runners?'*) login=${endpoint#orgs/}; login=${login%%/*}; jq -c --arg login "$login" '(.[$login] // []) as $r | [{runners:$r[:1]},{runners:$r[1:]}]' "$FIXTURE/remote.json" ;;
            */actions/runners/*)
                [ ! -f "$FIXTURE/fail-delete" ] || return 1
                login=${endpoint#orgs/}; login=${login%%/*}; runner_id=${endpoint##*/}
                jq --arg login "$login" --argjson id "$runner_id" '.[$login] = [.[$login][] | select(.id!=$id)]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"
                mv "$FIXTURE/remote.new" "$FIXTURE/remote.json" ;;
            *) echo "Unexpected endpoint $endpoint" >&2; return 1 ;;
        esac
    }
    export GH_TOKEN=should-not-reach-runner
    reconcile
    assert jq -e '."1".login=="alpha" and ."1".runner_id==100' "$ROOT/conf/organizations.json"
    assert jq -e --arg name "$PREFIX-1" '.alpha[0].name==$name' "$FIXTURE/remote.json"
    assert jq -e --arg name "$PREFIX-1" '."1".runner_name==$name' "$ROOT/conf/organizations.json"
    assert jq -e --arg work "$ROOT/data/alpha" '.work==$work' "$ROOT/runner/alpha/app/.runner"
    reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 101
    touch "$FIXTURE/fail-discovery"
    if reconcile; then echo 'Discovery failure not propagated' >&2; exit 1; fi
    assert jq -e 'has("1")' "$ROOT/conf/organizations.json"
    rm "$FIXTURE/fail-discovery"
    # Remote deletion and lost local configuration each recover the owned runner.
    printf '{}\n' > "$FIXTURE/remote.json"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 102
    rm "$ROOT/runner/alpha/app/.runner"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 103
    # Rename keeps old data and defers while the runner is busy.
    mkdir -p "$ROOT/data/alpha/repo"; printf keep > "$ROOT/data/alpha/repo/keep"
    printf '[[{"state":"active","organization":{"id":1,"login":"renamed"}}]]\n' > "$FIXTURE/memberships.json"
    jq '.renamed=.alpha|del(.alpha)|.renamed[0].busy=true' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="alpha"' "$ROOT/conf/organizations.json"
    jq '.renamed[0].busy=false' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="renamed"' "$ROOT/conf/organizations.json"
    assert test -f "$ROOT/data/alpha/repo/keep"
    assert test -d "$ROOT/data/renamed"
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
    # A migrated registration is reconfigured with its number and new work path.
    jq '."3".relocated=true' "$ROOT/conf/organizations.json" > "$ROOT/conf/state.new"; mv "$ROOT/conf/state.new" "$ROOT/conf/organizations.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-11" '."3".runner_name==$name and (."3"|has("relocated")|not)' "$ROOT/conf/organizations.json"
    # If another installation takes a deleted registration's number, allocate anew.
    jq --arg name "$PREFIX-11" '.collision |= map(if .name==$name then .id=995 else . end)' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-12" '.collision[-1].name==$name and any(.collision[]; .id==995)' "$FIXTURE/remote.json"
    # A legacy unnumbered runner is upgraded only after it becomes idle.
    jq --arg name "$PREFIX" '.legacy=[{id:996,name:$name,busy:true}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    mkdir -p "$ROOT/runner/legacy/app"
    printf '{"agentId":996}\n' > "$ROOT/runner/legacy/app/.runner"
    save_entry 7 legacy 996 "$PREFIX"
    reconcile_one 7 legacy
    assert jq -e --arg name "$PREFIX" '.legacy[0].name==$name' "$FIXTURE/remote.json"
    jq '.legacy[0].busy=false' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 7 legacy
    assert jq -e --arg name "$PREFIX-1" '.legacy|length==1 and .[0].name==$name' "$FIXTURE/remote.json"
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
    printf '[[]]\n' > "$FIXTURE/memberships.json"; reconcile
    assert jq -e 'all(.[]; .active==false)' "$ROOT/conf/organizations.json"
    assert test -f "$ROOT/data/alpha/repo/keep"
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
    new_work=$FIXTURE/"new work $arch"
    "$command_path" config "--dir=$new_work"
    assert test "$(cat "$ROOT/conf/active-work-dir")" = "$ROOT"
    (command_main restart)
    for attempt in $(seq 1 100); do
        if [ "$(cat "$ROOT/conf/active-work-dir" 2>/dev/null || :)" = "$new_work" ] && jq -e --arg work "$new_work/data/renamed" '.workFolder==$work' "$ROOT/runner/renamed/app/.runner" >/dev/null; then break; fi
        sleep 0.1
    done
    assert test "$(cat "$ROOT/conf/active-work-dir")" = "$new_work"
    assert jq -e --arg work "$new_work/data/renamed" '.workFolder==$work' "$ROOT/runner/renamed/app/.runner"
    (command_main stop)
    assert test -f "$ROOT/conf/stopped"
    if record_alive "$ROOT/conf/manager.pid"; then echo 'Stop left the manager running' >&2; exit 1; fi
    assert test -f "$ROOT/data/alpha/repo/keep"
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
    assert test -f "$ROOT/data/alpha/repo/keep"
    assert test -f "$new_work/logs/service.log"
    assert jq -e '.beta|any(.[]; .id==999)' "$FIXTURE/remote.json"
    printf 'PASS %s/%s: discovery, numbered registration, pagination, race retry, migration, recovery, worker restart, cleanup\n' "$PLATFORM" "$arch"
done

TEST_FAILED=0
