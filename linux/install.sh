#!/bin/sh
# Complete POSIX entry point; safe for curl ... | sh.
set -eu
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
xml() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
unit_quote() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'; }
fetch() {
    if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then cp "$LOCAL_RUNNER_SOURCE_DIR/$1" "$2.new";
    else curl -fsSL --connect-timeout 15 --max-time 120 "$base/$1" -o "$2.new"; fi
    mv -f "$2.new" "$2"
}
detect_architecture() {
    case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) echo 'Only x64/arm64 are supported.' >&2; return 1 ;; esac
    if [ "$platform" = macos ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || :)" = 1 ]; then arch=arm64; fi
}
stop_installed_service() {
    user_id=$(id -u)
    if [ "$platform" = linux ]; then
        service_name=local-github-runner-$user_id-$arch.service
        definition_path=$(sudo systemctl show "$service_name" -p FragmentPath --value 2>/dev/null || :)
        if [ -n "$definition_path" ]; then
            installed_root=$(sudo systemctl show "$service_name" -p WorkingDirectory --value)
            case "$installed_root" in "$root"|"$root/$arch") ;; *) echo 'Another installation owns this service name.' >&2; exit 1 ;; esac
            sudo systemctl disable --now "$service_name"
        fi
    else
        service_name=com.suminwell.github-runner.$user_id.$arch
        definition_path=/Library/LaunchDaemons/$service_name.plist
        if [ -f "$definition_path" ]; then
            command_path=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$definition_path")
            case "$command_path" in "$root/bin/service.sh"|"$root/service.sh"|"$root/$arch/bin/service.sh") ;; *) echo 'Another installation owns this service name.' >&2; exit 1 ;; esac
            sudo launchctl bootout "system/$service_name" 2>/dev/null || :
            sudo launchctl disable "system/$service_name"
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
install_main() {
    umask 077
    platform=linux
    case "$platform:$(uname -s)" in linux:Linux|macos:Darwin) ;; *) echo 'Incorrect platform installer' >&2; exit 1 ;; esac
    detect_architecture
    if [ "${1:-auto}" != auto ] && [ "$1" != "$arch" ]; then echo "Architecture mismatch: requested $1, host $arch" >&2; exit 1; fi
    [ "$(id -u)" -ne 0 ] || { echo 'Use a normal user; sudo is used for system setup.' >&2; exit 1; }
    sudo -v
    if ! command -v jq >/dev/null 2>&1; then
        if [ "$platform" = macos ]; then
            if ! command -v brew >/dev/null 2>&1; then
                setup=$(mktemp)
                curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$setup"
                /bin/bash "$setup"; rm -f "$setup"
                if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
            fi
            brew install jq
        elif command -v apt-get >/dev/null; then sudo apt-get update; sudo apt-get install -y jq ca-certificates;
        elif command -v dnf >/dev/null; then sudo dnf install -y jq ca-certificates;
        elif command -v zypper >/dev/null; then sudo zypper --non-interactive install jq ca-certificates;
        elif command -v pacman >/dev/null; then sudo pacman -S --needed --noconfirm jq ca-certificates;
        else echo 'Install jq before running this installer.' >&2; exit 1; fi
    fi
    if [ "$platform" = linux ]; then command -v flock >/dev/null || { echo 'Install util-linux (flock) first.' >&2; exit 1; }; fi
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    default_root=${LOCAL_RUNNER_HOME:-"$HOME/.local/share/github-runner"}/$platform
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
    known_installation=false
    for settings_file in "$root/conf/settings.json" "$root/.state/settings.json" "$root/$arch/.state/settings.json"; do
        if [ -f "$settings_file" ]; then
            jq -e --arg platform "$platform" '.platform==$platform' "$settings_file" >/dev/null || { echo 'Installation configuration belongs to a different platform.' >&2; exit 1; }
            known_installation=true
        fi
    done
    if [ "$known_installation" = false ]; then
        for part in bin conf runner; do [ ! -e "$root/$part" ] || { echo "Refusing to reuse unrelated directory $root/$part; choose another installation directory." >&2; exit 1; }; done
    fi
    other_arch=x64; [ "$arch" != x64 ] || other_arch=arm64
    [ ! -f "$root/$other_arch/.state/settings.json" ] || { echo 'An installation for another architecture exists; stop it and move it aside before upgrading.' >&2; exit 1; }
    if [ -f "$root/$arch/.state/settings.json" ]; then
        for part in bin data logs .state; do
            [ ! -e "$root/$part" ] || { echo "Both layouts exist at $root; resolve them before upgrading." >&2; exit 1; }
        done
    fi
    stop_installed_service
    migrate_layout
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
        temporary=$(mktemp -d "$root/bin/.cache/gh.XXXXXX")
        curl -fsSL --max-time 120 https://api.github.com/repos/cli/cli/releases/latest -o "$temporary/release.json"
        version=$("$jq_path" -r '.tag_name|ltrimstr("v")' "$temporary/release.json")
        cli_arch=$arch; [ "$arch" != x64 ] || cli_arch=amd64
        cli_os=linux; extension=tar.gz
        if [ "$platform" = macos ]; then cli_os=macOS; extension=zip; fi
        filename=gh_${version}_${cli_os}_${cli_arch}.${extension}
        url=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.browser_download_url' "$temporary/release.json")
        digest=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.digest' "$temporary/release.json")
        printf '%s' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' || { echo 'Missing gh asset digest.' >&2; exit 1; }
        curl -fsSL --max-time 600 "$url" -o "$temporary/$filename"
        [ "$(sha256_file "$temporary/$filename")" = "${digest#sha256:}" ] || { echo 'gh SHA-256 mismatch.' >&2; exit 1; }
        mkdir "$temporary/unpacked"
        if [ "$extension" = zip ]; then unzip -q "$temporary/$filename" -d "$temporary/unpacked";
        else tar -xzf "$temporary/$filename" -C "$temporary/unpacked"; fi
        downloaded_gh=$(find "$temporary/unpacked" -type f -name gh -print | head -n 1)
        cp "$downloaded_gh" "$root/bin/tools/gh"; chmod 700 "$root/bin/tools/gh"
        gh_path=$root/bin/tools/gh
        rm -rf "$temporary"
    fi
    "$gh_path" auth status --hostname github.com >/dev/null 2>&1 || "$gh_path" auth login --hostname github.com --web --scopes admin:org,repo
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s\n' "$GH_TOKEN" > "$root/conf/github-token";
    elif [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s\n' "$GITHUB_TOKEN" > "$root/conf/github-token";
    else "$gh_path" auth token --hostname github.com > "$root/conf/github-token"; fi
    chmod 600 "$root/conf/github-token"
    printf '%s\n' "$gh_path" > "$root/conf/gh-path"
    printf '%s\n' "$jq_path" > "$root/conf/jq-path"
    default_work=$(pwd -P)
    [ ! -f "$root/conf/settings.json" ] || default_work=$root
    [ -f "$root/conf/settings.json" ] || printf '{}\n' > "$root/conf/settings.json"
    "$jq_path" --arg platform "$platform" --arg arch "$arch" --arg gh "$gh_path" --argjson owner_uid "$(id -u)" --arg default_work "$default_work" \
        '.platform=$platform|.arch=$arch|.gh=$gh|.owner_uid=$owner_uid|.work_dir //= $default_work|del(.python)|.poll_seconds //= 300|.restart_seconds //= 30|.organizations //= []' \
        "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    fetch "$platform/install.sh" "$root/bin/install.sh"
    fetch "$platform/service.sh" "$root/bin/service.sh"
    fetch "$platform/ghr.sh" "$root/bin/ghr.sh"
    fetch "$platform/runner.sh" "$root/bin/runner.sh"
    chmod 700 "$root/bin/install.sh" "$root/bin/service.sh" "$root/bin/ghr.sh" "$root/bin/runner.sh"
    /bin/bash "$root/bin/service.sh" prepare
    if [ "$platform" = linux ]; then sudo /bin/bash "$root/bin/.cache/package/bin/installdependencies.sh"; fi
    /bin/bash "$root/bin/ghr.sh" --install-command
    work_dir=$("$jq_path" -r .work_dir "$root/conf/settings.json")
    mkdir -p "$work_dir/data" "$work_dir/logs"
    printf 'Data/logs directory: %s\n' "$work_dir"
    rm -f "$root/conf/stopped"
    user=$(id -un); user_id=$(id -u)
    definition=$(mktemp)
    if [ "$platform" = linux ]; then
        [ -d /run/systemd/system ] || { echo 'Linux must be booted with systemd.' >&2; rm -f "$definition"; exit 1; }
        service_name=local-github-runner-$user_id-$arch.service
        exec_path=$(unit_quote "$root/bin/service.sh" | sed 's/\$/$$/g')
        cat > "$definition" <<UNIT
[Unit]
Description=GitHub organization runner supervisor
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=$user
WorkingDirectory="$(unit_quote "$root")"
Environment="HOME=$(unit_quote "$HOME")"
Environment="PATH=$(unit_quote "$PATH")"
ExecStart=/bin/bash "$exec_path"
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=90
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
        sudo install -m 644 "$definition" "/etc/systemd/system/$service_name"
        sudo systemctl daemon-reload
        sudo systemctl enable "$service_name"
        sudo systemctl restart "$service_name"
        sudo systemctl is-active --quiet "$service_name"
    else
        service_name=com.suminwell.github-runner.$user_id.$arch
        cat > "$definition" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$service_name</string>
<key>UserName</key><string>$(xml "$user")</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$(xml "$root/bin/service.sh")</string></array>
<key>WorkingDirectory</key><string>$(xml "$root")</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>AbandonProcessGroup</key><false/>
<key>ThrottleInterval</key><integer>10</integer><key>ExitTimeOut</key><integer>90</integer>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$(xml "$HOME")</string><key>PATH</key><string>$(xml "$PATH")</string></dict>
<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST
        sudo launchctl bootout "system/$service_name" 2>/dev/null || :
        sudo install -o root -g wheel -m 644 "$definition" "/Library/LaunchDaemons/$service_name.plist"
        sudo launchctl enable "system/$service_name"
        sudo launchctl bootstrap system "/Library/LaunchDaemons/$service_name.plist"
        sudo launchctl print "system/$service_name" >/dev/null
    fi
    rm -f "$definition" "$root/install.sh" "$root/service.sh" "$root/ghr.sh"
    printf '\nInstalled %s\n\n' "$service_name"
    /bin/bash "$root/bin/ghr.sh" help
    case ":$PATH:" in *:/usr/local/bin:*) ;; *) printf '\nAdd /usr/local/bin to PATH: export PATH="/usr/local/bin:$PATH"\n' ;; esac
}
if [ -t 0 ]; then install_main "$@";
elif ( : < /dev/tty ) 2>/dev/null; then install_main "$@" < /dev/tty;
else install_main "$@" < /dev/null; fi
