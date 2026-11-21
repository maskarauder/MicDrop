# SPDX-License-Identifier: MPL-2.0
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parent / "ci_sdkmanager_install.sh"
PACKAGES = ["platforms;android-36", "build-tools;35.0.0", "emulator"]


@unittest.skipIf(os.name == "nt" or shutil.which("bash") is None, "POSIX bash helper test")
class CiSdkmanagerInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.sdk = self.base / "sdk"
        self.log_file = self.base / "calls.log"
        self.failures_file = self.base / "failures-left"

    def _install_fake_sdkmanager(self, failures):
        """The fake records its arguments one per line and fails its first `failures` calls."""
        tool = self.sdk / "cmdline-tools" / "latest" / "bin" / "sdkmanager"
        tool.parent.mkdir(parents=True)
        self.failures_file.write_text(str(failures), encoding="utf-8")
        tool.write_text(
            f"""#!/usr/bin/env bash
{{ printf 'call\\n'; printf 'arg=%s\\n' "$@"; }} >> "{self.log_file}"
left=$(cat "{self.failures_file}")
if [ "$left" -gt 0 ]; then
  printf '%s' "$((left - 1))" > "{self.failures_file}"
  echo "Warning: An error occurred while preparing SDK package Android Emulator: Error on ZipFile unknown archive." >&2
  exit 1
fi
exit 0
""",
            encoding="utf-8",
        )
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def _run(self, *packages, android_home=None):
        env = dict(os.environ)
        env["ANDROID_HOME"] = str(self.sdk if android_home is None else android_home)
        env["MICDROP_SDKMANAGER_RETRY_DELAY_SECONDS"] = "0"
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), *packages], env=env, capture_output=True, text=True, check=False
        )

    def _calls(self):
        if not self.log_file.exists():
            return []
        calls = []
        for line in self.log_file.read_text(encoding="utf-8").splitlines():
            if line == "call":
                calls.append([])
            else:
                calls[-1].append(line.removeprefix("arg="))
        return calls

    def test_installs_once_when_the_first_attempt_succeeds(self):
        self._install_fake_sdkmanager(failures=0)
        result = self._run(*PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._calls(), [PACKAGES])
        self.assertNotIn("retrying", result.stderr)

    def test_retries_a_damaged_download_with_the_same_packages(self):
        self._install_fake_sdkmanager(failures=2)
        result = self._run(*PACKAGES)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._calls(), [PACKAGES, PACKAGES, PACKAGES])
        self.assertIn("sdkmanager attempt 1/3 failed", result.stderr)
        self.assertIn("sdkmanager attempt 2/3 failed", result.stderr)

    def test_fails_after_three_attempts(self):
        self._install_fake_sdkmanager(failures=5)
        result = self._run(*PACKAGES)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self._calls()), 3)
        self.assertIn("sdkmanager failed after 3 attempts", result.stderr)

    def test_rejects_a_missing_package_list_or_sdk(self):
        self._install_fake_sdkmanager(failures=0)
        self.assertEqual(self._run().returncode, 2)
        missing = self._run(*PACKAGES, android_home=self.base / "missing")
        self.assertEqual(missing.returncode, 2)
        self.assertIn("sdkmanager is not available", missing.stderr)
        self.assertEqual(self._calls(), [])


if __name__ == "__main__":
    unittest.main()
