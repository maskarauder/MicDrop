# SPDX-License-Identifier: MPL-2.0
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT_PATH = Path(__file__).resolve().parent / "ci_apt_install.sh"


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


@unittest.skipIf(os.name == "nt" or shutil.which("bash") is None, "POSIX bash helper test")
class CiAptInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin_dir = self.base / "bin"
        self.bin_dir.mkdir()
        self.log_file = self.base / "calls.log"
        self.mirrors_file = self.base / "apt-mirrors.txt"
        self.os_release = self.base / "os-release"
        self.os_release.write_text('VERSION_CODENAME="noble"\n', encoding="utf-8")
        self.stamp_file = self.base / "apt-updated.stamp"

        _write_executable(
            self.bin_dir / "sudo",
            '#!/usr/bin/env bash\nexec "$@"\n',
        )

    def _base_env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["MICDROP_APT_MIRRORS_FILE"] = str(self.mirrors_file)
        env["MICDROP_OS_RELEASE_FILE"] = str(self.os_release)
        env["MICDROP_APT_STAMP_FILE"] = str(self.stamp_file)
        env["MICDROP_APT_RETRY_DELAY_SECONDS"] = "0"
        env["FAKE_CALL_LOG"] = str(self.log_file)
        env.update(extra)
        return env

    def test_preserves_multiple_healthy_mirrors_and_caches_update_across_installs(self):
        self.mirrors_file.write_text(
            "http://dead.clouds.archive.ubuntu.com/ubuntu/\tpriority:1\n"
            "https://mirrors.edge.kernel.org/ubuntu/\tpriority:2\n",
            encoding="utf-8",
        )
        _write_executable(
            self.bin_dir / "curl",
            """#!/usr/bin/env bash
url="${!#}"
case "$url" in
  http://dead.clouds.archive.ubuntu.com/* | https://ftp.osuosl.org/*)
    exit 22
    ;;
  *)
    exit 0
    ;;
esac
""",
        )
        _write_executable(
            self.bin_dir / "apt-get",
            """#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$FAKE_CALL_LOG"
exit 0
""",
        )

        env = self._base_env()
        subprocess.run(["bash", str(SCRIPT_PATH), "install", "xvfb", "xauth"], env=env, check=True)
        subprocess.run(["bash", str(SCRIPT_PATH), "install", "pulseaudio"], env=env, check=True)

        mirrors_lines = self.mirrors_file.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(
            mirrors_lines,
            [
                "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1",
                "https://mirrors.edge.kernel.org/ubuntu/\tpriority:2",
                "https://archive.ubuntu.com/ubuntu/\tpriority:3",
            ],
        )

        calls = self.log_file.read_text(encoding="utf-8").strip().splitlines()
        updates = [line for line in calls if line.endswith(" update")]
        installs = [line for line in calls if " install " in line]
        self.assertEqual(len(updates), 1, calls)
        self.assertEqual(len(installs), 2, calls)
        self.assertIn("--fix-missing", installs[0])

    def test_keeps_existing_mirrors_when_all_probes_fail_and_retries_transient_install_error(self):
        original = "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n"
        self.mirrors_file.write_text(original, encoding="utf-8")
        fail_marker = self.base / "fail-once"
        fail_marker.write_text("1", encoding="utf-8")

        _write_executable(
            self.bin_dir / "curl",
            "#!/usr/bin/env bash\nexit 28\n",
        )
        _write_executable(
            self.bin_dir / "apt-get",
            f"""#!/usr/bin/env bash
printf 'apt-get %s\\n' "$*" >> "$FAKE_CALL_LOG"
if [[ " $* " == *" install "* ]] && [ -f "{fail_marker}" ]; then
  rm -f "{fail_marker}"
  exit 100
fi
exit 0
""",
        )

        env = self._base_env()
        subprocess.run(["bash", str(SCRIPT_PATH), "install", "acl"], env=env, check=True)

        # Because all curl probes failed and only 1 install retry was needed,
        # the original mirrors file was never overwritten with an empty file.
        self.assertEqual(self.mirrors_file.read_text(encoding="utf-8"), original)

        calls = self.log_file.read_text(encoding="utf-8").strip().splitlines()
        updates = [line for line in calls if line.endswith(" update")]
        installs = [line for line in calls if " install " in line]
        self.assertEqual(len(updates), 2, calls)
        self.assertEqual(len(installs), 2, calls)

    def test_second_install_retry_switches_to_fallback_mirrors(self):
        self.mirrors_file.write_text(
            "https://mirrors.edge.kernel.org/ubuntu/\tpriority:1\n",
            encoding="utf-8",
        )
        counter_file = self.base / "install-count"
        counter_file.write_text("0", encoding="utf-8")

        _write_executable(
            self.bin_dir / "curl",
            """#!/usr/bin/env bash
url="${!#}"
case "$url" in
  https://mirrors.edge.kernel.org/*)
    exit 0
    ;;
  *)
    exit 22
    ;;
esac
""",
        )
        _write_executable(
            self.bin_dir / "apt-get",
            f"""#!/usr/bin/env bash
printf 'apt-get %s\\n' "$*" >> "$FAKE_CALL_LOG"
if [[ " $* " == *" install "* ]]; then
  n=$(cat "{counter_file}")
  n=$((n + 1))
  printf '%s' "$n" > "{counter_file}"
  if [ "$n" -le 2 ]; then
    exit 100
  fi
fi
exit 0
""",
        )

        env = self._base_env()
        subprocess.run(["bash", str(SCRIPT_PATH), "install", "pulseaudio"], env=env, check=True)

        mirrors_lines = self.mirrors_file.read_text(encoding="utf-8").strip().splitlines()
        self.assertEqual(
            mirrors_lines,
            [
                "http://archive.ubuntu.com/ubuntu/\tpriority:1",
                "http://azure.archive.ubuntu.com/ubuntu/\tpriority:2",
            ],
        )


if __name__ == "__main__":
    unittest.main()
