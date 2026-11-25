import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / "common"))
import manager


class FakeGitHub:
    def __init__(self):
        self.memberships = {"1": "alpha"}
        self.remote = {}
        self.calls = []
        self.denied = set()

    def organizations(self):
        return self.memberships.copy()

    def runners(self, org):
        if org in self.denied:
            raise RuntimeError("HTTP 403")
        return list(self.remote.get(org, []))

    def api(self, endpoint, method="GET"):
        self.calls.append((endpoint, method))
        org = endpoint.split("/")[1]
        if method == "DELETE":
            runner_id = int(endpoint.split("/")[-1])
            self.remote[org] = [row for row in self.remote.get(org, []) if row["id"] != runner_id]
        return {"token": "temporary-registration-token"}


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.system, self.arch = manager.host_platform()
        manager.write_json(self.root / ".state/settings.json", {
            "platform": self.system, "arch": self.arch, "gh": "fake-gh", "poll_seconds": 10,
        })
        self.api = FakeGitHub()
        self.supervisor = manager.Supervisor(self.root, self.api)
        self.package_patch = patch.object(manager, "runner_package", return_value=self.root / "fake-package")
        self.package_patch.start()
        self.addCleanup(self.package_patch.stop)
        self.starts = patch.object(self.supervisor, "start").start()
        self.addCleanup(patch.stopall)
        self.configurations = []
        self.configure = patch.object(self.supervisor, "configure", side_effect=self.fake_configure).start()

    def fake_configure(self, org, directory, package):
        runner_id = 100 + len(self.configurations)
        self.configurations.append(org)
        manager.write_json(directory / "runner/.runner", {"agentId": runner_id})
        (self.root / "data" / org).mkdir(parents=True, exist_ok=True)
        self.api.remote.setdefault(org, []).append({"id": runner_id, "name": "local-%s-%s" % (self.system, self.arch), "busy": False})
        return runner_id

    def test_discovers_and_registers_new_organizations(self):
        self.supervisor.reconcile()
        self.api.memberships["2"] = "beta"
        self.supervisor.reconcile()
        self.assertEqual(self.configurations, ["alpha", "beta"])
        self.assertTrue((self.root / "data/beta").is_dir())
        self.assertEqual(set(manager.read_json(self.supervisor.state_file)), {"1", "2"})

    def test_reconcile_is_idempotent(self):
        self.supervisor.reconcile()
        self.supervisor.reconcile()
        self.assertEqual(self.configure.call_count, 1)

    def test_restarts_from_persisted_state_without_registration(self):
        self.supervisor.reconcile()
        rebooted = manager.Supervisor(self.root, self.api)
        with patch.object(rebooted, "start") as start, patch.object(rebooted, "configure") as configure:
            rebooted.reconcile()
            start.assert_called_once()
            configure.assert_not_called()

    def test_missing_remote_runner_is_registered_again(self):
        self.supervisor.reconcile()
        self.api.remote["alpha"] = []
        self.supervisor.reconcile()
        self.assertEqual(self.configure.call_count, 2)

    def test_other_machine_name_collision_is_preserved(self):
        self.api.remote["alpha"] = [{"id": 999, "name": "local-%s-%s" % (self.system, self.arch)}]
        self.supervisor.reconcile()
        self.configure.assert_not_called()
        self.assertEqual(self.api.calls, [])

    def test_other_architecture_runner_does_not_block_registration(self):
        other_arch = "arm64" if self.arch == "x64" else "x64"
        self.api.remote["alpha"] = [{"id": 999, "name": "local-%s-%s" % (self.system, other_arch)}]
        self.supervisor.reconcile()
        self.configure.assert_called_once()
        self.assertEqual(len(self.api.remote["alpha"]), 2)
        self.assertEqual(self.api.calls, [])

    def test_recovers_registration_after_crash_before_state_save(self):
        self.fake_configure("alpha", self.root / "bin/alpha", None)
        self.supervisor.reconcile()
        self.configure.assert_not_called()
        self.assertEqual(self.supervisor.organizations["1"]["runner_id"], 100)

    def test_missing_local_configuration_recreates_own_idle_runner(self):
        self.supervisor.reconcile()
        (self.root / "bin/alpha/runner/.runner").unlink()
        self.supervisor.reconcile()
        self.assertEqual(self.configure.call_count, 2)
        self.assertIn(("orgs/alpha/actions/runners/100", "DELETE"), self.api.calls)

    def test_organization_rename_preserves_old_data(self):
        self.supervisor.reconcile()
        old = self.root / "data/alpha/repo/keep"
        old.parent.mkdir()
        old.write_text("keep")
        self.api.memberships = {"1": "renamed"}
        self.api.remote["renamed"] = self.api.remote.pop("alpha")
        self.supervisor.reconcile()
        self.assertEqual(self.supervisor.organizations["1"]["login"], "renamed")
        self.assertTrue((self.root / "data/renamed").is_dir())
        self.assertEqual(old.read_text(), "keep")

    def test_busy_runner_defers_organization_rename(self):
        self.supervisor.reconcile()
        self.api.memberships = {"1": "renamed"}
        self.api.remote["renamed"] = self.api.remote.pop("alpha")
        self.api.remote["renamed"][0]["busy"] = True
        self.supervisor.reconcile()
        self.assertEqual(self.configure.call_count, 1)
        self.assertEqual(self.api.calls, [])

    def test_one_permission_failure_does_not_block_other_organizations(self):
        self.api.memberships["2"] = "beta"
        self.api.denied.add("alpha")
        self.supervisor.reconcile()
        self.assertEqual(self.configurations, ["beta"])

    def test_discovery_failure_retains_registration(self):
        self.supervisor.reconcile()
        with patch.object(self.api, "organizations", side_effect=RuntimeError("network")):
            with self.assertRaises(RuntimeError):
                self.supervisor.reconcile()
        self.assertIn("1", self.supervisor.organizations)

    def test_removed_membership_stops_but_retains_directories(self):
        self.supervisor.reconcile()
        self.api.memberships.clear()
        with patch.object(self.supervisor, "stop") as stop:
            self.supervisor.reconcile()
            stop.assert_called_once_with("1")
        self.assertTrue((self.root / "bin/alpha/runner/.runner").exists())
        self.assertFalse(self.supervisor.organizations)

    def test_allowlist_filters_discovery(self):
        self.supervisor.settings["organizations"] = ["BETA"]
        self.api.memberships["2"] = "beta"
        self.supervisor.reconcile()
        self.assertEqual(self.configurations, ["beta"])

    def test_invalid_organization_cannot_escape_bin(self):
        self.api.memberships = {"1": "../escape"}
        self.supervisor.reconcile()
        self.configure.assert_not_called()

    def test_configuration_uses_absolute_organization_work_directory(self):
        patch.stopall()
        directory = self.root / "bin/alpha"
        package = self.root / "package"
        package.mkdir()
        manager.write_json(package / ".runner", {"agentId": 1})
        with patch.object(manager, "launch_script") as launch:
            launch.return_value.wait.return_value = 0
            self.supervisor.configure("alpha", directory, package)
            args = launch.call_args.args[2]
            self.assertEqual(args[args.index("--work") + 1], str((self.root / "data/alpha").resolve()))
            self.assertNotIn("--replace", args)
            self.assertEqual(args[args.index("--labels") + 1], "local-%s-%s" % (self.system, self.arch))


