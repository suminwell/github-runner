#!/bin/bash
# Docker mode: legacy host detection, Docker consent and installation, the systemd unit
# and the container launcher. Docker, package managers and sudo are replaced by
# recorders; no image is built and no host package is changed.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-docker.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
refute() { if "$@"; then printf 'FAIL: unexpectedly true: %s\n' "$*" >&2; exit 1; fi; }
mkdir -p "$FIXTURE/bin"
printf 'NAME="CentOS Linux"\nID="centos"\nVERSION_ID="7"\nPRETTY_NAME="CentOS Linux 7 (Core)"\n' > "$FIXTURE/centos7"
printf 'ID=ubuntu\nVERSION_ID="18.04"\nVERSION_CODENAME=bionic\nUBUNTU_CODENAME=bionic\n' > "$FIXTURE/ubuntu1804"
printf 'ID=opensuse-leap\nVERSION_ID="15.1"\n' > "$FIXTURE/suse"

# Installer helpers: legacy distributions select Docker mode, Alpine stays unsupported.
sed '/^if \[ -t 0 \]/,$d' "$REPO/linux/install.sh" > "$FIXTURE/install.sh"
(
    . "$FIXTURE/install.sh"
    getconf() { echo 'glibc 2.17'; }
    read_linux_release() { cat "$FIXTURE/centos7"; }
    status=0; check_linux_compatibility 2> "$FIXTURE/out" || status=$?
    [ "$status" = 3 ] || { echo "legacy status $status" >&2; exit 1; }
    assert grep -q 'cannot run the official Runner directly' "$FIXTURE/out"
    read_linux_release() { printf 'ID=alpine\nVERSION_ID=3.20\n'; }
    status=0; check_linux_compatibility 2>/dev/null || status=$?
    [ "$status" = 1 ] || { echo "alpine status $status" >&2; exit 1; }
    systemd_unit runner /home/runner /usr/bin:/bin '/opt/github runner' docker > "$FIXTURE/unit"
    assert grep -Fxq 'SupplementaryGroups=docker' "$FIXTURE/unit"
    assert grep -Fxq 'ExecStart=/bin/bash "/opt/github runner/bin/docker.sh" run' "$FIXTURE/unit"
    assert grep -Fxq 'ExecStop=/bin/bash "/opt/github runner/bin/docker.sh" stop' "$FIXTURE/unit"
    assert grep -Fxq 'After=network-online.target docker.service' "$FIXTURE/unit"
    assert grep -Fxq 'WorkingDirectory=/opt/github runner' "$FIXTURE/unit"
    systemd_unit runner /home/runner /usr/bin:/bin /opt/runner > "$FIXTURE/unit"
    assert grep -Fxq 'ExecStart=/bin/bash "/opt/runner/bin/service.sh"' "$FIXTURE/unit"
    refute grep -q docker "$FIXTURE/unit"
)

