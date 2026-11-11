"""Dependency selection and checksum contracts; no network or native SDK needed."""
import hashlib
import io
import json
import os
import plistlib
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from fetch_webrtc import fetch

XCFRAMEWORK = "webrtc/Frameworks/WebRTC.xcframework/"
MTIME = 1_790_830_669


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as package:
        for name, content in files.items():
            package.writestr(name, content)
    return output.getvalue()


def tarball(files, links=(), hard_links=(), fifos=()):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as package:
        for name, content in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o755 if name.endswith("/WebRTC") else 0o644
            info.mtime = MTIME
            package.addfile(info, io.BytesIO(content))
        for name, target in links:
            info = tarfile.TarInfo(name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            package.addfile(info)
        for name, target in hard_links:
            info = tarfile.TarInfo(name)
            info.type = tarfile.LNKTYPE
            info.linkname = target
            package.addfile(info)
        for name in fifos:
            info = tarfile.TarInfo(name)
            info.type = tarfile.FIFOTYPE
            package.addfile(info)
    return output.getvalue()


def ios_files(source="ios-source", deployment="14.0", device=True, build_revision=None,
              device_binary=b"\xcf\xfa\xed\xfe" + bytes(28)):
    libraries = [{"LibraryIdentifier": "ios-arm64-simulator", "LibraryPath": "WebRTC.framework",
                  "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios",
                  "SupportedPlatformVariant": "simulator"}]
    if device:
        libraries.append({"LibraryIdentifier": "ios-arm64", "LibraryPath": "WebRTC.framework",
                          "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios"})
    return {
        "webrtc/NOTICE": b"iOS notice",
        "webrtc/VERSIONS": f"WEBRTC_BUILD_VERSION=155.8059.2.0\nWEBRTC_COMMIT={source}\n".encode(),
        "webrtc/DEPS": f"MACOS_DEPLOYMENT_TARGET=14\nIOS_DEPLOYMENT_TARGET={deployment}\n".encode(),
        "webrtc/include/api/peer_connection_interface.h": b"// header",
        XCFRAMEWORK + "Info.plist": plistlib.dumps({"AvailableLibraries": libraries,
                                                    "CFBundlePackageType": "XFWK",
                                                    "XCFrameworkFormatVersion": "1.0"}),
        XCFRAMEWORK + "build_info.json": json.dumps({"revision": build_revision or source}).encode(),
        XCFRAMEWORK + "LICENSE.md": b"upstream licenses",
        XCFRAMEWORK + "ios-arm64/WebRTC.framework/WebRTC": device_binary,
        XCFRAMEWORK + "ios-arm64/WebRTC.framework/Info.plist": b"framework plist",
        XCFRAMEWORK + "ios-arm64/dSYMs/WebRTC.dSYM/Contents/Resources/DWARF/WebRTC": b"dwarf",
        XCFRAMEWORK + "ios-arm64-simulator/WebRTC.framework/WebRTC": b"\xcf\xfa\xed\xfe" + bytes(28),
    }


def posix_host_files(source="posix-source", deployment="14", archive_magic=b"!<arch>\n" + bytes(24)):
    return {
        "webrtc/NOTICE": b"POSIX notice",
        "webrtc/VERSIONS": f"WEBRTC_BUILD_VERSION=155.8059.2.0\nWEBRTC_COMMIT={source}\n".encode(),
        "webrtc/DEPS": f"MACOS_DEPLOYMENT_TARGET={deployment}\nIOS_DEPLOYMENT_TARGET=14.0\n".encode(),
        "webrtc/include/api/peer_connection_interface.h": b"// header",
        "webrtc/lib/libwebrtc.a": archive_magic,
        XCFRAMEWORK + "Info.plist": b"unused framework",
    }


class FetchWebRtcTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "third_party").mkdir()
        self.android = archive({"META-INF/NOTICE": "Android notice"})
        self.windows = archive({"webrtc/VERSIONS": "WEBRTC_COMMIT=host-source\n"})
        self.linux = tarball(posix_host_files())
        self.macos = tarball(posix_host_files())
        self.ios = tarball(ios_files())
        self.lock = {
            "builder_repository": "https://example.invalid/producer",
            "build_version": "host-release",
            "webrtc_commit": "host-source",
            "assets": {
                "android": {
                    "build_version": "android-repair",
                    "webrtc_commit": "android-source",
                    "name": "libwebrtc.aar",
                    "sha256": hashlib.sha256(self.android).hexdigest(),
                },
                "windows": {
                    "name": "webrtc.windows_x86_64.zip",
                    "sha256": hashlib.sha256(self.windows).hexdigest(),
                },
                "linux": {
                    "build_version": "posix-release",
                    "webrtc_commit": "posix-source",
                    "name": "webrtc.ubuntu-22.04_x86_64.tar.gz",
                    "sha256": hashlib.sha256(self.linux).hexdigest(),
                    "size": len(self.linux),
                },
                "macos": {
                    "build_version": "posix-release",
                    "webrtc_commit": "posix-source",
                    "name": "webrtc.macos_arm64.tar.gz",
                    "sha256": hashlib.sha256(self.macos).hexdigest(),
                    "size": len(self.macos),
                },
                "ios": {
                    "build_version": "ios-release",
                    "webrtc_commit": "ios-source",
                    "name": "webrtc.ios_sdk.tar.gz",
                    "sha256": hashlib.sha256(self.ios).hexdigest(),
                    "size": len(self.ios),
                },
            },
        }

    def write_lock(self):
        (self.root / "third_party/webrtc.lock.json").write_text(json.dumps(self.lock))

    def use_ios(self, data):
        self.ios = data
        self.lock["assets"]["ios"]["sha256"] = hashlib.sha256(data).hexdigest()
        self.lock["assets"]["ios"]["size"] = len(data)

    def fetch_ios(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.ios)) as download:
            fetch("ios", self.root)
        return download

    def assert_ios_rejected(self, pattern):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.ios)):
            with self.assertRaisesRegex(RuntimeError, pattern):
                fetch("ios", self.root)
        self.assertFalse((self.root / ".deps/webrtc/ios/verified.sha256").exists())

    def test_android_uses_its_release_and_checksum(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.android)) as download:
            fetch("android", self.root)
        download.assert_called_once_with(
            "https://example.invalid/producer/releases/download/android-repair/libwebrtc.aar", timeout=60)
        destination = self.root / ".deps/webrtc/android"
        self.assertEqual(self.android, (destination / "libwebrtc.aar").read_bytes())
        self.assertEqual(b"Android notice", (destination / "assets/webrtc-notice.txt").read_bytes())
        self.assertEqual(self.lock["assets"]["android"]["sha256"],
                         (destination / "verified.sha256").read_text().strip())
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            fetch("android", self.root)
        download.assert_not_called()

    def test_windows_keeps_default_release_and_source(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.windows)) as download:
            fetch("windows", self.root)
        download.assert_called_once_with(
            "https://example.invalid/producer/releases/download/host-release/webrtc.windows_x86_64.zip", timeout=60)
        self.assertEqual("WEBRTC_COMMIT=host-source\n",
                         (self.root / ".deps/webrtc/windows/webrtc/VERSIONS").read_text())
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            fetch("windows", self.root)
        download.assert_not_called()

    def test_cached_windows_install_rechecks_lock_source(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.windows)):
            fetch("windows", self.root)
        self.lock["assets"]["windows"]["webrtc_commit"] = "different-host-source"
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "source revision"):
                fetch("windows", self.root)
        download.assert_not_called()

    def test_mismatched_checksum_never_installs_or_stamps(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(b"unexpected artifact")):
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                fetch("android", self.root)
        self.assertFalse((self.root / ".deps/webrtc/android").exists())
        self.assertEqual([], list((self.root / ".deps/cache").iterdir()))

    def test_wrong_windows_source_never_stamps(self):
        self.lock["assets"]["windows"]["webrtc_commit"] = "different-host-source"
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.windows)):
            with self.assertRaisesRegex(RuntimeError, "source revision"):
                fetch("windows", self.root)
        self.assertFalse((self.root / ".deps/webrtc/windows/verified.sha256").exists())

    def test_ios_uses_its_release_and_installs_framework(self):
        download = self.fetch_ios()
        download.assert_called_once_with(
            "https://example.invalid/producer/releases/download/ios-release/webrtc.ios_sdk.tar.gz", timeout=60)
        destination = self.root / ".deps/webrtc/ios"
        binary = destination / "WebRTC.xcframework/ios-arm64/WebRTC.framework/WebRTC"
        self.assertTrue(binary.is_file())
        self.assertTrue((destination / "WebRTC.xcframework/ios-arm64-simulator/WebRTC.framework/WebRTC").is_file())
        self.assertTrue((destination / "WebRTC.xcframework/ios-arm64/dSYMs/WebRTC.dSYM").is_dir())
        self.assertEqual(b"iOS notice", (destination / "assets/webrtc-notice.txt").read_bytes())
        self.assertEqual(ios_files()["webrtc/VERSIONS"], (destination / "VERSIONS").read_bytes())
        self.assertEqual(ios_files()["webrtc/DEPS"], (destination / "DEPS").read_bytes())
        self.assertFalse((destination / "include").exists())
        installed = [path.relative_to(destination).as_posix() for path in destination.rglob("*")]
        self.assertEqual([], [path for path in installed if "include" in path])
        self.assertEqual(MTIME, int(binary.stat().st_mtime))
        if os.name == "posix":
            self.assertEqual(0o755, binary.stat().st_mode & 0o7777)
            self.assertEqual(0o644, (destination / "WebRTC.xcframework/Info.plist").stat().st_mode & 0o7777)
        self.assertEqual(self.lock["assets"]["ios"]["sha256"],
                         (destination / "verified.sha256").read_text().strip())
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            fetch("ios", self.root)
        download.assert_not_called()

    def test_ios_accepts_fat_device_binary(self):
        self.use_ios(tarball(ios_files(device_binary=b"\xca\xfe\xba\xbe" + bytes(28))))
        self.fetch_ios()
        self.assertTrue((self.root / ".deps/webrtc/ios/verified.sha256").exists())

    def test_cached_ios_install_rechecks_lock_source(self):
        self.fetch_ios()
        self.lock["assets"]["ios"]["webrtc_commit"] = "different-ios-source"
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "source revision"):
                fetch("ios", self.root)
        download.assert_not_called()

    def test_cached_ios_install_rechecks_both_source_records(self):
        self.fetch_ios()
        destination = self.root / ".deps/webrtc/ios"
        records = {
            destination / "VERSIONS": b"WEBRTC_COMMIT=other\n",
            destination / "WebRTC.xcframework/build_info.json": b'{"revision": "other"}',
        }
        for path, mismatched in records.items():
            with self.subTest(record=path.name):
                original = path.read_bytes()
                path.write_bytes(mismatched)
                with patch("fetch_webrtc.urllib.request.urlopen") as download:
                    with self.assertRaisesRegex(RuntimeError, "source revision"):
                        fetch("ios", self.root)
                download.assert_not_called()
                path.write_bytes(original)
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            fetch("ios", self.root)
        download.assert_not_called()

    def test_ios_rejects_wrong_source_revision(self):
        self.use_ios(tarball(ios_files(source="other", build_revision="ios-source")))
        self.assert_ios_rejected("source revision")

    def test_ios_source_revision_is_a_line_not_a_substring(self):
        files = ios_files()
        files["webrtc/VERSIONS"] = b"WEBRTC_COMMIT=ios-source-and-more\n"
        self.use_ios(tarball(files))
        self.assert_ios_rejected("source revision")

    def test_ios_rejects_wrong_build_info_revision(self):
        self.use_ios(tarball(ios_files(build_revision="other")))
        self.assert_ios_rejected("source revision")

    def test_ios_rejects_traversal_and_absolute_members(self):
        for unsafe in ("webrtc/../evil", "/etc/evil", "webrtc\\evil", "webrtc/C:evil"):
            with self.subTest(member=unsafe):
                self.use_ios(tarball({unsafe: b"evil", **ios_files()}))
                self.assert_ios_rejected("Unsafe dependency archive path")
                self.assertEqual([], list(self.root.rglob("*evil*")))

    def test_ios_rejects_symbolic_links(self):
        self.use_ios(tarball(ios_files(), links=[(XCFRAMEWORK + "ios-arm64/WebRTC.framework/Headers", "/usr/include")]))
        self.assert_ios_rejected("symbolic link")

    def test_ios_rejects_hard_links_and_linked_metadata(self):
        self.use_ios(tarball(ios_files(), hard_links=[(XCFRAMEWORK + "ios-arm64/extra", XCFRAMEWORK + "Info.plist")]))
        self.assert_ios_rejected("symbolic link")
        files = ios_files()
        del files["webrtc/NOTICE"]
        self.use_ios(tarball(files, links=[("webrtc/NOTICE", "include/NOTICE")]))
        self.assert_ios_rejected("symbolic link")

    def test_ios_skips_symbolic_links_inside_the_unused_header_tree(self):
        # The pinned m155.8059.2.0 archive has relative links under webrtc/include/third_party/perfetto.
        link = "webrtc/include/third_party/perfetto/contrib/abi/export.h"
        self.use_ios(tarball(ios_files(), links=[(link, "../../../../include/perfetto/public/abi/export.h")]))
        self.fetch_ios()
        destination = self.root / ".deps/webrtc/ios"
        self.assertTrue((destination / "verified.sha256").exists())
        self.assertEqual([], [path for path in destination.rglob("*") if path.is_symlink()])

    def test_ios_rejects_special_entries(self):
        self.use_ios(tarball(ios_files(), fifos=[XCFRAMEWORK + "ios-arm64/pipe"]))
        self.assert_ios_rejected("unsupported entry")
        self.use_ios(tarball(ios_files(), fifos=["webrtc/include/pipe"]))
        self.assert_ios_rejected("unsupported entry")

    def test_ios_requires_device_slice(self):
        self.use_ios(tarball(ios_files(device=False)))
        self.assert_ios_rejected("device slice")

    def test_ios_requires_device_binary(self):
        files = ios_files(device_binary=b"not a mach-o binary")
        self.use_ios(tarball(files))
        self.assert_ios_rejected("device binary is missing")
        del files[XCFRAMEWORK + "ios-arm64/WebRTC.framework/WebRTC"]
        self.use_ios(tarball(files))
        self.assert_ios_rejected("device binary is missing")

    def test_ios_rejects_deployment_target_above_app(self):
        self.use_ios(tarball(ios_files(deployment="18.0")))
        self.assert_ios_rejected("deployment target exceeds")
        self.use_ios(tarball(ios_files(deployment="17.0.1")))
        self.assert_ios_rejected("deployment target exceeds")

    def test_ios_accepts_deployment_target_equal_to_app(self):
        for deployment in ("17", "17.0", "17.0.0"):
            with self.subTest(deployment=deployment):
                self.use_ios(tarball(ios_files(deployment=deployment)))
                self.fetch_ios()
                self.assertTrue((self.root / ".deps/webrtc/ios/verified.sha256").exists())

    def test_ios_rejects_unreadable_or_missing_deployment_target(self):
        for deployment in ("fourteen", "", "-1", "17.-1", "+17.0", "17..0", "17.0.0.0", "１７.０"):
            with self.subTest(deployment=deployment):
                self.use_ios(tarball(ios_files(deployment=deployment)))
                self.assert_ios_rejected("Unreadable WebRTC iOS deployment target")
        files = ios_files()
        files["webrtc/DEPS"] = b"MACOS_DEPLOYMENT_TARGET=14\n"
        self.use_ios(tarball(files))
        self.assert_ios_rejected("Unreadable WebRTC iOS deployment target")

    def test_ios_requires_metadata(self):
        files = ios_files()
        del files["webrtc/NOTICE"]
        self.use_ios(tarball(files))
        self.assert_ios_rejected("missing webrtc/NOTICE")

    def test_ios_requires_readable_xcframework_metadata(self):
        files = ios_files()
        del files[XCFRAMEWORK + "build_info.json"]
        self.use_ios(tarball(files))
        self.assert_ios_rejected("metadata is missing or unreadable")
        files = ios_files()
        files[XCFRAMEWORK + "Info.plist"] = b"not a plist"
        self.use_ios(tarball(files))
        self.assert_ios_rejected("metadata is missing or unreadable")

    def test_ios_rejects_unsafe_library_identifier(self):
        files = ios_files()
        info = plistlib.loads(files[XCFRAMEWORK + "Info.plist"])
        info["AvailableLibraries"][1]["LibraryIdentifier"] = ".."
        files[XCFRAMEWORK + "Info.plist"] = plistlib.dumps(info)
        self.use_ios(tarball(files))
        self.assert_ios_rejected("Unsafe dependency archive path")

    def test_size_mismatch_never_installs_or_stamps(self):
        self.lock["assets"]["ios"]["size"] = len(self.ios) + 1
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.ios)):
            with self.assertRaisesRegex(RuntimeError, "size mismatch"):
                fetch("ios", self.root)
        self.assertEqual([], list((self.root / ".deps/cache").iterdir()))
        self.assertFalse((self.root / ".deps/webrtc/ios").exists())

    def test_linux_and_macos_install_static_library_and_headers(self):
        self.write_lock()
        for platform, payload, name in (
            ("linux", self.linux, "webrtc.ubuntu-22.04_x86_64.tar.gz"),
            ("macos", self.macos, "webrtc.macos_arm64.tar.gz"),
        ):
            with self.subTest(platform=platform):
                with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(payload)) as download:
                    fetch(platform, self.root)
                download.assert_called_once_with(
                    f"https://example.invalid/producer/releases/download/posix-release/{name}", timeout=60)
                destination = self.root / ".deps/webrtc" / platform
                self.assertTrue((destination / "webrtc/lib/libwebrtc.a").is_file())
                self.assertTrue((destination / "webrtc/include/api/peer_connection_interface.h").is_file())
                self.assertEqual(b"POSIX notice", (destination / "webrtc/NOTICE").read_bytes())
                self.assertFalse((destination / "webrtc/Frameworks").exists())
                self.assertEqual(self.lock["assets"][platform]["sha256"],
                                 (destination / "verified.sha256").read_text().strip())
                with patch("fetch_webrtc.urllib.request.urlopen") as cached:
                    fetch(platform, self.root)
                cached.assert_not_called()

    def test_cached_posix_host_install_rechecks_source_and_library(self):
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.linux)):
            fetch("linux", self.root)
        self.lock["assets"]["linux"]["webrtc_commit"] = "different-posix-source"
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "source revision"):
                fetch("linux", self.root)
        download.assert_not_called()
        self.lock["assets"]["linux"]["webrtc_commit"] = "posix-source"
        self.write_lock()
        library = self.root / ".deps/webrtc/linux/webrtc/lib/libwebrtc.a"
        library.write_bytes(b"corrupt")
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "static library is missing"):
                fetch("linux", self.root)
        download.assert_not_called()

    def test_posix_host_skips_sysroot_and_perfetto_symlinks_and_rejects_other_links(self):
        allowed = tarball(posix_host_files(), links=[
            ("webrtc/include/build/linux/debian_bullseye_amd64-sysroot/usr/include/krb5.h", "mit-krb5/krb5.h"),
            ("webrtc/include/third_party/perfetto/contrib/abi/export.h", "../../../../include/perfetto/public/abi/export.h"),
        ])
        self.linux = allowed
        self.lock["assets"]["linux"]["sha256"] = hashlib.sha256(allowed).hexdigest()
        self.lock["assets"]["linux"]["size"] = len(allowed)
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.linux)):
            fetch("linux", self.root)
        destination = self.root / ".deps/webrtc/linux"
        self.assertEqual([], [path for path in destination.rglob("*") if path.is_symlink()])

        rejected = tarball(posix_host_files(), links=[("webrtc/include/api/evil.h", "/etc/passwd")])
        self.macos = rejected
        self.lock["assets"]["macos"]["sha256"] = hashlib.sha256(rejected).hexdigest()
        self.lock["assets"]["macos"]["size"] = len(rejected)
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.macos)):
            with self.assertRaisesRegex(RuntimeError, "symbolic link"):
                fetch("macos", self.root)
        self.assertFalse((self.root / ".deps/webrtc/macos/verified.sha256").exists())

    def test_macos_rejects_deployment_target_above_host_minimum(self):
        too_new = tarball(posix_host_files(deployment="15.0"))
        self.macos = too_new
        self.lock["assets"]["macos"]["sha256"] = hashlib.sha256(too_new).hexdigest()
        self.lock["assets"]["macos"]["size"] = len(too_new)
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", return_value=io.BytesIO(self.macos)):
            with self.assertRaisesRegex(RuntimeError, "deployment target exceeds"):
                fetch("macos", self.root)
        self.assertFalse((self.root / ".deps/webrtc/macos/verified.sha256").exists())

    def test_posix_toolchain_verifies_clang_symlinks_libcxx_tree_and_provenance(self):
        import base64
        files = posix_host_files()
        files["webrtc/VERSIONS"] = (
            b"WEBRTC_BUILD_VERSION=155.8059.2.0\n"
            b"WEBRTC_COMMIT=posix-source\n"
            b"WEBRTC_SRC_TOOLS_COMMIT=tools-pin\n"
            b"WEBRTC_SRC_BUILDTOOLS_COMMIT=buildtools-pin\n"
            b"WEBRTC_SRC_THIRD_PARTY_LIBCXX_SRC_COMMIT=libcxx-pin-123456\n"
        )
        host_tar = tarball(files)
        clang_tar = tarball({"bin/clang": b"#!/bin/sh\n"}, links=[("bin/clang++", "clang")])
        libcxx_files = {
            "LICENSE.TXT": b"Apache-2.0 WITH LLVM-exception\n",
            "include/string": b"// string\n",
        }
        tree_state = hashlib.sha256()
        for rel in sorted(libcxx_files):
            digest_hex = hashlib.sha256(libcxx_files[rel]).hexdigest()
            tree_state.update(f"{rel}:{digest_hex}\n".encode("utf-8"))
        tree_sha = tree_state.hexdigest()
        libcxx_cache_tar = tarball(libcxx_files)
        cache = self.root / ".deps/cache"
        cache.mkdir(parents=True, exist_ok=True)
        (cache / f"{tree_sha}-libcxx-libcxx-pin-1.tar.gz").write_bytes(libcxx_cache_tar)

        config_site = b"#define _LIBCPP_ABI_NAMESPACE __Cr\n"
        assertion_handler = b"#define _LIBCPP_ASSERTION_HANDLER(m) __builtin_trap()\n"
        url_map = {
            "https://example.invalid/producer/releases/download/posix-release/webrtc.ubuntu-22.04_x86_64.tar.gz": host_tar,
            "https://example.invalid/clang.tar.gz": clang_tar,
            "https://example.invalid/config_site": base64.b64encode(config_site),
            "https://example.invalid/assertion_handler": base64.b64encode(assertion_handler),
        }
        self.lock["assets"]["linux"] = {
            "build_version": "posix-release",
            "webrtc_commit": "posix-source",
            "name": "webrtc.ubuntu-22.04_x86_64.tar.gz",
            "sha256": hashlib.sha256(host_tar).hexdigest(),
            "size": len(host_tar),
            "toolchain": {
                "tools_commit": "tools-pin",
                "buildtools_commit": "buildtools-pin",
                "archives": [{
                    "name": "clang.tar.gz",
                    "url": "https://example.invalid/clang.tar.gz",
                    "sha256": hashlib.sha256(clang_tar).hexdigest(),
                    "size": len(clang_tar),
                }],
                "libcxx": {
                    "repository": "https://example.invalid/libcxx.git",
                    "commit": "libcxx-pin-123456",
                    "tree_sha256": tree_sha,
                    "config_site": {
                        "url": "https://example.invalid/config_site",
                        "sha256": hashlib.sha256(config_site).hexdigest(),
                        "size": len(config_site),
                    },
                    "assertion_handler": {
                        "url": "https://example.invalid/assertion_handler",
                        "sha256": hashlib.sha256(assertion_handler).hexdigest(),
                        "size": len(assertion_handler),
                    },
                },
            },
        }
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", side_effect=lambda u, timeout=60: io.BytesIO(url_map[u])):
            fetch("linux", self.root)
        dest = self.root / ".deps/webrtc/linux"
        self.assertTrue((dest / "clang/bin/clang++").is_symlink())
        self.assertEqual(config_site, (dest / "libcxx/include/__config_site").read_bytes())
        self.assertEqual(assertion_handler, (dest / "libcxx/include/__assertion_handler").read_bytes())

        # Tampering with __config_site on a stamped install must fail closed.
        (dest / "libcxx/include/__config_site").write_bytes(b"tampered")
        with patch("fetch_webrtc.urllib.request.urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "__config_site is missing or modified"):
                fetch("linux", self.root)
        download.assert_not_called()

        # Escaping relative symlinks inside a Clang archive must fail closed.
        escaping = tarball({"bin/clang": b"#!/bin/sh\n"}, links=[("bin/clang++", "../../outside")])
        url_map["https://example.invalid/clang.tar.gz"] = escaping
        self.lock["assets"]["linux"]["toolchain"]["archives"][0]["sha256"] = hashlib.sha256(escaping).hexdigest()
        self.lock["assets"]["linux"]["toolchain"]["archives"][0]["size"] = len(escaping)
        self.write_lock()
        with patch("fetch_webrtc.urllib.request.urlopen", side_effect=lambda u, timeout=60: io.BytesIO(url_map[u])):
            with self.assertRaisesRegex(RuntimeError, "Unsafe dependency archive link"):
                fetch("linux", self.root)


if __name__ == "__main__":
    unittest.main()
