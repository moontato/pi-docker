"""Offline regression tests for the generated launcher/image (no Docker daemon)."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install-pi-docker.sh"
IMAGE = "local/pi-docker:latest"


def generated(source, name):
    marker = name + "_CONTENT"
    return source.split("<<'" + marker + "'\n", 1)[1].split("\n" + marker, 1)[0] + "\n"


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pi-docker-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.log = self.root / "docker.jsonl"
        self.home.mkdir()
        self.bin.mkdir()
        # Do not inherit real credentials or host-specific Pi/XDG settings.
        self.env = {
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.root),
            "DOCKER_TEST_LOG": str(self.log),
        }
        self.source = INSTALLER.read_text()
        self.launcher = self.bin / "pi-docker"
        self.entrypoint = self.bin / "entrypoint"
        executable(self.launcher, generated(self.source, "LAUNCHER"))
        executable(self.entrypoint, generated(self.source, "ENTRYPOINT"))
        executable(self.bin / "docker", """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['image', 'inspect'] and '--format' in args:
    print(os.environ.get('DOCKER_TEST_LABEL', '3'))
if args and args[0] == 'build':
    from pathlib import Path
    context = {p.name: p.read_text() for p in Path(args[-1]).iterdir() if p.is_file()}
    Path(os.environ['DOCKER_TEST_LOG'] + '.context').write_text(json.dumps(context))
if '--entrypoint' in args:
    entrypoint = args[args.index('--entrypoint') + 1]
    if entrypoint == 'pi':
        print(os.environ.get('DOCKER_TEST_PI_VERSION', '1.0.0'))
    elif entrypoint == 'curl':
        sys.exit(int(os.environ.get('DOCKER_TEST_NETWORK_FAIL', '0')))
""")

    def run_script(self, script, *args, expected=0):
        result = subprocess.run(
            ["bash", str(script), *args], cwd=ROOT, env=self.env,
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def launch(self, *args, expected=0):
        return self.run_script(self.launcher, *args, expected=expected)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def runtime_call(self):
        return self.calls()[-1]

    def mounts(self, args):
        return [args[i + 1] for i, arg in enumerate(args) if arg == "--mount"]

    def prepare_profile(self, isolated=False):
        agent = (self.home / ".local/share/pi-docker/agent" if isolated
                 else self.home / ".pi/agent")
        for package in ("pi-permission-modes", "pi-ext-int-search"):
            (agent / "npm/node_modules" / package).mkdir(parents=True)
        (agent / "auth.json").write_text('{"test": {"key": "never-print-this"}}\n')
        (self.home / ".local/share/pi-docker/home").mkdir(parents=True, exist_ok=True)
        (self.home / ".config/pi-docker").mkdir(parents=True, exist_ok=True)
        return agent

    def fake_user_commands(self, existing=True):
        executable(self.bin / "getent", "#!/bin/sh\nexit " + ("0\n" if existing else "1\n"))
        for command in ("groupadd", "useradd"):
            executable(self.bin / command, """#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$DOCKER_TEST_LOG"
""")
        # Reproduce real gosu's HOME reset for the base image's existing node user.
        executable(self.bin / "gosu", """#!/bin/sh
shift
export HOME=/home/node
exec "$@"
""")
        executable(self.bin / "pi", """#!/usr/bin/env python3
import json, os, sys
print(json.dumps({'home': os.environ['HOME'],
                  'agent': os.environ.get('PI_CODING_AGENT_DIR',
                                          os.path.join(os.environ['HOME'], '.pi', 'agent')),
                  'args': sys.argv[1:]}))
