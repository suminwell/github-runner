#!/bin/sh
# Complete POSIX entry point; safe for curl ... | sh.
set -eu
privileged() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
systemd_property() (
    property_unit=$1; property_name=$2
    property_output=$(privileged systemctl show "$property_unit" -p "$property_name" --all) || {
        printf 'Cannot read systemd property %s for %s.\n' "$property_name" "$property_unit" >&2; exit 1;
    }
    case "$property_output" in
        "$property_name="*) printf '%s\n' "${property_output#*=}" ;;
        *) printf 'Missing systemd property %s for %s.\n' "$property_name" "$property_unit" >&2; exit 1 ;;
    esac
)
# Classic OAuth tokens report their scopes; other token kinds (fine-grained, GitHub App)
# do not, and are left to the API itself.
token_has_admin_org() {
    token_scopes=$(GH_TOKEN=$1 GH_HOST=github.com GH_PROMPT_DISABLED=1 "$gh_path" api --hostname github.com -i user 2>/dev/null | tr -d '\r' | \
        sed -n 's/^[Xx]-[Oo][Aa][Uu][Tt][Hh]-[Ss][Cc][Oo][Pp][Ee][Ss]: *//p' | head -n 1) || token_scopes=
    [ -n "$token_scopes" ] || return 0
    case ", $token_scopes," in *", admin:org,"*) return 0 ;; *) return 1 ;; esac
}
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
unit_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'; }
# systemd unquotes Environment= and ExecStart=, but rejects a quoted WorkingDirectory=.
# A fifth argument (the Docker socket group) selects Docker mode: the unit then only
# starts and stops the supervisor's container, as the same account. A sixth gives native
# mode the Docker socket group.
systemd_unit() {
    exec_path=$(unit_quote "$4/bin/service.sh" | sed 's/\$/$$/g')
    docker_path=$(unit_quote "$4/bin/docker.sh" | sed 's/\$/$$/g')
    after=network-online.target
    [ -z "${5:-}" ] || after="network-online.target docker.service"
    cat <<UNIT
[Unit]
Description=GitHub organization runner supervisor
Wants=$after
After=$after
StartLimitIntervalSec=0
[Service]
Type=simple
User=$1
WorkingDirectory=$(printf '%s' "$4" | sed 's/%/%%/g')
Environment="HOME=$(unit_quote "$2")"
Environment="PATH=$(unit_quote "$3")"
UNIT
    if [ -n "${5:-}" ]; then
        printf 'SupplementaryGroups=%s\nExecStart=/bin/bash "%s" run\nExecStop=/bin/bash "%s" stop\n' "$5" "$docker_path" "$docker_path"
    else
        # A sixth argument is the Docker socket group that native jobs may use.
        [ -z "${6:-}" ] || printf 'SupplementaryGroups=%s\n' "$6"
        printf 'ExecStart=/bin/bash "%s"\n' "$exec_path"
    fi
    cat <<UNIT
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=90
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
}
# Bound to the supervisor unit: holds a logind inhibitor (sleep, idle and lid-close
# suspend) while it runs, and stops with it. It runs as root, which logind always allows.
awake_unit() {
    cat <<UNIT
[Unit]
Description=Keep this machine awake while $1 runs
BindsTo=$1
After=$1
[Service]
Type=simple
ExecStart=$2 --what=sleep:idle:handle-lid-switch --who=github-runner "--why=GitHub runner is waiting for jobs" --mode=block $3 infinity
Restart=on-failure
RestartSec=60
[Install]
WantedBy=$1
UNIT
}
# Job permissions requested for this run (empty keeps the recorded choice). Checked before
# anything on the host changes.
yes_no() {
    case "$2" in
        yes|true|1) printf true ;; no|false|0) printf false ;; '') ;;
        *) echo "$1 must be yes or no." >&2; return 1 ;;
    esac
}
check_job_permissions() {
    requested_docker_access=$(yes_no LOCAL_RUNNER_DOCKER_ACCESS "${LOCAL_RUNNER_DOCKER_ACCESS:-}") || exit 1
    requested_sudo=$(yes_no LOCAL_RUNNER_SUDO "${LOCAL_RUNNER_SUDO:-}") || exit 1
    if [ "$runtime" = docker ] && [ "$requested_docker_access" = false ]; then
        echo 'Docker mode needs the host Docker daemon; LOCAL_RUNNER_DOCKER_ACCESS=no is only possible in native mode.' >&2; exit 1
    fi
    if [ "$runtime" = native ] && [ "$requested_sudo" = true ]; then
        $root_install || {
            echo 'LOCAL_RUNNER_SUDO=yes needs a root installation: a normal-user installation runs jobs as your own login account, which would then have passwordless sudo everywhere.' >&2; exit 1;
        }
        sudoers_included || { echo '/etc/sudoers does not include /etc/sudoers.d; LOCAL_RUNNER_SUDO=yes cannot grant sudo.' >&2; exit 1; }
    fi
}
# A missing /etc/sudoers is fine: the sudo package installed later brings the include.
sudoers_included() { [ ! -f /etc/sudoers ] || grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; }
install_sudo_package() {
    if command -v apt-get >/dev/null; then apt-get update && apt-get install -y sudo;
    elif command -v dnf >/dev/null; then dnf install -y sudo;
    elif command -v zypper >/dev/null; then zypper --non-interactive install sudo;
    elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm sudo;
    elif command -v yum >/dev/null; then yum install -y sudo;
    else return 1; fi
}
# Passwordless sudo for the runner account: a validated sudoers.d file in native mode, or a
# file that only the Docker mode container mounts (the host sudoers stays unchanged).
# Only files carrying this marker are ever replaced or removed.
JOB_SUDO_MARK='# github-runner: workflow jobs may use sudo without a password.'
job_sudo_path() { if [ "$1" = docker ]; then printf '/etc/github-runner/sudoers/%s' "$2"; else printf '/etc/sudoers.d/%s' "$2"; fi; }
remove_job_sudo() {
    for sudo_file in "$(job_sudo_path native "$1")" "$(job_sudo_path docker "$1")"; do
        if [ -f "$sudo_file" ] && [ "$(privileged head -n 1 "$sudo_file")" = "$JOB_SUDO_MARK" ]; then privileged rm -f "$sudo_file" "$sudo_file.shadow"; fi
    done
}
install_job_sudo() {
    sudo_file=$(job_sudo_path "$1" "$2")
    if [ -e "$sudo_file" ] && [ "$(privileged head -n 1 "$sudo_file")" != "$JOB_SUDO_MARK" ]; then
        echo "$sudo_file exists and was not written by this installer; leaving it unchanged." >&2; return 1
    fi
    printf '%s\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$JOB_SUDO_MARK" "$3" > "$definition"
    if [ "$1" = native ]; then privileged visudo -cqf "$definition" || { echo 'The generated sudoers rule did not validate; sudo was not granted.' >&2; return 1; }
    else privileged mkdir -p "${sudo_file%/*}"; fi
    privileged install -o root -g root -m 0440 "$definition" "$sudo_file"
    if [ "$1" = docker ]; then
        # PAM's account check needs a shadow entry; the container gets a locked one for the
        # account (and root) instead of the host's /etc/shadow.
        printf 'root:*:20000:0:99999:7:::\n%s:!:20000::::::\n' "$4" > "$definition"
        privileged install -o root -g root -m 0640 "$definition" "$sudo_file.shadow"
    fi
    # Switching between native and Docker mode leaves no rule for the other one behind.
    if [ "$1" = native ]; then other_sudo_file=$(job_sudo_path docker "$2"); else other_sudo_file=$(job_sudo_path native "$2"); fi
    if [ -f "$other_sudo_file" ] && [ "$(privileged head -n 1 "$other_sudo_file")" = "$JOB_SUDO_MARK" ]; then privileged rm -f "$other_sudo_file" "$other_sudo_file.shadow"; fi
}
# Connections to GitHub can drop mid-handshake (curl 35, "EOF"); retry before failing.
download() {
    download_attempt=1
    while ! curl -fsSL --connect-timeout 15 --max-time "${3:-600}" "$1" -o "$2"; do
        [ "$download_attempt" -lt 4 ] || { printf 'Download failed after 4 attempts: %s\nCheck the network to GitHub and run the same install command again; completed steps are kept.\n' "$1" >&2; return 1; }
        printf 'Download attempt %s failed; retrying in %ss: %s\n' "$download_attempt" "$((download_attempt * 5))" "$1" >&2
        sleep "$((download_attempt * 5))"
        download_attempt=$((download_attempt + 1))
    done
}
fetch() {
    if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then cp "$LOCAL_RUNNER_SOURCE_DIR/$1" "$2.new";
    else download "$base/$1" "$2.new" 120; fi
    mv -f "$2.new" "$2"
}
detect_architecture() {
    case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) echo 'Only x64/arm64 are supported.' >&2; return 1 ;; esac
}
is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] || uname -r | grep -qi microsoft
}
# WSL appends Windows directories under /mnt; services should not resolve Linux tools to Windows binaries.
linux_service_path() {
    is_wsl || { printf '%s\n' "$PATH"; return; }
    printf '%s\n' "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd: -
}
systemd_running() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
read_linux_release() { cat /etc/os-release 2>/dev/null; }
linux_release_field() {
    awk -F= -v key="$1" '$1==key {v=substr($0,index($0,"=")+1); gsub(/^["\047]|["\047]$/,"",v); print v; exit}'
}
check_linux_compatibility() {
    # Match GitHub's documented distro floors before sudo, packages, account
    # creation or stopping an existing installation. Unknown distros still have
    # to pass execution of the downloaded Listener and bundled Node.js binaries.
    release=$(read_linux_release || :)
    distribution=$(printf '%s\n' "$release" | linux_release_field ID)
    version=$(printf '%s\n' "$release" | linux_release_field VERSION_ID)
    description=$(printf '%s\n' "$release" | linux_release_field PRETTY_NAME)
    minimum=
    case "$distribution" in
        rhel|centos|ol|rocky|almalinux) minimum=8 ;;
        debian) minimum=10 ;;
        ubuntu) minimum=20.04 ;;
        linuxmint) minimum=20 ;;
        fedora) minimum=29 ;;
        opensuse-leap|sles) minimum=15.2 ;;
        alpine) echo 'Alpine/musl is unsupported; the official Linux Runner requires a compatible glibc system.' >&2; return 1 ;;
    esac
    [ -n "$minimum" ] || return 0
    # Rolling or nonnumeric vendor versions are checked by the actual binaries.
    printf '%s\n' "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || return 0
    if ! awk -v actual="$version" -v minimum="$minimum" 'BEGIN {
        a=split(actual,x,"."); b=split(minimum,y,"."); n=(a>b?a:b);
        for (i=1;i<=n;i++) {if (x[i]+0>y[i]+0) exit 0; if (x[i]+0<y[i]+0) exit 1} exit 0
    }'; then
        libc=$(getconf GNU_LIBC_VERSION 2>/dev/null || printf unknown)
        printf 'Linux %s (%s) cannot run the official Runner directly; %s %s or later is required.\n' "${description:-$distribution $version}" "$libc" "$distribution" "$minimum" >&2
        printf 'https://docs.github.com/en/actions/reference/runners/self-hosted-runners#linux\n' >&2
        return 3
    fi
}
install_static_jq() {
    case "$arch" in
        x64) jq_asset=jq-linux-amd64; jq_sum=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d ;;
        *) jq_asset=jq-linux-arm64; jq_sum=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4 ;;
    esac
    jq_bootstrap=$(mktemp -d)
    download "https://github.com/jqlang/jq/releases/download/jq-1.8.1/$jq_asset" "$jq_bootstrap/jq"
    [ "$(sha256_file "$jq_bootstrap/jq")" = "$jq_sum" ] || { echo 'jq SHA-256 mismatch.' >&2; rm -rf "$jq_bootstrap"; exit 1; }
    chmod 755 "$jq_bootstrap/jq"
    PATH=$jq_bootstrap:$PATH
}
# Docker mode: consent, then install, upgrade or start Docker before any other change.
prepare_docker_engine() {
    [ "$docker_engine_ready" = false ] || return 0
    docker_helper=$(mktemp -d)
    fetch linux/docker.sh "$docker_helper/docker.sh"
    /bin/bash "$docker_helper/docker.sh" engine || { rm -rf "$docker_helper"; exit 1; }
    rm -rf "$docker_helper"
    docker_engine_ready=true
}
# sudo drops the environment; pass the documented Docker mode overrides explicitly.
docker_privileged() {
    privileged env "LOCAL_RUNNER_REGION=${LOCAL_RUNNER_REGION:-}" "LOCAL_RUNNER_DOCKER_BASE=${LOCAL_RUNNER_DOCKER_BASE:-}" \
        "LOCAL_RUNNER_DOCKER_IMAGE=${LOCAL_RUNNER_DOCKER_IMAGE:-}" "LOCAL_RUNNER_UBUNTU_MIRROR=${LOCAL_RUNNER_UBUNTU_MIRROR:-}" "$@"
}
check_linux_host() {
    if is_wsl; then
        case "$(uname -r | tr '[:upper:]' '[:lower:]')" in
            *microsoft-standard*|*wsl2*) ;;
            *microsoft*) echo 'WSL1 is unsupported. Convert this distribution to WSL2 using wsl --set-version <distribution> 2 in Windows.' >&2; return 1 ;;
        esac
        if ! systemd_running; then
            cat >&2 <<'WSL'
