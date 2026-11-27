#!/bin/bash
# Docker mode for Linux hosts whose system libraries cannot run the official Runner
# (for example CentOS 7). The Shell supervisor, the Runner and every job run in an
# Ubuntu 22.04 container; systemd on the host only starts and stops that container.
#
# The container shares the host PID namespace and mounts the installation, work and
# home directories at their host paths, so ghr's PID records, locks and job bind mounts
# mean the same thing inside and outside. The host Docker socket is mounted for jobs:
# anything that can run a job can control the host as root through it.
#
# Commands: engine (installer: consent, then install/upgrade/start Docker), build, run,
# stop and verify. Bash is used because the commands need arrays; it is already required.
DOCKER_MINIMUM=20.10.10
DOCKER_SOCKET=${LOCAL_RUNNER_DOCKER_SOCKET:-/var/run/docker.sock}
DOCKER_OS_RELEASE=${LOCAL_RUNNER_OS_RELEASE:-/etc/os-release}
privileged() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

docker_version_at_least() {
    awk -v actual="$1" -v minimum="$2" 'BEGIN {
        if (actual !~ /^[0-9]+(\.[0-9]+)*/) exit 1
        sub(/[^0-9.].*$/, "", actual)
        a=split(actual,x,"."); b=split(minimum,y,"."); n=(a>b?a:b)
        for (i=1;i<=n;i++) {if (x[i]+0>y[i]+0) exit 0; if (x[i]+0<y[i]+0) exit 1} exit 0
    }'
}
# Mainland China cannot reliably reach Docker Hub or download.docker.com. Decide by the
# public IP's country, overridable with LOCAL_RUNNER_REGION=cn|global.
docker_region() {
    case "${LOCAL_RUNNER_REGION:-}" in cn|global) printf '%s\n' "$LOCAL_RUNNER_REGION"; return ;; esac
    region_trace=$(curl -fsS --connect-timeout 5 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || :)
    case "$region_trace" in
        *loc=CN*) echo cn ;;
        *loc=*) echo global ;;
        *) if curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null https://download.docker.com/ 2>/dev/null; then echo global; else echo cn; fi ;;
    esac
}
docker_package_mirror() { if [ "$1" = cn ]; then echo https://mirrors.aliyun.com/docker-ce; else echo https://download.docker.com; fi; }
docker_release_field() {
    awk -F= -v key="$1" '$1==key {v=substr($0,index($0,"=")+1); gsub(/^["\047]|["\047]$/,"",v); print v; exit}' "$DOCKER_OS_RELEASE" 2>/dev/null
}
# Installed Docker version: the daemon's when it answers, otherwise the client's.
docker_installed_version() {
    command -v docker >/dev/null 2>&1 || return 1
    installed=$(privileged docker version --format '{{.Server.Version}}' 2>/dev/null || :)
    [ -n "$installed" ] || installed=$(docker --version 2>/dev/null | sed -n 's/^Docker version \([^ ,]*\).*/\1/p')
    printf '%s\n' "${installed:-unknown}"
}
docker_confirm() {
    [ "${LOCAL_RUNNER_ASSUME_YES:-}" != yes ] || return 0
    [ -t 0 ] || return 1
    printf '%s [y/N]: ' "$1"
    IFS= read -r docker_answer || return 1
    case "$docker_answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}
docker_cancel() {
    printf '%s\nInstallation cancelled; this host was not changed.\n' "$1" >&2
    exit 1
}
docker_package_family() {
    docker_distribution=$(docker_release_field ID)
    docker_distribution_version=$(docker_release_field VERSION_ID)
    case "$docker_distribution:$docker_distribution_version" in
        rhel:7*|centos:7*|ol:7*|scientific:7*) echo el7 ;;
        ubuntu:*|debian:*|linuxmint:*) command -v apt-get >/dev/null 2>&1 && echo apt || echo manual ;;
        *) echo manual ;;
    esac
}
# CentOS 7 left the official mirrors in 2024; the base repositories then fail and
# docker-ce cannot resolve container-selinux. Only that distribution is repointed.
docker_el7_repositories_broken() {
    [ "$(docker_release_field ID)" = centos ] || return 1
    ! privileged yum -q makecache fast >/dev/null 2>&1
}
# Decide everything that needs consent before the installer changes anything.
# Sets docker_action (none|start|install|upgrade), docker_family and docker_vault.
docker_preflight() {
    docker_vault=false
    docker_family=$(docker_package_family)
    docker_current=
    if command -v docker >/dev/null 2>&1 || command -v dockerd >/dev/null 2>&1; then docker_current=$(docker_installed_version || echo unknown); fi
    if [ -n "$docker_current" ] && docker_version_at_least "$docker_current" "$DOCKER_MINIMUM"; then
        docker_action=none
        privileged docker info >/dev/null 2>&1 || docker_action=start
        printf 'Docker %s found.\n' "$docker_current"
        return 0
    fi
    if [ "$docker_family" = manual ]; then
        if [ -n "$docker_current" ]; then printf 'Docker %s is too old; Docker %s or later is required.\n' "$docker_current" "$DOCKER_MINIMUM" >&2;
        else printf 'Docker %s or later is required.\n' "$DOCKER_MINIMUM" >&2; fi
        docker_cancel 'This distribution has no automatic Docker installation. Install Docker manually and retry.'
    fi
    if [ -n "$docker_current" ]; then
        docker_action=upgrade
        cat <<NOTICE
Docker $docker_current is installed, but Docker mode requires $DOCKER_MINIMUM or later.
Upgrading replaces the old Docker packages with the latest docker-ce and restarts the
Docker daemon: running containers stop, and only those with a restart policy come back.
Images and containers of an old storage driver (for example devicemapper) may no longer
be listed after the upgrade. Back up anything important before continuing.
NOTICE
        docker_confirm 'Upgrade Docker now?' || docker_cancel 'Docker upgrade declined.'
    else
        docker_action=install
        printf 'Docker is not installed; docker-ce will be installed.\n'
    fi
    if [ "$docker_family" = el7 ] && docker_el7_repositories_broken; then
        cat <<NOTICE
The CentOS 7 base repositories are unreachable (CentOS 7 reached end of life).
Docker's dependencies need them. The installer can back up /etc/yum.repos.d/CentOS-*.repo
and point CentOS-Base at the archived CentOS 7.9.2009 vault.
NOTICE
        docker_confirm 'Switch the CentOS 7 base repositories to the vault?' || docker_cancel 'Repository change declined.'
        docker_vault=true
    fi
}
docker_write_root_file() {
    docker_temporary=$(mktemp) || return 1
    cat > "$docker_temporary" || { rm -f "$docker_temporary"; return 1; }
    privileged install -m 644 "$docker_temporary" "$1" || { rm -f "$docker_temporary"; return 1; }
    rm -f "$docker_temporary"
}
docker_el7_vault() {
    if [ "$1" = cn ]; then vault=https://mirrors.aliyun.com/centos-vault/7.9.2009; else vault=https://vault.centos.org/7.9.2009; fi
    backup=/etc/yum.repos.d/ghr-backup-$(date +%Y%m%d%H%M%S)
    privileged mkdir -p "$backup" || return 1
    for repository in /etc/yum.repos.d/CentOS-*.repo; do
        [ -f "$repository" ] || continue
        privileged mv "$repository" "$backup/" || return 1
    done
    printf 'Original CentOS repositories saved in %s\n' "$backup"
    docker_write_root_file /etc/yum.repos.d/CentOS-Base.repo <<REPO
# Written by the GitHub Runner installer; originals are in $backup.
[base]
name=CentOS-7.9.2009 - Base
baseurl=$vault/os/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[updates]
name=CentOS-7.9.2009 - Updates
baseurl=$vault/updates/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[extras]
name=CentOS-7.9.2009 - Extras
baseurl=$vault/extras/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
REPO
    privileged yum clean all >/dev/null
}
docker_engine_el7() {
    mirror=$(docker_package_mirror "$1")
    if [ "$docker_action" = upgrade ]; then
        privileged yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || return 1
    fi
    docker_write_root_file /etc/yum.repos.d/docker-ce.repo <<REPO
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=$mirror/linux/centos/7/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=$mirror/linux/centos/gpg
REPO
    privileged yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
docker_engine_apt() {
    mirror=$(docker_package_mirror "$1")
    distribution=$(docker_release_field ID)
    codename=$(docker_release_field UBUNTU_CODENAME)
    [ -n "$codename" ] && [ "$distribution" != debian ] && distribution=ubuntu || codename=$(docker_release_field VERSION_CODENAME)
    [ -n "$codename" ] || { echo 'Cannot determine the distribution codename for the Docker repository.' >&2; return 1; }
    if [ "$docker_action" = upgrade ]; then
        for package in docker.io docker-doc docker-compose podman-docker containerd runc docker-engine; do
            ! dpkg -s "$package" >/dev/null 2>&1 || privileged apt-get remove -y "$package" || return 1
        done
    fi
    privileged apt-get update || return 1
    privileged apt-get install -y ca-certificates curl || return 1
    privileged install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL --max-time 60 "$mirror/linux/$distribution/gpg" | docker_write_root_file /etc/apt/keyrings/docker.asc || return 1
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$mirror" "$distribution" "$codename" | \
        docker_write_root_file /etc/apt/sources.list.d/docker.list || return 1
    privileged apt-get update || return 1
    privileged apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
# Changes the host only for the action consented to in docker_preflight.
docker_engine_prepare() {
    case "$docker_action" in
        none) return 0 ;;
        start) privileged systemctl enable docker && privileged systemctl start docker || return 1 ;;
        install|upgrade)
            region=$(docker_region)
            printf 'Installing Docker from %s (region: %s).\n' "$(docker_package_mirror "$region")" "$region"
            if [ "$docker_vault" = true ]; then docker_el7_vault "$region" || return 1; fi
            if [ "$docker_family" = el7 ]; then docker_engine_el7 "$region" || return 1; else docker_engine_apt "$region" || return 1; fi
            privileged systemctl enable docker || return 1
            privileged systemctl restart docker || return 1 ;;
    esac
    docker_current=$(docker_installed_version || echo unknown)
    docker_version_at_least "$docker_current" "$DOCKER_MINIMUM" || { printf 'Docker %s is still older than %s.\n' "$docker_current" "$DOCKER_MINIMUM" >&2; return 1; }
    privileged docker info >/dev/null || { echo 'The Docker daemon is not answering.' >&2; return 1; }
    printf 'Docker %s ready.\n' "$docker_current"
}

