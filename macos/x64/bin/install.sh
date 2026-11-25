#!/bin/sh
# POSIX entry point: safe for curl ... | sh.
set -eu
install_main() {
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    setup=$(mktemp)
    trap 'rm -f "$setup"' EXIT HUP INT TERM
    if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then
        cp "$LOCAL_RUNNER_SOURCE_DIR/macos/install.sh" "$setup"
    else
        curl -fsSL "$base/macos/install.sh" -o "$setup"
    fi
    if [ -t 0 ]; then sh "$setup" x64;
    elif ( : < /dev/tty ) 2>/dev/null; then sh "$setup" x64 < /dev/tty;
    else sh "$setup" x64 < /dev/null; fi
}
install_main
