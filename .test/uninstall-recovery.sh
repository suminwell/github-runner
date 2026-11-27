#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/runner-uninstall.XXXXXX")
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
for platform in linux macos; do
    setup_case() {
        export LOCAL_RUNNER_ROOT=$fixture/$platform-$1
        ROOT=$LOCAL_RUNNER_ROOT
        mkdir -p "$ROOT/bin" "$ROOT/conf" "$ROOT/runners/directory-is-not-identity/runner/app"
        cp "$repo/$platform/service.sh" "$repo/$platform/ghr.sh" "$ROOT/bin/"
        command -v jq > "$ROOT/conf/jq-path"
        printf '/bin/false\n' > "$ROOT/conf/gh-path"
        printf 'fixture-credential\n' > "$ROOT/conf/github-token"
        printf '{"arch":"x64"}\n' > "$ROOT/conf/settings.json"
        printf '{}\n' > "$ROOT/conf/organizations.json"
        . "$ROOT/bin/ghr.sh"
        init control
        api() { fake_api "$@"; }
        metadata=$ROOT/runners/directory-is-not-identity/runner/app/.runner
        jq -n --arg name "$PREFIX-1" '{agentId:42,agentName:$name,gitHubUrl:"https://github.com/alpha"}' > "$metadata"
        fixture_remote=$ROOT/conf/fake-remote.json
        jq -n --arg name "$PREFIX-1" '[{id:42,name:$name},{id:43,name:"unrelated-runner"}]' > "$fixture_remote"
        delete_log=$ROOT/conf/deletions
    }
    fake_api() {
        case "$1" in
            orgs/alpha|organizations/100) printf '{"id":100,"login":"alpha"}\n' ;;
            orgs/beta|organizations/200) printf '{"id":200,"login":"beta"}\n' ;;
            'orgs/alpha/actions/runners?per_page=100') jq -c '[{runners:.}]' "$fixture_remote" ;;
            'orgs/beta/actions/runners?per_page=100') printf '[{"runners":[{"id":42,"name":"tracked-beta"}]}]\n' ;;
            orgs/beta/actions/runners/42) printf 'beta/42\n' >> "$delete_log" ;;
            orgs/alpha/actions/runners/*)
                [ ! -f "$ROOT/conf/fail-delete" ] || return 1
                printf '%s\n' "${1##*/}" >> "$delete_log"
                jq_update "$fixture_remote" --argjson id "${1##*/}" '[.[]|select(.id!=$id)]' ;;
            *) printf 'Unexpected API endpoint: %s\n' "$1" >&2; return 1 ;;
        esac
    }
    setup_case fresh
    mkdir -p "$ROOT/runners/duplicate-local-copy/runner/app"
    cp "$metadata" "$ROOT/runners/duplicate-local-copy/runner/app/.runner"
    unregister_runners
    assert jq -e 'length==1 and .[0].id==43' "$fixture_remote" >/dev/null
    assert grep -Fxq 42 "$delete_log"
    assert test -f "$metadata"
    unregister_runners
    assert test "$(wc -l < "$delete_log" | tr -d ' ')" = 1

    setup_case same-id-other-organization
    jq -n '{"200":{login:"beta",runner_id:42,runner_name:"tracked-beta"}}' > "$ROOT/conf/organizations.json"
    # Even a misleading directory name cannot override the official organization URL.
    mv "$ROOT/runners/directory-is-not-identity" "$ROOT/runners/beta"
    unregister_runners
    assert jq -e 'length==1 and .[0].id==43' "$fixture_remote" >/dev/null
    assert grep -Fxq 42 "$delete_log"
    assert grep -Fxq beta/42 "$delete_log"
    assert test "$(wc -l < "$delete_log" | tr -d ' ')" = 2

    setup_case partial
    jq -n --arg name "$PREFIX-2" '{"100":{login:"alpha",runner_id:44,runner_name:$name}}' > "$ROOT/conf/organizations.json"
    jq_update "$fixture_remote" --arg name "$PREFIX-2" '.+[{id:44,name:$name}]'
    api() { if [ "$1" = orgs/alpha/actions/runners/44 ]; then return 1; else fake_api "$@"; fi; }
    if unregister_runners 2>/dev/null; then echo 'Ignored failure after orphan deletion' >&2; exit 1; fi
    assert test -f "$metadata"
    api() { fake_api "$@"; }
    unregister_runners
    assert jq -e 'length==1 and .[0].id==43' "$fixture_remote" >/dev/null
    assert test "$(wc -l < "$delete_log" | tr -d ' ')" = 2

    setup_case repaired
    jq -n --arg name "$PREFIX-1" '{"100":{login:"alpha",runner_id:41,runner_name:$name}}' > "$ROOT/conf/organizations.json"
    jq_update "$fixture_remote" '.+[{id:41,name:"previous-owned-runner"}]'
    unregister_runners
    assert jq -e 'length==1 and .[0].id==43' "$fixture_remote" >/dev/null
    assert test "$(wc -l < "$delete_log" | tr -d ' ')" = 2

    for invalid in name url state linked; do
        setup_case "$invalid"
        case "$invalid" in
            name) jq_update "$fixture_remote" '.[0].name="other-installation"' ;;
            url) jq_update "$metadata" '.gitHubUrl="https://github.com/alpha/repository"' ;;
            state) printf '[]\n' > "$ROOT/conf/organizations.json" ;;
            linked) mv "$metadata" "$ROOT/conf/linked-runner"; ln -s "$ROOT/conf/linked-runner" "$metadata" ;;
        esac
        if unregister_runners 2>/dev/null; then echo "Accepted ambiguous $invalid identity" >&2; exit 1; fi
        assert test ! -f "$delete_log"
        assert test -f "$ROOT/conf/github-token"
    done

    setup_case retry
    touch "$ROOT/conf/fail-delete"
    if unregister_runners 2>/dev/null; then echo 'Ignored DELETE failure' >&2; exit 1; fi
    assert test -f "$metadata"
    assert test -f "$ROOT/conf/github-token"
    rm "$ROOT/conf/fail-delete"
    unregister_runners
    assert jq -e 'length==1 and .[0].id==43' "$fixture_remote" >/dev/null

    setup_case symlink
    ln -s "$ROOT" "$ROOT-alias"
    mkdir "$ROOT/bin/empty"
    if env -u LOCAL_RUNNER_ROOT /bin/bash "$ROOT-alias/bin/ghr.sh" config --data-dir "$ROOT-alias/bin/empty" 2> "$ROOT-alias.err"; then echo 'Allowed program data through an installation alias' >&2; exit 1; fi
    assert grep -q 'outside the program and state directories' "$ROOT-alias.err"
    assert test ! -d "$ROOT/bin/empty/jobs"
    printf 'PASS %s uninstall recovery, identity validation, retry and physical directory guard\n' "$platform"
done
