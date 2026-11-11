# SPDX-License-Identifier: MPL-2.0
"""Assemble, check, and package the macOS arm64 MicDrop.app desktop bundle."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import unicodedata
import xml.parsers.expat
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_version  # noqa: E402

MAX_UNCOMPRESSED = 512 * 1024 * 1024
DEFAULT_BUNDLE_ID = "com.maskarauder.micdrop.mac"
DEFAULT_MIN_MACOS = "14.2"
BONJOUR_SERVICE = "_micdrop._tcp"
REVISION_RE = re.compile(r"^([0-9a-f]{12}|local)$")

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_DYLIB = 6
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
PLATFORM_MACOS = 1

MACH_HEADER_64 = struct.Struct("<IiiIIIII")
LOAD_COMMAND = struct.Struct("<II")
BUILD_VERSION = struct.Struct("<IIIIII")
VERSION_MIN = struct.Struct("<IIII")
FAT_HEADER = struct.Struct(">II")
FAT_ARCH = struct.Struct(">iiIII")
FAT_ARCH_64 = struct.Struct(">iiQQII")

REQUIRED_RESOURCES = (
    "LICENSE",
    "NOTICE",
    "QR-CODE-NOTICE.txt",
    "DISCOVERY-NOTICES.txt",
    "WEBSOCKET-NOTICE.txt",
    "WEBRTC-NOTICE.txt",
    "WEBRTC-VERSIONS.txt",
)

USAGE_KEYS = (
    "NSAudioCaptureUsageDescription",
    "NSLocalNetworkUsageDescription",
)


def dotted(text):
    if not isinstance(text, str) or re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", text) is None:
        raise ValueError(f"Unreadable macOS version {text!r}")
    parts = tuple(int(part) for part in text.split("."))
    return parts + (0,) * (3 - len(parts))


def version_text(version):
    return ".".join(str(part) for part in (version if version[2] else version[:2]))


def has_control(text):
    return any(unicodedata.category(ch) == "Cc" for ch in text)


def reject_link(path):
    candidate = Path(path)
    if candidate.is_symlink() or (hasattr(candidate, "is_junction") and candidate.is_junction()):
        raise ValueError(f"Symbolic links are not allowed in macOS app staging: {candidate}")


def git_revision(root):
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if re.fullmatch(r"[0-9a-f]{12}", out):
            return out
    except (OSError, subprocess.CalledProcessError):
        pass
    return "local"


def derive_bundle_identity(root=release_version.ROOT, revision=None):
    shared = release_version.read(root)
    version_name = shared["version"]
    rev = git_revision(root) if revision is None else revision
    if not REVISION_RE.match(rev):
        raise ValueError(f"Invalid revision {rev!r}; expected 12 lowercase hex characters or 'local'")
    return {
        "marketing_version": version_name.split("-", 1)[0],
        "build_number": str(shared["android_version_code"]),
        "version_name": version_name,
        "revision": rev,
    }


def make_info_plist(identity, bundle_id=DEFAULT_BUNDLE_ID, minimum_os=DEFAULT_MIN_MACOS):
    dotted(minimum_os)
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "MicDrop",
        "CFBundleExecutable": "MicDrop",
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "MicDrop",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": identity["marketing_version"],
        "CFBundleVersion": identity["build_number"],
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSMinimumSystemVersion": minimum_os,
        "MicDropRevision": identity["revision"],
        "MicDropVersionName": identity["version_name"],
        "NSAudioCaptureUsageDescription": (
            "MicDrop captures desktop output audio only while an authenticated paired phone session is active."
        ),
        "NSBonjourServices": [BONJOUR_SERVICE],
        "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": (
            "MicDrop listens on your selected local network adapter and advertises local pairing discovery "
            "so your paired phone can connect."
        ),
        "NSSupportsAutomaticGraphicsSwitching": True,
    }


def arm64_slice(data, label):
    if len(data) < 8:
        raise ValueError(f"{label}: malformed Mach-O")
    magic = struct.unpack_from(">I", data)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = FAT_HEADER.unpack_from(data)[1]
        entry = FAT_ARCH if magic == FAT_MAGIC else FAT_ARCH_64
        if count == 0 or FAT_HEADER.size + count * entry.size > len(data):
            raise ValueError(f"{label}: malformed Mach-O")
        for index in range(count):
            fields = entry.unpack_from(data, FAT_HEADER.size + index * entry.size)
            cputype, offset, size = fields[0], fields[2], fields[3]
            if cputype == CPU_TYPE_ARM64:
                if size < MACH_HEADER_64.size or offset + size > len(data):
                    raise ValueError(f"{label}: malformed Mach-O")
                return memoryview(data)[offset : offset + size]
        return None
    if struct.unpack_from("<I", data)[0] == MH_MAGIC_64:
        return memoryview(data)
    return None


def parse_macos_arm64_macho(data, label, expected_filetype, kind):
    image = arm64_slice(data, label)
    if image is None or len(image) < MACH_HEADER_64.size:
        raise ValueError(f"{label}: expected an arm64 Mach-O {kind}")
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = MACH_HEADER_64.unpack_from(image)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != expected_filetype:
        raise ValueError(f"{label}: expected an arm64 Mach-O {kind}")
    end = MACH_HEADER_64.size + sizeofcmds
    if end > len(image):
        raise ValueError(f"{label}: malformed Mach-O")
    offset = MACH_HEADER_64.size
    minimum = None
    for _ in range(ncmds):
        if offset + LOAD_COMMAND.size > end:
            raise ValueError(f"{label}: malformed Mach-O")
        cmd, cmdsize = LOAD_COMMAND.unpack_from(image, offset)
        if cmdsize < LOAD_COMMAND.size or offset + cmdsize > end:
            raise ValueError(f"{label}: malformed Mach-O")
        command = image[offset : offset + cmdsize]
        if cmd == LC_BUILD_VERSION:
            if cmdsize < BUILD_VERSION.size:
                raise ValueError(f"{label}: malformed Mach-O")
            _, _, platform, minos, _, _ = BUILD_VERSION.unpack_from(command)
            if platform == PLATFORM_MACOS:
                minimum = (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
        elif cmd == LC_VERSION_MIN_MACOSX and minimum is None:
            if cmdsize < VERSION_MIN.size:
                raise ValueError(f"{label}: malformed Mach-O")
            ver = VERSION_MIN.unpack_from(command)[2]
            minimum = (ver >> 16, (ver >> 8) & 0xFF, ver & 0xFF)
        offset += cmdsize
    if minimum is None:
        raise ValueError(f"{label}: macOS minimum deployment target is missing")
    return minimum


def copy_regular_file(source, destination, mode):
    source = Path(source)
    destination = Path(destination)
    reject_link(source)
    if not source.is_file():
        raise FileNotFoundError(f"Missing required bundle input: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, mode)


def build_app_bundle(
    executable,
    rtc_dylib,
    webrtc_notice,
    webrtc_versions,
    output_app,
    *,
    root=release_version.ROOT,
    bundle_id=DEFAULT_BUNDLE_ID,
    minimum_os=DEFAULT_MIN_MACOS,
    revision=None,
):
    root = Path(root).resolve()
    output_app = Path(output_app)
    if output_app.name != "MicDrop.app":
        raise ValueError(f"Output app bundle must be named MicDrop.app, got {output_app.name!r}")
    reject_link(output_app)
    if output_app.exists():
        shutil.rmtree(output_app)

    identity = derive_bundle_identity(root=root, revision=revision)
    info = make_info_plist(identity, bundle_id=bundle_id, minimum_os=minimum_os)

    contents = output_app / "Contents"
    macos_dir = contents / "MacOS"
    frameworks_dir = contents / "Frameworks"
    resources_dir = contents / "Resources"
    for folder in (macos_dir, frameworks_dir, resources_dir):
        folder.mkdir(parents=True, exist_ok=True)

    (contents / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
    os.chmod(contents / "Info.plist", 0o644)
    (contents / "PkgInfo").write_bytes(b"APPL????")
    os.chmod(contents / "PkgInfo", 0o644)

    copy_regular_file(executable, macos_dir / "MicDrop", 0o755)
    copy_regular_file(rtc_dylib, frameworks_dir / "libmicdrop_rtc.dylib", 0o755)

    notice_sources = {
        "LICENSE": root / "LICENSE",
        "NOTICE": root / "NOTICE",
        "QR-CODE-NOTICE.txt": root / "third_party" / "QR-CODE-NOTICE.txt",
        "DISCOVERY-NOTICES.txt": root / "third_party" / "DISCOVERY-NOTICES.txt",
        "WEBSOCKET-NOTICE.txt": root / "third_party" / "WEBSOCKET-NOTICE.txt",
        "WEBRTC-NOTICE.txt": Path(webrtc_notice),
        "WEBRTC-VERSIONS.txt": Path(webrtc_versions),
    }
    for name, src in notice_sources.items():
        copy_regular_file(src, resources_dir / name, 0o644)

    check_app_directory(
        output_app,
        root=root,
        bundle_id=bundle_id,
        minimum_os=minimum_os,
        revision=identity["revision"],
    )
    return output_app


def _validate_info_dict(info, *, expected_identity, bundle_id, minimum_os, revision):
    if not isinstance(info, dict):
        raise ValueError("Contents/Info.plist is not a dictionary")
    checks = {
        "CFBundleIdentifier": bundle_id,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "MicDrop",
        "LSMinimumSystemVersion": minimum_os,
        "CFBundleShortVersionString": expected_identity["marketing_version"],
        "CFBundleVersion": expected_identity["build_number"],
        "MicDropVersionName": expected_identity["version_name"],
    }
    for key, expected in checks.items():
        actual = info.get(key)
        if actual != expected:
            raise ValueError(f"Info.plist {key} is {actual!r}; expected {expected!r}")
    if "CFBundleIconFile" in info or "CFBundleIconName" in info:
        raise ValueError("Info.plist must not reference custom icon artwork without explicit approval")
    actual_rev = info.get("MicDropRevision")
    if not isinstance(actual_rev, str) or not REVISION_RE.match(actual_rev):
        raise ValueError(f"Info.plist MicDropRevision {actual_rev!r} is invalid")
    if revision is not None and actual_rev != revision:
        raise ValueError(f"Info.plist MicDropRevision {actual_rev!r} does not match {revision!r}")
    if has_control(info["MicDropVersionName"]):
        raise ValueError("Info.plist MicDropVersionName contains control characters")
    for key in USAGE_KEYS:
        val = info.get(key)
        if not isinstance(val, str) or not val.strip():
            raise ValueError(f"Info.plist is missing {key}")
    services = info.get("NSBonjourServices")
    if not isinstance(services, list) or BONJOUR_SERVICE not in services:
        raise ValueError(f"Info.plist NSBonjourServices must declare {BONJOUR_SERVICE}")
    ats = info.get("NSAppTransportSecurity")
    if isinstance(ats, dict) and ats.get("NSAllowsArbitraryLoads") is True:
        raise ValueError("Arbitrary network loads must stay disabled")


def check_app_directory(
    app_dir,
    *,
    root=release_version.ROOT,
    bundle_id=DEFAULT_BUNDLE_ID,
    minimum_os=DEFAULT_MIN_MACOS,
    revision=None,
):
    app_dir = Path(app_dir)
    minimum = dotted(minimum_os)
    reject_link(app_dir)
    if not app_dir.is_dir() or app_dir.name != "MicDrop.app":
        raise ValueError(f"Expected MicDrop.app directory, got {app_dir}")

    total_bytes = 0
    for entry in sorted(app_dir.rglob("*")):
        reject_link(entry)
        if entry.is_file():
            total_bytes += entry.stat().st_size
        elif not entry.is_dir():
            raise ValueError(f"Unexpected special file in bundle: {entry}")
    if total_bytes > MAX_UNCOMPRESSED:
        raise ValueError("MicDrop.app is unexpectedly large")

    info_path = app_dir / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise ValueError("MicDrop.app is missing Contents/Info.plist")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (ValueError, xml.parsers.expat.ExpatError) as exc:
        raise ValueError(f"Contents/Info.plist is unreadable: {exc}") from None

    expected_identity = derive_bundle_identity(root=Path(root), revision=revision)
    _validate_info_dict(
        info,
        expected_identity=expected_identity,
        bundle_id=bundle_id,
        minimum_os=minimum_os,
        revision=revision,
    )

    exe_path = app_dir / "Contents" / "MacOS" / "MicDrop"
    if not exe_path.is_file():
        raise ValueError("MicDrop.app is missing Contents/MacOS/MicDrop")
    if os.name != "nt" and (exe_path.stat().st_mode & 0o111) == 0:
        raise ValueError("Contents/MacOS/MicDrop is not marked executable")
    exe_min = parse_macos_arm64_macho(
        exe_path.read_bytes(), "Contents/MacOS/MicDrop", MH_EXECUTE, "executable"
    )
    if exe_min > minimum:
        raise ValueError(
            f"Contents/MacOS/MicDrop minimum macOS {version_text(exe_min)} exceeds {minimum_os}"
        )

    dylib_path = app_dir / "Contents" / "Frameworks" / "libmicdrop_rtc.dylib"
    if not dylib_path.is_file():
        raise ValueError("MicDrop.app is missing Contents/Frameworks/libmicdrop_rtc.dylib")
    dylib_min = parse_macos_arm64_macho(
        dylib_path.read_bytes(),
        "Contents/Frameworks/libmicdrop_rtc.dylib",
        MH_DYLIB,
        "dynamic library",
    )
    if dylib_min > minimum:
        raise ValueError(
            f"Contents/Frameworks/libmicdrop_rtc.dylib minimum macOS {version_text(dylib_min)} exceeds {minimum_os}"
        )

    for resource in REQUIRED_RESOURCES:
        res_path = app_dir / "Contents" / "Resources" / resource
        if not res_path.is_file() or res_path.stat().st_size == 0:
            raise ValueError(f"MicDrop.app is missing non-empty Contents/Resources/{resource}")


def check_app_zip(
    zip_path,
    *,
    root=release_version.ROOT,
    bundle_id=DEFAULT_BUNDLE_ID,
    minimum_os=DEFAULT_MIN_MACOS,
    revision=None,
):
    zip_path = Path(zip_path)
    reject_link(zip_path)
    minimum = dotted(minimum_os)
    expected_identity = derive_bundle_identity(root=Path(root), revision=revision)

    with zipfile.ZipFile(zip_path) as archive:
        items = archive.infolist()
        if not items:
            raise ValueError("macOS app archive is empty")
        for item in items:
            name = item.filename
            parts = PurePosixPath(name).parts
            if (
                name.startswith("/")
                or ".." in parts
                or "\\" in name
                or not parts
                or parts[0] != "MicDrop.app"
            ):
                raise ValueError(f"Archive entry is unsafe: {name}")
            mode = (item.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise ValueError(f"Archive contains a symbolic link: {name}")
        if sum(item.file_size for item in items) > MAX_UNCOMPRESSED:
            raise ValueError("Archive is unexpectedly large")
        corrupt = archive.testzip()
        if corrupt is not None:
            raise ValueError(f"Archive entry is corrupt: {corrupt}")

        by_name = {item.filename: item for item in items if not item.is_dir()}
        info_name = "MicDrop.app/Contents/Info.plist"
        if info_name not in by_name:
            raise ValueError(f"Archive is missing {info_name}")
        try:
            info = plistlib.loads(archive.read(info_name))
        except (ValueError, xml.parsers.expat.ExpatError) as exc:
            raise ValueError(f"{info_name} is unreadable: {exc}") from None
        _validate_info_dict(
            info,
            expected_identity=expected_identity,
            bundle_id=bundle_id,
            minimum_os=minimum_os,
            revision=revision,
        )

        exe_name = "MicDrop.app/Contents/MacOS/MicDrop"
        if exe_name not in by_name:
            raise ValueError(f"Archive is missing {exe_name}")
        exe_perms = (by_name[exe_name].external_attr >> 16) & 0o777
        if (exe_perms & 0o111) == 0:
            raise ValueError(f"{exe_name} is missing executable permissions in zip archive")
        exe_min = parse_macos_arm64_macho(
            archive.read(exe_name), exe_name, MH_EXECUTE, "executable"
        )
        if exe_min > minimum:
            raise ValueError(
                f"{exe_name} minimum macOS {version_text(exe_min)} exceeds {minimum_os}"
            )

        dylib_name = "MicDrop.app/Contents/Frameworks/libmicdrop_rtc.dylib"
        if dylib_name not in by_name:
            raise ValueError(f"Archive is missing {dylib_name}")
        dylib_min = parse_macos_arm64_macho(
            archive.read(dylib_name), dylib_name, MH_DYLIB, "dynamic library"
        )
        if dylib_min > minimum:
            raise ValueError(
                f"{dylib_name} minimum macOS {version_text(dylib_min)} exceeds {minimum_os}"
            )

        for resource in REQUIRED_RESOURCES:
            res_name = f"MicDrop.app/Contents/Resources/{resource}"
            if res_name not in by_name or by_name[res_name].file_size == 0:
                raise ValueError(f"Archive is missing non-empty {res_name}")

    with zip_path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def zip_app_bundle(
    app_dir,
    output_zip,
    *,
    root=release_version.ROOT,
    bundle_id=DEFAULT_BUNDLE_ID,
    minimum_os=DEFAULT_MIN_MACOS,
    revision=None,
):
    app_dir = Path(app_dir)
    output_zip = Path(output_zip)
    check_app_directory(
        app_dir,
        root=root,
        bundle_id=bundle_id,
        minimum_os=minimum_os,
        revision=revision,
    )
    reject_link(output_zip)
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    fixed_timestamp = (2026, 1, 1, 0, 0, 0)

    with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for entry in sorted(app_dir.rglob("*")):
            reject_link(entry)
            rel = entry.relative_to(app_dir.parent).as_posix()
            if entry.is_dir():
                zinfo = zipfile.ZipInfo(rel + "/", date_time=fixed_timestamp)
                zinfo.external_attr = (stat.S_IFDIR | 0o755) << 16
                archive.writestr(zinfo, b"")
                continue
            is_exec = rel in (
                "MicDrop.app/Contents/MacOS/MicDrop",
                "MicDrop.app/Contents/Frameworks/libmicdrop_rtc.dylib",
            )
            perms = 0o755 if is_exec else 0o644
            zinfo = zipfile.ZipInfo(rel, date_time=fixed_timestamp)
            zinfo.compress_type = zipfile.ZIP_DEFLATED
            zinfo.external_attr = (stat.S_IFREG | perms) << 16
            archive.writestr(zinfo, entry.read_bytes())

    return check_app_zip(
        output_zip,
        root=root,
        bundle_id=bundle_id,
        minimum_os=minimum_os,
        revision=revision,
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    build_cmd = sub.add_parser("build", help="Assemble build/macos-app/MicDrop.app")
    build_cmd.add_argument("--executable", required=True, type=Path)
    build_cmd.add_argument("--rtc-dylib", required=True, type=Path)
    build_cmd.add_argument("--webrtc-notice", required=True, type=Path)
    build_cmd.add_argument("--webrtc-versions", required=True, type=Path)
    build_cmd.add_argument("--output-app", required=True, type=Path)
    build_cmd.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    build_cmd.add_argument("--minimum-os", default=DEFAULT_MIN_MACOS)
    build_cmd.add_argument("--revision")

    check_cmd = sub.add_parser("check", help="Check a MicDrop.app folder or zip archive")
    check_cmd.add_argument("target", type=Path)
    check_cmd.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    check_cmd.add_argument("--minimum-os", default=DEFAULT_MIN_MACOS)
    check_cmd.add_argument("--revision")

    zip_cmd = sub.add_parser("zip", help="Package MicDrop.app into a deterministic zip archive")
    zip_cmd.add_argument("--app", required=True, type=Path)
    zip_cmd.add_argument("--output", required=True, type=Path)
    zip_cmd.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    zip_cmd.add_argument("--minimum-os", default=DEFAULT_MIN_MACOS)
    zip_cmd.add_argument("--revision")

    args = parser.parse_args(argv)
    if args.command == "build":
        out = build_app_bundle(
            args.executable,
            args.rtc_dylib,
            args.webrtc_notice,
            args.webrtc_versions,
            args.output_app,
            bundle_id=args.bundle_id,
            minimum_os=args.minimum_os,
            revision=args.revision,
        )
        print(f"Built {out}")
    elif args.command == "check":
        if args.target.is_dir():
            check_app_directory(
                args.target,
                bundle_id=args.bundle_id,
                minimum_os=args.minimum_os,
                revision=args.revision,
            )
            print(f"Verified {args.target}")
        else:
            digest = check_app_zip(
                args.target,
                bundle_id=args.bundle_id,
                minimum_os=args.minimum_os,
                revision=args.revision,
            )
            print(f"{digest}  {args.target}")
    elif args.command == "zip":
        digest = zip_app_bundle(
            args.app,
            args.output,
            bundle_id=args.bundle_id,
            minimum_os=args.minimum_os,
            revision=args.revision,
        )
        print(f"{digest}  {args.output}")


if __name__ == "__main__":
    main()