class RuntimeTests(unittest.TestCase):
    def test_native_platform_architecture_detection(self):
        cases = [('Linux', 'x86_64', 'linux', 'x64'), ('Linux', 'aarch64', 'linux', 'arm64'),
                 ('Darwin', 'x86_64', 'macos', 'x64'), ('Darwin', 'arm64', 'macos', 'arm64'),
                 ('Windows', 'AMD64', 'windows', 'x64'), ('Windows', 'ARM64', 'windows', 'arm64')]
        for host, machine, system, arch in cases:
            with self.subTest(system=system, arch=arch), patch.object(manager.platform, 'system', return_value=host), patch.object(manager.platform, 'machine', return_value=machine), patch.dict(os.environ, {'PROCESSOR_ARCHITECTURE': machine, 'PROCESSOR_ARCHITEW6432': ''}), patch.object(manager.subprocess, 'run') as run:
                run.return_value.returncode = 0
                run.return_value.stdout = '1' if arch == 'arm64' else '0'
                self.assertEqual(manager.host_platform(), (system, arch))

    def test_apple_silicon_is_detected_under_rosetta(self):
        with patch.object(manager.platform, 'system', return_value='Darwin'), patch.object(manager.platform, 'machine', return_value='x86_64'), patch.object(manager.subprocess, 'run') as run:
            run.return_value.returncode = 0
            run.return_value.stdout = '1\n'
            self.assertEqual(manager.host_platform(), ('macos', 'arm64'))

    def test_incorrect_architecture_is_rejected_before_preparing_installation(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(manager, 'host_platform', return_value=('linux', 'arm64')):
            root = Path(temporary) / 'linux/x64'
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                manager.prepare(root, 'x64')
            self.assertFalse(root.exists())

    def test_each_architecture_entrypoint_forwards_the_selected_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            (source / 'common').mkdir()
            env = os.environ.copy()
            env['LOCAL_RUNNER_SOURCE_DIR'] = str(source)
            if os.name == 'nt':
                (source / 'common/install_windows.ps1').write_text('param($Architecture)\nWrite-Output $Architecture\n')
                for arch in ('x64', 'arm64'):
                    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(BASE / 'windows' / arch / 'bin/install.ps1')], env=env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), arch)
            else:
                (source / 'common/install_unix.sh').write_text('printf "%s %s\\n" "$1" "${2:-auto}"\n')
                for system in ('linux', 'macos'):
                    for arch in ('x64', 'arm64'):
                        result = subprocess.run(['sh', str(BASE / system / arch / 'bin/install.sh')], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout.strip(), system + ' ' + arch)

    @unittest.skipIf(os.name == 'nt', 'POSIX installer')
    def test_unix_installer_creates_architecture_specific_root_before_privileged_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            commands = base / 'commands'
            commands.mkdir()
            (commands / 'uname').write_text('#!/bin/sh\nif [ "$1" = -s ]; then echo Linux; else echo "$TEST_MACHINE"; fi\n')
            (commands / 'id').write_text('#!/bin/sh\necho 1000\n')
            # Stop before any real dependency installation or system service operation.
            (commands / 'sudo').write_text('#!/bin/sh\nexit 17\n')
            for command in commands.iterdir():
                command.chmod(0o755)
            env = os.environ.copy()
            env.update(PATH=str(commands) + os.pathsep + env['PATH'], LOCAL_RUNNER_HOME=str(base / 'install'))
            for machine, arch in [('x86_64', 'x64'), ('aarch64', 'arm64')]:
                env['TEST_MACHINE'] = machine
                result = subprocess.run(['sh', str(BASE / 'common/install_unix.sh'), 'linux'], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertTrue((base / 'install/linux' / arch / 'bin').is_dir())
                self.assertFalse((base / 'install/linux/bin').exists())

    def test_all_six_registration_names_labels_and_work_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary) / 'package'
            manager.write_json(package / '.runner', {'agentId': 1})
            for system in ('linux', 'macos', 'windows'):
                for arch in ('x64', 'arm64'):
                    with self.subTest(system=system, arch=arch):
                        root = (Path(temporary) / system / arch).resolve()
                        manager.write_json(root / '.state/settings.json', {'platform': system, 'arch': arch, 'gh': 'fake'})
                        supervisor = manager.Supervisor(root, FakeGitHub())
                        with patch.object(manager, 'launch_script') as launch:
                            launch.return_value.wait.return_value = 0
                            supervisor.configure('alpha', root / 'bin/alpha', package)
                            args = launch.call_args.args[2]
                            expected = 'local-%s-%s' % (system, arch)
                            self.assertEqual(args[args.index('--name') + 1], expected)
                            self.assertEqual(args[args.index('--labels') + 1], expected)
                            self.assertEqual(args[args.index('--work') + 1], str(root / 'data/alpha'))

    def test_actual_configuration_script_preserves_arguments_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix="runner test ") as temporary:
            root = Path(temporary).resolve()
            system, arch = manager.host_platform()
            manager.write_json(root / ".state/settings.json", {"platform": system, "arch": arch, "gh": "fake"})
            package = root / "package"
            package.mkdir()
            (package / "probe.py").write_text('import json,sys\nfrom pathlib import Path\nPath("arguments.json").write_text(json.dumps(sys.argv[1:]))\nPath(".runner").write_text(json.dumps({"agentId": 123}))\n')
            if system == "windows":
                (package / "config.cmd").write_text('@echo off\n"%s" probe.py %%*\nexit /b %%ERRORLEVEL%%\n' % sys.executable)
            else:
                import shlex
                (package / "config.sh").write_text('exec %s probe.py "$@"\n' % shlex.quote(sys.executable))
            supervisor = manager.Supervisor(root, FakeGitHub())
            directory = root / "bin/alpha"
            self.assertEqual(supervisor.configure("alpha", directory, package), 123)
            args = manager.read_json(directory / "runner/arguments.json")
            self.assertEqual(args[args.index("--work") + 1], str(root / "data/alpha"))
            self.assertEqual(args[args.index("--token") + 1], "temporary-registration-token")
            self.assertEqual(args[args.index("--name") + 1], "local-%s-%s" % (system, arch))
            self.assertEqual(args[args.index("--labels") + 1], "local-%s-%s" % (system, arch))

    def test_supervisor_restarts_exited_real_process_and_excludes_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            system, arch = manager.host_platform()
            manager.write_json(root / ".state/settings.json", {"platform": system, "arch": arch, "gh": "fake"})
            manager.write_json(root / "bin/alpha/runner/.runner", {"agentId": 1})
            directory = root / "bin/alpha/runner"
            probe = directory / "probe.py"
            probe.write_text('import os\nfrom pathlib import Path\np=Path("calls")\np.write_text(p.read_text()+"x" if p.exists() else "x")\nassert "GH_TOKEN" not in os.environ\n')
            if system == "windows":
                (directory / "run.cmd").write_text('@echo off\n"%s" probe.py\nexit /b %%ERRORLEVEL%%\n' % sys.executable)
            else:
                import shlex
                (directory / "run.sh").write_text('#!/bin/sh\nexec %s probe.py\n' % shlex.quote(sys.executable))
                (directory / "run.sh").chmod(0o755)
            supervisor = manager.Supervisor(root, FakeGitHub())
            entry = {"login": "alpha", "runner_id": 1}
            with patch.dict(os.environ, {"GH_TOKEN": "should-not-reach-job"}):
                supervisor.start("1", entry)
                self.assertEqual(supervisor.processes["1"].wait(timeout=30), 0)
                supervisor.retry_after["1"] = 0
                supervisor.start("1", entry)
                self.assertEqual(supervisor.processes["1"].wait(timeout=30), 0)
            self.assertEqual((directory / "calls").read_text(), "xx")
            self.assertTrue((directory.parent / ("runner.ps1" if system == "windows" else "runner.sh")).exists())

    def test_second_supervisor_lock_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock"
            with manager.single_instance(path):
                with self.assertRaises(OSError):
                    with manager.single_instance(path):
                        self.fail("duplicate service acquired lock")
            with manager.single_instance(path):
                pass

    def test_paginated_organization_and_runner_discovery(self):
        api = manager.GitHub("fake")
        with patch.object(api, "api", return_value=[[{"state": "active", "organization": {"id": 1, "login": "alpha"}}], [{"state": "active", "organization": {"id": 2, "login": "beta"}}]]):
            self.assertEqual(api.organizations(), {"1": "alpha", "2": "beta"})
        with patch.object(api, "api", return_value=[{"runners": [{"id": 1}]}, {"runners": [{"id": 2}]}]):
            self.assertEqual(api.runners("alpha"), [{"id": 1}, {"id": 2}])

    def test_download_digest_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            asset = {"name": "package.zip", "digest": "sha256:" + "0" * 64, "browser_download_url": "https://example.invalid"}
            with patch.object(manager, "download", side_effect=lambda url, target: target.write_bytes(b"bad")):
                with self.assertRaisesRegex(RuntimeError, "mismatch"):
                    manager.verified_asset(asset, temporary)

    def test_zip_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("../escape", "bad")
            with self.assertRaisesRegex(RuntimeError, "Unsafe"):
                manager.extract(archive, Path(temporary) / "out")

    def test_tar_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as package:
                entry = tarfile.TarInfo("escape")
                entry.type = tarfile.SYMTYPE
                entry.linkname = "../../outside"
                package.addfile(entry)
            with self.assertRaisesRegex(RuntimeError, "Unsafe"):
                manager.extract(archive, Path(temporary) / "out")

    @unittest.skipIf(os.name == "nt", "Unix service definitions")
    def test_unix_boot_service_uses_installing_user_and_escaped_paths(self):
        import install_service
        root = Path('/tmp/path with spaces/100%/macos/arm64')
        unit = install_service.linux_unit(root, 'tester', '/home/tester', '/usr/bin')
        self.assertIn('User=tester', unit)
        self.assertIn('100%%', unit)
        self.assertIn('Restart=always', unit)
        plist = install_service.macos_plist(root, 'tester', '/Users/tester', '/usr/bin', 'test.runner')
        self.assertEqual(plist['UserName'], 'tester')
        self.assertTrue(plist['RunAtLoad'])
        self.assertTrue(plist['KeepAlive'])
        self.assertFalse(plist['AbandonProcessGroup'])
        for system in ('linux', 'macos'):
            self.assertNotEqual(install_service.service_name(system, 1000, 'x64'), install_service.service_name(system, 1000, 'arm64'))


if __name__ == '__main__':
    unittest.main()
