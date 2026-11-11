"""Fetch the exact, checksummed native dependency. Requires Python 3.11+."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

IOS_APP_MINIMUM = (17, 0, 0)
MACOS_HOST_MINIMUM = (14, 2, 0)
IOS_METADATA = {"webrtc/NOTICE", "webrtc/VERSIONS", "webrtc/DEPS"}
IOS_FRAMEWORK = PurePosixPath("webrtc/Frameworks/WebRTC.xcframework")
MACOS_FRAMEWORKS = PurePosixPath("webrtc/Frameworks")
IOS_HEADERS = PurePosixPath("webrtc/include")
SKIPPED_POSIX_HEADERS = (
    PurePosixPath("webrtc/include/build/linux"),
    PurePosixPath("webrtc/include/third_party/perfetto"),
)
POSIX_HOST_ARCHIVE = PurePosixPath("webrtc/lib/libwebrtc.a")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def checked_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
        raise RuntimeError("Unsafe dependency archive path")
    return path


def deployment_version(text, label="iOS"):
    text = text.strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", text):
        raise RuntimeError(f"Unreadable WebRTC {label} deployment target")
    parts = tuple(int(part) for part in text.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_source(versions, source_commit):
    if f"WEBRTC_COMMIT={source_commit}" not in versions.splitlines():
        raise RuntimeError("WebRTC source revision does not match the lock file")


def checked_relative_symlink(member_path, linkname):
    if not linkname or linkname.startswith("/") or "\\" in linkname or ":" in linkname:
        raise RuntimeError("Unsafe dependency archive link")
    resolved = []
    for part in member_path.parent.parts + PurePosixPath(linkname).parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not resolved:
                raise RuntimeError("Unsafe dependency archive link")
            resolved.pop()
        else:
            resolved.append(part)


def download_cached(url, archive, expected_sha256, expected_size=None, decode_base64=False, label="WebRTC archive"):
    if archive.exists() and digest(archive) == expected_sha256:
        if expected_size is None or archive.stat().st_size == expected_size:
            return
    partial = archive.with_suffix(archive.suffix + ".partial")
    try:
        with urllib.request.urlopen(url, timeout=60) as source:
            if decode_base64:
                payload = base64.b64decode(source.read())
                partial.write_bytes(payload)
            else:
                with partial.open("wb") as target:
                    shutil.copyfileobj(source, target, 1024 * 1024)
        if expected_size is not None and partial.stat().st_size != expected_size:
            raise RuntimeError(f"{label} size mismatch")
        if digest(partial) != expected_sha256:
            raise RuntimeError(f"{label} checksum mismatch")
        partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)


def extract_clang_archive(archive, destination):
    with tarfile.open(archive, "r:*") as package:
        for member in package:
            path = checked_path(member.name)
            if member.islnk():
                raise RuntimeError("Dependency archive contains a hard link")
            if member.isdir():
                continue
            if member.issym():
                checked_relative_symlink(path, member.linkname)
                target = destination.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.is_symlink() or target.exists():
                    target.unlink()
                target.symlink_to(member.linkname)
                continue
            if not member.isfile():
                raise RuntimeError("Dependency archive contains an unsupported entry")
            target = destination.joinpath(*path.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink() or target.exists():
                target.unlink()
            with package.extractfile(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            target.chmod(0o755 if member.mode & 0o100 else 0o644)
            os.utime(target, (member.mtime, member.mtime))


def compute_tree_sha256(root, exclude=()):
    excluded = set(exclude)
    state = hashlib.sha256()
    seen = 0
    for item in sorted(p for p in root.rglob("*") if ".git" not in p.parts and (p.is_file() or p.is_symlink())):
        if item.is_symlink():
            raise RuntimeError("Unexpected symbolic link in libcxx tree")
        rel = item.relative_to(root).as_posix()
        if rel in excluded:
            continue
        state.update(f"{rel}:{digest(item)}\n".encode("utf-8"))
        seen += 1
    if seen == 0:
        raise RuntimeError("Empty libcxx header tree")
    return state.hexdigest()


def install_libcxx(spec, cache, destination):
    libcxx_dir = destination / "libcxx"
    cached_tar = cache / f"{spec['tree_sha256']}-libcxx-{spec['commit'][:12]}.tar.gz"
    restored = False
    if cached_tar.is_file():
        libcxx_dir.mkdir(parents=True, exist_ok=True)
        with tarfile.open(cached_tar, "r:gz") as package:
            for member in package:
                path = checked_path(member.name)
                if member.issym() or member.islnk():
                    raise RuntimeError("Dependency archive contains a symbolic link")
                if member.isdir():
                    continue
                if not member.isfile():
                    raise RuntimeError("Dependency archive contains an unsupported entry")
                target = libcxx_dir.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o644)
        if compute_tree_sha256(libcxx_dir) == spec["tree_sha256"]:
            restored = True
        else:
            cached_tar.unlink(missing_ok=True)
            shutil.rmtree(libcxx_dir, ignore_errors=True)
    if not restored:
        with tempfile.TemporaryDirectory(dir=cache, prefix="libcxx-fetch-") as tmp:
            tmp_path = Path(tmp)
            subprocess.run(["git", "-C", tmp, "init", "-q"], check=True)
            subprocess.run(
                ["git", "-C", tmp, "fetch", "-q", "--depth", "1", spec["repository"], spec["commit"]],
                check=True,
            )
            fetched = subprocess.check_output(
                ["git", "-C", tmp, "rev-parse", "FETCH_HEAD"], text=True
            ).strip()
            if fetched != spec["commit"]:
                raise RuntimeError("Fetched libcxx revision does not match the lock file")
            subprocess.run(
                ["git", "-C", tmp, "checkout", "-q", "FETCH_HEAD", "--", "include", "LICENSE.TXT"],
                check=True,
            )
            if compute_tree_sha256(tmp_path) != spec["tree_sha256"]:
                raise RuntimeError("Fetched libcxx header tree checksum mismatch")
            partial = cached_tar.with_suffix(".tar.gz.partial")
            try:
                with tarfile.open(partial, "w:gz") as package:
                    for item in sorted(p for p in tmp_path.rglob("*") if ".git" not in p.parts and p.is_file()):
                        rel = item.relative_to(tmp_path)
                        target = libcxx_dir.joinpath(*rel.parts)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(item, target)
                        target.chmod(0o644)
                        info = tarfile.TarInfo(rel.as_posix())
                        info.size = item.stat().st_size
                        info.mode = 0o644
                        info.mtime = 0
                        with item.open("rb") as source:
                            package.addfile(info, source)
                partial.replace(cached_tar)
            finally:
                partial.unlink(missing_ok=True)
    for key, filename in (("config_site", "__config_site"), ("assertion_handler", "__assertion_handler")):
        item = spec[key]
        blob = cache / f"{item['sha256']}-{filename}"
        download_cached(
            item["url"],
            blob,
            item["sha256"],
            item.get("size"),
            decode_base64=True,
            label=f"libcxx {filename}",
        )
        target = libcxx_dir / "include" / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(blob, target)
        target.chmod(0o644)


def install_posix_toolchain(toolchain, cache, destination):
    clang_dir = destination / "clang"
    clang_dir.mkdir(parents=True, exist_ok=True)
    for item in toolchain["archives"]:
        archive = cache / (item["sha256"] + "-" + item["name"])
        download_cached(item["url"], archive, item["sha256"], item.get("size"), label="WebRTC Clang archive")
        extract_clang_archive(archive, clang_dir)
    install_libcxx(toolchain["libcxx"], cache, destination)


def stamp_digest(asset):
    if "toolchain" not in asset:
        return asset["sha256"]
    canonical = json.dumps(
        {"sha256": asset["sha256"], "toolchain": asset["toolchain"]},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def extract_posix_host(archive, destination, source_commit, platform, cache=None, toolchain=None):
    seen = set()
    with tarfile.open(archive, "r:gz") as package:
        for member in package:
            path = checked_path(member.name)
            if platform == "macos" and path.is_relative_to(MACOS_FRAMEWORKS):
                # The macOS host links libwebrtc.a into its C-ABI dylib directly;
                # skip the duplicate Objective-C xcframework and dSYM payload.
                if not (member.isfile() or member.isdir()):
                    raise RuntimeError("Dependency archive contains an unsupported entry")
                continue
            if any(path.is_relative_to(skipped) for skipped in SKIPPED_POSIX_HEADERS):
                # Chromium's bundled Debian sysroot and disabled Perfetto headers
                # contain relative symlinks and are never included by native/rtc.
                if not (member.isfile() or member.isdir() or member.issym()):
                    raise RuntimeError("Dependency archive contains an unsupported entry")
                continue
            if member.issym() or member.islnk():
                raise RuntimeError("Dependency archive contains a symbolic link")
            if member.isdir():
                continue
            if not member.isfile():
                raise RuntimeError("Dependency archive contains an unsupported entry")
            name = path.as_posix()
            if name in IOS_METADATA or path == POSIX_HOST_ARCHIVE or path.is_relative_to(IOS_HEADERS):
                target = destination.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o644)
                os.utime(target, (member.mtime, member.mtime))
                seen.add(name)
    missing = sorted((IOS_METADATA | {POSIX_HOST_ARCHIVE.as_posix()}) - seen)
    if missing:
        raise RuntimeError("WebRTC archive is missing " + ", ".join(missing))
    if toolchain is not None:
        install_posix_toolchain(toolchain, cache, destination)
    validate_posix_host(destination, source_commit, platform, toolchain)


def validate_posix_host(destination, source_commit, platform, toolchain=None):
    """Check installed provenance and static archive headers on fresh and cached installs."""
    root = destination / "webrtc"
    try:
        versions = (root / "VERSIONS").read_text(encoding="utf-8")
        dependencies = (root / "DEPS").read_text(encoding="utf-8")
        notice = (root / "NOTICE").read_bytes()
    except (OSError, ValueError) as error:
        raise RuntimeError("WebRTC host metadata is missing or unreadable") from error
    if not notice:
        raise RuntimeError("WebRTC host metadata is missing or unreadable")
    validate_source(versions, source_commit)
    version_lines = set(versions.splitlines())
    if toolchain is not None:
        expected_lines = (
            f"WEBRTC_SRC_TOOLS_COMMIT={toolchain['tools_commit']}",
            f"WEBRTC_SRC_BUILDTOOLS_COMMIT={toolchain['buildtools_commit']}",
            f"WEBRTC_SRC_THIRD_PARTY_LIBCXX_SRC_COMMIT={toolchain['libcxx']['commit']}",
        )
        if not all(line in version_lines for line in expected_lines):
            raise RuntimeError("WebRTC toolchain provenance does not match the lock file")
        if not (destination / "clang/bin/clang").is_file() or not (destination / "clang/bin/clang++").exists():
            raise RuntimeError("WebRTC Clang compiler is missing")
        libcxx_dir = destination / "libcxx"
        if not (libcxx_dir / "include/string").is_file() or not (libcxx_dir / "LICENSE.TXT").is_file():
            raise RuntimeError("WebRTC libc++ headers are missing")
        for key, filename in (("config_site", "__config_site"), ("assertion_handler", "__assertion_handler")):
            header = libcxx_dir / "include" / filename
            if not header.is_file() or digest(header) != toolchain["libcxx"][key]["sha256"]:
                raise RuntimeError(f"WebRTC libc++ {filename} is missing or modified")
    if platform == "macos":
        targets = [line.partition("=")[2] for line in dependencies.splitlines()
                   if line.startswith("MACOS_DEPLOYMENT_TARGET=")]
        if len(targets) != 1:
            raise RuntimeError("Unreadable WebRTC macOS deployment target")
        if deployment_version(targets[0], "macOS") > MACOS_HOST_MINIMUM:
            raise RuntimeError("WebRTC macOS deployment target exceeds the host minimum")
    library = root / "lib/libwebrtc.a"
    magic = b""
    if library.is_file():
        with library.open("rb") as source:
            magic = source.read(8)
    if magic != b"!<arch>\n" and not (platform == "macos" and magic[:4] == b"\xca\xfe\xba\xbe"):
        raise RuntimeError("WebRTC static library is missing")
    if not (root / "include/api/peer_connection_interface.h").is_file():
        raise RuntimeError("WebRTC C++ headers are missing")


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
    expected = stamp_digest(asset)
    if stamp.exists() and stamp.read_text().strip() == expected:
        # A checksum stamp identifies the archive, not the current lock's source
        # expectation. Recheck provenance when a local lock or install changes.
        if platform == "ios":
            validate_ios(destination, source_commit)
        elif platform in ("linux", "macos"):
            validate_posix_host(destination, source_commit, platform, asset.get("toolchain"))
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
    elif platform in ("linux", "macos"):
        extract_posix_host(archive, destination, source_commit, platform, cache, asset.get("toolchain"))
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
    stamp.write_text(expected + "\n")
    print(f"Verified WebRTC {version}: {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["windows", "linux", "macos", "android", "ios"])
    arguments = parser.parse_args()
    fetch(arguments.platform, Path(__file__).resolve().parents[1])
