"""Test only the credential-definition block; never source or run the startup script."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest


WORKSPACE = Path(__file__).resolve().parents[2]
SCRIPT = WORKSPACE / "scripts/start_ogg_services.sh"
BASH = shutil.which("bash")


class StartupCredentialsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_text(encoding="utf-8")
        match = re.search(r"^# Connection Strings:[^\n]*\n(.*?)\n# -+", cls.source, re.M | re.S)
        if not match:
            raise AssertionError("Missing isolated credential-definition block")
        cls.block = match.group(1)

    def run_block(self, password=None, user=None, trace=False):
        if not BASH:
            self.skipTest("Bash is required to test the isolated credential block")
        environment = dict(os.environ)
        for key in ("OGG_ADMIN_PASSWORD", "OGG_ADMIN_USER", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
            environment.pop(key, None)
        if password is not None:
            environment["OGG_ADMIN_PASSWORD"] = password
        if user is not None:
            environment["OGG_ADMIN_USER"] = user
        command = "set -eu\n" + self.block + '\nprintf "%s\\n" "$CONN_SM" "$CONN_DB" "$CONN_DAA"\n'
        args = [BASH, "--noprofile", "--norc"]
        if trace:
            args.append("-x")
        return subprocess.run(args + ["-c", command], env=environment, text=True, capture_output=True, timeout=10)

    def test_password_guard_precedes_startup(self):
        self.assertIn('${OGG_ADMIN_PASSWORD:?', self.block)
        self.assertLess(self.source.index('${OGG_ADMIN_PASSWORD:?'), self.source.index("main()"))
        self.assertEqual(self.block.count("password ${OGG_ADMIN_PASSWORD}"), 3)
        self.assertTrue(self.block.startswith("set +x\n"))

    def test_missing_or_empty_password_fails(self):
        for password in (None, ""):
            with self.subTest(password=password):
                result = self.run_block(password=password)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Set OGG_ADMIN_PASSWORD", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_configured_connections(self):
        for user, expected_user in ((None, "oggadmin"), ("test-admin", "test-admin")):
            with self.subTest(user=user):
                result = self.run_block(password="offline-dummy-password", user=user)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    f"connect https://localhost:{port} deployment {deployment} as {expected_user} password offline-dummy-password"
                    for port, deployment in ((7801, "ServiceManager"), (7862, "ogg_oracle03"), (7872, "ogg_daa03"))
                ])

    def test_connection_password_not_in_shell_trace(self):
        result = self.run_block(password="offline-trace-sentinel", trace=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("offline-trace-sentinel", result.stderr)


if __name__ == "__main__":
    unittest.main()
