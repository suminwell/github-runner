#!/bin/sh
# POSIX entry point: safe for curl ... | sh.
set -eu
install_main() {
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    setup=$(mktemp)
    trap 'rm -f "$setup"' EXIT HUP INT TERM
    if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then
        cp "$LOCAL_RUNNER_SOURCE_DIR/common/install_unix.sh" "$setup"
    else
        curl -fsSL "$base/common/install_unix.sh" -o "$setup"
    fi
    if [ -t 0 ]; then sh "$setup" linux;
    elif [ -r /dev/tty ]; then sh "$setup" linux < /dev/tty;
    else sh "$setup" linux < /dev/null; fi
}
install_main
