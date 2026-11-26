#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/runner-compatibility.XXXXXX")
FIXTURE=$(cd "$FIXTURE" && pwd -P)
success=false
trap 'if $success; then rm -rf "$FIXTURE"; else printf "Retained fixture: %s\n" "$FIXTURE"; fi' EXIT
assert() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; }
sed '/^if \[ -t 0 \]/,$d' "$REPO/linux/install.sh" > "$FIXTURE/install.sh"
cat > "$FIXTURE/os-release" <<'OS'
NAME="CentOS Linux"
VERSION_ID="7"
ID=centos
PRETTY_NAME="CentOS Linux 7 (Core)"
OS
# Exercise the real installer entry before privileged setup or any existing service
# can be changed. Only the host description and privileged boundary are replaced.
result=0
cat > "$FIXTURE/run-install.sh" <<'INSTALL'
    #!/bin/bash
    set -eu
    . "$FIXTURE/install.sh"
    uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
    read_linux_release() { cat "$FIXTURE/os-release"; }
    getconf() { echo 'glibc 2.17'; }
    check_linux_host() { :; }
    id() { echo 1001; }
    sudo() { printf 'privileged setup reached\n' > "$FIXTURE/mutated"; exit 77; }
    install_main auto
INSTALL
FIXTURE=$FIXTURE /bin/bash "$FIXTURE/run-install.sh" > "$FIXTURE/unsupported-output" 2>&1 || result=$?
if [ "$result" != 1 ] || [ -e "$FIXTURE/mutated" ]; then
    cat "$FIXTURE/unsupported-output" >&2
    echo "FAIL: CentOS 7 reached privileged setup (installer exit $result)" >&2; exit 1
fi
assert grep -q 'CentOS Linux 7' "$FIXTURE/unsupported-output"
assert grep -q 'glibc 2.17' "$FIXTURE/unsupported-output"
(
    . "$FIXTURE/install.sh"
    read_linux_release() { printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="Fixture Linux"\n' "$distribution" "$version"; }
    getconf() { echo 'glibc 2.36'; }
    for pair in 'centos 7.9' 'rhel 7' 'ol 7.9' 'ubuntu 18.04' 'ubuntu 20.03' 'debian 9' 'linuxmint 19' 'fedora 28' 'opensuse-leap 15.1' 'sles 15.1'; do
        read -r distribution version <<< "$pair"
        if check_linux_compatibility >/dev/null 2>&1; then echo "Accepted unsupported $pair" >&2; exit 1; fi
    done
    for pair in 'centos 9' 'rhel 8.10' 'ol 8' 'ubuntu 20.04' 'ubuntu 24.04' 'debian 12' 'linuxmint 20' 'fedora 29' 'opensuse-leap 15.2' 'sles 15.2' 'custom 1'; do
        read -r distribution version <<< "$pair"
        check_linux_compatibility
    done
)
export LOCAL_RUNNER_ROOT=$FIXTURE/program
mkdir -p "$LOCAL_RUNNER_ROOT/bin/.cache/package/bin" "$LOCAL_RUNNER_ROOT/conf" "$FIXTURE/work"
command -v jq > "$LOCAL_RUNNER_ROOT/conf/jq-path"
printf '/bin/false\n' > "$LOCAL_RUNNER_ROOT/conf/gh-path"
jq -n --arg work "$FIXTURE/work" '{arch:"x64",work_dir:$work}' > "$LOCAL_RUNNER_ROOT/conf/settings.json"
(
    . "$REPO/linux/service.sh"
    init control
    package=$ROOT/bin/.cache/package
    cat > "$package/bin/Runner.Listener" <<'LISTENER'
#!/bin/sh
echo "Runner.Listener: /lib64/libstdc++.so.6: version GLIBCXX_3.4.20 not found" >&2
echo "Runner.Listener: /lib64/libstdc++.so.6: version GLIBCXX_3.4.21 not found" >&2
exit 127
LISTENER
    chmod +x "$package/bin/Runner.Listener"
    if verify_runtime > "$FIXTURE/runtime-output" 2>&1; then echo 'Accepted incompatible Runner.Listener' >&2; exit 1; fi
    assert grep -q GLIBCXX_3.4.20 "$FIXTURE/runtime-output"
    assert grep -q GLIBCXX_3.4.21 "$FIXTURE/runtime-output"
    printf '#!/bin/sh\necho 2.338.2\n' > "$package/bin/Runner.Listener"
    mkdir -p "$package/externals/node24/bin" "$package/externals/node24_alpine/bin"
    printf '#!/bin/sh\necho "GLIBC_2.28 not found" >&2\nexit 1\n' > "$package/externals/node24/bin/node"
    printf '#!/bin/sh\nexit 94\n' > "$package/externals/node24_alpine/bin/node"
    chmod +x "$package/externals/"*/bin/node
    if verify_runtime > "$FIXTURE/runtime-output" 2>&1; then echo 'Accepted incompatible bundled Node.js' >&2; exit 1; fi
    assert grep -q GLIBC_2.28 "$FIXTURE/runtime-output"
    printf '#!/bin/sh\necho v24.0.0\n' > "$package/externals/node24/bin/node"
    verify_runtime > "$FIXTURE/runtime-output"
    assert grep -q 'Runtime check passed' "$FIXTURE/runtime-output"
)
success=true
printf 'PASS Linux OS preflight before mutations and actual runtime execution checks\n'
