"""iPhone bundle version derivation from the shared release identity."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ios_version import bundle_versions, env_lines
import release_version

ROOT = Path(__file__).resolve().parents[1]


class IOSVersionTest(unittest.TestCase):
    def test_pre_release_keeps_numeric_marketing_version(self):
        versions = bundle_versions(release_version.parse("version=0.1.0-beta.1\nandroid_version_code=2\n"))
        self.assertEqual(versions, {
            "MICDROP_MARKETING_VERSION": "0.1.0",
            "MICDROP_BUILD_NUMBER": "2",
            "MICDROP_VERSION_NAME": "0.1.0-beta.1",
        })

    def test_release_version_is_used_unchanged(self):
        versions = bundle_versions(release_version.parse("version=1.12.3\nandroid_version_code=40\n"))
        self.assertEqual(versions["MICDROP_MARKETING_VERSION"], "1.12.3")
        self.assertEqual(versions["MICDROP_VERSION_NAME"], "1.12.3")
        self.assertEqual(versions["MICDROP_BUILD_NUMBER"], "40")

    def test_env_lines_format(self):
        lines = env_lines(bundle_versions(release_version.parse("version=2.0.0-rc.3\nandroid_version_code=7\n")))
        self.assertEqual(lines, "MICDROP_MARKETING_VERSION=2.0.0\nMICDROP_BUILD_NUMBER=7\nMICDROP_VERSION_NAME=2.0.0-rc.3\n")

    def test_invalid_metadata_is_rejected(self):
        with self.assertRaises(ValueError):
            release_version.parse("version=0.1.0-dev\nandroid_version_code=2\n")

    def test_cli_reads_the_repository_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "internal" / "version").mkdir(parents=True)
            (root / release_version.VERSION_PATH).write_text("version=3.4.5-alpha.2\nandroid_version_code=9\n",
                                                             encoding="utf-8")
            output = subprocess.check_output([sys.executable, str(ROOT / "tools" / "ios_version.py"),
                                              "--root", str(root)], text=True)
        self.assertEqual(output, "MICDROP_MARKETING_VERSION=3.4.5\nMICDROP_BUILD_NUMBER=9\n"
                                 "MICDROP_VERSION_NAME=3.4.5-alpha.2\n")


if __name__ == "__main__":
    unittest.main()
