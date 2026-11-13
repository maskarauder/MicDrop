# SPDX-License-Identifier: MPL-2.0
"""Unit tests for tools/package_unix_host.py."""

import gzip
import io
import os
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package_unix_host  # noqa: E402
import test_macos_app_bundle  # noqa: E402


def fake_elf_x64(e_type):
    header = package_unix_host.ELF_HEADER_64.pack(
        package_unix_host.ELF_MAGIC,
        package_unix_host.ELFCLASS64,
        package_unix_host.ELFDATA2LSB,
        1,
        0,
        e_type,
        package_unix_host.EM_X86_64,
        1,
    )
    return header + b"\x00" * (64 - len(header))


CLI_HOST_NOTICES = (
    "LICENSE",
    "NOTICE",
    "QR-CODE-NOTICE.txt",
    "DISCOVERY-NOTICES.txt",
    "WEBSOCKET-NOTICE.txt",
    "WEBRTC-NOTICE.txt",
    "WEBRTC-VERSIONS.txt",
)


class PackageUnixHostTests(unittest.TestCase):
    def _populate_stage(self, stage_dir: Path, platform: str):
        stage_dir.mkdir(parents=True, exist_ok=True)
        exe = stage_dir / "micdrop-host"
        if platform == "linux-x64":
            exe.write_bytes(fake_elf_x64(package_unix_host.ET_DYN))
            lib = stage_dir / "libmicdrop_rtc.so"
            lib.write_bytes(fake_elf_x64(package_unix_host.ET_DYN))
        else:
            exe.write_bytes(
                test_macos_app_bundle.make_macho(package_unix_host.macos_app_bundle.MH_EXECUTE)
            )
            lib = stage_dir / "libmicdrop_rtc.dylib"
            lib.write_bytes(
                test_macos_app_bundle.make_macho(package_unix_host.macos_app_bundle.MH_DYLIB)
            )
        exe.chmod(0o755)
        lib.chmod(0o755)
        for notice in CLI_HOST_NOTICES:
            (stage_dir / notice).write_text(f"{notice}\n", encoding="utf-8")

    def test_cli_host_packages_do_not_require_or_allow_gui_app_icon(self):
        self.assertIn("AppIcon.icns", package_unix_host.macos_app_bundle.REQUIRED_APP_RESOURCES)
        self.assertNotIn("AppIcon.icns", package_unix_host.REQUIRED_NOTICES)
        self.assertEqual(set(package_unix_host.REQUIRED_NOTICES), set(CLI_HOST_NOTICES))
        for platform in ("linux-x64", "macos-arm64"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as tmp:
                stage = Path(tmp) / "stage"
                self._populate_stage(stage, platform)
                self.assertNotIn("AppIcon.icns", package_unix_host.expected_filenames(platform))
                package_unix_host.check_stage_directory(stage, platform=platform)

                (stage / "AppIcon.icns").write_bytes(b"icns")
                with self.assertRaisesRegex(ValueError, "unexpected files.*AppIcon\\.icns"):
                    package_unix_host.check_stage_directory(stage, platform=platform)

    def test_linux_and_macos_tarballs_preserve_executable_permissions_after_chmod_strip(self):
        for platform, top_dir in (
            ("linux-x64", "MicDrop-linux-x64-host"),
            ("macos-arm64", "MicDrop-macos-arm64-host"),
        ):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                stage = base / "stage"
                archive = base / "dist" / f"{top_dir}.tar.gz"
                extracted = base / "extracted"
                self._populate_stage(stage, platform)

                digest1 = package_unix_host.package_host_tarball(stage, archive, platform=platform)
                digest2 = package_unix_host.package_host_tarball(stage, archive, platform=platform)
                self.assertEqual(digest1, digest2)

                # Simulate upload-artifact@v4 stripping execute bits on the outer archive file.
                archive.chmod(0o644)
                extracted.mkdir()
                with tarfile.open(archive, "r:gz") as tar:
                    if sys.version_info >= (3, 12):
                        tar.extractall(extracted, filter="data")
                    else:
                        tar.extractall(extracted)

                exe_out = extracted / top_dir / "micdrop-host"
                self.assertTrue(exe_out.is_file())
                if os.name != "nt":
                    self.assertTrue(os.access(exe_out, os.X_OK))
                    self.assertEqual(exe_out.stat().st_mode & 0o777, 0o755)

    def test_rejects_non_executable_archive_entry_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            stage = base / "stage"
            self._populate_stage(stage, "linux-x64")

            bad_tar = base / "bad.tar.gz"
            with bad_tar.open("wb") as raw_out:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw_out, mtime=0) as gz_out:
                    with tarfile.open(mode="w", fileobj=gz_out, format=tarfile.PAX_FORMAT) as tar:
                        for filename in package_unix_host.expected_filenames("linux-x64"):
                            data = (stage / filename).read_bytes()
                            info = tarfile.TarInfo(name=f"MicDrop-linux-x64-host/{filename}")
                            info.size = len(data)
                            info.mode = 0o644  # Missing +x on micdrop-host!
                            tar.addfile(info, io.BytesIO(data))

            with self.assertRaisesRegex(ValueError, "mode 0755"):
                package_unix_host.check_host_tarball(bad_tar, platform="linux-x64")

            traversal_tar = base / "traversal.tar.gz"
            with traversal_tar.open("wb") as raw_out:
                with gzip.GzipFile(filename="", mode="wb", fileobj=raw_out, mtime=0) as gz_out:
                    with tarfile.open(mode="w", fileobj=gz_out, format=tarfile.PAX_FORMAT) as tar:
                        info = tarfile.TarInfo(name="../escape")
                        info.size = 1
                        info.mode = 0o644
                        tar.addfile(info, io.BytesIO(b"x"))

            with self.assertRaisesRegex(ValueError, "unsafe"):
                package_unix_host.check_host_tarball(traversal_tar, platform="linux-x64")

    def test_rejects_wrong_architecture_or_extra_staged_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            stage = base / "stage"
            self._populate_stage(stage, "linux-x64")
            (stage / "unexpected.txt").write_text("extra\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected files"):
                package_unix_host.check_stage_directory(stage, platform="linux-x64")

            (stage / "unexpected.txt").unlink()
            arm_elf = bytearray(fake_elf_x64(package_unix_host.ET_DYN))
            struct.pack_into("<H", arm_elf, 18, 183)  # EM_AARCH64 != EM_X86_64
            (stage / "micdrop-host").write_bytes(bytes(arm_elf))
            with self.assertRaisesRegex(ValueError, "x86_64"):
                package_unix_host.check_stage_directory(stage, platform="linux-x64")


if __name__ == "__main__":
    unittest.main()
