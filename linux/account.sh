#!/bin/sh
# Root installations: protected program/configuration, unprivileged runtime state.
# POSIX helpers are shared only within the Linux platform.
account_validate_path() (
    checked=$1
    while :; do
        [ "$(stat -c %u "$checked")" = 0 ] && [ -z "$(find "$checked" -maxdepth 0 -perm /022 -print)" ] || {
            printf 'Root installation requires root-owned directories without group/other write access: %s\n' "$checked" >&2; exit 1;
        }
        [ "$checked" != / ] || break
        checked=$(dirname "$checked")
    done
)
account_load() {
    account_user=ghrunner
    # The installed jq: CentOS 7 hosts only have the bundled static binary.
    account_uid=$("${JQ:-jq}" -er '.uid | select(type=="number" and .>0) | tostring' "$ROOT/conf/account.json") || return 1
    account_home=/var/lib/github-runner/home
    [ "$(id -u "$account_user")" = "$account_uid" ] || { echo 'Runner account identity changed; repair it before continuing.' >&2; return 1; }
    account_gid=$(id -g "$account_user") || return 1
}
account_run() {
    # No sudo rights are granted to the service account. Preserve proxy and WSL
    # interoperability variables, but never root's HOME or GitHub environment token.
    runuser -u "$account_user" -- env -u GH_TOKEN -u GITHUB_TOKEN -u GH_CONFIG_DIR \
        HOME="$account_home" USER="$account_user" LOGNAME="$account_user" GHR_NESTED=1 \
        PATH=/usr/local/bin:/usr/bin:/bin /bin/sh -c 'cd / && exec "$@"' sh "$@"
}
account_setup() {
    account_validate_path "$ROOT" || return 1
    for protected in "$ROOT/bin" "$ROOT/conf" /var/lib/github-runner; do
        [ ! -L "$protected" ] || { echo "Refusing a symlink: $protected" >&2; return 1; }
        mkdir -p "$protected" || return 1
        account_validate_path "$protected" || return 1
    done
    if [ -f "$ROOT/conf/settings.json" ] && [ ! -f "$ROOT/conf/account.json" ]; then
        echo 'This installation belongs to a normal user. Re-run its installer as that user.' >&2; return 1
    fi
    if id ghrunner >/dev/null 2>&1; then
        [ -f /var/lib/github-runner/account.json ] && \
            jq -e --argjson uid "$(id -u ghrunner)" '(.uid==$uid) and (.uid>0)' /var/lib/github-runner/account.json >/dev/null || {
                echo 'An unrelated ghrunner account already exists; refusing to reuse it.' >&2; return 1;
            }
    else
        [ ! -f /var/lib/github-runner/account.json ] || { echo 'The saved runner account is missing; repair it before reinstalling.' >&2; return 1; }
        useradd --system --user-group --home-dir /var/lib/github-runner/home --no-create-home --shell /usr/sbin/nologin ghrunner || return 1
        jq -n --argjson uid "$(id -u ghrunner)" '{uid:$uid}' > /var/lib/github-runner/account.json || return 1
        chmod 600 /var/lib/github-runner/account.json
    fi
    if [ ! -f "$ROOT/conf/account.json" ]; then
        cp /var/lib/github-runner/account.json "$ROOT/conf/account.json" || return 1
    fi
    account_load || return 1
    chgrp "$account_gid" "$ROOT" "$ROOT/bin" "$ROOT/conf" /var/lib/github-runner
    chmod 755 "$ROOT" "$ROOT/bin"
    # The default script path is also read by Windows when WSL launches PowerShell.
    [ "$ROOT" != /opt/github-runner/linux ] || chmod 755 /opt/github-runner
    chmod 750 "$ROOT/conf" /var/lib/github-runner
    chgrp "$account_gid" "$ROOT/conf/account.json"; chmod 640 "$ROOT/conf/account.json"
    account_traverse "$ROOT" || return 1
    for writable in "$account_home" "$ROOT/conf/runtime" "$ROOT/runner" "$ROOT/bin/.cache"; do
        if [ ! -e "$writable" ] && [ ! -L "$writable" ]; then
            mkdir "$writable" && chown "$account_uid:$account_gid" "$writable" && chmod 700 "$writable" || return 1
        fi
        # Never recursively chown existing runtime trees or follow their symlinks as root.
        [ -d "$writable" ] && [ ! -L "$writable" ] && [ "$(stat -c %u "$writable")" = "$account_uid" ] || {
            printf 'Unexpected runtime directory ownership: %s\n' "$writable" >&2; return 1;
        }
    done
}
account_traverse() (
    checked=$1
    while :; do
        account_run test -x "$checked" || setfacl -m "u:$account_uid:--x" "$checked" || exit 1
        [ "$checked" != / ] || break
        checked=$(dirname "$checked")
    done
)
account_work_directory() (
    requested=$(realpath -m -- "$1") || exit 1
    case "$requested" in "$ROOT/bin"|"$ROOT/bin/"*|"$ROOT/conf"|"$ROOT/conf/"*|"$ROOT/runner"|"$ROOT/runner/"*)
        echo 'Data must be outside the program and state directories.' >&2; exit 1 ;;
    esac
    if ! account_run mkdir -p "$requested" 2>/dev/null; then
        ancestor=$requested
        while [ ! -d "$ancestor" ]; do ancestor=$(dirname "$ancestor"); done
        account_validate_path "$ancestor" || exit 1
        mkdir -p "$requested" || exit 1
    fi
    for directory in "$requested/data" "$requested/logs"; do
        [ ! -L "$directory" ] || { echo "Refusing a symlink: $directory" >&2; exit 1; }
    done
    # On a user-writable path, do everything as that user. Only grant permissions
    # as root when no unprivileged process can replace any parent during the change.
    if account_run mkdir -p "$requested/data" "$requested/logs" 2>/dev/null && \
        account_run test -w "$requested/data" && account_run test -x "$requested/data" && \
        account_run test -w "$requested/logs" && account_run test -x "$requested/logs"; then exit 0; fi
    account_validate_path "$requested" || exit 1
    account_traverse "$requested" || exit 1
    for directory in "$requested/data" "$requested/logs"; do
        [ ! -L "$directory" ] || { echo "Refusing a symlink: $directory" >&2; exit 1; }
        if [ ! -e "$directory" ]; then
            mkdir "$directory" && chown "$account_uid:$account_gid" "$directory" && chmod 700 "$directory" || exit 1
        else
            account_run test -w "$directory" && account_run test -x "$directory" || \
                setfacl -m "u:$account_uid:rwx,d:u:$account_uid:rwx" "$directory" || exit 1
        fi
        account_run test -w "$directory" && account_run test -x "$directory" || exit 1
    done
)
account_protect_config() {
    # Only files in the protected parent are touched; runtime is a separate subtree.
    for protected in "$ROOT/conf/"*; do
        [ -f "$protected" ] && [ ! -L "$protected" ] || continue
        chgrp "$account_gid" "$protected" && chmod 640 "$protected" || return 1
    done
}
account_prepare_package() (
    # The runtime cache is writable by jobs. Never execute its dependency installer
    # as root: download and verify a fresh archive into a root-only staging directory.
    staging=$(mktemp -d "$ROOT/conf/package.XXXXXX") || exit 1
    trap 'rm -rf "$staging"' EXIT
    mkdir -p "$staging/conf" "$staging/bin"
    cp "$ROOT/conf/gh-path" "$ROOT/conf/jq-path" "$ROOT/conf/github-token" "$staging/conf/"
    jq --arg work "$staging" '.work_dir=$work' "$ROOT/conf/settings.json" > "$staging/conf/settings.json"
    LOCAL_RUNNER_ROOT=$staging /bin/bash "$ROOT/bin/service.sh" prepare || exit 1
    # Docker mode installs the Runner's libraries in the image, not on this host.
    [ "${1:-}" = docker ] || /bin/bash "$staging/bin/.cache/package/bin/installdependencies.sh" || exit 1
    account_run rm -rf "$ROOT/bin/.cache/package" || exit 1
    tar -C "$staging/bin/.cache" -cf - package | account_run tar -C "$ROOT/bin/.cache" --no-same-owner -xf - || exit 1
)