""")
        self.env.update(PI_DOCKER_UID="1000", PI_DOCKER_GID="1000")

    def test_generated_shell_syntax(self):
        for script in (INSTALLER, self.launcher, self.entrypoint):
            subprocess.run(["bash", "-n", str(script)], check=True)
        subprocess.run(["sh", "-n", str(self.entrypoint)], check=True)

    def test_shared_profile_and_host_resolver(self):
        self.launch("--version")
        args = self.runtime_call()
        mounts = self.mounts(args)
        self.assertIn(f"type=bind,source={self.home}/.pi,target=/home/pi/.pi", mounts)
        # An explicit override would bypass ~/.pi/web-search.json discovery.
        self.assertFalse(any(arg.startswith("PI_CODING_AGENT_DIR=") for arg in args))
        self.assertIn("--network=host", args)
        self.assertIn("type=bind,source=/etc/resolv.conf,target=/etc/resolv.conf,readonly", mounts)
        self.assertFalse(any(arg.startswith("--dns") for arg in args))
        self.assertEqual(args[-2:], [IMAGE, "--version"])

    def test_isolated_profile(self):
        self.launch("--isolated", "--version")
        args = self.runtime_call()
        self.assertIn(f"type=bind,source={self.home}/.local/share/pi-docker/agent,target=/pi-agent",
                      self.mounts(args))
        self.assertIn("PI_CODING_AGENT_DIR=/pi-agent", args)
        self.assertFalse(any("target=/home/pi/.pi" in mount for mount in self.mounts(args)))
        self.assertFalse((self.home / ".pi").exists())

    def test_no_tailnet_leaves_docker_dns_alone(self):
        self.launch("--no-tailnet", "--version")
        args = self.runtime_call()
        self.assertNotIn("--network=host", args)
        self.assertFalse(any("resolv.conf" in mount for mount in self.mounts(args)))
        self.assertFalse(any(arg.startswith("PI_CODING_AGENT_DIR=") for arg in args))

    def test_project_spaces_and_pi_args_are_preserved(self):
        project = self.root / "project with spaces"
        project.mkdir()
        self.launch("--project", str(project), "-p", "hello world", "--model", "test")
        args = self.runtime_call()
        self.assertIn(f"type=bind,source={project},target=/workspace", self.mounts(args))
        self.assertEqual(args[-5:], [IMAGE, "-p", "hello world", "--model", "test"])

    def test_only_allowlisted_provider_environment_is_forwarded(self):
        self.env.update(OPENAI_API_KEY="fake-key", UNRELATED_SECRET="must-not-forward",
                        PI_CODING_AGENT_DIR="/some/host/path")
        self.launch("--version")
        args = self.runtime_call()
        self.assertIn("OPENAI_API_KEY=fake-key", args)
        self.assertNotIn("UNRELATED_SECRET=must-not-forward", args)
        self.assertNotIn("PI_CODING_AGENT_DIR=/some/host/path", args)

    def test_uid_1000_collision_restores_home_after_gosu(self):
        self.fake_user_commands()
        result = self.run_script(self.entrypoint, "-p", "hello world")
        data = json.loads(result.stdout)
        self.assertEqual(data["home"], "/home/pi")
        self.assertEqual(data["agent"], "/home/pi/.pi/agent")
        self.assertEqual(data["args"], ["-p", "hello world"])
        self.assertFalse(self.log.exists(), "Existing users/groups should not be modified")

    def test_new_uid_creation_and_isolated_home(self):
        self.fake_user_commands(existing=False)
        self.env.update(PI_DOCKER_UID="12345", PI_DOCKER_GID="23456",
                        PI_CODING_AGENT_DIR="/pi-agent")
        result = self.run_script(self.entrypoint, "--version")
        self.assertEqual(json.loads(result.stdout)["home"], "/home/pi")
        self.assertEqual(json.loads(result.stdout)["agent"], "/pi-agent")
        commands = self.log.read_text()
        self.assertIn("groupadd --gid 23456 pi-docker", commands)
        self.assertIn("--uid 12345 --gid 23456", commands)
        self.assertIn("--home-dir /home/pi", commands)

    def test_invalid_uid_is_rejected(self):
        self.fake_user_commands()
        self.env["PI_DOCKER_UID"] = "not-a-uid"
        result = self.run_script(self.entrypoint, expected=1)
        self.assertIn("Invalid PI_DOCKER_UID", result.stderr)

    def test_fd_is_in_image_and_image_version_is_bumped(self):
        dockerfile = generated(self.source, "DOCKERFILE")
        self.assertIn("fd-find", dockerfile)
        self.assertIn("ln -s /usr/bin/fdfind /usr/local/bin/fd", dockerfile)
        self.assertIn('LABEL io.pi-docker.installer="3"', dockerfile)
        self.assertIn("IMAGE_VERSION=3", self.source)

    def test_doctor_probes_selected_container_network_and_profile(self):
        agent = self.prepare_profile()
        result = self.launch("doctor")
        self.assertIn(str(agent), result.stdout)
        self.assertNotIn("never-print-this", result.stdout + result.stderr)
        probes = [call for call in self.calls() if "--entrypoint" in call
                  and call[call.index("--entrypoint") + 1] == "curl"]
        self.assertEqual({call[-1] for call in probes},
                         {"https://github.com", "https://auth.openai.com"})
        for call in probes:
            self.assertIn("--network=host", call)
            self.assertIn("type=bind,source=/etc/resolv.conf,target=/etc/resolv.conf,readonly",
                          self.mounts(call))
            self.assertNotIn("--tty", call)
        profile_probe = next(call for call in self.calls()
                             if call[-1].startswith("\n            exec gosu"))
        # Validate nested shell quoting, even though Docker itself is stubbed.
        subprocess.run(["sh", "-n", "-c", profile_probe[-1]], check=True)
        self.assertIn('agent_dir=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}', profile_probe[-1])
        self.assertIn('test -r "$agent_dir/auth.json"', profile_probe[-1])

    def test_doctor_respects_no_tailnet_and_isolated(self):
        agent = self.prepare_profile(isolated=True)
        result = self.launch("doctor", "--no-tailnet", "--isolated")
        self.assertIn(str(agent), result.stdout)
        for call in self.calls():
            self.assertNotIn("--network=host", call)
            self.assertFalse(any("resolv.conf" in mount for mount in self.mounts(call)))
        self.assertFalse((self.home / ".pi").exists())

    def test_doctor_reports_network_failure(self):
        self.prepare_profile()
        self.env["DOCKER_TEST_NETWORK_FAIL"] = "6"
        result = self.launch("doctor", expected=1)
        self.assertIn("Container DNS/HTTPS failed: https://auth.openai.com", result.stdout)

    def test_doctor_does_not_create_missing_profile(self):
        result = self.launch("doctor", expected=1)
        self.assertIn("Directory missing", result.stdout)
        self.assertFalse((self.home / ".pi").exists())
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse((self.home / ".config").exists())

    def test_v4_install_upgrades_without_force_and_preserves_auth(self):
        # Fixed regression snapshot, not HEAD (tests remain valid after new commits).
        old = subprocess.run(["git", "show", "066dd5c:install-pi-docker.sh"],
                             cwd=ROOT, text=True, capture_output=True)
        if old.returncode:
            self.skipTest("v4 snapshot unavailable in this checkout")
        config = self.home / ".config/pi-docker"
        agent = self.prepare_profile()
        auth_before = (agent / "auth.json").read_bytes()
        for name, path in (("DOCKERFILE", config / "Dockerfile"),
                           ("ENTRYPOINT", config / "entrypoint.sh"),
                           ("LAUNCHER", self.home / ".local/bin/pi-docker")):
            executable(path, generated(old.stdout, name))
        self.env["DOCKER_TEST_LABEL"] = "2"
        self.run_script(INSTALLER, "--searxng-url", "https://search.example",
                        "--llama-url", "http://localhost:8080")
        self.assertEqual((config / "entrypoint.sh").read_text(),
                         generated(self.source, "ENTRYPOINT"))
        self.assertEqual((self.home / ".local/bin/pi-docker").read_text(),
                         generated(self.source, "LAUNCHER"))
        self.assertEqual((agent / "auth.json").read_bytes(), auth_before)
        self.assertTrue(any(call[0] == "build" for call in self.calls()))

    def test_installer_excludes_saved_keys_from_build_context(self):
        self.prepare_profile()
        config = self.home / ".config/pi-docker"
        (config / "env").write_text("OPENAI_API_KEY=do-not-upload-this-key\n")
        self.run_script(INSTALLER, "--rebuild", "--searxng-url", "https://search.example",
                        "--llama-url", "http://localhost:8080")
        build = next(call for call in self.calls() if call[0] == "build")
        self.assertNotEqual(build[-1], str(config))
        self.assertIn("--no-cache", build)
        self.assertIn("--pull", build)
        context = json.loads(Path(str(self.log) + ".context").read_text())
        self.assertEqual(set(context), {"Dockerfile", "entrypoint.sh", "pi-docker"})
        self.assertNotIn("do-not-upload-this-key", json.dumps(context))

    def test_exact_main_and_feature_launchers_upgrade_without_force(self):
        self.prepare_profile()
        launcher = self.home / ".local/bin/pi-docker"
        for rev in ("0504639", "f0cf6e7"):
            with self.subTest(snapshot=rev):
                old = subprocess.run(["git", "show", rev + ":install-pi-docker.sh"],
                                     cwd=ROOT, text=True, capture_output=True)
                if old.returncode:
                    self.skipTest("upgrade snapshot unavailable in this checkout")
                executable(launcher, generated(old.stdout, "LAUNCHER"))
                self.run_script(INSTALLER, "--searxng-url", "https://search.example",
                                "--llama-url", "http://localhost:8080")
                self.assertEqual(launcher.read_text(), generated(self.source, "LAUNCHER"))

    def test_doctor_reports_pi_version_mismatch(self):
        self.prepare_profile()
        executable(self.bin / "pi", "#!/bin/sh\nprintf '1.2.0\\n'\n")
        self.env["DOCKER_TEST_PI_VERSION"] = "0.87.1"
        result = self.launch("doctor")
        self.assertIn("Pi version mismatch: host 1.2.0, container 0.87.1", result.stdout)
        self.assertIn("--rebuild updates container Pi", result.stdout)

    def test_config_rejects_multiline_values_without_changing_saved_keys(self):
        self.launch("config", "set", "OPENAI_API_KEY", "keep-this-key")
        for value in ("new-key\nPI_DOCKER_DNS=1.1.1.1", "new-key\rhidden-value"):
            with self.subTest(value=value):
                result = self.launch("config", "set", "OPENAI_API_KEY", value, expected=1)
                self.assertIn("must be a single line", result.stderr)
        self.assertEqual(self.launch("config", "get", "OPENAI_API_KEY").stdout.strip(),
                         "keep-this-key")
        listing = self.launch("config", "list").stdout
        self.assertIn("OPENAI_API_KEY=***", listing)
        self.assertNotIn("keep-this-key", listing)

    def test_installer_does_not_overwrite_custom_entrypoint(self):
        config = self.home / ".config/pi-docker"
        config.mkdir(parents=True)
        custom = "#!/bin/sh\necho custom\n"
        (config / "entrypoint.sh").write_text(custom)
        result = self.run_script(INSTALLER, expected=1)
        self.assertIn("differs from this installer", result.stderr)
        self.assertEqual((config / "entrypoint.sh").read_text(), custom)


if __name__ == "__main__":
    unittest.main()
