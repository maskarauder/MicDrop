"""Reject incompatible or malformed native libraries before APK publication."""
import tempfile
import unittest
import zipfile
from pathlib import Path

from check_android_page_sizes import (
    ELF_HEADER, PROGRAM_HEADER, PT_GNU_RELRO, PT_LOAD, check_apk, check_elf)


def library(alignment=0x4000, address=0, relro_end=0x8000):
    image = bytearray(512)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    ELF_HEADER.pack_into(image, 0, ident, 3, 183, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    PROGRAM_HEADER.pack_into(image, 64, PT_LOAD, 5, 0, address, 0, len(image), 0x10000, alignment)
    PROGRAM_HEADER.pack_into(image, 120, PT_GNU_RELRO, 4, 0, 0, 0, 0, relro_end, 1)
    return image


class AndroidPageSizeTest(unittest.TestCase):
    def test_accepts_16kb_and_larger_load_alignment(self):
        check_elf(library())
        check_elf(library(alignment=0x10000))

    def test_rejects_load_alignment_and_mapping_incompatibility(self):
        with self.assertRaisesRegex(ValueError, "LOAD alignment"):
            check_elf(library(alignment=0x1000))
        with self.assertRaisesRegex(ValueError, "congruent"):
            check_elf(library(address=0x1000))

    def test_rejects_4kb_relro_even_when_loads_are_16kb_aligned(self):
        with self.assertRaisesRegex(ValueError, "RELRO end"):
            check_elf(library(relro_end=0x9000))

    def test_rejects_truncated_program_headers(self):
        with self.assertRaisesRegex(ValueError, "Truncated ELF"):
            check_elf(b"\x7fELF")
        with self.assertRaisesRegex(ValueError, "program-header table"):
            check_elf(library()[:160])

    def test_checks_every_packaged_library(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "fixture.apk"
            with zipfile.ZipFile(apk, "w") as package:
                package.writestr("lib/arm64-v8a/libjingle_peerconnection_so.so", library())
                package.writestr("lib/arm64-v8a/libdependency.so", library(alignment=0x1000))
            with self.assertRaisesRegex(ValueError, "libdependency.so: LOAD alignment"):
                check_apk(apk)


if __name__ == "__main__":
    unittest.main()
