"""Check every packaged native library's ELF LOAD and RELRO alignment for 16 KB."""
import argparse
import struct
import zipfile
from pathlib import Path

PAGE_SIZE = 16 * 1024
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM_HEADER = struct.Struct("<IIQQQQQQ")
PT_LOAD = 1
PT_GNU_RELRO = 0x6474E552


def check_elf(data):
    if len(data) < ELF_HEADER.size:
        raise ValueError("Truncated ELF header")
    header = ELF_HEADER.unpack_from(data)
    if data[:7] != b"\x7fELF\x02\x01\x01" or header[1] != 3 or header[2] not in (62, 183):
        raise ValueError("Expected an Android x86_64 or arm64 ELF64 shared library")
    offset, entry_size, count = header[5], header[9], header[10]
    if (offset < ELF_HEADER.size or entry_size != PROGRAM_HEADER.size or count == 0
            or offset + entry_size * count > len(data)):
        raise ValueError("Invalid ELF program-header table")
    loads = 0
    for index in range(count):
        kind, _, file_offset, address, _, file_size, memory_size, alignment = (
            PROGRAM_HEADER.unpack_from(data, offset + index * entry_size))
        if kind == PT_LOAD:
            loads += 1
            if alignment < PAGE_SIZE or alignment & (alignment - 1):
                raise ValueError(f"LOAD alignment 0x{alignment:x} is not compatible with 16 KB pages")
            if file_offset % alignment != address % alignment:
                raise ValueError("LOAD file/virtual offsets are not congruent with their alignment")
            if file_size > memory_size or file_offset + file_size > len(data):
                raise ValueError("Invalid LOAD segment size")
        elif kind == PT_GNU_RELRO and (address + memory_size) % PAGE_SIZE:
            raise ValueError("RELRO end is not aligned to 16 KB")
    if not loads:
        raise ValueError("ELF has no LOAD segments")


def check_apk(path):
    failures = []
    with zipfile.ZipFile(path) as apk:
        libraries = [entry for entry in apk.infolist()
                     if entry.filename.startswith("lib/") and entry.filename.endswith(".so")]
        if not libraries:
            raise ValueError("APK contains no native libraries")
        for entry in libraries:
            try:
                check_elf(apk.read(entry))
            except ValueError as error:
                failures.append(f"{entry.filename}: {error}")
            else:
                print(f"16 KB ELF alignment passed: {entry.filename}")
    if failures:
        raise ValueError("\n".join(failures))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    arguments = parser.parse_args()
    try:
        check_apk(arguments.apk)
    except (ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Android 16 KB compatibility check failed: {error}\n")
