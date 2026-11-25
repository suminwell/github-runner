#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in Darwin) PLATFORM=macos ;; *) PLATFORM=linux ;; esac
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-shell.XXXXXX")
export FAKE_FIXTURE=$FIXTURE
cleanup() {
    if declare -F stop_worker >/dev/null; then
        for id in 1 2 3 4 5 6 7; do stop_worker "$id" 2>/dev/null || :; done
    fi
    if [ "${TEST_FAILED:-1}" = 0 ]; then rm -rf "$FIXTURE"; else printf "Retained fixture: %s\n" "$FIXTURE"; fi
}
trap cleanup EXIT
assert() { if ! "$@" >/dev/null; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
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
        mkdir -p "$root/$arch/.state" "$root/$arch/bin/alpha/runner" "$root/$arch/data/alpha/repo" "$root/$arch/logs"
        printf '{}\n' > "$root/$arch/.state/settings.json"
        printf '{"1":{"login":"alpha","runner_id":100,"runner_name":"local-linux-x64-3"}}\n' > "$root/$arch/.state/organizations.json"
        printf 'keep' > "$root/$arch/data/alpha/repo/.hidden"
        printf 'credential' > "$root/$arch/bin/alpha/runner/.credentials"
        touch "$root/$arch/bin/install.sh" "$root/$arch/bin/service.sh"
        migrate_layout
        assert test ! -d "$root/$arch"
        assert test ! -f "$root/bin/service.sh"
        assert test "$(cat "$root/data/alpha/repo/.hidden")" = keep
        assert test "$(cat "$root/bin/alpha/runner/.credentials")" = credential
        assert jq -e '."1".relocated and ."1".runner_id==100 and ."1".runner_name=="local-linux-x64-3"' "$root/.state/organizations.json"
        migrate_layout
    done
    root=$FIXTURE/conflicting-layout; arch=x64
    mkdir -p "$root/$arch/.state" "$root/data"
    printf '{}\n' > "$root/$arch/.state/settings.json"
    if (migrate_layout) 2>/dev/null; then echo 'Merged conflicting layouts' >&2; exit 1; fi
    assert test -f "$root/$arch/.state/settings.json"
)
for arch in x64 arm64; do
    export LOCAL_RUNNER_ROOT=$FIXTURE/$arch
    ROOT=$LOCAL_RUNNER_ROOT
    mkdir -p "$ROOT/bin" "$ROOT/.state/package"
    cp "$REPO/$PLATFORM/service.sh" "$ROOT/service.sh"
    printf '%s\n' "$(command -v jq)" > "$ROOT/.state/jq-path"
    printf '/usr/bin/false\n' > "$ROOT/.state/gh-path"
    printf 'secret-test-token\n' > "$ROOT/.state/github-token"
    jq -n --arg arch "$arch" '{arch:$arch,poll_seconds:10,restart_seconds:1,organizations:[]}' > "$ROOT/.state/settings.json"
    printf 'fixture\n' > "$ROOT/.state/package/.complete"
    printf '{}\n' > "$FIXTURE/remote.json"
    printf '100\n' > "$FIXTURE/next-id"
    printf '[[{"state":"active","organization":{"id":1,"login":"alpha"}}]]\n' > "$FIXTURE/memberships.json"
    cat > "$ROOT/.state/package/config.sh" <<'CONFIG'
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
    cat > "$ROOT/.state/package/run.sh" <<'RUN'