# Engine preflight and installation, with every privileged command recorded.
(
    . "$REPO/linux/docker.sh"
    log=$FIXTURE/privileged
    privileged() {
        printf '%s\n' "$*" >> "$log"
        case "$1" in
            install) [ "$2" != -m ] || [ "$4" = -d ] || cp "$4" "$FIXTURE/written-${5##*/}" ;;
            docker) case "$2" in version) printf '%s\n' "$daemon_version" ;; info) [ "$daemon_running" = yes ] ;; esac ;;
            yum) [ "$2" != -q ] || [ "$makecache" = ok ] ;;
        esac
    }
    docker() { [ "$1" = --version ] && printf 'Docker version %s, build x\n' "$daemon_version"; }
    curl() { case "$*" in *cdn-cgi/trace*) printf '%s' "$trace" ;; *gpg*) echo key ;; *) [ "$probe" = ok ] ;; esac; }
    dpkg() { [ "$1" = --print-architecture ] && echo amd64 || [ "$2" = docker.io ]; }
    reset() { rm -f "$log" "$FIXTURE"/written-*; : > "$log"; }

    for value in 20.10.10 20.10.24+dfsg1 24.0.7 26.1.4; do docker_version_at_least "$value" "$DOCKER_MINIMUM"; done
    for value in 1.13.1 20.10.9 19.03.15 unknown ''; do refute docker_version_at_least "$value" "$DOCKER_MINIMUM"; done

    trace='loc=CN'; probe=ok; [ "$(docker_region)" = cn ]
    trace='loc=US'; [ "$(docker_region)" = global ]
    trace=; probe=fail; [ "$(docker_region)" = cn ]
    probe=ok; [ "$(docker_region)" = global ]
    LOCAL_RUNNER_REGION=cn; [ "$(docker_region)" = cn ]; unset LOCAL_RUNNER_REGION

    # An old Docker without consent: nothing runs except read-only queries.
    LOCAL_RUNNER_OS_RELEASE=$FIXTURE/centos7; DOCKER_OS_RELEASE=$LOCAL_RUNNER_OS_RELEASE
    command() {
        if [ "$1" = -v ]; then case "$2" in docker|dockerd) [ "$installed" = yes ]; return ;; apt-get) [ "$apt" = yes ]; return ;; esac; fi
        builtin command "$@"
    }
    apt=no
    installed=yes; daemon_version=1.13.1; daemon_running=yes; makecache=ok; reset
    if (docker_preflight < /dev/null) > "$FIXTURE/out" 2>&1; then echo 'Upgraded Docker without consent' >&2; exit 1; fi
    assert grep -q 'Docker upgrade declined' "$FIXTURE/out"
    assert grep -q 'this host was not changed' "$FIXTURE/out"
    refute grep -Eq '^(yum (remove|install)|systemctl|install|mv)' "$log"

    # Consent upgrades CentOS 7 from the regional mirror and restarts the daemon.
    reset; trace='loc=CN'
    (
        LOCAL_RUNNER_ASSUME_YES=yes
        docker_preflight > "$FIXTURE/out"
        assert [ "$docker_action" = upgrade ]; assert [ "$docker_family" = el7 ]; assert [ "$docker_vault" = false ]
        daemon_version=26.1.4
        docker_engine_prepare >> "$FIXTURE/out"
    )
    assert grep -q '^yum remove -y docker docker-client' "$log"
    assert grep -q '^yum install -y docker-ce docker-ce-cli containerd.io' "$log"
    assert grep -Fxq 'systemctl restart docker' "$log"
    assert grep -q 'baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/7/\$basearch/stable' "$FIXTURE/written-docker-ce.repo"
    assert grep -q 'Docker 26.1.4 ready' "$FIXTURE/out"

    # Dead CentOS 7 repositories need a second consent before being repointed.
    reset; installed=no; makecache=fail
    if (LOCAL_RUNNER_ASSUME_YES=; docker_confirm() { return 1; }; docker_preflight) > "$FIXTURE/out" 2>&1; then echo 'Changed repositories without consent' >&2; exit 1; fi
    assert grep -q 'Repository change declined' "$FIXTURE/out"
    reset; trace='loc=DE'
    (
        LOCAL_RUNNER_ASSUME_YES=yes
        docker_preflight > "$FIXTURE/out"
        assert [ "$docker_action" = install ]; assert [ "$docker_vault" = true ]
        installed=yes; daemon_version=26.1.4
        docker_engine_prepare >> "$FIXTURE/out"
    )
    refute grep -q '^yum remove' "$log"
    assert grep -q 'baseurl=https://vault.centos.org/7.9.2009/os/\$basearch/' "$FIXTURE/written-CentOS-Base.repo"
    assert grep -q 'baseurl=https://download.docker.com/linux/centos/7' "$FIXTURE/written-docker-ce.repo"
    assert grep -q '^mv /etc/yum.repos.d/CentOS-\*.repo\|^mkdir -p /etc/yum.repos.d/ghr-backup-' "$log"

    # A current Docker is used as is; a stopped daemon is only started.
    reset; installed=yes; daemon_version=26.1.4; daemon_running=no
    (docker_preflight > /dev/null; assert [ "$docker_action" = start ]; daemon_running=yes; docker_engine_prepare > /dev/null)
    assert grep -Fxq 'systemctl start docker' "$log"
    refute grep -q '^yum' "$log"

    # Debian family uses Docker's apt repository for the distribution codename.
    reset; DOCKER_OS_RELEASE=$FIXTURE/ubuntu1804; installed=no; trace='loc=CN'
    apt=yes
    (docker_preflight > /dev/null; assert [ "$docker_family" = apt ]; installed=yes; daemon_version=26.1.4; daemon_running=yes; docker_engine_prepare > /dev/null)
    assert grep -Fxq 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu bionic stable' "$FIXTURE/written-docker.list"
    assert grep -q '^apt-get install -y docker-ce' "$log"

    # Distributions without an automatic path stop before changing anything.
    reset; DOCKER_OS_RELEASE=$FIXTURE/suse; installed=no
    if (docker_preflight) > "$FIXTURE/out" 2>&1; then echo 'Accepted manual distribution' >&2; exit 1; fi
    assert grep -q 'Install Docker manually' "$FIXTURE/out"
    [ ! -s "$log" ] || { cat "$log" >&2; exit 1; }
)