WSL2 requires systemd before installing ghr. Update WSL in Windows with wsl --update.
Merge the following into /etc/wsl.conf, preserving its other settings:
[boot]
systemd=true
Then save your work, restart this distribution from Windows and retry installation.
No host settings have been changed by this installer.
WSL
            return 1
        fi
    elif ! systemd_running; then
        echo 'Linux must be booted with systemd before installing ghr.' >&2; return 1
    fi
}
stop_installed_service() {
    service_name=local-github-runner-${runtime_uid:-$(id -u)}-$arch.service
    [ -n "$(systemd_property "$service_name" FragmentPath)" ] || return 0
    [ "$(systemd_property "$service_name" WorkingDirectory)" = "$root" ] || { echo 'Another installation owns this service name.' >&2; exit 1; }
    privileged systemctl disable "$service_name"
    privileged systemctl stop "$service_name"
    installed_state=$(systemd_property "$service_name" ActiveState)
    case "$installed_state" in inactive|failed) ;; *) printf 'Service %s did not stop (state: %s).\n' "$service_name" "$installed_state" >&2; exit 1 ;; esac
}
initialize_install_settings() {
    [ ! -f "$root/conf/settings.json" ] || return 0
    mkdir -p "$root/conf"
    # Claim this fresh installation before downloads or login can fail. Keep the first
    # invocation's data directory when a retry is launched from a different directory.
    jq -n --arg platform "$platform" --arg arch "$arch" --arg work_dir "$(pwd -P)" --argjson owner_uid "${runtime_uid:-$(id -u)}" \
        '{platform:$platform,arch:$arch,owner_uid:$owner_uid,work_dir:$work_dir}' > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
}
install_main() {
    umask 077
    platform=linux
    [ "$(uname -s)" = Linux ] || { echo 'Incorrect platform installer' >&2; exit 1; }
    detect_architecture
    if [ "${1:-auto}" != auto ] && [ "$1" != "$arch" ]; then echo "Architecture mismatch: requested $1, host $arch" >&2; exit 1; fi
    check_linux_host
    runtime=native; compatibility=0
    check_linux_compatibility || compatibility=$?
    case "$compatibility" in 0) ;; 3) runtime=docker ;; *) exit 1 ;; esac
    case "${LOCAL_RUNNER_RUNTIME:-}" in
        docker) runtime=docker ;;
        native) [ "$runtime" = native ] || { echo 'This Linux cannot run the official Runner natively; LOCAL_RUNNER_RUNTIME=native is not possible here.' >&2; exit 1; } ;;
        '') ;;
        *) echo 'LOCAL_RUNNER_RUNTIME must be docker or native.' >&2; exit 1 ;;
    esac
    root_install=false
    if [ "$(id -u)" = 0 ]; then root_install=true; else sudo -v; fi
    check_job_permissions
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    docker_engine_ready=false
    if [ "$runtime" = docker ]; then
        if is_wsl; then echo 'Docker mode is not supported in WSL; use a WSL distribution supported by the official Runner.' >&2; exit 1; fi
        printf '\nDocker mode: the supervisor, the official Runner and all jobs run in an Ubuntu 22.04 container.\n'
        printf 'Jobs can use the host Docker daemon, which gives them root-equivalent control of this host.\n\n'
        prepare_docker_engine
    fi
    if ! command -v jq >/dev/null 2>&1; then
        if command -v apt-get >/dev/null; then privileged apt-get update; privileged apt-get install -y jq ca-certificates;
        elif command -v dnf >/dev/null; then privileged dnf install -y jq ca-certificates;
        elif command -v zypper >/dev/null; then privileged zypper --non-interactive install jq ca-certificates;
        elif command -v pacman >/dev/null; then privileged pacman -S --needed --noconfirm jq ca-certificates;
        elif command -v yum >/dev/null; then install_static_jq;
        else echo 'Install jq before running this installer.' >&2; exit 1; fi
    fi
    command -v flock >/dev/null || { echo 'Install util-linux (flock) first.' >&2; exit 1; }
    if $root_install; then
        if ! command -v setfacl >/dev/null; then
            if command -v apt-get >/dev/null; then apt-get update; apt-get install -y acl;
            elif command -v dnf >/dev/null; then dnf install -y acl;
            elif command -v zypper >/dev/null; then zypper --non-interactive install acl;
            elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm acl;
            elif command -v yum >/dev/null; then yum install -y acl;
            else echo 'Install acl (setfacl) before running this installer as root.' >&2; exit 1; fi
        fi
        command -v runuser >/dev/null && command -v useradd >/dev/null || { echo 'Install util-linux (runuser) and shadow/passwd (useradd) first.' >&2; exit 1; }
        account_helper=$(mktemp -d)
        fetch linux/account.sh "$account_helper/account.sh"
        . "$account_helper/account.sh"
        rm -f "$account_helper/account.sh"; rmdir "$account_helper"
        default_root=${LOCAL_RUNNER_HOME:-/opt/github-runner}/$platform
    else default_root=${LOCAL_RUNNER_HOME:-"$HOME/.local/share/github-runner"}/$platform; fi
    installed_command=$(command -v ghr || :)
    if [ -z "${LOCAL_RUNNER_HOME:-}" ] && [ -f "$installed_command" ]; then
        installed_root=$(sed -n 's/^# ghr: //p' "$installed_command")
        [ ! -f "$installed_root/conf/settings.json" ] || default_root=$installed_root
    fi
    root=$default_root
    if [ -z "${LOCAL_RUNNER_HOME:-}" ] && [ -t 0 ]; then
        printf '安装目录（维护bin和conf）[%s]: ' "$default_root"
        IFS= read -r selected_root || selected_root=
        root=${selected_root:-$default_root}
    fi
    case "$root" in *'
