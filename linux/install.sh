#!/bin/sh
# Complete platform installer; safe for curl ... | sh.
set -eu

install_main() {
    umask 077

    platform=linux
    requested_arch=${1:-auto}
    case "$platform:$(uname -s)" in linux:Linux|macos:Darwin) ;; *) echo 'Incorrect platform installer' >&2; exit 1 ;; esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) echo 'Only x64 and arm64 hosts are supported.' >&2; exit 1 ;;
    esac
    if [ "$platform" = macos ] && [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || :)" = 1 ]; then arch=arm64; fi
    if [ "$requested_arch" != auto ] && [ "$requested_arch" != "$arch" ]; then
        echo "Installer architecture $requested_arch does not match host architecture $arch." >&2
        exit 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        echo 'Run as your normal user; the installer uses sudo only for system setup.' >&2
        exit 1
    fi
    base=${LOCAL_RUNNER_BASE_URL:-https://raw.githubusercontent.com/suminwell/github-runner/main}
    root=${LOCAL_RUNNER_HOME:-"$HOME/.local/share/github-runner"}/$platform/$arch
    mkdir -p "$root/bin" "$root/.state" "$root/logs"
    command -v sudo >/dev/null || { echo 'sudo is required for boot-time service installation.' >&2; exit 1; }
    sudo -v

    python_ok() { command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1; }
    if ! python_ok; then
        if [ "$platform" = macos ]; then
            if ! command -v brew >/dev/null 2>&1; then
                brew_setup=$(mktemp)
                curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$brew_setup"
                /bin/bash "$brew_setup"
                rm -f "$brew_setup"
                if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)";
                else eval "$(/usr/local/bin/brew shellenv)"; fi
            fi
            brew install python
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y python3 ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y python3 ca-certificates
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper --non-interactive install python3 ca-certificates
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --needed --noconfirm python ca-certificates
        else
            echo 'Install Python 3.9+ first; this distribution has no supported package manager.' >&2
            exit 1
        fi
    fi
    python_ok || { echo 'Python 3.9+ is required.' >&2; exit 1; }
    python=$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')

    fetch() {
        source=$1
        target=$2
        if [ -n "${LOCAL_RUNNER_SOURCE_DIR:-}" ]; then
            cp "$LOCAL_RUNNER_SOURCE_DIR/$source" "$target.new"
        else
            curl -fsSL "$base/$source" -o "$target.new"
        fi
        mv "$target.new" "$target"
    }
    fetch "$platform/$arch/bin/manager.py" "$root/bin/manager.py"
    fetch "$platform/$arch/bin/install_service.py" "$root/bin/install_service.py"
    fetch "$platform/$arch/bin/install.sh" "$root/bin/install.sh"
    fetch "$platform/$arch/bin/service.sh" "$root/bin/service.sh"
    chmod 700 "$root/bin/service.sh"
    printf '%s\n' "$python" > "$root/.state/python"
    "$python" "$root/bin/manager.py" prepare --root "$root" --arch "$arch"
    "$python" "$root/bin/install_service.py" --root "$root"
    printf '\nInstalled in %s\nCheck registration: %s status\nService log: %s/logs/service.log\n' "$root" "$root/bin/service.sh" "$root"
}

if [ -t 0 ]; then install_main "$@";
elif ( : < /dev/tty ) 2>/dev/null; then install_main "$@" < /dev/tty;
else install_main "$@" < /dev/null; fi