# The real installer entry on CentOS 7 asks before upgrading an old Docker, and a
# refusal ends the installation before any account, directory or service change.
cat > "$FIXTURE/bin/sudo" <<'MOCK'
#!/bin/sh
[ "$1" != -v ] || exit 0
exec "$@"
MOCK
cat > "$FIXTURE/bin/docker" <<'MOCK'
#!/bin/sh
case "$1" in version) echo 1.13.1 ;; --version) echo 'Docker version 1.13.1, build 7d71120' ;; info) exit 0 ;; *) echo "docker $*" >> "$FIXTURE/mutated"; exit 1 ;; esac
MOCK
cat > "$FIXTURE/bin/yum" <<'MOCK'
#!/bin/sh
echo "yum $*" >> "$FIXTURE/mutated"; exit 1
MOCK
chmod +x "$FIXTURE/bin/"*
cat > "$FIXTURE/run-install.sh" <<'INSTALL'
#!/bin/bash
set -eu
. "$FIXTURE/install.sh"
uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) echo 3.10.0-1160.el7.x86_64 ;; esac; }
read_linux_release() { cat "$FIXTURE/centos7"; }
getconf() { echo 'glibc 2.17'; }
check_linux_host() { :; }
id() { echo 1001; }
account_setup() { echo account >> "$FIXTURE/mutated"; }
mkdir() { echo "mkdir $*" >> "$FIXTURE/mutated"; command mkdir "$@"; }
install_main auto
INSTALL
result=0
FIXTURE=$FIXTURE PATH="$FIXTURE/bin:$PATH" LOCAL_RUNNER_SOURCE_DIR=$REPO LOCAL_RUNNER_OS_RELEASE=$FIXTURE/centos7 HOME=$FIXTURE/home \
    /bin/bash "$FIXTURE/run-install.sh" > "$FIXTURE/install-output" 2>&1 < /dev/null || result=$?
if [ "$result" != 1 ] || [ -s "$FIXTURE/mutated" ]; then
    cat "$FIXTURE/install-output" >&2; cat "$FIXTURE/mutated" >&2 2>/dev/null || :
    echo "FAIL: declined Docker upgrade changed the host (installer exit $result)" >&2; exit 1
fi
assert grep -q 'CentOS Linux 7' "$FIXTURE/install-output"
assert grep -q 'Docker mode' "$FIXTURE/install-output"
assert grep -q 'Docker upgrade declined' "$FIXTURE/install-output"
assert test ! -e "$FIXTURE/home/.local/share/github-runner"

