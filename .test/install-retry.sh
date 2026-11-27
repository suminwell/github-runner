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
sudo() {
    printf '%s\n' "$*" >> "$INSTALL_HOME/host-calls"
    if [ "$1" = install ] && [ "$2" = -m ]; then cp "$4" "$INSTALL_HOME/unit-${5##*/}"; fi
}
stop_installed_service() { printf 'stop\n' >> "$INSTALL_HOME/host-calls"; }
# Only the systemd-presence predicate is simulated; no host service is touched.
[() {
    if builtin [ "$#" -eq 3 ] && builtin [ "$1" = -d ] && builtin [ "$2" = /run/systemd/system ]; then return 0; fi
    if builtin [ "$#" -eq 3 ] && builtin [ "$1" = -S ] && builtin [ "$2" = /run/dbus/system_bus_socket ]; then builtin [ -n "${INSTALL_LOGIND:-}" ]; return; fi
    builtin [ "$@"
}
# A logind inhibitor is offered only where a scenario says logind exists.
systemd-inhibit() { :; }
gh() {
    case "$1 ${2:-}" in
        '--version ') if [ "$INSTALL_FAILURE" = download ]; then echo 'gh version 1.0.0'; else echo 'gh version 2.70.0'; fi ;;
        'auth status') [ "$INSTALL_FAILURE" != login ] ;;
        'auth login') echo 'Simulated login cancellation' >&2; return 41 ;;
        'auth token') echo fixture-token ;;
        # Scopes are reported only when a scenario sets them; a refresh adds admin:org.
        'api --hostname')
            [ -n "${INSTALL_SCOPES:-}" ] || return 93
            scopes=$INSTALL_SCOPES; [ ! -f "$INSTALL_HOME/refreshed" ] || scopes="$scopes, admin:org"
            printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: %s\r\n\r\n{}\n' "$scopes" ;;
        'auth refresh') printf 'refresh %s\n' "$*" >> "$INSTALL_HOME/host-calls"; touch "$INSTALL_HOME/refreshed" ;;
        *) return 93 ;;
    esac
}
curl() { echo 'Simulated download failure' >&2; return 42; }
sleep() { :; }
# The Docker socket's group as GNU stat reports it; units are kept for inspection.
stat() { if [ "$1" = -c ]; then echo "${INSTALL_SOCKET_GROUP:-docker}"; else command stat "$@"; fi; }
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
        if grep -v '\.sleep' "$home/host-calls" | grep -Eq 'systemctl (enable|restart)|launchctl (enable|bootstrap|print)'; then echo 'Stopped installation resumed during upgrade' >&2; exit 1; fi
    done
    for legacy_state in .state conf; do
        home=$FIXTURE/$target-legacy-$legacy_state
        mkdir -p "$home/$target/x64/$legacy_state"
        printf '{"platform":"%s","work_dir":"%s"}\n' "$target" "$home/work" > "$home/$target/x64/$legacy_state/settings.json"
        printf stopped > "$home/$target/x64/$legacy_state/stopped"
        run_install "$target" none "$home" "$FIXTURE" 0
        assert test -f "$home/$target/conf/stopped"
        assert jq -e --arg work "$home/work" '.work_dir==$work' "$home/$target/conf/settings.json"
        if grep -v '\.sleep' "$home/host-calls" | grep -Eq 'systemctl (enable|restart)|launchctl (enable|bootstrap|print)'; then echo 'Stopped legacy installation resumed during upgrade' >&2; exit 1; fi
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
# An existing gh login without admin:org is refreshed before its token is saved; a
# supplied token without it is refused instead of producing an idle service.
for target in linux macos; do
    home=$FIXTURE/$target-scope; work=$FIXTURE/scope-$target
    INSTALL_SCOPES='gist, read:org, repo, workflow' run_install "$target" none "$home" "$work" 0
    assert grep -q '^refresh auth refresh --hostname github.com --scopes admin:org,repo$' "$home/host-calls"
    assert grep -q 'lacks the admin:org scope' "$home/output"
    home=$FIXTURE/$target-scope-ok
    INSTALL_SCOPES='admin:org, repo' run_install "$target" none "$home" "$work" 0
    if grep -q '^refresh' "$home/host-calls" 2>/dev/null; then echo 'Refreshed a sufficient login' >&2; exit 1; fi
    home=$FIXTURE/$target-scope-env
    GH_TOKEN=env-token INSTALL_SCOPES='repo' run_install "$target" none "$home" "$work" 1
    assert grep -q 'Use a token with admin:org and run the installer again' "$home/output"
    if grep -q '^refresh' "$home/host-calls" 2>/dev/null; then echo 'Refreshed despite a supplied token' >&2; exit 1; fi
done
# Re-running the installer retries every organization at once instead of after backoff.
for target in linux macos; do
    home=$FIXTURE/$target-scope-ok
    mkdir -p "$home/$target/conf/backoff"; printf '9999999999\n5\n' > "$home/$target/conf/backoff/42"
    run_install "$target" none "$home" "$FIXTURE/scope-$target" 0
    assert test ! -e "$home/$target/conf/backoff/42"
