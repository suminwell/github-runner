#!/usr/bin/env python3
"""GitHub organization runner supervisor. Standard library only; Python >= 3.9."""
import argparse
import contextlib
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
import zipfile

LOG = logging.getLogger("local-runner")
ORG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")
SECRET_NAMES = {"GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"}


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except FileNotFoundError:
        return default


def host_platform():
    system = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}[platform.system()]
    machine = platform.machine().lower()
    if system == "windows":
        machine = (os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE") or machine).lower()
    elif system == "macos":
        native_arm = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True)
        if native_arm.returncode == 0 and native_arm.stdout.strip() == "1":
            machine = "arm64"  # Also select native binaries when Python runs under Rosetta.
    arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    if not arch:
        raise RuntimeError("Only x64 and arm64 hosts are supported")
    return system, arch


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "suminwell/github-runner"})
    with urllib.request.urlopen(request, timeout=120) as response, open(destination, "wb") as output:
        shutil.copyfileobj(response, output)


def extract(archive, destination):
    """Reject archive paths and links escaping the destination."""
    destination = Path(destination).resolve()
    def check(name):
        target = (destination / name).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError("Unsafe archive member")
    if str(archive).endswith(".zip"):
        with zipfile.ZipFile(archive) as package:
            for entry in package.infolist():
                check(entry.filename)
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise RuntimeError("Unexpected symlink in zip")
            package.extractall(destination)
    else:
        with tarfile.open(archive) as package:
            for entry in package.getmembers():
                check(entry.name)
                if entry.isdev() or entry.isfifo():
                    raise RuntimeError("Unexpected special file in archive")
                if entry.issym():
                    check(str(Path(entry.name).parent / entry.linkname))
                if entry.islnk():
                    check(entry.linkname)
            # Python 3.9 compatibility; members were validated above.
            package.extractall(destination)


def verified_asset(asset, directory):
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", digest):
        raise RuntimeError("GitHub release asset has no SHA-256 digest; refusing download")
    target = Path(directory) / asset["name"]
    download(asset["browser_download_url"], target)
    actual = hashlib.sha256()
    with target.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            actual.update(chunk)
    if actual.hexdigest() != digest.split(":", 1)[1].lower():
        target.unlink()
        raise RuntimeError("Release asset SHA-256 mismatch")
    return target


class GitHub:
    def __init__(self, executable, token_path=None):
        self.executable = str(executable)
        self.token_path = token_path

    def environment(self):
        env = os.environ.copy()
        for key in SECRET_NAMES:
            env.pop(key, None)
        env["GH_HOST"] = "github.com"
        env["GH_PROMPT_DISABLED"] = "1"
        if self.token_path:
            env["GH_TOKEN"] = Path(self.token_path).read_text().strip()
        return env

    def api(self, endpoint, method="GET", paginate=False):
        command = [self.executable, "api", "--hostname", "github.com", endpoint, "--method", method]
        if paginate:
            command += ["--paginate", "--slurp"]
        result = subprocess.run(command, env=self.environment(), capture_output=True, text=True, timeout=90)
        if result.returncode:
            # Do not echo API response bodies or commands containing credentials.
            status = re.search(r"HTTP (\d+)", result.stderr)
            raise RuntimeError("GitHub API %s failed%s" % (endpoint, " (HTTP " + status[1] + ")" if status else ""))
        return json.loads(result.stdout) if result.stdout.strip() else None

    def organizations(self):
        pages = self.api("user/memberships/orgs?state=active&per_page=100", paginate=True)
        return {str(item["organization"]["id"]): item["organization"]["login"]
                for page in pages for item in page if item["state"] == "active"}

    def runners(self, org):
        pages = self.api("orgs/%s/actions/runners?per_page=100" % org, paginate=True)
        return [runner for page in pages for runner in page["runners"]]


