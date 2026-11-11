# SPDX-License-Identifier: MPL-2.0
"""Verify macOS MicDrop.app assembly, Mach-O arm64/14.2 checks, Info.plist privacy keys, and zip safety."""

from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macos_app_bundle as bundle  # noqa: E402
import release_version  # noqa: E402


def encoded(version):
    return version[0] << 16 | version[1] << 8 | (version[2] if len(version) > 2 else 0)


def make_macho(
    filetype=bundle.MH_EXECUTE,
    minimum=(14, 2),
    cputype=bundle.CPU_TYPE_ARM64,
    platform=bundle.PLATFORM_MACOS,
    legacy=False,
):
    if legacy:
        cmd = bundle.VERSION_MIN.pack(
            bundle.LC_VERSION_MIN_MACOSX,
            bundle.VERSION_MIN.size,
            encoded(minimum),
            encoded((26, 6)),
        )
    else:
        cmd = bundle.BUILD_VERSION.pack(
            bundle.LC_BUILD_VERSION,
            bundle.BUILD_VERSION.size,
            platform,
            encoded(minimum),
            encoded((26, 6)),
            0,
        )
    header = bundle.MACH_HEADER_64.pack(
        bundle.MH_MAGIC_64, cputype, 0, filetype, 1, len(cmd), 0, 0
    )
    return header + cmd + bytes(32)


class MacOSAppBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.exe = self.base / "MicDrop"
        self.dylib = self.base / "libmicdrop_rtc.dylib"
        self.webrtc_notice = self.base / "WEBRTC-NOTICE.txt"
        self.webrtc_versions = self.base / "WEBRTC-VERSIONS.txt"
        self.exe.write_bytes(make_macho(bundle.MH_EXECUTE, (14, 2)))
        self.dylib.write_bytes(make_macho(bundle.MH_DYLIB, (14, 2)))
        self.webrtc_notice.write_text("WebRTC notice\n", encoding="utf-8")
        self.webrtc_versions.write_text("webrtc=m137\n", encoding="utf-8")
        self.app_out = self.base / "out" / "MicDrop.app"
        self.zip_out = self.base / "dist" / "MicDrop-macos-arm64-app.zip"

    def build_valid(self, revision="abcdef012345"):
        return bundle.build_app_bundle(
            self.exe,
            self.dylib,
            self.webrtc_notice,
            self.webrtc_versions,
            self.app_out,
            revision=revision,
        )

    def test_build_check_and_deterministic_zip_succeed(self):
        app = self.build_valid()
        bundle.check_app_directory(app, revision="abcdef012345")
        digest1 = bundle.zip_app_bundle(app, self.zip_out, revision="abcdef012345")
        second_zip = self.base / "dist" / "second.zip"
        digest2 = bundle.zip_app_bundle(app, second_zip, revision="abcdef012345")
        self.assertEqual(digest1, digest2)

        shared = release_version.read()
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], shared["version"].split("-", 1)[0])
        self.assertEqual(info["CFBundleVersion"], str(shared["android_version_code"]))
        self.assertEqual(info["MicDropVersionName"], shared["version"])
        self.assertNotIn("CFBundleIconFile", info)

    def test_rejects_wrong_architecture_or_higher_deployment_target(self):
        x86_64 = 0x01000007
        self.exe.write_bytes(make_macho(bundle.MH_EXECUTE, (14, 2), cputype=x86_64))
        with self.assertRaisesRegex(ValueError, "arm64 Mach-O executable"):
            self.build_valid()

        self.exe.write_bytes(make_macho(bundle.MH_EXECUTE, (15, 0)))
        with self.assertRaisesRegex(ValueError, "exceeds 14.2"):
            self.build_valid()

        self.exe.write_bytes(make_macho(bundle.MH_EXECUTE, (14, 2)))
        self.dylib.write_bytes(make_macho(bundle.MH_DYLIB, (26, 0)))
        with self.assertRaisesRegex(ValueError, "exceeds 14.2"):
            self.build_valid()

    def test_rejects_missing_privacy_keys_or_custom_icon_or_missing_notice(self):
        app = self.build_valid()
        info_path = app / "Contents" / "Info.plist"
        original = plistlib.loads(info_path.read_bytes())

        for key in ("NSAudioCaptureUsageDescription", "NSLocalNetworkUsageDescription", "NSBonjourServices"):
            mutated = dict(original)
            mutated.pop(key)
            info_path.write_bytes(plistlib.dumps(mutated))
            with self.subTest(missing=key), self.assertRaises(ValueError):
                bundle.check_app_directory(app)

        with_icon = dict(original, CFBundleIconFile="AppIcon.icns")
        info_path.write_bytes(plistlib.dumps(with_icon))
        with self.assertRaisesRegex(ValueError, "custom icon"):
            bundle.check_app_directory(app)

        info_path.write_bytes(plistlib.dumps(original))
        (app / "Contents" / "Resources" / "WEBRTC-NOTICE.txt").unlink()
        with self.assertRaisesRegex(ValueError, "WEBRTC-NOTICE.txt"):
            bundle.check_app_directory(app)

    def test_rejects_symlinks_and_unsafe_zip_entries(self):
        app = self.build_valid()
        secret = self.base / "secret.txt"
        secret.write_text("secret", encoding="utf-8")
        link = app / "Contents" / "Resources" / "extra-link"
        try:
            link.symlink_to(secret)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks unavailable")
        with self.assertRaisesRegex(ValueError, "Symbolic links"):
            bundle.check_app_directory(app)
        link.unlink()

        bundle.zip_app_bundle(app, self.zip_out, revision="abcdef012345")
        bad_zip = self.base / "bad.zip"
        with zipfile.ZipFile(self.zip_out) as src, zipfile.ZipFile(bad_zip, "w") as dst:
            for item in src.infolist():
                dst.writestr(item, src.read(item.filename))
            sym = zipfile.ZipInfo("MicDrop.app/Contents/Resources/link")
            sym.external_attr = (stat.S_IFLNK | 0o777) << 16
            dst.writestr(sym, b"/etc/passwd")
        with self.assertRaisesRegex(ValueError, "symbolic link"):
            bundle.check_app_zip(bad_zip)


if __name__ == "__main__":
    unittest.main()