'*) echo 'Newlines are not supported in installation paths.' >&2; exit 1 ;; esac
    mkdir -p "$root"
    root=$(cd "$root" && pwd)
    if $root_install; then account_validate_path "$root"; fi
    if [ -f "$root/conf/settings.json" ]; then
        jq -e --arg platform "$platform" '.platform==$platform' "$root/conf/settings.json" >/dev/null || { echo 'Installation configuration belongs to a different platform.' >&2; exit 1; }
    else
        for part in bin conf; do [ ! -e "$root/$part" ] || { echo "Refusing to reuse unrelated directory $root/$part; choose another installation directory." >&2; exit 1; }; done
    fi
    # A reinstall keeps Docker mode unless LOCAL_RUNNER_RUNTIME=native switches back.
    if [ "${LOCAL_RUNNER_RUNTIME:-}" != native ] && [ -f "$root/conf/settings.json" ] && jq -e '.runtime=="docker"' "$root/conf/settings.json" >/dev/null 2>&1; then
        runtime=docker
        if is_wsl; then echo 'Docker mode is not supported in WSL.' >&2; exit 1; fi
        check_job_permissions
        prepare_docker_engine
    fi
    if $root_install; then
        ROOT=$root
        account_setup
        runtime_uid=$account_uid
    fi
    stop_installed_service
    initialize_install_settings
    # Re-running the installer usually repairs credentials or configuration, so every
    # organization is retried at once instead of after its backoff (up to an hour).
    for backoff_directory in "$root/conf/backoff" "$root/conf/runtime/backoff"; do
        [ -d "$backoff_directory" ] && [ ! -L "$backoff_directory" ] || continue
        rm -f "$backoff_directory"/*
    done
    if $root_install; then account_protect_config; fi
    mkdir -p "$root/bin/.cache" "$root/bin/tools" "$root/conf"
    jq_path=$(command -v jq)
    gh_path=$(command -v gh || :)
    if [ -z "$gh_path" ] && [ -x "$root/bin/tools/gh" ]; then gh_path=$root/bin/tools/gh; fi
    if [ -n "$gh_path" ]; then
        gh_major=$("$gh_path" --version | sed -n '1s/^gh version \([0-9]*\)\..*/\1/p')
        gh_minor=$("$gh_path" --version | sed -n '1s/^gh version [0-9]*\.\([0-9]*\).*/\1/p')
        if [ "${gh_major:-0}" -lt 2 ] || { [ "${gh_major:-0}" -eq 2 ] && [ "${gh_minor:-0}" -lt 62 ]; }; then gh_path=; fi
    fi
    if [ -z "$gh_path" ]; then
        download_cache=$root/bin/.cache
        if $root_install; then download_cache=$root/conf; fi
        temporary=$(mktemp -d "$download_cache/gh.XXXXXX")
        download https://api.github.com/repos/cli/cli/releases/latest "$temporary/release.json" 120
        version=$("$jq_path" -r '.tag_name|ltrimstr("v")' "$temporary/release.json")
        cli_arch=$arch; [ "$arch" != x64 ] || cli_arch=amd64
        filename=gh_${version}_linux_${cli_arch}.tar.gz
        url=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.browser_download_url' "$temporary/release.json")
        digest=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.digest' "$temporary/release.json")
        printf '%s' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' || { echo 'Missing gh asset digest.' >&2; exit 1; }
        download "$url" "$temporary/$filename"
        [ "$(sha256_file "$temporary/$filename")" = "${digest#sha256:}" ] || { echo 'gh SHA-256 mismatch.' >&2; exit 1; }
        mkdir "$temporary/unpacked"
        tar -xzf "$temporary/$filename" -C "$temporary/unpacked"
        downloaded_gh=$(find "$temporary/unpacked" -type f -name gh -print | head -n 1)
        cp "$downloaded_gh" "$root/bin/tools/gh"; chmod 700 "$root/bin/tools/gh"
        gh_path=$root/bin/tools/gh
        rm -rf "$temporary"
    fi
    # Docker mode runs the same gh inside the container; the official build is static.
    if { $root_install || [ "$runtime" = docker ]; } && [ "$gh_path" != "$root/bin/tools/gh" ]; then
        cp "$gh_path" "$root/bin/tools/gh"
        gh_path=$root/bin/tools/gh
    fi
    if [ -n "${jq_bootstrap:-}" ]; then
        cp "$jq_bootstrap/jq" "$root/bin/tools/jq"; chmod 700 "$root/bin/tools/jq"
        jq_path=$root/bin/tools/jq
    fi
    "$gh_path" auth status --hostname github.com >/dev/null 2>&1 || "$gh_path" auth login --hostname github.com --web --scopes admin:org,repo
    # An existing gh login may predate this installer and lack admin:org, which runner
    # registration requires. Ask gh to add it before the token is saved for the service.
    if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && ! token_has_admin_org "$("$gh_path" auth token --hostname github.com)"; then
        printf 'The current GitHub login lacks the admin:org scope required to register organization runners.\nAuthorize the additional scope:\n'
        "$gh_path" auth refresh --hostname github.com --scopes admin:org,repo
    fi
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s\n' "$GH_TOKEN" > "$root/conf/github-token";
    elif [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s\n' "$GITHUB_TOKEN" > "$root/conf/github-token";
    else "$gh_path" auth token --hostname github.com > "$root/conf/github-token"; fi
    token_has_admin_org "$(cat "$root/conf/github-token")" || {
        echo 'The GitHub token lacks the admin:org scope required to register organization runners. Use a token with admin:org and run the installer again.' >&2; exit 1;
    }
    chmod 600 "$root/conf/github-token"
    # Keeping the machine awake (also with the lid closed) while the supervisor runs is on by
    # default; LOCAL_RUNNER_PREVENT_SLEEP=no turns it off, and a re-run keeps the choice.
    case "${LOCAL_RUNNER_PREVENT_SLEEP:-}" in
        yes|true|1) prevent_sleep=true ;; no|false|0) prevent_sleep=false ;;
        '') prevent_sleep=$("$jq_path" -r 'if .prevent_sleep == false then "false" else "true" end' "$root/conf/settings.json" 2>/dev/null || echo true) ;;
        *) echo 'LOCAL_RUNNER_PREVENT_SLEEP must be yes or no.' >&2; exit 1 ;;
    esac
    # Native jobs may use the host Docker daemon by default.
    docker_access=${requested_docker_access:-$("$jq_path" -r 'if .docker_access == false then "false" else "true" end' "$root/conf/settings.json" 2>/dev/null || echo true)}
    [ "$runtime" != docker ] || docker_access=true
    # Passwordless sudo for jobs is on by default, as on GitHub-hosted runners, wherever it
    # cannot reach a login account: root installations and Docker mode. Only an explicit
    # LOCAL_RUNNER_SUDO is remembered, so a default never sticks as a choice.
    sudo_choice=${requested_sudo:-$("$jq_path" -r 'if has("job_sudo_choice") then (.job_sudo_choice|tostring) else empty end' "$root/conf/settings.json" 2>/dev/null || :)}
    if [ -n "$sudo_choice" ]; then job_sudo=$sudo_choice
    elif [ "$runtime" = docker ] || $root_install; then job_sudo=true
    else job_sudo=false; fi
    if [ "$runtime" = native ] && [ "$job_sudo" = true ]; then
        # A remembered choice is checked again; a normal-user installation never allows it.
        $root_install || { echo 'Passwordless sudo for jobs needs a root installation; run with LOCAL_RUNNER_SUDO=no or as root.' >&2; exit 1; }
        command -v visudo >/dev/null 2>&1 || install_sudo_package || :
        if ! command -v visudo >/dev/null 2>&1 || ! sudoers_included; then
            [ -z "$sudo_choice" ] || { echo 'LOCAL_RUNNER_SUDO=yes cannot grant sudo: install sudo and include /etc/sudoers.d, then run the installer again.' >&2; exit 1; }
            printf 'Job sudo: off; sudo is unavailable or /etc/sudoers does not include /etc/sudoers.d.\n' >&2
            job_sudo=false
        fi
    fi
    printf '%s\n' "$gh_path" > "$root/conf/gh-path"
    printf '%s\n' "$jq_path" > "$root/conf/jq-path"
    default_work=$(pwd -P)
    [ ! -f "$root/conf/settings.json" ] || default_work=$root
    [ -f "$root/conf/settings.json" ] || printf '{}\n' > "$root/conf/settings.json"
    "$jq_path" --arg platform "$platform" --arg arch "$arch" --argjson owner_uid "${runtime_uid:-$(id -u)}" --arg default_work "$default_work" --arg runtime "$runtime" --argjson prevent_sleep "$prevent_sleep" \
        --argjson docker_access "$docker_access" --argjson job_sudo "$job_sudo" --arg sudo_choice "${requested_sudo:-}" \
        '.platform=$platform|.arch=$arch|.owner_uid=$owner_uid|.runtime=$runtime|.prevent_sleep=$prevent_sleep|.docker_access=$docker_access|.job_sudo=$job_sudo|(if $sudo_choice == "" then . else .job_sudo_choice=($sudo_choice == "true") end)|.work_dir //= $default_work|.poll_seconds //= 300|.restart_seconds //= 30|.organizations //= []' \
        "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    if $root_install; then fetch linux/account.sh "$root/bin/account.sh"; fi
    fetch "$platform/install.sh" "$root/bin/install.sh"
    fetch "$platform/service.sh" "$root/bin/service.sh"
    fetch "$platform/ghr.sh" "$root/bin/ghr.sh"
    fetch "$platform/runner.sh" "$root/bin/runner.sh"
    fetch 'linux/wsl.sh' "$root/bin/wsl.sh"
    fetch 'linux/wsl.ps1' "$root/bin/wsl.ps1"
    # The Windows side of sleep prevention for WSL hosts, shared with native Windows.
    fetch 'windows/awake.ps1' "$root/bin/awake.ps1"
    fetch linux/docker.sh "$root/bin/docker.sh"
    fetch linux/Dockerfile "$root/bin/Dockerfile"
    chmod 700 "$root/bin/install.sh" "$root/bin/service.sh" "$root/bin/ghr.sh" "$root/bin/runner.sh" "$root/bin/docker.sh"
    if [ "$runtime" = docker ]; then
        printf 'Building the Docker mode image.\n'
        docker_image=$(docker_privileged /bin/bash "$root/bin/docker.sh" build) || { echo 'Docker image build failed; the existing service was left stopped. Fix the error and retry.' >&2; exit 1; }
        "$jq_path" --arg image "$docker_image" '.docker_image=$image' "$root/conf/settings.json" > "$root/conf/settings.new"
        mv "$root/conf/settings.new" "$root/conf/settings.json"
    fi
    # Native mode joins the Docker socket's group, as Docker mode does, unless turned off.
    docker_access_group=
    if [ "$runtime" = native ] && [ "$docker_access" = true ]; then
        docker_socket=${LOCAL_RUNNER_DOCKER_SOCKET:-/var/run/docker.sock}
        if [ -S "$docker_socket" ]; then
            docker_access_group=$(stat -c %G "$docker_socket" 2>/dev/null || :)
            case "$docker_access_group" in
                ''|root|UNKNOWN)
                    printf 'Docker access: %s belongs to group %s, so jobs cannot use Docker. Give the socket a dedicated group (usually docker) and run the installer again.\n' "$docker_socket" "${docker_access_group:-unknown}" >&2
                    docker_access_group= ;;
                *) printf 'Docker access: on (group %s); jobs can control the host Docker daemon, which is equivalent to root on this host.\n' "$docker_access_group" ;;
            esac
        elif command -v docker >/dev/null 2>&1; then
            printf 'Docker access: Docker is installed but %s is missing; start Docker and run the installer again so jobs can use it.\n' "$docker_socket" >&2
        fi
    fi
    "$jq_path" --arg group "$docker_access_group" 'if $group == "" then del(.docker_group) else .docker_group=$group end' "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    # The sudo rule exists before the runtime check and the service start: Docker mode mounts it.
    if $root_install; then sudo_user=$account_user; sudo_uid=$account_uid; else sudo_user=$(id -un); sudo_uid=$(id -u); fi
    sudo_name=local-github-runner-$sudo_uid-$arch
    definition=$(mktemp)
    if [ "$job_sudo" = true ]; then
        sudo_principal=$sudo_user; [ "$runtime" != docker ] || sudo_principal="#$sudo_uid"
        install_job_sudo "$runtime" "$sudo_name" "$sudo_principal" "$sudo_user" || { echo 'Passwordless sudo was not granted; run the installer again after fixing the error above.' >&2; rm -f "$definition"; exit 1; }
        if [ "$runtime" = docker ]; then printf 'Job sudo: on; jobs can use sudo without a password inside the container.\n'
        else printf 'Job sudo: on; jobs can use sudo without a password, which is root on this host.\n'; fi
    else
        remove_job_sudo "$sudo_name"
        [ "$runtime" = docker ] || $root_install || printf 'Job sudo: off; jobs run as your own login account here. Install as root for passwordless sudo.\n'
    fi
    rm -f "$definition"
    if $root_install; then
        chgrp "$account_gid" "$root/bin/"*.sh "$root/bin/"*.ps1 "$root/bin/tools" "$root/bin/tools/"*
        chmod 755 "$root/bin/"*.sh "$root/bin/tools" "$root/bin/tools/"*
        chmod 644 "$root/bin/"*.ps1
        account_protect_config
        work_dir=$("$jq_path" -r .work_dir "$root/conf/settings.json")
        account_work_directory "$work_dir"
        account_prepare_package "$runtime" || { echo 'Preparing the official Runner failed (see the error above). Run the same install command again to retry.' >&2; exit 1; }
        if [ "$runtime" = docker ]; then
            LOCAL_RUNNER_DOCKER_USER=$account_uid:$account_gid LOCAL_RUNNER_DOCKER_HOME=$account_home /bin/bash "$root/bin/docker.sh" verify
        else account_run env -i HOME="$account_home" PATH=/usr/local/bin:/usr/bin:/bin /bin/bash "$root/bin/service.sh" verify; fi
    else
        /bin/bash "$root/bin/service.sh" prepare || { echo 'Preparing the official Runner failed (see the error above). Run the same install command again to retry.' >&2; exit 1; }
        if [ "$runtime" = docker ]; then
            privileged env LOCAL_RUNNER_DOCKER_USER="$(id -u):$(id -g)" LOCAL_RUNNER_DOCKER_HOME="$HOME" /bin/bash "$root/bin/docker.sh" verify
        else
            privileged /bin/bash "$root/bin/.cache/package/bin/installdependencies.sh"
            env -i HOME="$HOME" PATH="$(linux_service_path)" /bin/bash "$root/bin/service.sh" verify
        fi
    fi
    /bin/bash "$root/bin/ghr.sh" --install-command
    work_dir=$("$jq_path" -r .work_dir "$root/conf/settings.json")
    mkdir -p "$work_dir/jobs" "$work_dir/runners" "$work_dir/logs"
    printf 'Work directory (jobs, runners, logs): %s\n' "$work_dir"
    user=$(id -un); user_id=$(id -u); service_home=$HOME; service_path=$(linux_service_path)
    if $root_install; then
        user=$account_user; user_id=$account_uid; service_home=$account_home
        service_path=/usr/local/bin:/usr/bin:/bin
        printf 'Runner account: %s (UID %s); workflows do not run as root.\n' "$user" "$user_id"
    fi
    definition=$(mktemp)
    [ -d /run/systemd/system ] || { echo 'Linux must be booted with systemd.' >&2; rm -f "$definition"; exit 1; }
    service_name=local-github-runner-$user_id-$arch.service
    docker_group=
    if [ "$runtime" = docker ]; then
        docker_group=$(stat -c %G /var/run/docker.sock)
        [ -n "$docker_group" ] && [ "$docker_group" != root ] && [ "$docker_group" != UNKNOWN ] || { echo 'The Docker socket has no dedicated group; cannot grant the runner account access.' >&2; rm -f "$definition"; exit 1; }
    fi
    systemd_unit "$user" "$service_home" "$service_path" "$root" "$docker_group" "$docker_access_group" > "$definition"
    privileged install -m 644 "$definition" "/etc/systemd/system/$service_name"
    privileged systemctl daemon-reload
    if [ -f "$root/conf/stopped" ]; then privileged systemctl disable "$service_name";
    else
        privileged systemctl enable "$service_name"
        privileged systemctl restart "$service_name"
        privileged systemctl is-active --quiet "$service_name"
    fi
    # WSL is kept awake by its Windows host task instead (ghr wsl setup).
    awake_name=${service_name%.service}-awake.service
    inhibit_path=$(command -v systemd-inhibit || :); sleep_path=$(command -v sleep || :)
    if [ "$prevent_sleep" = true ] && ! is_wsl && [ -n "$inhibit_path" ] && [ -n "$sleep_path" ] && [ -S /run/dbus/system_bus_socket ]; then
        awake_unit "$service_name" "$inhibit_path" "$sleep_path" > "$definition"
        privileged install -m 644 "$definition" "/etc/systemd/system/$awake_name"
        privileged systemctl daemon-reload
        privileged systemctl enable "$awake_name"
        [ -f "$root/conf/stopped" ] || privileged systemctl restart "$awake_name"
        printf 'Sleep prevention: on; this machine stays awake, also with the lid closed, while the runner service runs.\n'
    elif [ -f "/etc/systemd/system/$awake_name" ]; then
        privileged systemctl disable "$awake_name" || :; privileged systemctl stop "$awake_name" || :
        privileged rm -f "/etc/systemd/system/$awake_name"
        privileged systemctl daemon-reload
    fi
    rm -f "$definition"
    [ -z "${jq_bootstrap:-}" ] || rm -rf "$jq_bootstrap"
    printf '\nInstalled %s\n\n' "$service_name"
    /bin/bash "$root/bin/ghr.sh" help
    case ":$PATH:" in *:/usr/local/bin:*) ;; *) printf '\nAdd /usr/local/bin to PATH: export PATH="/usr/local/bin:$PATH"\n' ;; esac
    if is_wsl; then
        printf '\nWSL: configuring Windows boot startup through Windows interoperability.\n'
        printf 'Accept the local Windows elevation prompt and enter your Windows account password (not a PIN).\n'
        /bin/bash "$root/bin/wsl.sh" setup || { printf 'Linux runner installed, but Windows boot startup is incomplete. Run ghr wsl setup to retry.\n' >&2; return 1; }
    fi
}
if [ -t 0 ]; then install_main "$@";
elif ( : < /dev/tty ) 2>/dev/null; then install_main "$@" < /dev/tty;
else install_main "$@" < /dev/null; fi