#!/bin/bash
[ -z "${GH_TOKEN:-}" ] || exit 92
printf 'run\n' >> "$FAKE_FIXTURE/listener-runs"
sleep 0.2
RUN
    . "$ROOT/service.sh"
    init
    api() {
        local endpoint=$1 login runner_id
        case "$endpoint" in
            user/memberships/*) [ ! -f "$FIXTURE/fail-discovery" ] || return 1; cat "$FIXTURE/memberships.json" ;;
            */registration-token) printf '{"token":"temporary"}\n' ;;
            *'/runners?'*) login=${endpoint#orgs/}; login=${login%%/*}; jq -c --arg login "$login" '(.[$login] // []) as $r | [{runners:$r[:1]},{runners:$r[1:]}]' "$FIXTURE/remote.json" ;;
            */actions/runners/*)
                login=${endpoint#orgs/}; login=${login%%/*}; runner_id=${endpoint##*/}
                jq --arg login "$login" --argjson id "$runner_id" '.[$login] = [.[$login][] | select(.id!=$id)]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"
                mv "$FIXTURE/remote.new" "$FIXTURE/remote.json" ;;
            *) echo "Unexpected endpoint $endpoint" >&2; return 1 ;;
        esac
    }
    export GH_TOKEN=should-not-reach-runner
    reconcile
    assert jq -e '."1".login=="alpha" and ."1".runner_id==100' "$ROOT/.state/organizations.json"
    assert jq -e --arg name "$PREFIX-1" '.alpha[0].name==$name' "$FIXTURE/remote.json"
    assert jq -e --arg name "$PREFIX-1" '."1".runner_name==$name' "$ROOT/.state/organizations.json"
    assert jq -e --arg work "$ROOT/data/alpha" '.work==$work' "$ROOT/bin/alpha/runner/.runner"
    reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 101
    touch "$FIXTURE/fail-discovery"
    if reconcile; then echo 'Discovery failure not propagated' >&2; exit 1; fi
    assert jq -e 'has("1")' "$ROOT/.state/organizations.json"
    rm "$FIXTURE/fail-discovery"
    # Remote deletion and lost local configuration each recover the owned runner.
    printf '{}\n' > "$FIXTURE/remote.json"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 102
    rm "$ROOT/bin/alpha/runner/.runner"; reconcile
    assert test "$(cat "$FIXTURE/next-id")" = 103
    # Rename keeps old data and defers while the runner is busy.
    mkdir -p "$ROOT/data/alpha/repo"; printf keep > "$ROOT/data/alpha/repo/keep"
    printf '[[{"state":"active","organization":{"id":1,"login":"renamed"}}]]\n' > "$FIXTURE/memberships.json"
    jq '.renamed=.alpha|del(.alpha)|.renamed[0].busy=true' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="alpha"' "$ROOT/.state/organizations.json"
    jq '.renamed[0].busy=false' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile
    assert jq -e '."1".login=="renamed"' "$ROOT/.state/organizations.json"
    assert test -f "$ROOT/data/alpha/repo/keep"
    assert test -d "$ROOT/data/renamed"
    # Lost state after successful registration recovers the existing identity.
    printf '{}\n' > "$ROOT/.state/organizations.json"; previous=$(cat "$FIXTURE/next-id"); reconcile
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
    assert jq -e --arg name "$PREFIX-1" '."6".runner_name==$name' "$ROOT/.state/organizations.json"
    # A migrated registration is reconfigured with its number and new work path.
    jq '."3".relocated=true' "$ROOT/.state/organizations.json" > "$ROOT/.state/state.new"; mv "$ROOT/.state/state.new" "$ROOT/.state/organizations.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-11" '."3".runner_name==$name and (."3"|has("relocated")|not)' "$ROOT/.state/organizations.json"
    # If another installation takes a deleted registration's number, allocate anew.
    jq --arg name "$PREFIX-11" '.collision |= map(if .name==$name then .id=995 else . end)' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 3 collision
    assert jq -e --arg name "$PREFIX-12" '.collision[-1].name==$name and any(.collision[]; .id==995)' "$FIXTURE/remote.json"
    # A legacy unnumbered runner is upgraded only after it becomes idle.
    jq --arg name "$PREFIX" '.legacy=[{id:996,name:$name,busy:true}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    mkdir -p "$ROOT/bin/legacy/runner"
    printf '{"agentId":996}\n' > "$ROOT/bin/legacy/runner/.runner"
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
    assert record_alive "$ROOT/.state/workers/1.pid"
    stop_worker 1
    assert test ! -f "$ROOT/.state/workers/1.pid"
    printf '[[]]\n' > "$FIXTURE/memberships.json"; reconcile
    assert jq -e 'length==0' "$ROOT/.state/organizations.json"
    assert test -f "$ROOT/data/alpha/repo/keep"
    if grep -q 'secret-test-token\|should-not-reach-runner' "$ROOT/logs/service.log"; then echo 'Credential leaked to log' >&2; exit 1; fi
    printf 'PASS %s/%s: discovery, numbered registration, pagination, race retry, migration, recovery, worker restart, cleanup\n' "$PLATFORM" "$arch"
done

TEST_FAILED=0
