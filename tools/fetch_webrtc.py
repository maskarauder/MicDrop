"""Fetch the exact, checksummed native dependency. Requires Python 3.11+."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import tarfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

IOS_APP_MINIMUM = (17, 0, 0)
IOS_METADATA = {"webrtc/NOTICE", "webrtc/VERSIONS", "webrtc/DEPS"}
IOS_FRAMEWORK = PurePosixPath("webrtc/Frameworks/WebRTC.xcframework")
IOS_HEADERS = PurePosixPath("webrtc/include")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def checked_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
        raise RuntimeError("Unsafe dependency archive path")
    return path


def deployment_version(text):
    text = text.strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", text):
        raise RuntimeError("Unreadable WebRTC iOS deployment target")
    parts = tuple(int(part) for part in text.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_source(versions, source_commit):
    if f"WEBRTC_COMMIT={source_commit}" not in versions.splitlines():
        raise RuntimeError("WebRTC source revision does not match the lock file")


def extract_ios(archive, destination, source_commit):
    metadata = {}
    with tarfile.open(archive, "r:gz") as package:
        # Members are read one by one and never passed to extract/extractall, so the
        # result does not depend on the Python version's tar extraction filter.
        for member in package:
            path = checked_path(member.name)
            if path.is_relative_to(IOS_HEADERS):
                # The SDK header tree is never installed. Upstream Perfetto headers in it
                # are relative symbolic links (12 in m155.8059.2.0); they are skipped
                # unread, while links anywhere else still fail closed.
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise RuntimeError("Dependency archive contains an unsupported entry")
                continue
            if member.issym() or member.islnk():
                raise RuntimeError("Dependency archive contains a symbolic link")
            if member.isdir():
                continue
            if not member.isfile():
                raise RuntimeError("Dependency archive contains an unsupported entry")
            name = path.as_posix()
            if name in IOS_METADATA:
                with package.extractfile(member) as source:
                    metadata[name] = source.read()
            elif path != IOS_FRAMEWORK and path.is_relative_to(IOS_FRAMEWORK):
                target = destination.joinpath(*path.relative_to(IOS_FRAMEWORK.parent).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                # Never carry setuid/setgid or group/other write bits from the archive.
                target.chmod(0o755 if member.mode & 0o100 else 0o644)
                os.utime(target, (member.mtime, member.mtime))
            # Anything else is not needed by the app.
    missing = sorted(IOS_METADATA - metadata.keys())
    if missing:
        raise RuntimeError("WebRTC archive is missing " + ", ".join(missing))
    assets = destination / "assets"
    assets.mkdir()
    (assets / "webrtc-notice.txt").write_bytes(metadata["webrtc/NOTICE"])
    (destination / "VERSIONS").write_bytes(metadata["webrtc/VERSIONS"])
    (destination / "DEPS").write_bytes(metadata["webrtc/DEPS"])
    validate_ios(destination, source_commit)


def validate_ios(destination, source_commit):
    """Check installed provenance on both fresh installs and stamped cache hits."""
    framework = destination / "WebRTC.xcframework"
    try:
        versions = (destination / "VERSIONS").read_text(encoding="utf-8")
        dependencies = (destination / "DEPS").read_text(encoding="utf-8")
        build = json.loads((framework / "build_info.json").read_text(encoding="utf-8"))
        info = plistlib.loads((framework / "Info.plist").read_bytes())
    except (OSError, ValueError) as error:
        raise RuntimeError("WebRTC.xcframework metadata is missing or unreadable") from error
    if not isinstance(build, dict) or not isinstance(info, dict):
        raise RuntimeError("WebRTC.xcframework metadata is missing or unreadable")
    validate_source(versions, source_commit)
    if build.get("revision") != source_commit:
        raise RuntimeError("WebRTC source revision does not match the lock file")
    targets = [line.partition("=")[2] for line in dependencies.splitlines()
               if line.startswith("IOS_DEPLOYMENT_TARGET=")]
    if len(targets) != 1:
        raise RuntimeError("Unreadable WebRTC iOS deployment target")
    if deployment_version(targets[0]) > IOS_APP_MINIMUM:
        raise RuntimeError("WebRTC iOS deployment target exceeds the app minimum")
    libraries = info.get("AvailableLibraries", [])
    devices = [entry for entry in libraries if isinstance(entry, dict)] if isinstance(libraries, list) else []
    devices = [entry for entry in devices
               if entry.get("SupportedPlatform") == "ios" and "SupportedPlatformVariant" not in entry
               and "arm64" in entry.get("SupportedArchitectures", [])]
    if len(devices) != 1:
        raise RuntimeError("WebRTC.xcframework needs exactly one iOS arm64 device slice")
    identifier, library = devices[0].get("LibraryIdentifier", ""), devices[0].get("LibraryPath", "")
    for part in (identifier, library):
        if not isinstance(part, str) or not part or "/" in part or "\\" in part or part in (".", ".."):
            raise RuntimeError("Unsafe dependency archive path")
    binary = framework / identifier / library / "WebRTC"
    magic = b""
    if binary.is_file():
        with binary.open("rb") as source:
            magic = source.read(4)
    # MH_MAGIC_64 (little-endian) or a FAT header (big-endian); the pinned release is FAT.
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        raise RuntimeError("WebRTC.xcframework device binary is missing")


def fetch(platform, root):
    lock = json.loads((root / "third_party/webrtc.lock.json").read_text())
    asset = lock["assets"][platform]
    # A platform-specific repair must not upgrade the other native engine.
    version = asset.get("build_version", lock["build_version"])
    source_commit = asset.get("webrtc_commit", lock["webrtc_commit"])
    cache = root / ".deps/cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (asset["sha256"] + "-" + asset["name"])
    if not archive.exists() or digest(archive) != asset["sha256"]:
        url = f'{lock["builder_repository"]}/releases/download/{version}/{asset["name"]}'
        partial = archive.with_suffix(".partial")
        try:
            with urllib.request.urlopen(url, timeout=60) as source, partial.open("wb") as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            if asset.get("size") is not None and partial.stat().st_size != asset["size"]:
                raise RuntimeError("WebRTC archive size mismatch")
            if digest(partial) != asset["sha256"]:
                raise RuntimeError("WebRTC archive checksum mismatch")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    destination = root / ".deps/webrtc" / platform
    stamp = destination / "verified.sha256"
    if stamp.exists() and stamp.read_text().strip() == asset["sha256"]:
        # A checksum stamp identifies the archive, not the current lock's source
        # expectation. Recheck provenance when a local lock or install changes.
        if platform == "ios":
            validate_ios(destination, source_commit)
        elif platform == "windows":
            validate_source((destination / "webrtc/VERSIONS").read_text(), source_commit)
        print(f"Verified WebRTC {version}: {destination}")
        return
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    if platform == "ios":
        # The iOS SDK is a tar.gz, not a zip; branch before opening it.
        extract_ios(archive, destination, source_commit)
    else:
        with zipfile.ZipFile(archive) as package:
            if platform == "windows":
                for item in package.infolist():
                    path = PurePosixPath(item.filename)
                    if path.is_absolute() or ".." in path.parts or "\\" in item.filename or ":" in item.filename:
                        raise RuntimeError("Unsafe dependency archive path")
                    if (item.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError("Dependency archive contains a symbolic link")
                    # Symbols are not needed for this developer executable.
                    if item.filename.endswith(".pdb"):
                        continue
                    package.extract(item, destination)
                versions = (destination / "webrtc/VERSIONS").read_text()
                validate_source(versions, source_commit)
            else:
                shutil.copyfile(archive, destination / "libwebrtc.aar")
                assets = destination / "assets"
                assets.mkdir()
                (assets / "webrtc-notice.txt").write_bytes(package.read("META-INF/NOTICE"))
    stamp.write_text(asset["sha256"] + "\n")
    print(f"Verified WebRTC {version}: {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["windows", "android", "ios"])
    arguments = parser.parse_args()
    fetch(arguments.platform, Path(__file__).resolve().parents[1])