def install_gh(root, system, arch):
    existing = shutil.which("gh")
    if existing:
        version = subprocess.check_output([existing, "--version"], text=True, timeout=15)
        match = re.search(r"gh version (\d+)\.(\d+)", version)
        if not match or tuple(map(int, match.groups())) < (2, 62):
            existing = None  # Older releases lack API flags used by the supervisor.
    if existing:
        # Windows LocalService needs an executable outside the installing user's profile.
        if system != "windows":
            return str(Path(existing).resolve())
        target = root / ".state" / "tools" / "gh.exe"
        target.parent.mkdir(parents=True, exist_ok=True)
        if Path(existing).resolve() != target.resolve():
            shutil.copy2(existing, target)
        return str(target)
    target = root / ".state" / "tools" / ("gh.exe" if system == "windows" else "gh")
    if target.exists():
        return str(target)
    request = urllib.request.Request("https://api.github.com/repos/cli/cli/releases/latest",
                                     headers={"User-Agent": "suminwell/github-runner"})
    with urllib.request.urlopen(request, timeout=60) as response:
        release = json.load(response)
    version = release["tag_name"].removeprefix("v")
    cli_os = {"linux": "linux", "macos": "macOS", "windows": "windows"}[system]
    cli_arch = "amd64" if arch == "x64" else "arm64"
    extension = "zip" if system in {"macos", "windows"} else "tar.gz"
    name = "gh_%s_%s_%s.%s" % (version, cli_os, cli_arch, extension)
    asset = next(item for item in release["assets"] if item["name"] == name)
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent) as temporary:
        archive = verified_asset(asset, temporary)
        unpacked = Path(temporary) / "unpacked"
        extract(archive, unpacked)
        executable = next(unpacked.rglob(target.name))
        shutil.copy2(executable, target)
    target.chmod(0o755)
    return str(target)


def runner_package(root, api, system, arch):
    cache = root / ".state" / "package"
    if (cache / ".complete").exists() and time.time() - (cache / ".complete").stat().st_mtime < 86400:
        return cache
    release = api.api("repos/actions/runner/releases/latest")
    version = release["tag_name"].removeprefix("v")
    runner_os = {"linux": "linux", "macos": "osx", "windows": "win"}[system]
    name = "actions-runner-%s-%s-%s.%s" % (runner_os, arch, version, "zip" if system == "windows" else "tar.gz")
    asset = next(item for item in release["assets"] if item["name"] == name)
    with tempfile.TemporaryDirectory(dir=root / ".state") as temporary:
        LOG.info("Downloading official Actions Runner %s (%s/%s)", version, system, arch)
        archive = verified_asset(asset, temporary)
        unpacked = Path(temporary) / "unpacked"
        extract(archive, unpacked)
        (unpacked / ".complete").write_text(version)
        if cache.exists():
            shutil.rmtree(cache)
        unpacked.replace(cache)
    return cache


@contextlib.contextmanager
def single_instance(path):
    handle = open(path, "a+b")
    try:
        if os.name == "nt":
            import msvcrt
            if handle.tell() == 0:
                handle.write(b"0")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        handle.close()


def clean_environment():
    env = os.environ.copy()
    for key in SECRET_NAMES | {"GH_CONFIG_DIR"}:
        env.pop(key, None)
    return env


def launch_script(path, system, arguments=(), **kwargs):
    if system == "windows":
        wrapper = Path(path).with_name("configure-wrapper.ps1")
        wrapper.write_text("& (Join-Path $PSScriptRoot 'config.cmd') @args\nexit $LASTEXITCODE\n", encoding="utf-8")
        command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(wrapper), *arguments]
    else:
        command = ["/bin/bash", str(path), *arguments]
    return subprocess.Popen(command, **kwargs)


