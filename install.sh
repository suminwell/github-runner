#!/bin/sh
# Universal POSIX entry point: Linux/macOS, including curl ... | sh.
set -eu
install_main() {
    case "$(uname -s)" in
        Linux) platform=linux ;;
        Darwin) platform=macos ;;
        MINGW*|MSYS*|CYGWIN*) echo 'On Windows, run install.ps1 from PowerShell.' >&2; exit 1 ;;
        *) echo 'Only Linux and macOS are supported by install.sh.' >&2; exit 1 ;;
    esac
    # Prefer a requested source directory, or this checkout when run as a file.
    if [ -z "${LOCAL_RUNNER_SOURCE_DIR:-}" ] && [ -z "${LOCAL_RUNNER_BASE_URL:-}" ]; then
        case "$0" in
            */install.sh|install.sh)
                checkout=$(cd "$(dirname "$0")" && pwd)
                if [ -f "$checkout/$platform/install.sh" ]; then LOCAL_RUNNER_SOURCE_DIR=$checkout; fi ;;
        esac
    fi
    bootstrap_file=$(mktemp "${TMPDIR:-/tmp}/github-runner-install.XXXXXX")
    trap 'rm -f "$bootstrap_file"' 0
    trap 'exit 1' 1 2 15
    if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then
        LOCAL_RUNNER_SOURCE_DIR=$(cd "$LOCAL_RUNNER_SOURCE_DIR" && pwd)
        export LOCAL_RUNNER_SOURCE_DIR
        cp "$LOCAL_RUNNER_SOURCE_DIR/$platform/install.sh" "$bootstrap_file"
    else
        base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
        curl -fsSL --connect-timeout 15 --max-time 120 "${base%/}/$platform/install.sh" -o "$bootstrap_file"
    fi
    # The platform installer handles interactive login through /dev/tty.
    sh "$bootstrap_file" "$@"
}
install_main "$@"
