#!/bin/bash
# Run only in a disposable Linux container; never create accounts on the host.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" != --inside ]; then
    tar_options=(); [ "$(uname -s)" != Darwin ] || tar_options=(--no-xattrs)
    COPYFILE_DISABLE=1 tar "${tar_options[@]}" -C "$REPO" --exclude=.git -cf - . | docker run --rm -i debian:bookworm sh -c \
        'mkdir /source && tar -C /source -xf - && apt-get update -qq && apt-get install -y -qq jq acl curl ca-certificates procps sudo >/dev/null && bash /source/.test/root-install.sh --inside'
    exit $?
fi
[ -f /.dockerenv ] && [ "$(id -u)" = 0 ] || exit 1
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
mkdir -p /run/systemd/system /root/builds /fixture/package/bin
chmod 700 /root /root/builds
cat > /usr/local/bin/systemctl <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> /fixture/systemctl-calls
for argument in "$@"; do
    case "$argument" in --value|--now) echo "systemctl: unrecognized option $argument" >&2; exit 1 ;; esac
done
case "$1" in
    show) case "$4" in
        FragmentPath) printf 'FragmentPath='; [ ! -f "/etc/systemd/system/$2" ] || printf '%s' "/etc/systemd/system/$2"; printf '\n' ;;
        WorkingDirectory) sed -n '/^WorkingDirectory=/p' "/etc/systemd/system/$2" ;;
        ActiveState) if [ -f /fixture/active ]; then echo ActiveState=active; else echo ActiveState=inactive; fi ;;
    esac ;;
    start|restart)
        user=$(sed -n 's/^User=//p' "/etc/systemd/system/$2")
        root=$(sed -n 's/^WorkingDirectory=//p' "/etc/systemd/system/$2")
        runuser -u "$user" -- env -i HOME=/var/lib/github-runner/home PATH=/usr/local/bin:/usr/bin:/bin \
            /bin/bash "$root/bin/service.sh" > /fixture/manager-output 2>&1 &
        echo "$!" > /fixture/launcher.pid
        touch /fixture/active ;;
    disable) touch /fixture/disabled ;;
    stop)
        if [ -f /fixture/active ]; then kill -TERM "$(cat /fixture/launcher.pid)"; sleep 3; fi
        rm -f /fixture/active ;;
    is-active) [ -f /fixture/active ] ;;
