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
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
xml() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
unit_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'; }
# systemd unquotes Environment= and ExecStart=, but rejects a quoted WorkingDirectory=.
# A fifth argument (the Docker socket group) selects Docker mode: the unit then only
# starts and stops the supervisor's container, as the same account.
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
launchd_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml "$1")</string>
<key>UserName</key><string>$(xml "$2")</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$(xml "$5/bin/service.sh")</string></array>
<key>WorkingDirectory</key><string>$(xml "$5")</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>AbandonProcessGroup</key><false/>
<key>ThrottleInterval</key><integer>10</integer><key>ExitTimeOut</key><integer>90</integer>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$(xml "$3")</string><key>PATH</key><string>$(xml "$4")</string></dict>
<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST
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
    if [ "$platform" = macos ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || :)" = 1 ]; then arch=arm64; fi
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
    user_id=${runtime_uid:-$(id -u)}
    if [ "$platform" = linux ]; then
        service_name=local-github-runner-$user_id-$arch.service
        definition_path=$(systemd_property "$service_name" FragmentPath)
        if [ -n "$definition_path" ]; then
            installed_root=$(systemd_property "$service_name" WorkingDirectory)
            case "$installed_root" in "$root"|"$root/$arch") ;; *) echo 'Another installation owns this service name.' >&2; exit 1 ;; esac
            privileged systemctl disable "$service_name"
            privileged systemctl stop "$service_name"
            installed_state=$(systemd_property "$service_name" ActiveState)
            case "$installed_state" in inactive|failed) ;; *) printf 'Service %s did not stop (state: %s).\n' "$service_name" "$installed_state" >&2; exit 1 ;; esac
        fi
    else
        service_name=com.suminwell.github-runner.$user_id.$arch
        definition_path=/Library/LaunchDaemons/$service_name.plist
        if [ -f "$definition_path" ]; then
            command_path=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$definition_path")
            case "$command_path" in "$root/bin/service.sh"|"$root/service.sh"|"$root/$arch/bin/service.sh") ;; *) echo 'Another installation owns this service name.' >&2; exit 1 ;; esac
            privileged launchctl bootout "system/$service_name" 2>/dev/null || :
            privileged launchctl disable "system/$service_name"
        fi
    fi
}
migrate_layout() {
    legacy=$root/$arch
    if [ -f "$legacy/.state/settings.json" ] || [ -f "$legacy/conf/settings.json" ]; then
        for part in bin data logs conf; do [ ! -e "$root/$part" ] || { echo "Both layouts exist at $root; resolve them before upgrading." >&2; exit 1; }; done
        for part in bin data logs; do [ ! -d "$legacy/$part" ] || mv "$legacy/$part" "$root/$part"; done
        if [ -d "$legacy/.state" ]; then mv "$legacy/.state" "$root/conf"; else mv "$legacy/conf" "$root/conf"; fi
        rmdir "$legacy" 2>/dev/null || :
    fi
    if [ -d "$root/.state" ]; then
        [ ! -e "$root/conf" ] || { echo 'Both .state and conf exist; resolve them before upgrading.' >&2; exit 1; }
        mv "$root/.state" "$root/conf"
    fi
    if [ -d "$root/conf/package" ]; then mkdir -p "$root/bin/.cache"; [ ! -e "$root/bin/.cache/package" ] || { echo 'Both package caches exist.' >&2; exit 1; }; mv "$root/conf/package" "$root/bin/.cache/package"; fi
    if [ -d "$root/conf/tools" ]; then mkdir -p "$root/bin"; [ ! -e "$root/bin/tools" ] || { echo 'Both tool directories exist.' >&2; exit 1; }; mv "$root/conf/tools" "$root/bin/tools"; fi
    for organization in "$root"/bin/*; do
        [ -f "$organization/runner/.runner" ] || continue
        login=${organization##*/}
        destination=$root/runner/$login
        [ ! -e "$destination" ] || { echo 'Both organization runner layouts exist.' >&2; exit 1; }
        mkdir -p "$destination"
        mv "$organization/runner" "$destination/app"
        rm -f "$organization/runner.sh"
        rmdir "$organization" 2>/dev/null || :
    done
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
    case "$platform:$(uname -s)" in linux:Linux|macos:Darwin) ;; *) echo 'Incorrect platform installer' >&2; exit 1 ;; esac
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
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    docker_engine_ready=false
    if [ "$runtime" = docker ]; then
        if is_wsl; then echo 'Docker mode is not supported in WSL; use a WSL distribution supported by the official Runner.' >&2; exit 1; fi
        printf '\nDocker mode: the supervisor, the official Runner and all jobs run in an Ubuntu 22.04 container.\n'
        printf 'Jobs can use the host Docker daemon, which gives them root-equivalent control of this host.\n\n'
        prepare_docker_engine
    fi
    if ! command -v jq >/dev/null 2>&1; then
        if [ "$platform" = macos ]; then
            if ! command -v brew >/dev/null 2>&1; then
                setup=$(mktemp)
                curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$setup"
                /bin/bash "$setup"; rm -f "$setup"
                if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
            fi
            brew install jq
        elif command -v apt-get >/dev/null; then privileged apt-get update; privileged apt-get install -y jq ca-certificates;
        elif command -v dnf >/dev/null; then privileged dnf install -y jq ca-certificates;
        elif command -v zypper >/dev/null; then privileged zypper --non-interactive install jq ca-certificates;
        elif command -v pacman >/dev/null; then privileged pacman -S --needed --noconfirm jq ca-certificates;
        elif command -v yum >/dev/null; then install_static_jq;
        else echo 'Install jq before running this installer.' >&2; exit 1; fi
    fi
    if [ "$platform" = linux ]; then command -v flock >/dev/null || { echo 'Install util-linux (flock) first.' >&2; exit 1; }; fi
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
    previous_root=$HOME/.local/share/github-runner/$platform
    if [ -z "${LOCAL_RUNNER_HOME:-}" ] && { [ -d "$previous_root/.state" ] || [ -d "$previous_root/$arch/.state" ]; }; then default_root=$previous_root; fi
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
    known_installation=false
    for settings_file in "$root/conf/settings.json" "$root/.state/settings.json" "$root/$arch/.state/settings.json" "$root/$arch/conf/settings.json"; do
        if [ -f "$settings_file" ]; then
            jq -e --arg platform "$platform" '.platform==$platform' "$settings_file" >/dev/null || { echo 'Installation configuration belongs to a different platform.' >&2; exit 1; }
            known_installation=true
        fi
    done
    # A reinstall keeps Docker mode unless LOCAL_RUNNER_RUNTIME=native switches back.
    if [ "${LOCAL_RUNNER_RUNTIME:-}" != native ] && [ -f "$root/conf/settings.json" ] && jq -e '.runtime=="docker"' "$root/conf/settings.json" >/dev/null 2>&1; then
        runtime=docker
        if is_wsl; then echo 'Docker mode is not supported in WSL.' >&2; exit 1; fi
        prepare_docker_engine
    fi
    if [ "$known_installation" = false ]; then
        for part in bin conf runner; do [ ! -e "$root/$part" ] || { echo "Refusing to reuse unrelated directory $root/$part; choose another installation directory." >&2; exit 1; }; done
    fi
    other_arch=x64; [ "$arch" != x64 ] || other_arch=arm64
    { [ ! -f "$root/$other_arch/.state/settings.json" ] && [ ! -f "$root/$other_arch/conf/settings.json" ]; } || { echo 'An installation for another architecture exists; stop it and move it aside before upgrading.' >&2; exit 1; }
    if [ -f "$root/$arch/.state/settings.json" ] || [ -f "$root/$arch/conf/settings.json" ]; then
        for part in bin data logs .state; do
            [ ! -e "$root/$part" ] || { echo "Both layouts exist at $root; resolve them before upgrading." >&2; exit 1; }
        done
    fi
    if $root_install; then
        ROOT=$root
        account_setup
        runtime_uid=$account_uid
    fi
    stop_installed_service
    migrate_layout
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
        cli_os=linux; extension=tar.gz
        if [ "$platform" = macos ]; then cli_os=macOS; extension=zip; fi
        filename=gh_${version}_${cli_os}_${cli_arch}.${extension}
        url=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.browser_download_url' "$temporary/release.json")
        digest=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.digest' "$temporary/release.json")
        printf '%s' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' || { echo 'Missing gh asset digest.' >&2; exit 1; }
        download "$url" "$temporary/$filename"
        [ "$(sha256_file "$temporary/$filename")" = "${digest#sha256:}" ] || { echo 'gh SHA-256 mismatch.' >&2; exit 1; }
        mkdir "$temporary/unpacked"
        if [ "$extension" = zip ]; then unzip -q "$temporary/$filename" -d "$temporary/unpacked";
        else tar -xzf "$temporary/$filename" -C "$temporary/unpacked"; fi
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
    printf '%s\n' "$gh_path" > "$root/conf/gh-path"
    printf '%s\n' "$jq_path" > "$root/conf/jq-path"
    default_work=$(pwd -P)
    [ ! -f "$root/conf/settings.json" ] || default_work=$root
    [ -f "$root/conf/settings.json" ] || printf '{}\n' > "$root/conf/settings.json"
    "$jq_path" --arg platform "$platform" --arg arch "$arch" --arg gh "$gh_path" --argjson owner_uid "${runtime_uid:-$(id -u)}" --arg default_work "$default_work" --arg runtime "$runtime" \
        '.platform=$platform|.arch=$arch|.gh=$gh|.owner_uid=$owner_uid|.runtime=$runtime|.work_dir //= $default_work|del(.python)|.poll_seconds //= 300|.restart_seconds //= 30|.organizations //= []' \
        "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    if $root_install; then fetch linux/account.sh "$root/bin/account.sh"; fi
    fetch "$platform/install.sh" "$root/bin/install.sh"
    fetch "$platform/service.sh" "$root/bin/service.sh"
    fetch "$platform/ghr.sh" "$root/bin/ghr.sh"
    fetch "$platform/runner.sh" "$root/bin/runner.sh"
    fetch 'linux/wsl.sh' "$root/bin/wsl.sh"
    fetch 'linux/wsl.ps1' "$root/bin/wsl.ps1"
    fetch linux/docker.sh "$root/bin/docker.sh"
    fetch linux/Dockerfile "$root/bin/Dockerfile"
    chmod 700 "$root/bin/install.sh" "$root/bin/service.sh" "$root/bin/ghr.sh" "$root/bin/runner.sh" "$root/bin/docker.sh"
    if [ "$runtime" = docker ]; then
        printf 'Building the Docker mode image.\n'
        docker_image=$(docker_privileged /bin/bash "$root/bin/docker.sh" build) || { echo 'Docker image build failed; the existing service was left stopped. Fix the error and retry.' >&2; exit 1; }
        "$jq_path" --arg image "$docker_image" '.docker_image=$image' "$root/conf/settings.json" > "$root/conf/settings.new"
        mv "$root/conf/settings.new" "$root/conf/settings.json"
    fi
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
    mkdir -p "$work_dir/data" "$work_dir/logs"
    printf 'Data/logs directory: %s\n' "$work_dir"
    user=$(id -un); user_id=$(id -u); service_home=$HOME; service_path=$(linux_service_path)
    if $root_install; then
        user=$account_user; user_id=$account_uid; service_home=$account_home
        service_path=/usr/local/bin:/usr/bin:/bin
        printf 'Runner account: %s (UID %s); workflows do not run as root.\n' "$user" "$user_id"
    fi
    definition=$(mktemp)
    if [ "$platform" = linux ]; then
        [ -d /run/systemd/system ] || { echo 'Linux must be booted with systemd.' >&2; rm -f "$definition"; exit 1; }
        service_name=local-github-runner-$user_id-$arch.service
        docker_group=
        if [ "$runtime" = docker ]; then
            docker_group=$(stat -c %G /var/run/docker.sock)
            [ -n "$docker_group" ] && [ "$docker_group" != root ] && [ "$docker_group" != UNKNOWN ] || { echo 'The Docker socket has no dedicated group; cannot grant the runner account access.' >&2; rm -f "$definition"; exit 1; }
        fi
        systemd_unit "$user" "$service_home" "$service_path" "$root" "$docker_group" > "$definition"
        privileged install -m 644 "$definition" "/etc/systemd/system/$service_name"
        privileged systemctl daemon-reload
        if [ -f "$root/conf/stopped" ]; then privileged systemctl disable "$service_name";
        else
            privileged systemctl enable "$service_name"
            privileged systemctl restart "$service_name"
            privileged systemctl is-active --quiet "$service_name"
        fi
    else
        service_name=com.suminwell.github-runner.$user_id.$arch
        launchd_plist "$service_name" "$user" "$HOME" "$PATH" "$root" > "$definition"
        privileged launchctl bootout "system/$service_name" 2>/dev/null || :
        privileged install -o root -g wheel -m 644 "$definition" "/Library/LaunchDaemons/$service_name.plist"
        if [ -f "$root/conf/stopped" ]; then privileged launchctl disable "system/$service_name";
        else
            privileged launchctl enable "system/$service_name"
            privileged launchctl bootstrap system "/Library/LaunchDaemons/$service_name.plist"
            privileged launchctl print "system/$service_name" >/dev/null
        fi
    fi
    rm -f "$definition" "$root/install.sh" "$root/service.sh" "$root/ghr.sh"
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
