#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-install-retry.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
success=false
cleanup() { if $success; then rm -rf "$FIXTURE"; else printf 'Retained fixture: %s\n' "$FIXTURE"; fi; }
trap cleanup EXIT
assert() { if ! "$@" >/dev/null; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
cat > "$FIXTURE/run.sh" <<'RUN'
#!/bin/bash
set -eu
. "$INSTALL_FIXTURE/$INSTALL_PLATFORM.sh"
export LOCAL_RUNNER_HOME="$INSTALL_HOME"
uname() { case "$1" in -s) if [ "$INSTALL_PLATFORM" = linux ]; then echo Linux; else echo Darwin; fi ;; *) echo fixture ;; esac; }
detect_architecture() { arch=x64; }
check_linux_host() { :; }
is_wsl() { return 1; }
id() { if [ "$1" = -u ]; then echo 1001; else /usr/bin/id "$@"; fi; }
flock() { return 99; }
sudo() { printf '%s\n' "$*" >> "$INSTALL_HOME/host-calls"; }
stop_installed_service() { printf 'stop\n' >> "$INSTALL_HOME/host-calls"; }
# Only the systemd-presence predicate is simulated; no host service is touched.
[() { if builtin [ "$#" -eq 3 ] && builtin [ "$1" = -d ] && builtin [ "$2" = /run/systemd/system ]; then return 0; fi; builtin [ "$@"; }
gh() {
    case "$1 ${2:-}" in
        '--version ') if [ "$INSTALL_FAILURE" = download ]; then echo 'gh version 1.0.0'; else echo 'gh version 2.70.0'; fi ;;
        'auth status') [ "$INSTALL_FAILURE" != login ] ;;
        'auth login') echo 'Simulated login cancellation' >&2; return 41 ;;
        'auth token') echo fixture-token ;;
        *) return 93 ;;
    esac
}
curl() { echo 'Simulated download failure' >&2; return 42; }
sleep() { :; }
fetch() { printf '#!/bin/sh\nexit 0\n' > "$2"; }
install_main auto
RUN
# Do not invoke real installer entry points: load their actual definitions and replace
# only host/download/login boundaries before calling install_main in a separate shell.
for target in linux macos; do
    sed '/^if \[ -t 0 \]/,$d' "$REPO/$target/install.sh" > "$FIXTURE/$target.sh"