class Supervisor:
    def __init__(self, root, api=None):
        self.root = Path(root).resolve()
        self.settings = read_json(self.root / ".state/settings.json")
        self.system = self.settings["platform"]
        self.runner_name = "local-%s-%s" % (self.system, self.settings["arch"])
        self.api = api or GitHub(self.settings["gh"], self.root / ".state/github-token")
        self.state_file = self.root / ".state/organizations.json"
        self.organizations = read_json(self.state_file, {})
        self.processes = {}
        self.retry_after = {}
        self.paused = set()
        self.stop_event = threading.Event()
        self.process_lock = threading.RLock()

    def save(self):
        write_json(self.state_file, self.organizations)

    def configure(self, org, directory, package):
        runner = directory / "runner"
        if not runner.exists():
            staging = directory / "runner.staging"
            if staging.exists():
                shutil.rmtree(staging)
            shutil.copytree(package, staging)
            staging.rename(runner)
        work = self.root / "data" / org
        work.mkdir(parents=True, exist_ok=True)
        token = self.api.api("orgs/%s/actions/runners/registration-token" % org, "POST")["token"]
        args = ["--unattended", "--url", "https://github.com/" + org, "--token", token,
                "--name", self.runner_name, "--labels", self.runner_name, "--work", str(work)]
        config = runner / ("config.cmd" if self.system == "windows" else "config.sh")
        process = launch_script(config, self.system, args, cwd=runner, env=clean_environment(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("Runner configuration timed out")
        if code:
            raise RuntimeError("Runner configuration failed (exit %s); check organization permissions and runner _diag logs" % code)
        config_data = read_json(runner / ".runner")
        return config_data["agentId"]

    def wrapper(self, directory):
        if self.system == "windows":
            path = directory / "runner.ps1"
            path.write_text("$ErrorActionPreference = 'Stop'\nSet-Location (Join-Path $PSScriptRoot 'runner')\n& .\\run.cmd\nexit $LASTEXITCODE\n", encoding="utf-8")
        else:
            path = directory / "runner.sh"
            path.write_text('#!/bin/sh\nset -eu\ncd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/runner"\nexec ./run.sh\n')
            path.chmod(0o755)
        return path

    def alive(self, org_id):
        process = self.processes.get(org_id)
        return process is not None and process.poll() is None

    def start(self, org_id, entry):
        with self.process_lock:
            self._start(org_id, entry)

    def _start(self, org_id, entry):
        if self.stop_event.is_set() or org_id in self.paused:
            return
        if self.alive(org_id) or time.monotonic() < self.retry_after.get(org_id, 0):
            return
        directory = self.root / "bin" / entry["login"]
        if not (directory / "runner/.runner").exists():
            return
        wrapper = self.wrapper(directory)
        env = clean_environment()
        env.pop("RUNNER_MANUALLY_TRAP_SIG", None)
        if self.system == "windows":
            command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(wrapper)]
        else:
            command = [str(wrapper)]
        # The OS service owns this process tree. run.sh handles Runner self-updates.
        # Runner's own _diag directory preserves detailed operational logs.
        process = subprocess.Popen(command, cwd=directory, env=env, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        self.processes[org_id] = process
        self.retry_after[org_id] = time.monotonic() + 30
        LOG.info("Started %s for %s (pid %s)", self.runner_name, entry["login"], process.pid)

    def stop(self, org_id):
        with self.process_lock:
            self._stop(org_id)

    def _stop(self, org_id):
        process = self.processes.pop(org_id, None)
        if process and process.poll() is None:
            if self.system == "windows":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)
            else:
                # No detached sessions: launchd can reap the process group after a crash.
                rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
                children = [tuple(map(int, row.split())) for row in rows.splitlines() if row.strip()]
                tree = {process.pid}
                while True:
                    more = {pid for pid, parent in children if parent in tree} - tree
                    if not more:
                        break
                    tree.update(more)
                for pid in tree:
                    try:
                        os.kill(pid, signal.SIGINT)
                    except ProcessLookupError:
                        pass
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                # The OS service also cleans up its full process tree on shutdown.
                if os.name != "nt":
                    subprocess.run(["pkill", "-KILL", "-P", str(process.pid)], capture_output=True)
                process.kill()
                process.wait()

    def reconcile(self):
        # A failed discovery never means organizations disappeared.
        memberships = self.api.organizations()
        allowed = self.settings.get("organizations", [])
        desired = {key: value for key, value in memberships.items()
                   if not allowed or value.lower() in {name.lower() for name in allowed}}
        for org_id, org in desired.items():
            try:
                if self.stop_event.is_set():
                    return
                if not ORG.fullmatch(org):
                    raise RuntimeError("Invalid organization login")
                remote = self.api.runners(org)
                entry = self.organizations.get(org_id)
                registered = next((item for item in remote if entry and item["id"] == entry["runner_id"]), None)
                if entry and entry["login"] != org:
                    if registered and registered.get("busy"):
                        LOG.info("Deferring organization rename for busy runner: %s", org)
                        continue
                    self.paused.add(org_id)
                    self.stop(org_id)
                    if registered:
                        self.api.api("orgs/%s/actions/runners/%s" % (org, registered["id"]), "DELETE")
                        remote = [item for item in remote if item["id"] != registered["id"]]
                    entry = None
                    registered = None
                if entry and registered and (self.root / "bin" / org / "runner/.runner").exists():
                    self.paused.discard(org_id)
                    self.start(org_id, entry)
                    continue
                if entry and registered:
                    if registered.get("busy"):
                        continue
                    self.paused.add(org_id)
                    self.stop(org_id)
                    self.api.api("orgs/%s/actions/runners/%s" % (org, registered["id"]), "DELETE")
                    remote = [item for item in remote if item["id"] != registered["id"]]
                if entry:
                    self.paused.add(org_id)
                    self.stop(org_id)
                directory = self.root / "bin" / org
                directory.mkdir(parents=True, exist_ok=True)
                local_config = read_json(directory / "runner/.runner")
                # Recover a completed registration if the manager crashed before saving state.
                if local_config and any(item["id"] == local_config["agentId"] for item in remote):
                    runner_id = local_config["agentId"]
                else:
                    if any(item["name"] == self.runner_name for item in remote):
                        raise RuntimeError("Runner name %s already exists; refusing to replace another machine" % self.runner_name)
                    for name in (".runner", ".credentials", ".credentials_rsaparams"):
                        (directory / "runner" / name).unlink(missing_ok=True)
                    package = runner_package(self.root, self.api, self.system, self.settings["arch"])
                    runner_id = self.configure(org, directory, package)
                self.organizations[org_id] = {"login": org, "runner_id": runner_id}
                self.save()
                self.paused.discard(org_id)
                self.start(org_id, self.organizations[org_id])
            except Exception as error:
                LOG.warning("Organization %s: %s", org, error)
        for org_id in list(self.organizations):
            if org_id not in desired:
                self.paused.add(org_id)
                self.stop(org_id)
                del self.organizations[org_id]
                self.save()
                LOG.info("Stopped organization no longer in discovery; local data retained: %s", org_id)

    def serve(self):
        def discover():
            while not self.stop_event.is_set():
                try:
                    self.reconcile()
                except Exception as error:
                    LOG.warning("Discovery failed; retaining current runners: %s", error)
                self.stop_event.wait(max(10, self.settings.get("poll_seconds", 300)))
        discovery = threading.Thread(target=discover, name="organization-discovery", daemon=True)
        discovery.start()
        try:
            while not self.stop_event.is_set():
                if (self.root / ".state/stop").exists():
                    break
                for org_id, entry in list(self.organizations.items()):
                    self.start(org_id, entry)
                self.stop_event.wait(5)
        finally:
            self.stop_event.set()
            for org_id in list(self.processes):
                self.stop(org_id)


def prepare(root, expected_arch=None):
    root = Path(root).resolve()
    system, arch = host_platform()
    if expected_arch and arch != expected_arch:
        raise RuntimeError("Installer architecture %s does not match host architecture %s" % (expected_arch, arch))
    for name in (".state", "logs", "data", "bin"):
        (root / name).mkdir(parents=True, exist_ok=True)
    (root / ".state").chmod(0o700)
    gh = install_gh(root, system, arch)
    if subprocess.run([gh, "auth", "status", "--hostname", "github.com"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.run([gh, "auth", "login", "--hostname", "github.com", "--web", "--scopes", "admin:org,repo"], check=True)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        token = subprocess.check_output([gh, "auth", "token", "--hostname", "github.com"], text=True).strip()
    token_path = root / ".state/github-token"
    token_path.touch(mode=0o600)
    token_path.chmod(0o600)
    token_path.write_text(token + "\n")
    api = GitHub(gh, token_path)
    api.api("user")
    settings = read_json(root / ".state/settings.json", {})
    settings.update(platform=system, arch=arch, gh=gh, python=sys.executable)
    settings.setdefault("poll_seconds", 300)
    settings.setdefault("organizations", [])
    write_json(root / ".state/settings.json", settings)
    package = runner_package(root, api, system, arch)
    if system == "linux":
        # Official script installs distro-specific .NET runtime dependencies.
        subprocess.run(["sudo", "/bin/bash", str(package / "bin/installdependencies.sh")], check=True)
    LOG.info("Dependencies and GitHub credentials prepared")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare", "serve", "status"])
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--arch", choices=["x64", "arm64"])
    args = parser.parse_args()
    root = args.root.resolve()
    (root / "logs").mkdir(parents=True, exist_ok=True)
    handlers = [logging.StreamHandler()]
    if args.command == "serve":
        handlers.append(RotatingFileHandler(root / "logs/service.log", maxBytes=5 * 1024 * 1024, backupCount=3))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=handlers)
    if args.command == "prepare":
        prepare(root, args.arch)
    elif args.command == "status":
        settings = read_json(root / ".state/settings.json")
        api = GitHub(settings["gh"], root / ".state/github-token")
        for entry in read_json(root / ".state/organizations.json", {}).values():
            remote = next((item for item in api.runners(entry["login"]) if item["id"] == entry["runner_id"]), None)
            print("%s: %s" % (entry["login"], json.dumps(remote or {"status": "missing"})))
    else:
        supervisor = Supervisor(root)
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda *_: supervisor.stop_event.set())
        with single_instance(root / ".state/service.lock"):
            supervisor.serve()


if __name__ == "__main__":
    main()
