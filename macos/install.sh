#!/bin/sh
# Complete POSIX entry point; safe for curl ... | sh.
set -eu
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
systemd_unit() {
    exec_path=$(unit_quote "$4/bin/service.sh" | sed 's/\$/$$/g')
    cat <<UNIT
[Unit]
Description=GitHub organization runner supervisor
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0
[Service]
Type=simple
User=$1
WorkingDirectory=$(printf '%s' "$4" | sed 's/%/%%/g')
Environment="HOME=$(unit_quote "$2")"
Environment="PATH=$(unit_quote "$3")"
ExecStart=/bin/bash "$exec_path"
Restart=always
RestartSec=10
KillMode=control-group
TimeoutStopSec=90
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
}
# Interactive: launchd applies no background CPU/IO throttling to the runner and its jobs.
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
<key>ProcessType</key><string>Interactive</string>
<key>ThrottleInterval</key><integer>10</integer><key>ExitTimeOut</key><integer>90</integer>
<key>EnvironmentVariables</key><dict><key>HOME</key><string>$(xml "$3")</string><key>PATH</key><string>$(xml "$4")</string></dict>
<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST
}
# The root daemon that keeps the Mac awake while the manager runs (macos/awake.sh).
awake_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml "$1")</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$(xml "$2")</string><string>run</string><string>$(xml "$3")</string><string>$(xml "$4")</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST
}
# install: (re)start the guard from a root-owned copy; remove: let go of sleep and delete it.
# Earlier versions named the guard <service>.sleep; it is released and removed either way.
awake_guard() {
    local name script
    for name in "$service_name.sleep" "$service_name.awake"; do
        script=/Library/PrivilegedHelperTools/$name.sh
        # Booting the guard out releases sleep; its replacement takes it again within seconds.
        sudo launchctl bootout "system/$name" 2>/dev/null || :
        if [ -f "$script" ]; then sudo /bin/bash "$script" release "$service_name"; fi
        sudo rm -f "$script" "/Library/LaunchDaemons/$name.plist"
    done
    [ "$1" = install ] || return 0
    name=$service_name.awake; script=/Library/PrivilegedHelperTools/$name.sh
    awake_plist "$name" "$script" "$root/conf/manager.pid" "$service_name" > "$definition"
    sudo mkdir -p /Library/PrivilegedHelperTools
    sudo install -o root -g wheel -m 755 "$root/bin/awake.sh" "$script"
    sudo install -o root -g wheel -m 644 "$definition" "/Library/LaunchDaemons/$name.plist"
    sudo launchctl enable "system/$name"
    sudo launchctl bootstrap system "/Library/LaunchDaemons/$name.plist"
}
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
initialize_install_settings() {
    [ ! -f "$root/conf/settings.json" ] || return 0
    mkdir -p "$root/conf"
    # Claim this fresh installation before downloads or login can fail. Keep the first
    # invocation's data directory when a retry is launched from a different directory.
    jq -n --arg platform "$platform" --arg arch "$arch" --arg work_dir "$(pwd -P)" --argjson owner_uid "$(id -u)" \
        '{platform:$platform,arch:$arch,owner_uid:$owner_uid,work_dir:$work_dir}' > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
}
install_main() {
    umask 077
    platform=macos
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
    for settings_file in "$root/conf/settings.json" "$root/.state/settings.json" "$root/$arch/.state/settings.json" "$root/$arch/conf/settings.json"; do
        if [ -f "$settings_file" ]; then
            jq -e --arg platform "$platform" '.platform==$platform' "$settings_file" >/dev/null || { echo 'Installation configuration belongs to a different platform.' >&2; exit 1; }
            known_installation=true
        fi
    done
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
    stop_installed_service
    migrate_layout
    initialize_install_settings
    # Re-running the installer usually repairs credentials or configuration, so every
    # organization is retried at once instead of after its backoff (up to an hour).
    if [ -d "$root/conf/backoff" ] && [ ! -L "$root/conf/backoff" ]; then rm -f "$root/conf/backoff"/*; fi
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
    # Keeping the Mac awake (also with the lid closed) while the manager runs is on by
    # default; LOCAL_RUNNER_PREVENT_SLEEP=no turns it off, and a re-run keeps the choice.
    case "${LOCAL_RUNNER_PREVENT_SLEEP:-}" in
        yes|true|1) prevent_sleep=true ;; no|false|0) prevent_sleep=false ;;
        '') prevent_sleep=$("$jq_path" -r 'if .prevent_sleep == false then "false" else "true" end' "$root/conf/settings.json" 2>/dev/null || echo true) ;;
        *) echo 'LOCAL_RUNNER_PREVENT_SLEEP must be yes or no.' >&2; exit 1 ;;
    esac
    printf '%s\n' "$gh_path" > "$root/conf/gh-path"
    printf '%s\n' "$jq_path" > "$root/conf/jq-path"
    default_work=$(pwd -P)
    [ ! -f "$root/conf/settings.json" ] || default_work=$root
    [ -f "$root/conf/settings.json" ] || printf '{}\n' > "$root/conf/settings.json"
    "$jq_path" --arg platform "$platform" --arg arch "$arch" --arg gh "$gh_path" --argjson owner_uid "$(id -u)" --arg default_work "$default_work" \
        --argjson prevent_sleep "$prevent_sleep" \
        '.platform=$platform|.arch=$arch|.gh=$gh|.owner_uid=$owner_uid|.prevent_sleep=$prevent_sleep|.work_dir //= $default_work|del(.python)|.poll_seconds //= 300|.restart_seconds //= 30|.organizations //= []' \
        "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    fetch "$platform/install.sh" "$root/bin/install.sh"
    fetch "$platform/service.sh" "$root/bin/service.sh"
    fetch "$platform/ghr.sh" "$root/bin/ghr.sh"
    fetch "$platform/runner.sh" "$root/bin/runner.sh"
    fetch "$platform/awake.sh" "$root/bin/awake.sh"
    rm -f "$root/bin/sleep.sh"
    chmod 700 "$root/bin/install.sh" "$root/bin/service.sh" "$root/bin/ghr.sh" "$root/bin/runner.sh" "$root/bin/awake.sh"
    /bin/bash "$root/bin/service.sh" prepare
    if [ "$platform" = linux ]; then sudo /bin/bash "$root/bin/.cache/package/bin/installdependencies.sh"; fi
    /bin/bash "$root/bin/ghr.sh" --install-command
    work_dir=$("$jq_path" -r .work_dir "$root/conf/settings.json")
    mkdir -p "$work_dir/data" "$work_dir/logs"
    printf 'Data/logs directory: %s\n' "$work_dir"
    user=$(id -un); user_id=$(id -u)
    definition=$(mktemp)
    if [ "$platform" = linux ]; then
        [ -d /run/systemd/system ] || { echo 'Linux must be booted with systemd.' >&2; rm -f "$definition"; exit 1; }
        service_name=local-github-runner-$user_id-$arch.service
        systemd_unit "$user" "$HOME" "$PATH" "$root" > "$definition"
        sudo install -m 644 "$definition" "/etc/systemd/system/$service_name"
        sudo systemctl daemon-reload
        if [ -f "$root/conf/stopped" ]; then sudo systemctl disable "$service_name";
        else
            sudo systemctl enable "$service_name"
            sudo systemctl restart "$service_name"
            sudo systemctl is-active --quiet "$service_name"
        fi
    else
        service_name=com.suminwell.github-runner.$user_id.$arch
        launchd_plist "$service_name" "$user" "$HOME" "$PATH" "$root" > "$definition"
        sudo launchctl bootout "system/$service_name" 2>/dev/null || :
        sudo install -o root -g wheel -m 644 "$definition" "/Library/LaunchDaemons/$service_name.plist"
        if [ -f "$root/conf/stopped" ]; then sudo launchctl disable "system/$service_name";
        else
            sudo launchctl enable "system/$service_name"
            sudo launchctl bootstrap system "/Library/LaunchDaemons/$service_name.plist"
            sudo launchctl print "system/$service_name" >/dev/null
        fi
        # The guard runs even while the service is stopped, so ghr start needs no sudo for it.
        if [ "$prevent_sleep" = true ]; then
            awake_guard install
            printf 'Sleep prevention: on; this Mac stays awake, also with the lid closed, while the runner service runs.\n'
        else awake_guard remove; fi
    fi
    rm -f "$definition" "$root/install.sh" "$root/service.sh" "$root/ghr.sh"
    printf '\nInstalled %s\n\n' "$service_name"
    /bin/bash "$root/bin/ghr.sh" help
    case ":$PATH:" in *:/usr/local/bin:*) ;; *) printf '\nAdd /usr/local/bin to PATH: export PATH="/usr/local/bin:$PATH"\n' ;; esac
}
if [ -t 0 ]; then install_main "$@";
elif ( : < /dev/tty ) 2>/dev/null; then install_main "$@" < /dev/tty;
else install_main "$@" < /dev/null; fi