docker_load() {
    DOCKER_ROOT=$(cd "$(dirname "$0")/.." && pwd) || return 1
    DOCKER_JQ=$(cat "$DOCKER_ROOT/conf/jq-path") || return 1
    DOCKER_ARCH=$("$DOCKER_JQ" -er .arch "$DOCKER_ROOT/conf/settings.json") || return 1
    DOCKER_WORK=$("$DOCKER_JQ" -r --arg root "$DOCKER_ROOT" '.work_dir // $root' "$DOCKER_ROOT/conf/settings.json") || return 1
    DOCKER_IMAGE=$("$DOCKER_JQ" -r '.docker_image // empty' "$DOCKER_ROOT/conf/settings.json") || return 1
    # The installer writes this root-owned rule only when LOCAL_RUNNER_SUDO=yes; it is
    # mounted into the container and never into the host sudoers.
    DOCKER_SUDOERS=
    if [ "$("$DOCKER_JQ" -r '.job_sudo == true' "$DOCKER_ROOT/conf/settings.json")" = true ]; then
        DOCKER_SUDOERS=${LOCAL_RUNNER_DOCKER_SUDOERS_DIR:-/etc/github-runner/sudoers}/local-github-runner-$("$DOCKER_JQ" -r .owner_uid "$DOCKER_ROOT/conf/settings.json")-$DOCKER_ARCH
    fi
}
# Build the default image; prints the image reference. LOCAL_RUNNER_DOCKER_IMAGE uses a
# prepared image instead (it must provide bash, jq, curl, git, ps, tar and the Runner's
# .NET dependencies).
docker_build() {
    [ -z "${LOCAL_RUNNER_DOCKER_IMAGE:-}" ] || { printf '%s\n' "$LOCAL_RUNNER_DOCKER_IMAGE"; return 0; }
    region=$(docker_region)
    if [ -n "${LOCAL_RUNNER_DOCKER_BASE:-}" ]; then candidates=$LOCAL_RUNNER_DOCKER_BASE
    elif [ "$region" = cn ]; then candidates='ubuntu:22.04 docker.m.daocloud.io/library/ubuntu:22.04 docker.1ms.run/library/ubuntu:22.04'
    else candidates=ubuntu:22.04; fi
    base=
    for candidate in $candidates; do
        printf 'Pulling %s\n' "$candidate" >&2
        if timeout 600 docker pull "$candidate" >&2; then base=$candidate; break; fi
    done
    [ -n "$base" ] || { printf 'Cannot pull an Ubuntu 22.04 base image (%s). Set LOCAL_RUNNER_DOCKER_BASE to a reachable registry.\n' "$candidates" >&2; return 1; }
    ubuntu_mirror=${LOCAL_RUNNER_UBUNTU_MIRROR:-}
    [ -n "$ubuntu_mirror" ] || [ "$region" != cn ] || ubuntu_mirror=http://mirrors.aliyun.com
    image=local-github-runner:$DOCKER_ARCH
    context=$(mktemp -d) || return 1
    cp "$DOCKER_ROOT/bin/Dockerfile" "$context/Dockerfile" || { rm -rf "$context"; return 1; }
    if ! docker build --pull=false --label io.github.suminwell.github-runner=1 \
        --build-arg "BASE_IMAGE=$base" --build-arg "UBUNTU_MIRROR=$ubuntu_mirror" \
        --build-arg "DOCKER_MIRROR=$(docker_package_mirror "$region")" -t "$image" "$context" >&2; then
        rm -rf "$context"; return 1
    fi
    rm -rf "$context"
    printf '%s\n' "$image"
}
docker_container_name() { printf 'local-github-runner-%s-%s\n' "$(id -u)" "$DOCKER_ARCH"; }
# Arguments shared by the supervisor and the runtime check. LOCAL_RUNNER_DOCKER_USER
# and LOCAL_RUNNER_DOCKER_HOME let the installer, running as root, act for the account.
docker_arguments() {
    local user=${LOCAL_RUNNER_DOCKER_USER:-$(id -u):$(id -g)} home=${LOCAL_RUNNER_DOCKER_HOME:-$HOME} mounted= path
    [ -n "$DOCKER_IMAGE" ] || { echo 'No Docker image configured; re-run the installer.' >&2; return 1; }
    [ -S "$DOCKER_SOCKET" ] || { echo "Docker socket missing: $DOCKER_SOCKET" >&2; return 1; }
    DOCKER_ARGS=(--pid host --network host --user "$user" --group-add "$(stat -c %g "$DOCKER_SOCKET")"
        -e "HOME=$home" -e LOCAL_RUNNER_JQ=/usr/bin/jq -e TZ=UTC -w "$DOCKER_ROOT"
        -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro -v "$DOCKER_SOCKET:$DOCKER_SOCKET")
    if [ -n "${DOCKER_SUDOERS:-}" ]; then
        [ -f "$DOCKER_SUDOERS" ] && [ -f "$DOCKER_SUDOERS.shadow" ] || { echo "Job sudo is on but $DOCKER_SUDOERS is missing; re-run the installer." >&2; return 1; }
        DOCKER_ARGS+=(-v "$DOCKER_SUDOERS:/etc/sudoers.d/github-runner:ro" -v "$DOCKER_SUDOERS.shadow:/etc/shadow:ro")
    fi
    # Identical paths inside and outside; a path already covered by an exact mount is skipped.
    for path in "$DOCKER_ROOT" "$DOCKER_WORK" "$home"; do
        [ -d "$path" ] || continue
        case "|$mounted|" in *"|$path|"*) continue ;; esac
        mounted=$mounted\|$path
        DOCKER_ARGS+=(-v "$path:$path")
    done
}
docker_command() {
    set -u
    if [ "${1:-}" = engine ]; then docker_preflight && docker_engine_prepare; return; fi
    docker_load || return 1
    case "${1:-}" in
        build) docker_build ;;
        run)
            docker_arguments || return 1
            name=$(docker_container_name)
            docker rm -f "$name" >/dev/null 2>&1 || :
            exec docker run --rm --name "$name" "${DOCKER_ARGS[@]}" "$DOCKER_IMAGE" /bin/bash "$DOCKER_ROOT/bin/service.sh" serve ;;
        stop)
            name=$(docker_container_name)
            if docker inspect "$name" >/dev/null 2>&1; then docker stop -t 80 "$name" >/dev/null; fi ;;
        verify)
            docker_arguments || return 1
            docker run --rm "${DOCKER_ARGS[@]}" "$DOCKER_IMAGE" /bin/bash "$DOCKER_ROOT/bin/service.sh" verify ;;
        *) echo 'Usage: docker.sh engine|build|run|stop|verify' >&2; return 2 ;;
    esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    umask 077
    docker_command "$@"
fi
