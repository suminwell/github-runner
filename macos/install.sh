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
sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
# Progress before each step that can take a while, so a slow one does not look stuck.
step() { printf '==> %s\n' "$*"; }
xml() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
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
awake_guard() {
    guard_name=$service_name.awake
    guard_script=/Library/PrivilegedHelperTools/$guard_name.sh
    guard_definition=/Library/LaunchDaemons/$guard_name.plist
    # Booting the guard out releases sleep; its replacement takes it again within seconds.
    sudo launchctl bootout "system/$guard_name" 2>/dev/null || :
    if [ "$1" = install ]; then
        awake_plist "$guard_name" "$guard_script" "$root/conf/manager.pid" "$service_name" > "$definition"
        sudo mkdir -p /Library/PrivilegedHelperTools
        sudo install -o root -g wheel -m 755 "$root/bin/awake.sh" "$guard_script"
        sudo install -o root -g wheel -m 644 "$definition" "$guard_definition"
        sudo launchctl enable "system/$guard_name"
        sudo launchctl bootstrap system "$guard_definition"
    else
        if [ -f "$guard_script" ]; then sudo /bin/bash "$guard_script" release "$service_name"; fi
        sudo rm -f "$guard_script" "$guard_definition"
    fi
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
    # A Rosetta shell reports x86_64 on Apple silicon.
    if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || :)" = 1 ]; then arch=arm64; fi
}
stop_installed_service() {
    service_name=com.suminwell.github-runner.$(id -u).$arch
    definition_path=/Library/LaunchDaemons/$service_name.plist
    [ -f "$definition_path" ] || return 0
    [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$definition_path")" = "$root/bin/service.sh" ] || { echo 'Another installation owns this service name.' >&2; exit 1; }
    sudo launchctl bootout "system/$service_name" 2>/dev/null || :
    sudo launchctl disable "system/$service_name"
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
    [ "$(uname -s)" = Darwin ] || { echo 'Incorrect platform installer' >&2; exit 1; }
    detect_architecture
    if [ "${1:-auto}" != auto ] && [ "$1" != "$arch" ]; then echo "Architecture mismatch: requested $1, host $arch" >&2; exit 1; fi
    [ "$(id -u)" -ne 0 ] || { echo 'Use a normal user; sudo is used for system setup.' >&2; exit 1; }
    sudo -v
    if ! command -v jq >/dev/null 2>&1; then
        if ! command -v brew >/dev/null 2>&1; then
            setup=$(mktemp)
            download https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$setup" 120
            /bin/bash "$setup"; rm -f "$setup"
            if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
        fi
        step 'Installing jq with Homebrew'
        brew install jq
    fi
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    default_root=${LOCAL_RUNNER_HOME:-"$HOME/.local/share/github-runner"}/$platform
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
    if [ -f "$root/conf/settings.json" ]; then
        jq -e --arg platform "$platform" '.platform==$platform' "$root/conf/settings.json" >/dev/null || { echo 'Installation configuration belongs to a different platform.' >&2; exit 1; }
    else
        for part in bin conf; do [ ! -e "$root/$part" ] || { echo "Refusing to reuse unrelated directory $root/$part; choose another installation directory." >&2; exit 1; }; done
    fi
    step 'Stopping the installed runner service, if any'
    stop_installed_service
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
        step 'Downloading the GitHub CLI (gh)'
        temporary=$(mktemp -d "$root/bin/.cache/gh.XXXXXX")
        download https://api.github.com/repos/cli/cli/releases/latest "$temporary/release.json" 120
        version=$("$jq_path" -r '.tag_name|ltrimstr("v")' "$temporary/release.json")
        cli_arch=$arch; [ "$arch" != x64 ] || cli_arch=amd64
        filename=gh_${version}_macOS_${cli_arch}.zip
        url=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.browser_download_url' "$temporary/release.json")
        digest=$("$jq_path" -r --arg name "$filename" '.assets[]|select(.name==$name)|.digest' "$temporary/release.json")
        printf '%s' "$digest" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' || { echo 'Missing gh asset digest.' >&2; exit 1; }
        download "$url" "$temporary/$filename"
        [ "$(sha256_file "$temporary/$filename")" = "${digest#sha256:}" ] || { echo 'gh SHA-256 mismatch.' >&2; exit 1; }
        mkdir "$temporary/unpacked"
        unzip -q "$temporary/$filename" -d "$temporary/unpacked"
        downloaded_gh=$(find "$temporary/unpacked" -type f -name gh -print | head -n 1)
        cp "$downloaded_gh" "$root/bin/tools/gh"; chmod 700 "$root/bin/tools/gh"
        gh_path=$root/bin/tools/gh
        rm -rf "$temporary"
    fi
    step 'Checking the GitHub login'
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
    "$jq_path" --arg platform "$platform" --arg arch "$arch" --argjson owner_uid "$(id -u)" --arg default_work "$default_work" \
        --argjson prevent_sleep "$prevent_sleep" \
        '.platform=$platform|.arch=$arch|.owner_uid=$owner_uid|.prevent_sleep=$prevent_sleep|.work_dir //= $default_work|.poll_seconds //= 300|.restart_seconds //= 30|.organizations //= []' \
        "$root/conf/settings.json" > "$root/conf/settings.new"
    mv "$root/conf/settings.new" "$root/conf/settings.json"
    step "Downloading the runner scripts to $root/bin"
    fetch "$platform/install.sh" "$root/bin/install.sh"
    fetch "$platform/service.sh" "$root/bin/service.sh"
    fetch "$platform/ghr.sh" "$root/bin/ghr.sh"
    fetch "$platform/runner.sh" "$root/bin/runner.sh"
    fetch "$platform/awake.sh" "$root/bin/awake.sh"
    chmod 700 "$root/bin/install.sh" "$root/bin/service.sh" "$root/bin/ghr.sh" "$root/bin/runner.sh" "$root/bin/awake.sh"
    step 'Preparing the official Runner (the first download is about 200 MB)'
    /bin/bash "$root/bin/service.sh" prepare || { echo 'Preparing the official Runner failed (see the error above). Run the same install command again to retry.' >&2; exit 1; }
    /bin/bash "$root/bin/ghr.sh" --install-command
    work_dir=$("$jq_path" -r .work_dir "$root/conf/settings.json")
    mkdir -p "$work_dir/jobs" "$work_dir/runners" "$work_dir/logs"
    printf 'Work directory (jobs, runners, logs): %s\n' "$work_dir"
    user=$(id -un); user_id=$(id -u)
    definition=$(mktemp)
    service_name=com.suminwell.github-runner.$user_id.$arch
    step "Installing and starting $service_name"
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
    rm -f "$definition"
    printf '\nInstalled %s\n\n' "$service_name"
    /bin/bash "$root/bin/ghr.sh" help
    case ":$PATH:" in *:/usr/local/bin:*) ;; *) printf '\nAdd /usr/local/bin to PATH: export PATH="/usr/local/bin:$PATH"\n' ;; esac
}
if [ -t 0 ]; then install_main "$@";
elif ( : < /dev/tty ) 2>/dev/null; then install_main "$@" < /dev/tty;
else install_main "$@" < /dev/null; fi