done
# macOS installs the root sleep guard from a root-owned copy by default, keeps the choice
# on re-runs, and removes it (releasing sleep) when LOCAL_RUNNER_PREVENT_SLEEP=no.
home=$FIXTURE/macos-scope-ok; guard=com.suminwell.github-runner.1001.x64.sleep
assert grep -q "^install -o root -g wheel -m 755 $home/macos/bin/sleep.sh /Library/PrivilegedHelperTools/$guard.sh$" "$home/host-calls"
assert grep -q "^launchctl bootstrap system /Library/LaunchDaemons/$guard.plist$" "$home/host-calls"
assert jq -e '.prevent_sleep == true' "$home/macos/conf/settings.json"
: > "$home/host-calls"
LOCAL_RUNNER_PREVENT_SLEEP=no run_install macos none "$home" "$FIXTURE/scope-macos" 0
assert jq -e '.prevent_sleep == false' "$home/macos/conf/settings.json"
assert grep -q "^rm -f /Library/PrivilegedHelperTools/$guard.sh /Library/LaunchDaemons/$guard.plist$" "$home/host-calls"
if grep -q "launchctl bootstrap system /Library/LaunchDaemons/$guard.plist" "$home/host-calls"; then echo 'Started the sleep guard after it was turned off' >&2; exit 1; fi
: > "$home/host-calls"
run_install macos none "$home" "$FIXTURE/scope-macos" 0
assert jq -e '.prevent_sleep == false' "$home/macos/conf/settings.json"
LOCAL_RUNNER_PREVENT_SLEEP=maybe run_install macos none "$home" "$FIXTURE/scope-macos" 1
assert grep -q 'LOCAL_RUNNER_PREVENT_SLEEP must be yes or no' "$home/output"
# Linux binds a root logind inhibitor unit to the supervisor where logind is available.
home=$FIXTURE/linux-scope-ok; : > "$home/host-calls"
INSTALL_LOGIND=1 run_install linux none "$home" "$FIXTURE/scope-linux" 0
assert grep -q '^install -m 644 .* /etc/systemd/system/local-github-runner-1001-x64-awake.service$' "$home/host-calls"
assert grep -q '^systemctl enable local-github-runner-1001-x64-awake.service$' "$home/host-calls"
assert jq -e '.prevent_sleep == true' "$home/linux/conf/settings.json"
: > "$home/host-calls"
INSTALL_LOGIND=1 LOCAL_RUNNER_PREVENT_SLEEP=no run_install linux none "$home" "$FIXTURE/scope-linux" 0
if grep -q 'awake' "$home/host-calls"; then echo 'Installed the inhibitor after it was turned off' >&2; exit 1; fi
assert jq -e '.prevent_sleep == false' "$home/linux/conf/settings.json"
: > "$home/host-calls"
LOCAL_RUNNER_PREVENT_SLEEP=yes run_install linux none "$home" "$FIXTURE/scope-linux" 0
if grep -q 'awake' "$home/host-calls"; then echo 'Installed the inhibitor without logind' >&2; exit 1; fi
# Native jobs join the Docker socket's group unless LOCAL_RUNNER_DOCKER_ACCESS=no; the
# choice is kept on re-runs. A root-owned socket group is reported, not granted.
home=$FIXTURE/linux-scope-ok; unit=$home/unit-local-github-runner-1001-x64.service
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FIXTURE/docker.sock"
export LOCAL_RUNNER_DOCKER_SOCKET=$FIXTURE/docker.sock
run_install linux none "$home" "$FIXTURE/scope-linux" 0
assert grep -Fxq SupplementaryGroups=docker "$unit"
assert jq -e '.docker_access == true and .docker_group == "docker"' "$home/linux/conf/settings.json"
LOCAL_RUNNER_DOCKER_ACCESS=no run_install linux none "$home" "$FIXTURE/scope-linux" 0
if grep -q SupplementaryGroups "$unit"; then echo 'Docker access kept after it was turned off' >&2; exit 1; fi
run_install linux none "$home" "$FIXTURE/scope-linux" 0
assert jq -e '.docker_access == false and (has("docker_group") | not)' "$home/linux/conf/settings.json"
INSTALL_SOCKET_GROUP=root LOCAL_RUNNER_DOCKER_ACCESS=yes run_install linux none "$home" "$FIXTURE/scope-linux" 0
assert grep -q 'belongs to group root, so jobs cannot use Docker' "$home/output"
if grep -q SupplementaryGroups "$unit"; then echo 'Granted a root-owned socket group' >&2; exit 1; fi
unset LOCAL_RUNNER_DOCKER_SOCKET
# A normal-user native installation refuses passwordless sudo before changing anything.
home=$FIXTURE/linux-sudo
LOCAL_RUNNER_SUDO=yes run_install linux none "$home" "$FIXTURE/scope-linux" 1
assert grep -q 'LOCAL_RUNNER_SUDO=yes needs a root installation' "$home/output"
assert test ! -e "$home/linux"
LOCAL_RUNNER_SUDO=maybe run_install linux none "$home" "$FIXTURE/scope-linux" 1
assert grep -q 'LOCAL_RUNNER_SUDO must be yes or no' "$home/output"
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
