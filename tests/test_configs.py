"""Canonical config and deployer checks using disposable profiles only."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONFIGS = ROOT / "pi_configs"
DEPLOYER = CONFIGS / "setup-pi-config.sh"
MAPPINGS = {
    "models.json": ".pi/agent/models.json",
    "settings.json": ".pi/agent/settings.json",
    "permission-mode.json": ".pi/agent/permission-mode/permission-mode.json",
    "friendly-model-footer.ts": ".pi/agent/extensions/friendly-model-footer.ts",
    "web-search.json": ".pi/web-search.json",
}


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pi-config-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = {"HOME": str(self.home), "TMPDIR": str(self.home),
                    "PATH": "/usr/bin:/bin"}

    def deploy(self, *args, expected=0):
        result = subprocess.run(["bash", str(DEPLOYER), *args], cwd=ROOT,
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_canonical_json_is_valid(self):
        for file in CONFIGS.glob("*.json"):
            with self.subTest(file=file.name):
                self.assertIsInstance(json.loads(file.read_text()), dict)

    def test_sandbox_modes_inherit_current_security_defaults(self):
        config = json.loads((CONFIGS / "permission-mode.json").read_text())
        for name in ("default", "plan", "build"):
            with self.subTest(mode=name):
                sandbox = config["modes"][name]["sandbox"]
                self.assertNotIn("allowWrite", sandbox)
                self.assertNotIn("denyRead", sandbox)
                self.assertTrue(sandbox["enabled"])
                self.assertEqual(sandbox["writable"], name != "plan")

    def test_custom_unsandboxed_mode_is_explicit(self):
        mode = json.loads((CONFIGS / "permission-mode.json").read_text())["modes"]["host-nosandbox"]
        self.assertFalse(mode["sandbox"]["enabled"])
        self.assertTrue(mode["sandbox"]["writable"])
        self.assertEqual(mode["permission"]["external_directory"], "ask")
        self.assertEqual(mode["permission"]["write"], "ask")

    def test_check_reports_drift_without_creating_profile(self):
        result = self.deploy("--check", expected=1)
        self.assertIn("Drift detected: 5 file(s)", result.stdout)
        self.assertFalse((self.home / ".pi").exists())

    def test_sync_shared_profile_then_check_is_clean(self):
        self.deploy("--yes")
        for source, destination in MAPPINGS.items():
            self.assertEqual((self.home / destination).read_bytes(),
                             (CONFIGS / source).read_bytes())
        self.assertIn("In sync", self.deploy("--check").stdout)
        self.assertFalse((self.home / ".local").exists())

    def test_target_aliases_do_not_create_separate_profiles(self):
        self.deploy("--yes", "--target", "host")
        paths = [self.home / path for path in MAPPINGS.values()]
        mtimes = [path.stat().st_mtime_ns for path in paths]
        for target in ("docker", "both"):
            with self.subTest(target=target):
                self.deploy("--yes", "--target", target)
                self.assertEqual([path.stat().st_mtime_ns for path in paths], mtimes)
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse(list(self.home.rglob("*.bak")))

    def test_sync_backups_and_restore_preserve_previous_config(self):
        self.deploy("--yes")
        config = self.home / MAPPINGS["permission-mode.json"]
        previous = '{"custom": "preserve-me"}\n'
        config.write_text(previous)
        self.deploy("--yes")
        backup = Path(str(config) + ".bak")
        self.assertEqual(backup.read_text(), previous)
        self.assertEqual(config.read_bytes(), (CONFIGS / "permission-mode.json").read_bytes())
        self.deploy("--restore", "--yes")
        self.assertEqual(config.read_text(), previous)
        self.assertFalse(backup.exists())

    def test_restore_without_backups_is_noop(self):
        self.assertIn("Nothing to restore", self.deploy("--restore", "--yes").stdout)
        self.assertFalse((self.home / ".pi").exists())

    def test_conflicting_check_restore_flags_are_rejected(self):
        result = self.deploy("--check", "--restore", expected=1)
        self.assertIn("mutually exclusive", result.stderr)
        self.assertFalse((self.home / ".pi").exists())

    def test_deployer_refuses_symlink_destinations(self):
        target = self.home / "untouched.json"
        target.write_text('{"sentinel": true}\n')
        destination = self.home / MAPPINGS["models.json"]
        destination.parent.mkdir(parents=True)
        destination.symlink_to(target)
        result = self.deploy("--yes", expected=1)
        self.assertIn("Destination is a symlink", result.stderr)
        self.assertEqual(target.read_text(), '{"sentinel": true}\n')


if __name__ == "__main__":
    unittest.main()