esac
MOCK
cat > /usr/local/bin/gh <<'MOCK'
#!/bin/sh
case "$1 ${2:-}" in
    '--version ') echo 'gh version 2.70.0' ;;
    'auth token') echo fixture-token ;;
    'auth status'|'auth login') [ ! -f /fixture/cancel-login ] || exit 41 ;;
    'api --hostname')
        case "$4" in
            repos/actions/runner/releases/latest) cat /fixture/release.json ;;
            user/memberships/*) echo '[[{"state":"active","organization":{"id":1,"login":"fixture-org"}}]]' ;;
            orgs/fixture-org/actions/runners/registration-token) echo '{"token":"fixture-registration-token"}' ;;
            orgs/fixture-org/actions/runners\?*) jq '[{runners:.}]' /fixture/runners.json ;;
            orgs/fixture-org/actions/runners/100) printf '[]\n' > /fixture/runners.json ;;
            organizations/1|orgs/fixture-org) echo '{"id":1,"login":"fixture-org"}' ;;
            *) exit 92 ;;
        esac ;;
    *) exit 93 ;;
esac
MOCK
cat > /usr/local/bin/curl <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in -o) destination=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
case "$url" in
    https://api.github.com/repos/cli/cli/releases/latest) cp /fixture/gh-release.json "$destination" ;;
    https://fixture.invalid/gh.tgz) cp /fixture/gh.tgz "$destination" ;;
    https://fixture.invalid/runner.tgz) cp /fixture/runner.tgz "$destination" ;;
    *) exit 94 ;;
esac
MOCK
cat > /fixture/package/bin/installdependencies.sh <<'MOCK'
#!/bin/sh
id -u > /fixture/dependencies-uid
MOCK
cat > /fixture/package/bin/Runner.Listener <<'MOCK'
#!/bin/sh
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || exit 95
id -u >> /fixture/runtime-check-uids
if [ -f /fixture/incompatible-runtime ]; then
    echo "Runner.Listener: /lib64/libstdc++.so.6: version GLIBCXX_3.4.21 not found" >&2
    exit 127
fi
echo 2.338.2
MOCK
mkdir -p /fixture/package/externals/node24/bin
printf '#!/bin/sh\necho v24.0.0\n' > /fixture/package/externals/node24/bin/node
chmod +x /fixture/package/bin/Runner.Listener /fixture/package/externals/node24/bin/node
: > /fixture/runtime-check-uids
chmod 666 /fixture/runtime-check-uids
cat > /fixture/package/config.sh <<'MOCK'
#!/bin/sh
set -eu
[ "$(id -u)" != 0 ] || { echo 'Must not run with sudo' >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case "$1" in --name) name=$2; shift 2 ;; --work) work=$2; shift 2 ;; *) shift ;; esac
done
jq -n --arg name "$name" --arg work "$work" '{agentId:100,agentName:$name,workFolder:$work,gitHubUrl:"https://github.com/fixture-org"}' > .runner
jq -n --arg name "$name" '[{id:100,name:$name,status:"online",busy:false}]' > /fixture/runners.json
MOCK
cat > /fixture/package/run.sh <<'MOCK'
#!/bin/sh
set -eu
work=$(jq -r .workFolder .runner)
mkdir -p "$work/demo/demo"
id -u > "$work/demo/demo/job-uid"
trap 'exit 0' TERM INT
while :; do sleep 1 & wait "$!" || :; done
MOCK
printf '[]\n' > /fixture/runners.json
chmod 666 /fixture/runners.json
tar -czf /fixture/runner.tgz -C /fixture/package .
digest=$(sha256sum /fixture/runner.tgz | awk '{print $1}')
case "$(uname -m)" in aarch64) arch=arm64 ;; *) arch=x64 ;; esac
jq -n --arg name "actions-runner-linux-$arch-1.0.0.tar.gz" --arg digest "sha256:$digest" \
    '{tag_name:"v1.0.0",assets:[{name:$name,digest:$digest,browser_download_url:"https://fixture.invalid/runner.tgz"}]}' > /fixture/release.json
chmod +x /usr/local/bin/systemctl /usr/local/bin/gh /usr/local/bin/curl
# Start with no gh installed, exercising its verified download before cancelled login.
mkdir -p /fixture/cli/bin
mv /usr/local/bin/gh /fixture/cli/bin/gh
tar -czf /fixture/gh.tgz -C /fixture/cli .
cli_arch=$arch; [ "$arch" != x64 ] || cli_arch=amd64
digest=$(sha256sum /fixture/gh.tgz | awk '{print $1}')
jq -n --arg name "gh_2.70.0_linux_$cli_arch.tar.gz" --arg digest "sha256:$digest" \
    '{tag_name:"v2.70.0",assets:[{name:$name,digest:$digest,browser_download_url:"https://fixture.invalid/gh.tgz"}]}' > /fixture/gh-release.json
export LOCAL_RUNNER_SOURCE_DIR=$REPO
cd /root/builds
touch /fixture/cancel-login
result=0; sh "$REPO/install.sh" </dev/null > /fixture/first-output 2>&1 || result=$?
assert test "$result" = 41
rm /fixture/cancel-login
mkdir /root/retry
cd /root/retry
touch /fixture/incompatible-runtime
result=0; sh "$REPO/install.sh" </dev/null > /fixture/runtime-output 2>&1 || result=$?
if [ "$result" = 0 ]; then echo 'FAIL: installer reported success with an incompatible Runner.Listener' >&2; exit 1; fi
assert grep -q GLIBCXX_3.4.21 /fixture/runtime-output
assert test ! -f /fixture/active
assert test ! -e /usr/local/bin/ghr
rm /fixture/incompatible-runtime
sh "$REPO/install.sh" </dev/null
root=/opt/github-runner/linux
uid=$(id -u ghrunner)
assert test "$(sort -u /fixture/runtime-check-uids)" = "$uid"
wait_file() {
    for attempt in $(seq 1 600); do [ ! -f "$1" ] || return 0; sleep 0.1; done
    cat /fixture/manager-output >&2
    tail -n 40 /root/builds/logs/service.log '/root/new work/logs/service.log' >&2 || :
    return 1
}
assert test "$(id -u ghrunner)" -gt 0
assert test "$(cat /fixture/dependencies-uid)" = 0
assert grep -Fxq User=ghrunner "/etc/systemd/system/local-github-runner-$(id -u ghrunner)-$arch.service"
assert runuser -u ghrunner -- touch /root/builds/jobs/job /root/builds/logs/job
assert wait_file /root/builds/jobs/fixture-org/local-linux-$arch-1/demo/demo/job-uid
assert test "$(cat /root/builds/jobs/fixture-org/local-linux-$arch-1/demo/demo/job-uid)" = "$uid"
assert test ! -d /root/retry/jobs
assert test "$(ps -p "$(head -n 1 "$root/conf/runtime/manager.pid")" -o uid= | tr -d ' ')" = "$uid"
for protected in "$root/bin/ghr.sh" "$root/bin/account.sh" "$root/conf/settings.json" "$root/conf/github-token"; do
    if runuser -u ghrunner -- test -w "$protected"; then echo "Runner can modify $protected" >&2; exit 1; fi
done
printf 'private\n' > /root/private
chmod 600 /root/private
if runuser -u ghrunner -- cat /root/private >/dev/null 2>&1; then echo 'Root private file readable' >&2; exit 1; fi
ghr status > /fixture/status
assert grep -q -E '^Runner account +ghrunner' /fixture/status
assert grep -q 'online' /fixture/status
if ghr config --data-dir '/root/new work' > /fixture/missing-dir 2>&1; then echo 'Accepted a missing data directory' >&2; exit 1; fi
assert grep -q 'does not exist' /fixture/missing-dir
mkdir '/root/new work'
ghr config --data-dir '/root/new work'
assert test "$(ghr config --data-dir)" = '/root/new work'
assert test "$(cat "$root/conf/runtime/active-work-dir")" = /root/builds
ghr start
assert test "$(cat "$root/conf/runtime/active-work-dir")" = /root/builds
ghr restart
assert wait_file "/root/new work/jobs/fixture-org/local-linux-$arch-1/demo/demo/job-uid"
assert test "$(cat "/root/new work/jobs/fixture-org/local-linux-$arch-1/demo/demo/job-uid")" = "$uid"
mkdir -p /fixture/untrusted/blocked
chown ghrunner:ghrunner /fixture/untrusted
chmod 700 /fixture/untrusted/blocked
if ghr config --data-dir /fixture/untrusted/blocked > /fixture/unsafe-path-error 2>&1; then echo 'Granted root permissions through a user-writable parent' >&2; exit 1; fi
assert test "$(stat -c %a /fixture/untrusted/blocked)" = 700
if ghr config --data-dir /fixture/untrusted > /fixture/nonempty-error 2>&1; then echo 'Accepted a non-empty data directory' >&2; exit 1; fi
assert grep -q 'not empty' /fixture/nonempty-error
runuser -u ghrunner -- mkdir /fixture/untrusted/open
ghr config --data-dir /fixture/untrusted/open
assert runuser -u ghrunner -- touch /fixture/untrusted/open/jobs/job
mkdir '/root/final work'
ghr config --data-dir '/root/final work'
ghr logs > /fixture/logs
assert grep -q 'Started Shell supervisor' /fixture/logs
ghr stop
assert test -f "$root/conf/stopped"
ghr status > /fixture/stopped-status
assert grep -q -E '^Manager +stopped' /fixture/stopped-status
# Root management saves the runner count in the protected settings file.
LOCAL_RUNNER_CPU_COUNT=4 ghr runner --add
assert test "$(LOCAL_RUNNER_CPU_COUNT=4 ghr runner)" = 'Runners per organization: 2 (maximum 2: 4 CPUs / 2)'
assert test "$(runuser -u ghrunner -- jq .runner_count "$root/conf/settings.json")" = 2
assert test "$(stat -c '%U:%G %a' "$root/conf/settings.json")" = 'root:ghrunner 640'
if LOCAL_RUNNER_CPU_COUNT=4 ghr runner -a > /fixture/runner-error 2>&1; then echo 'Exceeded half the CPUs' >&2; exit 1; fi
assert grep -q 'maximum on this machine' /fixture/runner-error
if ghr config -d /tmp > /dev/null 2>&1; then echo 'Accepted the removed -d option' >&2; exit 1; fi
LOCAL_RUNNER_CPU_COUNT=4 ghr runner -s
assert test "$(runuser -u ghrunner -- jq .runner_count "$root/conf/settings.json")" = 1
assert test ! -f /fixture/active
# A forged PID file must never let root management signal an unrelated root process.
sleep 120 & unrelated=$!
stat=$(cat "/proc/$unrelated/stat"); stat=${stat##*) }; mark=$(printf '%s\n' "$stat" | awk '{print $20}')
printf '%s\n%s\n' "$unrelated" "$mark" | runuser -u ghrunner -- tee "$root/conf/runtime/manager.pid" >/dev/null
ghr stop
assert kill -0 "$unrelated"
kill "$unrelated"; wait "$unrelated" || :
# A poisoned runtime dependency installer is never executed as root during upgrade.
runuser -u ghrunner -- sh -c 'printf "touch /fixture/poison-executed\n" > "$1"' sh "$root/bin/.cache/package/bin/installdependencies.sh"
sh "$REPO/install.sh" </dev/null
assert test ! -f /fixture/poison-executed
assert test -f "$root/conf/stopped"
assert test ! -f /fixture/active
assert test "$(id -u ghrunner)" = "$uid"
ghr start
assert wait_file "$root/conf/runtime/manager.pid"
# Native jobs join the Docker socket's group by default; LOCAL_RUNNER_DOCKER_ACCESS=no is kept.
unit=/etc/systemd/system/local-github-runner-$uid-$arch.service
groupadd -f docker
perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die "$!"' /fixture/docker.sock
chgrp docker /fixture/docker.sock
export LOCAL_RUNNER_DOCKER_SOCKET=/fixture/docker.sock
sh "$REPO/install.sh" </dev/null > /fixture/docker-output 2>&1
assert grep -Fxq SupplementaryGroups=docker "$unit"
assert grep -q 'Docker access: on (group docker)' /fixture/docker-output
ghr status > /fixture/status
assert grep -Eq '^Docker access +on \(group docker\)' /fixture/status
assert grep -Eq '^Job sudo +off' /fixture/status
LOCAL_RUNNER_DOCKER_ACCESS=no sh "$REPO/install.sh" </dev/null >/dev/null 2>&1
if grep -q SupplementaryGroups "$unit"; then echo 'Docker access kept after it was turned off' >&2; exit 1; fi
sh "$REPO/install.sh" </dev/null >/dev/null 2>&1
if grep -q SupplementaryGroups "$unit"; then echo 'Docker access returned on a plain re-run' >&2; exit 1; fi
chgrp root /fixture/docker.sock
LOCAL_RUNNER_DOCKER_ACCESS=yes sh "$REPO/install.sh" </dev/null > /fixture/docker-output 2>&1
assert grep -q 'belongs to group root, so jobs cannot use Docker' /fixture/docker-output
if grep -q SupplementaryGroups "$unit"; then echo 'Granted a root-owned socket group' >&2; exit 1; fi
unset LOCAL_RUNNER_DOCKER_SOCKET
# Passwordless sudo is opt-in, validated, kept on re-runs and removed when turned off.
sudoers=/etc/sudoers.d/local-github-runner-$uid-$arch
if runuser -u ghrunner -- sudo -n true 2>/dev/null; then echo 'Runner account had sudo by default' >&2; exit 1; fi
LOCAL_RUNNER_SUDO=yes sh "$REPO/install.sh" </dev/null > /fixture/sudo-output 2>&1
assert test "$(stat -c '%a %U' "$sudoers")" = '440 root'
assert runuser -u ghrunner -- sudo -n true
assert grep -q 'Job sudo: on' /fixture/sudo-output
sh "$REPO/install.sh" </dev/null >/dev/null 2>&1
assert runuser -u ghrunner -- sudo -n true
ghr status > /fixture/status
assert grep -Eq '^Job sudo +on; passwordless sudo, which is root on this host' /fixture/status
LOCAL_RUNNER_SUDO=no sh "$REPO/install.sh" </dev/null >/dev/null 2>&1
assert test ! -e "$sudoers"
if runuser -u ghrunner -- sudo -n true 2>/dev/null; then echo 'sudo kept after it was turned off' >&2; exit 1; fi
# A sudoers file this installer did not write is never replaced.
printf 'Defaults:ghrunner !lecture\n' > "$sudoers"; chmod 440 "$sudoers"
if LOCAL_RUNNER_SUDO=yes sh "$REPO/install.sh" </dev/null > /fixture/sudo-output 2>&1; then echo 'Replaced a foreign sudoers file' >&2; exit 1; fi
assert grep -q 'was not written by this installer' /fixture/sudo-output
assert test "$(cat "$sudoers")" = 'Defaults:ghrunner !lecture'
rm "$sudoers"
LOCAL_RUNNER_SUDO=yes sh "$REPO/install.sh" </dev/null >/dev/null 2>&1
assert test -f "$sudoers"
ghr start >/dev/null 2>&1 || :
# WSL bridges from the root shell, while describe/hold/link use the service identity.
cat > /usr/bin/wslpath <<'MOCK'
#!/bin/sh
printf '%s\n' "$2"
MOCK
cat > /usr/local/bin/powershell.exe <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > /fixture/wsl-arguments
MOCK
chmod +x /usr/bin/wslpath /usr/local/bin/powershell.exe
WSL_DISTRO_NAME=Fixture ghr wsl setup
assert grep -Fxq ghrunner /fixture/wsl-arguments
WSL_DISTRO_NAME=Fixture PATH=/usr/bin:/bin bash "$root/bin/wsl.sh" setup
runuser -u ghrunner -- bash "$root/bin/wsl.sh" describe | jq -e --argjson uid "$uid" '.uid==$uid and .user=="ghrunner"' >/dev/null
runuser -u ghrunner -- bash "$root/bin/wsl.sh" link Fixture ghrunner /fixture/poison LocalGitHubRunner-WSL-fixture
PATH=/usr/bin:/bin bash "$root/bin/wsl.sh" status
assert grep -Fxq status /fixture/wsl-arguments
ghr status > /fixture/status
assert grep -Fxq status /fixture/wsl-arguments
ghr uninstall
assert test ! -e "$sudoers"
assert test ! -d "$root/conf"
assert test ! -e /usr/local/bin/ghr
assert test -f "/root/new work/jobs/fixture-org/local-linux-$arch-1/demo/demo/job-uid"
assert jq -e 'length==0' /fixture/runners.json
assert id ghrunner >/dev/null
printf 'PASS root install/retry, non-root jobs, protected config, directories, lifecycle, WSL bridge and uninstall\n'
