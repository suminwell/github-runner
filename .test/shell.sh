#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
case "$(uname -s)" in Darwin) PLATFORM=macos ;; *) PLATFORM=linux ;; esac
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-shell.XXXXXX")
export FAKE_FIXTURE=$FIXTURE
cleanup() {
    if declare -F stop_worker >/dev/null; then
        for id in 1 2 3 4 5 6; do stop_worker "$id" 2>/dev/null || :; done
    fi
    if [ "${TEST_FAILED:-1}" = 0 ]; then rm -rf "$FIXTURE"; else printf "Retained fixture: %s\n" "$FIXTURE"; fi
}
trap cleanup EXIT
assert() { if ! "$@" >/dev/null; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
for arch in x64 arm64; do
    export LOCAL_RUNNER_ROOT=$FIXTURE/$arch
    ROOT=$LOCAL_RUNNER_ROOT
    mkdir -p "$ROOT/bin" "$ROOT/.state/package"
    cp "$REPO/$PLATFORM/$arch/bin/service.sh" "$ROOT/bin/service.sh"
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
[ "$name" = "$labels" ] || exit 91
id=$(cat "$FAKE_FIXTURE/next-id")
printf '%s\n' "$((id+1))" > "$FAKE_FIXTURE/next-id"
jq -n --argjson id "$id" --arg work "$work" '{agentId:$id,work:$work}' > .runner
jq --arg login "$login" --arg name "$name" --argjson id "$id" '.[$login] = ((.[$login] // []) + [{id:$id,name:$name,busy:false,status:"online"}])' "$FAKE_FIXTURE/remote.json" > "$FAKE_FIXTURE/remote.new"
mv "$FAKE_FIXTURE/remote.new" "$FAKE_FIXTURE/remote.json"
CONFIG
    cat > "$ROOT/.state/package/run.sh" <<'RUN'
#!/bin/bash
[ -z "${GH_TOKEN:-}" ] || exit 92
printf 'run\n' >> "$FAKE_FIXTURE/listener-runs"
sleep 0.2
RUN
    . "$ROOT/bin/service.sh"
    init
    api() {
        local endpoint=$1 login runner_id
        case "$endpoint" in
            user/memberships/*) [ ! -f "$FIXTURE/fail-discovery" ] || return 1; cat "$FIXTURE/memberships.json" ;;
            */registration-token) printf '{"token":"temporary"}\n' ;;
            *'/runners?'*) login=${endpoint#orgs/}; login=${login%%/*}; jq -c --arg login "$login" '[{runners:(.[$login] // [])}]' "$FIXTURE/remote.json" ;;
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
    assert jq -e --arg name "local-$PLATFORM-$arch" '.alpha[0].name==$name' "$FIXTURE/remote.json"
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
    # A different architecture is allowed; the exact name is never stolen.
    other=x64; [ "$arch" != x64 ] || other=arm64
    jq --arg name "local-$PLATFORM-$other" '.beta=[{id:999,name:$name,busy:false}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    reconcile_one 2 beta
    assert jq -e '.beta|length==2' "$FIXTURE/remote.json"
    jq --arg name "$NAME" '.collision=[{id:998,name:$name,busy:false}]' "$FIXTURE/remote.json" > "$FIXTURE/remote.new"; mv "$FIXTURE/remote.new" "$FIXTURE/remote.json"
    if reconcile_one 3 collision; then echo 'Stole a conflicting runner' >&2; exit 1; fi
    assert jq -e '.collision[0].id==998' "$FIXTURE/remote.json"
    if reconcile_one 4 ../escape; then echo 'Accepted unsafe organization' >&2; exit 1; fi
    # Exercise the actual persistent wrapper and verify repeated child restarts.
    rm -f "$FIXTURE/listener-runs"
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
    printf 'PASS %s/%s: discovery, registration, idempotency, rename, collision, recovery, worker restart, cleanup\n' "$PLATFORM" "$arch"
done

TEST_FAILED=0
