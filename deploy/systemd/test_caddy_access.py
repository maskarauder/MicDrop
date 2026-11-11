import importlib.util
import os
from pathlib import Path, PurePosixPath
import pwd
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("caddy_access", Path(__file__).with_name("caddy-access.py"))
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)


class PathTests(unittest.TestCase):
    def test_only_selected_caddy_subtree(self):
        for invalid in ("/etc/shadow", "/var/lib/caddy/../secret", "relative/cert", "/var/lib/caddy"):
            with self.assertRaises(ValueError):
                access.checked_path(invalid)
        self.assertEqual(access.checked_path("/var/lib/caddy/private/site/cert.pem"),
                         PurePosixPath("/var/lib/caddy/private/site/cert.pem"))


@unittest.skipUnless(os.geteuid() == 0 and shutil.which("setfacl") and shutil.which("runuser"),
                     "real ACL contracts require root, acl and runuser (enabled in CI)")
class AccessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.parent.chmod(0o755)
        self.root = self.parent / "caddy"
        self.root.mkdir(mode=0o700)
        self.site = self.root / "certificates" / "site"
        self.site.mkdir(parents=True, mode=0o700)
        self.file = self.site / "cert.pem"
        self.file.write_text("synthetic certificate fixture")
        self.file.chmod(0o600)
        self.uid = pwd.getpwnam("nobody").pw_uid
        original = access.CADDY_ROOT
        access.CADDY_ROOT = PurePosixPath(self.root)
        self.addCleanup(setattr, access, "CADDY_ROOT", original)

    def allowed(self, flag, path):
        return subprocess.run(["runuser", "-u", "nobody", "--", "test", flag, str(path)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

    def test_read_only_access_survives_file_replacement_after_refresh(self):
        unrelated = self.site / "other.key"
        unrelated.write_text("unrelated synthetic fixture"); unrelated.chmod(0o600)
        self.assertFalse(self.allowed("-r", self.file))
        access.grant_file(self.file, self.uid)
        self.assertTrue(self.allowed("-r", self.file))
        self.assertFalse(self.allowed("-w", self.file))
        self.assertFalse(self.allowed("-r", self.site))  # no listing
        self.assertFalse(self.allowed("-w", self.site))
        self.assertFalse(self.allowed("-r", unrelated))
        replacement = self.site / "replacement"
        replacement.write_text("renewed synthetic fixture"); replacement.chmod(0o600)
        replacement.replace(self.file)
        self.assertFalse(self.allowed("-r", self.file))
        access.grant_file(self.file, self.uid)
        self.assertTrue(self.allowed("-r", self.file))
        self.assertFalse(self.allowed("-w", self.file))
        self.assertFalse(self.allowed("-r", unrelated))

    def test_refuses_symlink_hardlink_and_nonregular_file(self):
        outside = self.parent / "unrelated"
        outside.write_text("unrelated fixture"); outside.chmod(0o600)
        self.file.unlink(); self.file.symlink_to(outside)
        with self.assertRaises(OSError): access.grant_file(self.file, self.uid)
        self.file.unlink(); os.link(outside, self.file)
        with self.assertRaises(ValueError): access.grant_file(self.file, self.uid)
        self.file.unlink(); os.mkfifo(self.file)
        with self.assertRaises(ValueError): access.grant_file(self.file, self.uid)
        self.file.unlink()
        linked_directory = self.root / "linked"
        linked_directory.symlink_to(self.parent, target_is_directory=True)
        with self.assertRaises(OSError): access.grant_file(linked_directory / "unrelated", self.uid)
        self.assertFalse(self.allowed("-r", outside))


if __name__ == "__main__":
    unittest.main()