done
export INSTALL_FIXTURE=$FIXTURE
run_install() {
    local target=$1 failure=$2 home=$3 directory=$4 expected=$5 result=0
    mkdir -p "$home" "$directory"
    (cd "$directory" && INSTALL_PLATFORM=$target INSTALL_FAILURE=$failure INSTALL_HOME=$home /bin/bash "$FIXTURE/run.sh") > "$home/output" 2>&1 || result=$?
    if [ "$result" != "$expected" ]; then cat "$home/output" >&2; printf 'Expected %s, got %s\n' "$expected" "$result" >&2; exit 1; fi
}
for target in linux macos; do
    for failure in login download; do
        home=$FIXTURE/$target-$failure; first=$FIXTURE/first-$target-$failure; second=$FIXTURE/second-$target-$failure
        # Linux retries the download and then reports failure itself; macOS returns curl's status.
        expected=41; [ "$failure" != download ] || { expected=42; [ "$target" != linux ] || expected=1; }
        run_install "$target" "$failure" "$home" "$first" "$expected"
        assert jq -e --arg p "$target" --arg work "$first" '.platform==$p and .arch=="x64" and .work_dir==$work' "$home/$target/conf/settings.json"
        run_install "$target" "$failure" "$home" "$second" "$expected"
        assert jq -e --arg work "$first" '.work_dir==$work' "$home/$target/conf/settings.json"
        run_install "$target" none "$home" "$second" 0
        assert jq -e --arg work "$first" '.work_dir==$work' "$home/$target/conf/settings.json"
        assert test -d "$first/data"
        if [ "$target" = linux ]; then assert grep -q 'systemctl restart' "$home/host-calls";
        else assert grep -q 'launchctl bootstrap' "$home/host-calls"; fi
        printf stopped > "$home/$target/conf/stopped"
        : > "$home/host-calls"
        run_install "$target" none "$home" "$second" 0
        assert test -f "$home/$target/conf/stopped"
        if grep -Eq 'systemctl (enable|restart)|launchctl (enable|bootstrap|print)' "$home/host-calls"; then echo 'Stopped installation resumed during upgrade' >&2; exit 1; fi
    done
    for legacy_state in .state conf; do
        home=$FIXTURE/$target-legacy-$legacy_state
        mkdir -p "$home/$target/x64/$legacy_state"
        printf '{"platform":"%s","work_dir":"%s"}\n' "$target" "$home/work" > "$home/$target/x64/$legacy_state/settings.json"
        printf stopped > "$home/$target/x64/$legacy_state/stopped"
        run_install "$target" none "$home" "$FIXTURE" 0
        assert test -f "$home/$target/conf/stopped"
        assert jq -e --arg work "$home/work" '.work_dir==$work' "$home/$target/conf/settings.json"
        if grep -Eq 'systemctl (enable|restart)|launchctl (enable|bootstrap|print)' "$home/host-calls"; then echo 'Stopped legacy installation resumed during upgrade' >&2; exit 1; fi
    done
    home=$FIXTURE/$target-unrelated
    mkdir -p "$home/$target/bin"
    printf keep > "$home/$target/bin/keep"
    run_install "$target" login "$home" "$FIXTURE" 1
    assert test "$(cat "$home/$target/bin/keep")" = keep
    assert test ! -e "$home/$target/conf/settings.json"
    # A legacy conf layout is subject to platform and architecture validation too.
    home=$FIXTURE/$target-foreign
    mkdir -p "$home/$target/x64/conf"
    printf '{"platform":"windows"}\n' > "$home/$target/x64/conf/settings.json"
    run_install "$target" login "$home" "$FIXTURE" 1
    assert test -f "$home/$target/x64/conf/settings.json"
    assert test ! -e "$home/$target/conf"
    home=$FIXTURE/$target-other-arch
    mkdir -p "$home/$target/arm64/conf"
    printf '{"platform":"%s"}\n' "$target" > "$home/$target/arm64/conf/settings.json"
    run_install "$target" login "$home" "$FIXTURE" 1
    assert test -f "$home/$target/arm64/conf/settings.json"
done
# A dropped GitHub connection is retried; a persistent failure explains how to resume.
(
    sed '/^if \[ -t 0 \]/,$d' "$REPO/linux/install.sh" > "$FIXTURE/helpers.sh"
    . "$FIXTURE/helpers.sh"
    sleep() { :; }
    curl() { attempts=$((attempts + 1)); [ "$attempts" -ge "$succeed_on" ] && printf ok > "$8"; }
    attempts=0; succeed_on=3
    download https://example.invalid/file "$FIXTURE/downloaded" 2> "$FIXTURE/download-log"
    [ "$attempts" = 3 ] && [ "$(cat "$FIXTURE/downloaded")" = ok ] || { echo "download retry: $attempts attempts" >&2; exit 1; }
    [ "$(grep -c 'retrying' "$FIXTURE/download-log")" = 2 ] || exit 1
    attempts=0; succeed_on=9
    if download https://example.invalid/file "$FIXTURE/downloaded" 2> "$FIXTURE/download-log"; then echo 'Ignored download failure' >&2; exit 1; fi
    [ "$attempts" = 4 ] || exit 1
    grep -q 'run the same install command again' "$FIXTURE/download-log"
)
(
    . "$REPO/linux/service.sh"
    sleep() { :; }
    curl() { attempts=$((attempts + 1)); [ "$attempts" -ge 2 ] && printf ok > "$8"; }
    attempts=0
    download https://example.invalid/runner.tgz "$FIXTURE/runner.tgz" 2>/dev/null
    [ "$attempts" = 2 ] || { echo "service download retry: $attempts" >&2; exit 1; }
)
success=true
printf 'PASS installer retry, original data directory, stopped upgrade and layout ownership\n'
