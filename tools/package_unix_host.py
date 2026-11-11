# SPDX-License-Identifier: MPL-2.0
"""Package and verify permission-preserving Unix CLI host tarballs."""

import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import struct
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macos_app_bundle  # noqa: E402

MAX_UNCOMPRESSED = 512 * 1024 * 1024

ELF_HEADER_64 = struct.Struct("<4sBBBB8xHHI")
ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2
ELFDATA2LSB = 1
ET_EXEC = 2
ET_DYN = 3
EM_X86_64 = 62

PLATFORMS = {
    "linux-x64": {
        "top_dir": "MicDrop-linux-x64-host",
        "rtc_lib": "libmicdrop_rtc.so",
    },
    "macos-arm64": {
        "top_dir": "MicDrop-macos-arm64-host",
        "rtc_lib": "libmicdrop_rtc.dylib",
    },
}

REQUIRED_NOTICES = macos_app_bundle.REQUIRED_RESOURCES


def reject_link(path):
    candidate = Path(path)
    if candidate.is_symlink() or (hasattr(candidate, "is_junction") and candidate.is_junction()):
        raise ValueError(f"Symbolic links are not allowed in Unix host staging: {candidate}")


def parse_linux_x64_elf(data, label, *, allow_exec):
    if len(data) < ELF_HEADER_64.size:
        raise ValueError(f"{label} is too small to be a 64-bit ELF binary")
    magic, elf_class, endian, _version, _osabi, e_type, e_machine, _e_ver = (
        ELF_HEADER_64.unpack_from(data, 0)
    )
    if magic != ELF_MAGIC or elf_class != ELFCLASS64 or endian != ELFDATA2LSB:
        raise ValueError(f"{label} is not a 64-bit little-endian ELF binary")
    if e_machine != EM_X86_64:
        raise ValueError(f"{label} is not an x86_64 ELF binary")
    allowed_types = (ET_EXEC, ET_DYN) if allow_exec else (ET_DYN,)
    if e_type not in allowed_types:
        raise ValueError(f"{label} has unexpected ELF type {e_type:#x}")


def validate_binary(platform, filename, data, *, is_executable, minimum_macos="14.2"):
    if platform == "linux-x64":
        parse_linux_x64_elf(data, filename, allow_exec=is_executable)
        return
    if platform == "macos-arm64":
        minimum = macos_app_bundle.dotted(minimum_macos)
        filetype = macos_app_bundle.MH_EXECUTE if is_executable else macos_app_bundle.MH_DYLIB
        kind = "executable" if is_executable else "dynamic library"
        found = macos_app_bundle.parse_macos_arm64_macho(data, filename, filetype, kind)
        if found > minimum:
            raise ValueError(
                f"{filename} minimum macOS {macos_app_bundle.version_text(found)} exceeds {minimum_macos}"
            )
        return
    raise ValueError(f"Unsupported Unix host platform: {platform!r}")


def expected_filenames(platform):
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported Unix host platform: {platform!r}")
    rtc_lib = PLATFORMS[platform]["rtc_lib"]
    return ("micdrop-host", rtc_lib, *REQUIRED_NOTICES)


def check_stage_directory(stage_dir, *, platform, minimum_macos="14.2"):
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported Unix host platform: {platform!r}")
    stage_dir = Path(stage_dir)
    reject_link(stage_dir)
    if not stage_dir.is_dir():
        raise ValueError(f"Staging directory does not exist: {stage_dir}")

    expected = set(expected_filenames(platform))
    actual = set()
    for child in sorted(stage_dir.iterdir()):
        reject_link(child)
        if not child.is_file():
            raise ValueError(f"Unexpected non-regular entry in staging directory: {child.name}")
        actual.add(child.name)

    missing = sorted(expected - actual)
    if missing:
        raise ValueError(f"Staging directory is missing required files: {', '.join(missing)}")
    extra = sorted(actual - expected)
    if extra:
        raise ValueError(f"Staging directory contains unexpected files: {', '.join(extra)}")

    exe_path = stage_dir / "micdrop-host"
    if os.name != "nt" and (exe_path.stat().st_mode & 0o111) == 0:
        raise ValueError("Staged micdrop-host is not marked executable")
    validate_binary(
        platform,
        "micdrop-host",
        exe_path.read_bytes(),
        is_executable=True,
        minimum_macos=minimum_macos,
    )

    rtc_lib = PLATFORMS[platform]["rtc_lib"]
    rtc_path = stage_dir / rtc_lib
    validate_binary(
        platform,
        rtc_lib,
        rtc_path.read_bytes(),
        is_executable=False,
        minimum_macos=minimum_macos,
    )

    for notice in REQUIRED_NOTICES:
        notice_path = stage_dir / notice
        if notice_path.stat().st_size == 0:
            raise ValueError(f"Staged {notice} must not be empty")


