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
        self.api.remote.setdefault(org, []).append({"id": runner_id, "name": "local-" + self.system, "busy": False})
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
        self.api.remote["alpha"] = [{"id": 999, "name": "local-" + self.system}]
        self.supervisor.reconcile()
        self.configure.assert_not_called()
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
            self.assertEqual(args[args.index("--labels") + 1], "local-" + self.system)


class RuntimeTests(unittest.TestCase):
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
        root = Path('/tmp/path with spaces/100%/macos')
        unit = install_service.linux_unit(root, 'tester', '/home/tester', '/usr/bin')
        self.assertIn('User=tester', unit)
        self.assertIn('100%%', unit)
        self.assertIn('Restart=always', unit)
        plist = install_service.macos_plist(root, 'tester', '/Users/tester', '/usr/bin', 'test.runner')
        self.assertEqual(plist['UserName'], 'tester')
        self.assertTrue(plist['RunAtLoad'])
        self.assertTrue(plist['KeepAlive'])
        self.assertFalse(plist['AbandonProcessGroup'])


if __name__ == '__main__':
    unittest.main()
