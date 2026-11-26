#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
fixture=$(cd "$fixture" && pwd -P)
holder=
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null || :; rm -rf "$fixture"' EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
(
    sed '/^install_main()/,$d' "$repo/linux/install.sh" > "$fixture/helpers.sh"
    . "$fixture/helpers.sh"
    unset WSL_DISTRO_NAME WSL_INTEROP
    uname() { printf '%s\n' "$kernel"; }
    systemd_running() { [ "$systemd" = yes ]; }
    kernel=4.4.0-Microsoft; systemd=no
    if check_linux_host > "$fixture/error" 2>&1; then exit 1; fi
    assert grep -q WSL1 "$fixture/error"
    kernel=6.6.87.2-microsoft-standard-WSL2
    if check_linux_host > "$fixture/error" 2>&1; then exit 1; fi
    assert grep -q 'systemd=true' "$fixture/error"
    systemd=yes; check_linux_host
    kernel=6.8.0-generic; check_linux_host
    systemd=no
    if check_linux_host > "$fixture/error" 2>&1; then exit 1; fi
    assert grep -q 'Linux must be booted with systemd' "$fixture/error"
    export WSL_DISTRO_NAME='Ubuntu Work'; kernel=6.8.0-custom; systemd=yes
    check_linux_host
    [ "$(PATH='/usr/bin:/mnt/c/Windows/system32:/bin:/mnt/c/Program Files/nodejs' linux_service_path)" = /usr/bin:/bin ]
    unset WSL_DISTRO_NAME; kernel=6.8.0-generic
    [ "$(PATH=/usr/bin:/mnt/tools linux_service_path)" = /usr/bin:/mnt/tools ]
)
root=$fixture/'program files'
mkdir -p "$root/bin" "$root/conf" "$fixture/commands"
cp "$repo/linux/wsl.sh" "$root/bin/wsl.sh"
cp "$repo/linux/wsl.ps1" "$root/bin/wsl.ps1"
command -v jq > "$root/conf/jq-path"
jq -n --argjson uid "$(id -u)" '{platform:"linux",arch:"x64",owner_uid:$uid}' > "$root/conf/settings.json"
cat > "$fixture/commands/wslpath" <<'MOCK'
#!/bin/sh
printf '%s\n' "$2"
MOCK
cat > "$fixture/fake powershell" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > "$WSL_TEST_ARGS"
exit "${WSL_TEST_EXIT:-0}"
MOCK
chmod +x "$fixture/commands/wslpath" "$fixture/fake powershell"
ln -s "$fixture/fake powershell" "$fixture/commands/powershell.exe"
if ! command -v flock >/dev/null; then
    # The actual WSL helper runs on Linux; macOS tests mock only the Linux lock utility.
    printf '#!/bin/sh\nexit 0\n' > "$fixture/commands/flock"
    chmod +x "$fixture/commands/flock"
fi
export PATH="$fixture/commands:$PATH" WSL_TEST_ARGS="$fixture/args"
bash "$root/bin/wsl.sh" describe | jq -e --arg root "$root" '.root==$root and .arch=="x64"' >/dev/null
bash "$root/bin/wsl.sh" start
assert test ! -f "$fixture/args"
WSL_DISTRO_NAME='Ubuntu Work' bash "$root/bin/wsl.sh" setup
assert grep -Fxq Install "$fixture/args"
assert grep -Fxq 'Ubuntu Work' "$fixture/args"
ln -s "$root" "$fixture/program alias"
WSL_DISTRO_NAME='Ubuntu Work' bash "$fixture/program alias/bin/wsl.sh" setup
assert grep -Fxq "$root" "$fixture/args"
bash "$root/bin/wsl.sh" link 'Ubuntu Work' 'runner' "$fixture/fake powershell" LocalGitHubRunner-WSL-fixture
for action in start stop remove status; do
    bash "$root/bin/wsl.sh" "$action"
    assert grep -Fxq "$action" "$fixture/args"
    assert grep -Fxq 'Ubuntu Work' "$fixture/args"
    assert grep -Fxq "$root" "$fixture/args"
done
if WSL_TEST_EXIT=1 bash "$root/bin/wsl.sh" start 2>/dev/null; then echo 'Ignored Windows bridge failure' >&2; exit 1; fi
bash "$root/bin/wsl.sh" hold & holder=$!
sleep 0.2
assert kill -0 "$holder"
if [ "$(uname -s)" = Linux ]; then
    # The real Linux flock makes a duplicate foreground holder return immediately.
    bash "$root/bin/wsl.sh" hold & duplicate=$!
    sleep 0.2
    if kill -0 "$duplicate" 2>/dev/null; then kill "$duplicate"; echo 'Duplicate WSL holder remained running' >&2; exit 1; fi
    wait "$duplicate"
fi
touch "$root/conf/stopped"
bash "$root/bin/wsl.sh" describe | jq -e '.stopped==true' >/dev/null
wait "$holder"; holder=
bash "$root/bin/wsl.sh" hold
rm "$root/conf/stopped" "$root/conf/settings.json"
bash "$root/bin/wsl.sh" hold
(
    # Exercise the actual ghr lifecycle; only the native system service is mocked.
    export LOCAL_RUNNER_ROOT=$root
    jq -n --argjson uid "$(id -u)" '{platform:"linux",arch:"x64",owner_uid:$uid}' > "$root/conf/settings.json"
    printf '/bin/false\n' > "$root/conf/gh-path"
    . "$repo/linux/ghr.sh"
    init control
    native_service() { :; }
    stop_processes() { :; }
    record_alive() { return 1; }
    command_main stop
    assert test -f "$root/conf/stopped"
    assert grep -Fxq stop "$fixture/args"
    command_main start
    assert test ! -f "$root/conf/stopped"
    assert grep -Fxq start "$fixture/args"
    command_main restart
    assert grep -Fxq start "$fixture/args"
    command_main uninstall
    assert grep -Fxq remove "$fixture/args"
    assert test ! -d "$root/conf"
)
printf 'PASS WSL preflight, bridge arguments, failure propagation and keepalive lifecycle\n'