def check_host_tarball(tar_path, *, platform, minimum_macos="14.2"):
    if platform not in PLATFORMS:
        raise ValueError(f"Unsupported Unix host platform: {platform!r}")
    tar_path = Path(tar_path)
    reject_link(tar_path)
    top_dir = PLATFORMS[platform]["top_dir"]
    rtc_lib = PLATFORMS[platform]["rtc_lib"]
    expected_files = {f"{top_dir}/{name}" for name in expected_filenames(platform)}

    with tarfile.open(tar_path, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("Unix host archive is empty")

        seen = set()
        by_name = {}
        total_size = 0
        for member in members:
            name = member.name.rstrip("/") if member.isdir() else member.name
            parts = PurePosixPath(name).parts
            if (
                member.name.startswith("/")
                or ".." in parts
                or "\\" in member.name
                or not parts
                or parts[0] != top_dir
            ):
                raise ValueError(f"Archive entry is unsafe: {member.name}")
            if name in seen:
                raise ValueError(f"Archive contains duplicate entry: {name}")
            seen.add(name)
            if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                raise ValueError(f"Archive contains disallowed entry type: {member.name}")
            if member.isdir():
                if name != top_dir:
                    raise ValueError(f"Unexpected directory in archive: {member.name}")
                if (member.mode & 0o777) != 0o755:
                    raise ValueError(f"Top-level directory mode must be 0755, got {member.mode:#o}")
                continue
            total_size += member.size
            if total_size > MAX_UNCOMPRESSED:
                raise ValueError("Archive is unexpectedly large")
            by_name[name] = member

        missing = sorted(expected_files - set(by_name))
        if missing:
            raise ValueError(f"Archive is missing required entries: {', '.join(missing)}")
        extra = sorted(set(by_name) - expected_files)
        if extra:
            raise ValueError(f"Archive contains unexpected entries: {', '.join(extra)}")

        exe_entry = f"{top_dir}/micdrop-host"
        if (by_name[exe_entry].mode & 0o777) != 0o755:
            raise ValueError(
                f"{exe_entry} must have mode 0755 in archive, got {by_name[exe_entry].mode:#o}"
            )
        exe_stream = archive.extractfile(by_name[exe_entry])
        validate_binary(
            platform,
            exe_entry,
            b"" if exe_stream is None else exe_stream.read(),
            is_executable=True,
            minimum_macos=minimum_macos,
        )

        lib_entry = f"{top_dir}/{rtc_lib}"
        if (by_name[lib_entry].mode & 0o777) != 0o755:
            raise ValueError(
                f"{lib_entry} must have mode 0755 in archive, got {by_name[lib_entry].mode:#o}"
            )
        lib_stream = archive.extractfile(by_name[lib_entry])
        validate_binary(
            platform,
            lib_entry,
            b"" if lib_stream is None else lib_stream.read(),
            is_executable=False,
            minimum_macos=minimum_macos,
        )

        for notice in REQUIRED_NOTICES:
            notice_entry = f"{top_dir}/{notice}"
            info = by_name[notice_entry]
            if info.size == 0:
                raise ValueError(f"{notice_entry} must not be empty")
            if (info.mode & 0o777) != 0o644:
                raise ValueError(f"{notice_entry} must have mode 0644, got {info.mode:#o}")

    with tar_path.open("rb") as raw:
        return hashlib.file_digest(raw, "sha256").hexdigest()


def package_host_tarball(stage_dir, output_tar, *, platform, minimum_macos="14.2"):
    stage_dir = Path(stage_dir)
    output_tar = Path(output_tar)
    check_stage_directory(stage_dir, platform=platform, minimum_macos=minimum_macos)

    top_dir = PLATFORMS[platform]["top_dir"]
    rtc_lib = PLATFORMS[platform]["rtc_lib"]
    executables = {"micdrop-host", rtc_lib}

    output_tar.parent.mkdir(parents=True, exist_ok=True)
    tmp_tar = output_tar.with_suffix(output_tar.suffix + ".tmp")
    if tmp_tar.exists() or tmp_tar.is_symlink():
        tmp_tar.unlink()

    with tmp_tar.open("wb") as raw_out:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_out, mtime=0) as gz_out:
            with tarfile.open(mode="w", fileobj=gz_out, format=tarfile.PAX_FORMAT) as archive:
                dir_info = tarfile.TarInfo(name=top_dir)
                dir_info.type = tarfile.DIRTYPE
                dir_info.mode = 0o755
                dir_info.uid = 0
                dir_info.gid = 0
                dir_info.uname = ""
                dir_info.gname = ""
                dir_info.mtime = 0
                archive.addfile(dir_info)

                for filename in sorted(expected_filenames(platform)):
                    src = stage_dir / filename
                    data = src.read_bytes()
                    info = tarfile.TarInfo(name=f"{top_dir}/{filename}")
                    info.type = tarfile.REGTYPE
                    info.size = len(data)
                    info.mode = 0o755 if filename in executables else 0o644
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(data))

    tmp_tar.replace(output_tar)
    return check_host_tarball(output_tar, platform=platform, minimum_macos=minimum_macos)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    pkg_cmd = sub.add_parser("package", help="Create and verify a Unix CLI host .tar.gz archive")
    pkg_cmd.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    pkg_cmd.add_argument("--stage-dir", required=True)
    pkg_cmd.add_argument("--output", required=True)
    pkg_cmd.add_argument("--minimum-macos", default="14.2")

    chk_cmd = sub.add_parser("check", help="Verify a Unix CLI host .tar.gz archive")
    chk_cmd.add_argument("--platform", choices=sorted(PLATFORMS), required=True)
    chk_cmd.add_argument("--archive", required=True)
    chk_cmd.add_argument("--minimum-macos", default="14.2")

    args = parser.parse_args(argv)
    if args.command == "package":
        digest = package_host_tarball(
            args.stage_dir,
            args.output,
            platform=args.platform,
            minimum_macos=args.minimum_macos,
        )
        print(f"Packaged {args.output} (sha256={digest})")
        return 0
    if args.command == "check":
        digest = check_host_tarball(
            args.archive,
            platform=args.platform,
            minimum_macos=args.minimum_macos,
        )
        print(f"Verified {args.archive} (sha256={digest})")
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