# Called by the protected ghr.sh before runtime initialization. All operations on
# job-writable files and PID records run with the runner's UID, including uninstall.
account_command() {
    [ -r "$ROOT/conf/account.json" ] || { echo 'Manage this installation as root (sudo ghr ...).' >&2; return 1; }
    JQ=$(cat "$ROOT/conf/jq-path") || return 1
    account_load || return 1
    ARCH=$("$JQ" -er '.arch' "$ROOT/conf/settings.json") || return 1
    case "$ARCH" in x64|arm64) ;; *) return 1 ;; esac
    command=${1:-help}; [ "$#" = 0 ] || shift
    if [ "$(id -u)" != 0 ]; then
        [ "$(id -u)" = "$account_uid" ] || { echo 'Manage this installation as root (sudo ghr ...).' >&2; return 1; }
        init control || return 1
        case "$command" in
            --runtime-stop) stop_processes ;;
            --runtime-unregister) unregister_runners ;;
            status) [ "$#" = 0 ] && status ;;
            logs) [ "$#" = 0 ] || { [ "$#" = 1 ] && [ "$1" = -f ]; } || return 2; show_logs "${1:-}" ;;
            help|--help|-h) usage ;;
            *) echo 'Manage this installation as root (sudo ghr ...).' >&2; return 1 ;;
        esac
        return $?
    fi
    case "$command" in
        config)
            config_arguments "$@" || return $?
            WORK_DIR=$("$JQ" -er .work_dir "$ROOT/conf/settings.json") || return 1
            if [ -z "$CONFIG_VALUE" ]; then show_config "$@"; return 0; fi
            config_directory "$CONFIG_VALUE" || return 1
            account_work_directory "$CONFIG_DIRECTORY" || return 1
            account_settings --arg directory "$CONFIG_DIRECTORY" '.work_dir=$directory' || return 1
            config_saved ;;
        runner)
            runner_arguments "$@" || return $?
            if [ -z "$RUNNER_CHANGE" ]; then show_runners; return 0; fi
            runner_target || return 1
            account_settings --argjson count "$RUNNER_TO" '.runner_count=$count' || return 1
            runner_saved "$ROOT/conf/runtime/manager.pid" ;;
        logs) account_run /bin/bash "$ROOT/bin/ghr.sh" logs "$@" ;;
        wsl) [ "$#" = 1 ] && [ "$1" = setup ] || return 2; wsl_host setup ;;
        status|start|stop|restart|uninstall|--install-command|help|--help|-h)
            [ "$#" = 0 ] || return 2
            case "$command" in
                status) result=0; account_run /bin/bash "$ROOT/bin/ghr.sh" status || result=$?; wsl_host status || result=1; return "$result" ;;
                start) account_start ;;
                stop) account_stop ;;
                restart) account_stop && account_start ;;
                --install-command) install_cli && account_protect_config ;;
                uninstall)
                    account_stop || return 1
                    account_run /bin/bash "$ROOT/bin/ghr.sh" --runtime-unregister || return 1
                    native_service remove && wsl_host remove || return 1
                    command_path=$("$JQ" -r '.command_path // empty' "$ROOT/conf/settings.json")
                    hint=$(docker_hint)
                    if [ -n "$command_path" ] && [ -e "$command_path" ]; then
                        [ ! -L "$command_path" ] && grep -Fqx "# ghr: $ROOT" "$command_path" || return 1
                        rm -f "$command_path" || return 1
                    fi
                    rm -rf "$ROOT/bin" "$ROOT/conf" "$ROOT/runner" || return 1
                    echo 'Runner uninstalled. Data, logs and the locked ghrunner account/home are retained.'
                    [ -z "$hint" ] || printf '%s\n' "$hint" ;;
                *) usage ;;
            esac ;;
        *) usage >&2; return 2 ;;
    esac
}
# settings.json stays root-owned and readable by the runner account.
account_settings() {
    local temporary
    temporary=$(mktemp "$ROOT/conf/settings.XXXXXX") || return 1
    if ! "$JQ" "$@" "$ROOT/conf/settings.json" > "$temporary" || \
        ! chgrp "$account_gid" "$temporary" || ! chmod 640 "$temporary" || ! mv -f "$temporary" "$ROOT/conf/settings.json"; then
        rm -f "$temporary"; return 1
    fi
}
account_stop() {
    native_service stop || return 1
    printf 'stopped\n' | atomic "$ROOT/conf/stopped" || return 1
    account_protect_config || return 1
    account_run /bin/bash "$ROOT/bin/ghr.sh" --runtime-stop || return 1
    wsl_host stop || return 1
    echo 'Runner stopped; automatic startup disabled. Run ghr start to resume.'
}
account_start() {
    service_identity || return 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        wsl_host start || return 1
        echo 'Runner already running. Use ghr restart to apply configuration.'; return 0
    fi
    work=$("$JQ" -er .work_dir "$ROOT/conf/settings.json") || return 1
    account_work_directory "$work" || return 1
    rm -f "$ROOT/conf/stopped" || return 1
    native_service start || { printf 'stopped\n' | atomic "$ROOT/conf/stopped"; account_protect_config; return 1; }
    wsl_host start || return 1
    echo 'Runner started; automatic startup enabled.'
}