# The container launcher: identical host paths, host PID namespace, the Docker socket
# and the account's identity; stop only stops this installation's container.
if [ "$(uname -s)" = Linux ]; then
    root=$FIXTURE/'program files'; work=$FIXTURE/work; home=$FIXTURE/home
    command mkdir -p "$root/bin" "$root/conf" "$work" "$home"
    cp "$REPO/linux/docker.sh" "$root/bin/docker.sh"
    command -v jq > "$root/conf/jq-path"
    jq -n --arg work "$work" '{arch:"x64",work_dir:$work,runtime:"docker",docker_image:"local-github-runner:x64"}' > "$root/conf/settings.json"
    python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FIXTURE/docker.sock"
    cat > "$FIXTURE/bin/docker" <<'MOCK'
#!/bin/sh
printf '%s\n' "$@" > "$FIXTURE/docker-$1"
case "$1" in inspect) [ -f "$FIXTURE/running" ] ;; esac
MOCK
    export FIXTURE LOCAL_RUNNER_DOCKER_SOCKET=$FIXTURE/docker.sock
    PATH="$FIXTURE/bin:$PATH" HOME=$home bash "$root/bin/docker.sh" run
    args=$FIXTURE/docker-run
    for expected in --rm --pid host --network host "$(id -u):$(id -g)" "$(stat -c %g "$FIXTURE/docker.sock")" \
        "$root:$root" "$work:$work" "$home:$home" "$FIXTURE/docker.sock:$FIXTURE/docker.sock" \
        /etc/passwd:/etc/passwd:ro LOCAL_RUNNER_JQ=/usr/bin/jq "local-github-runner-$(id -u)-x64" \
        local-github-runner:x64 "$root/bin/service.sh" serve; do
        assert grep -Fxq -- "$expected" "$args"
    done
    assert grep -Fxq -- "rm" "$FIXTURE/docker-rm"
    # A work directory inside the installation is mounted once.
    jq --arg work "$root" '.work_dir=$work' "$root/conf/settings.json" > "$FIXTURE/s" && mv "$FIXTURE/s" "$root/conf/settings.json"
    PATH="$FIXTURE/bin:$PATH" HOME=$home bash "$root/bin/docker.sh" run
    assert [ "$(grep -cFx -- "$root:$root" "$args")" = 1 ]
    LOCAL_RUNNER_DOCKER_USER=123:456 LOCAL_RUNNER_DOCKER_HOME=$home PATH="$FIXTURE/bin:$PATH" bash "$root/bin/docker.sh" verify
    assert grep -Fxq 123:456 "$FIXTURE/docker-run"
    assert grep -Fxq verify "$FIXTURE/docker-run"
    refute grep -Fxq -- --name "$FIXTURE/docker-run"
    rm -f "$FIXTURE/docker-stop"
    PATH="$FIXTURE/bin:$PATH" bash "$root/bin/docker.sh" stop
    assert test ! -e "$FIXTURE/docker-stop"
    touch "$FIXTURE/running"
    PATH="$FIXTURE/bin:$PATH" bash "$root/bin/docker.sh" stop
    assert grep -Fxq "local-github-runner-$(id -u)-x64" "$FIXTURE/docker-stop"
    jq 'del(.docker_image)' "$root/conf/settings.json" > "$FIXTURE/s" && mv "$FIXTURE/s" "$root/conf/settings.json"
    if PATH="$FIXTURE/bin:$PATH" bash "$root/bin/docker.sh" run 2> "$FIXTURE/out"; then echo 'Ran without an image' >&2; exit 1; fi
    assert grep -q 'No Docker image configured' "$FIXTURE/out"
fi
printf 'PASS Docker mode: legacy detection, consent before changes, engine install, unit and container launcher\n'
