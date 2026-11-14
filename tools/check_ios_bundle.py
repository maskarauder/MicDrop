"""Check unsigned or App Store signed iPhone IPAs: entries, Info.plist, PrivacyInfo, icons, Mach-O, WebRTC, and notices."""
import argparse
import hashlib
import plistlib
import re
import struct
import unicodedata
import xml.parsers.expat
import zipfile
from pathlib import Path, PurePosixPath

MAX_UNCOMPRESSED = 512 * 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2
MH_DYLIB = 6
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001C
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
MACH_HEADER_64 = struct.Struct("<IiiIIIII")
LOAD_COMMAND = struct.Struct("<II")
DYLIB_COMMAND = struct.Struct("<IIIIII")
RPATH_COMMAND = struct.Struct("<III")
BUILD_VERSION = struct.Struct("<IIIIII")
VERSION_MIN = struct.Struct("<IIII")
FAT_HEADER = struct.Struct(">II")
FAT_ARCH = struct.Struct(">iiIII")
FAT_ARCH_64 = struct.Struct(">iiQQII")
WEBRTC_LOAD = "@rpath/WebRTC.framework/WebRTC"
FRAMEWORKS_RPATH = "@executable_path/Frameworks"
REVISION = re.compile(r"^([0-9a-f]{12}|local)$")
USAGE_KEYS = ("NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription")
NOTICES = ("NOTICE", "LICENSE", "ios-notices.txt", "webrtc-notice.txt")
BONJOUR_SERVICE = "_micdrop._tcp"
REQUIRED_PRIVACY_CATEGORIES = {
    "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPICategorySystemBootTime",
    "NSPrivacyAccessedAPICategoryFileTimestamp",
}


def dotted(text):
    if not isinstance(text, str) or re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", text) is None:
        raise ValueError(f"Unreadable iOS version {text!r}")
    parts = tuple(int(part) for part in text.split("."))
    return parts + (0,) * (3 - len(parts))


def version_text(version):
    return ".".join(str(part) for part in (version if version[2] else version[:2]))


def arm64_slice(data, path):
    """The arm64 Mach-O image of a thin or FAT binary, or None if there is none."""
    if len(data) < 8:
        raise ValueError(f"{path}: malformed Mach-O")
    magic = struct.unpack_from(">I", data)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = FAT_HEADER.unpack_from(data)[1]
        entry = FAT_ARCH if magic == FAT_MAGIC else FAT_ARCH_64
        if count == 0 or FAT_HEADER.size + count * entry.size > len(data):
            raise ValueError(f"{path}: malformed Mach-O")
        for index in range(count):
            fields = entry.unpack_from(data, FAT_HEADER.size + index * entry.size)
            cputype, offset, size = fields[0], fields[2], fields[3]
            if cputype == CPU_TYPE_ARM64:
                if size < MACH_HEADER_64.size or offset + size > len(data):
                    raise ValueError(f"{path}: malformed Mach-O")
                return memoryview(data)[offset:offset + size]
        return None
    if struct.unpack_from("<I", data)[0] == MH_MAGIC_64:
        return memoryview(data)
    return None


def command_string(command, offset, path):
    if offset < 8 or offset >= len(command):
        raise ValueError(f"{path}: malformed Mach-O")
    raw = bytes(command[offset:]).split(b"\0", 1)[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ValueError(f"{path}: malformed Mach-O") from None


def parse_macho(image, path):
    """(filetype, iOS minimum or None, loaded dylibs, run paths) of an arm64 Mach-O image."""
    if len(image) < MACH_HEADER_64.size:
        raise ValueError(f"{path}: malformed Mach-O")
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = MACH_HEADER_64.unpack_from(image)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        return None
    end = MACH_HEADER_64.size + sizeofcmds
    if end > len(image):
        raise ValueError(f"{path}: malformed Mach-O")
    offset, minimum, dylibs, rpaths = MACH_HEADER_64.size, None, [], []
    for _ in range(ncmds):
        if offset + LOAD_COMMAND.size > end:
            raise ValueError(f"{path}: malformed Mach-O")
        cmd, cmdsize = LOAD_COMMAND.unpack_from(image, offset)
        if cmdsize < LOAD_COMMAND.size or offset + cmdsize > end:
            raise ValueError(f"{path}: malformed Mach-O")
        command = image[offset:offset + cmdsize]
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            if cmdsize < DYLIB_COMMAND.size:
                raise ValueError(f"{path}: malformed Mach-O")
            dylibs.append(command_string(command, DYLIB_COMMAND.unpack_from(command)[2], path))
        elif cmd == LC_RPATH:
            if cmdsize < RPATH_COMMAND.size:
                raise ValueError(f"{path}: malformed Mach-O")
            rpaths.append(command_string(command, RPATH_COMMAND.unpack_from(command)[2], path))
        elif cmd == LC_BUILD_VERSION:
            if cmdsize < BUILD_VERSION.size:
                raise ValueError(f"{path}: malformed Mach-O")
            _, _, platform, minos, _, _ = BUILD_VERSION.unpack_from(command)
            if platform == PLATFORM_IOS:
                minimum = (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
        elif cmd == LC_VERSION_MIN_IPHONEOS and minimum is None:
            if cmdsize < VERSION_MIN.size:
                raise ValueError(f"{path}: malformed Mach-O")
            version = VERSION_MIN.unpack_from(command)[2]
            minimum = (version >> 16, (version >> 8) & 0xFF, version & 0xFF)
        offset += cmdsize
    return filetype, minimum, dylibs, rpaths


def arm64_macho(data, path, filetype, kind):
    image = arm64_slice(data, path)
    parsed = parse_macho(image, path) if image is not None else None
    if parsed is None or parsed[0] != filetype:
        raise ValueError(f"{path}: expected an arm64 Mach-O {kind}")
    if parsed[1] is None:
        raise ValueError(f"{path}: iOS minimum is missing")
    return parsed


def has_control(text):
    return any(unicodedata.category(character) == "Cc" for character in text)


def read_info(package, path):
    try:
        info = plistlib.loads(package.read(path))
    except (ValueError, xml.parsers.expat.ExpatError) as error:
        raise ValueError(f"{path} is unreadable: {error}") from None
    if not isinstance(info, dict):
        raise ValueError(f"{path} is not a dictionary")
    return info


def require_equal(info, key, expected, path="Info.plist"):
    actual = info.get(key)
    if actual != expected:
        raise ValueError(f"{path} {key} is {actual!r}; expected {expected!r}")


def check_privacy_manifest(privacy, path):
    if not isinstance(privacy.get("NSPrivacyTracking"), bool) or privacy.get("NSPrivacyTracking") is not False:
        raise ValueError(f"{path} NSPrivacyTracking must be false")
    if privacy.get("NSPrivacyTrackingDomains") != []:
        raise ValueError(f"{path} NSPrivacyTrackingDomains must be empty")
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        raise ValueError(f"{path} NSPrivacyCollectedDataTypes must be empty")
    accessed = privacy.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed, list):
        raise ValueError(f"{path} NSPrivacyAccessedAPITypes must be an array")
    categories = set()
    for item in accessed:
        if not isinstance(item, dict):
            raise ValueError(f"{path} NSPrivacyAccessedAPITypes entry must be a dictionary")
        cat = item.get("NSPrivacyAccessedAPIType")
        reasons = item.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(cat, str) or not isinstance(reasons, list) or not reasons:
            raise ValueError(f"{path} NSPrivacyAccessedAPITypes entry is incomplete")
        categories.add(cat)
    missing = REQUIRED_PRIVACY_CATEGORIES - categories
    if missing:
        raise ValueError(f"{path} is missing required API category {sorted(missing)[0]}")


def check_info(info, entries, app, bundle_id, minimum_os, revision,
               marketing_version=None, build_number=None, version_name=None):
    require_equal(info, "CFBundleIdentifier", bundle_id)
    require_equal(info, "MinimumOSVersion", minimum_os)
    require_equal(info, "UIDeviceFamily", [1])
    if marketing_version is not None:
        require_equal(info, "CFBundleShortVersionString", marketing_version)
    if build_number is not None:
        require_equal(info, "CFBundleVersion", build_number)
    exempt = info.get("ITSAppUsesNonExemptEncryption")
    if not isinstance(exempt, bool) or exempt is not False:
        raise ValueError("Info.plist ITSAppUsesNonExemptEncryption must be false")
    icons = info.get("CFBundleIcons")
    primary_icon = icons.get("CFBundlePrimaryIcon") if isinstance(icons, dict) else None
    icon_files = primary_icon.get("CFBundleIconFiles") if isinstance(primary_icon, dict) else None
    icon_name = primary_icon.get("CFBundleIconName") if isinstance(primary_icon, dict) else None
    if not isinstance(primary_icon, dict) or (
        icon_name != "AppIcon"
        and not (isinstance(icon_files, list) and any(isinstance(f, str) and f.strip() for f in icon_files))
    ):
        raise ValueError("Info.plist is missing compiled AppIcon metadata (CFBundleIcons)")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable or executable in (".", ".."):
        raise ValueError(f"Info.plist CFBundleExecutable is {executable!r}; expected the executable's file name")
    if f"{app}/{executable}" not in entries:
        raise ValueError(f"Main executable {app}/{executable} is missing")
    modes = info.get("UIBackgroundModes")
    if not isinstance(modes, list) or "audio" not in modes:
        raise ValueError("Background audio mode is missing")
    for key in USAGE_KEYS:
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Info.plist is missing {key}")
    services = info.get("NSBonjourServices")
    if not isinstance(services, list) or BONJOUR_SERVICE not in services:
        raise ValueError(f"Bonjour service {BONJOUR_SERVICE} is not declared")
    transport = info.get("NSAppTransportSecurity")
    if isinstance(transport, dict) and transport.get("NSAllowsArbitraryLoads") is True:
        raise ValueError("Arbitrary network loads must stay disabled")
    actual = info.get("MicDropRevision")
    if not isinstance(actual, str) or not REVISION.match(actual):
        raise ValueError(f"Build revision {actual} does not match {revision or '12 lowercase hex or local'}")
    if revision is not None and actual != revision:
        raise ValueError(f"Build revision {actual} does not match {revision}")
    name = info.get("MicDropVersionName")
    if not isinstance(name, str) or not name or len(name) > 80 or has_control(name):
        raise ValueError(f"Info.plist MicDropVersionName is {name!r}; expected 1-80 characters without controls")
    if version_name is not None:
        require_equal(info, "MicDropVersionName", version_name)
    return executable


def check_ipa(path, bundle_id, minimum_os, revision=None, *,
              marketing_version=None, build_number=None, version_name=None, signed=False):
    """Raise ValueError for the first violated contract; return the IPA's SHA-256."""
    minimum = dotted(minimum_os)
    # Xcode App Store exports include SDK-origin signature receipts in Signatures/.
    allowed_roots = {"Payload", "Symbols", "SwiftSupport", "Signatures"} if signed else {"Payload"}
    with zipfile.ZipFile(path) as package:
        items = package.infolist()
        seen_paths = set()
        for item in items:
            name = item.filename
            parts = PurePosixPath(name).parts
            if (
                name.startswith("/")
                or ".." in parts
                or "\\" in name
                or not parts
                or parts[0] not in allowed_roots
            ):
                raise ValueError(f"IPA entry is unsafe: {name}")
            # PurePosixPath also normalizes repeated separators and '.' components.
            # Reject aliases before extraction can overwrite a previously checked entry.
            if parts in seen_paths:
                raise ValueError(f"IPA contains a duplicate path: {name}")
            seen_paths.add(parts)
        for item in items:
            if (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f"IPA contains a symbolic link: {item.filename}")
        if sum(item.file_size for item in items) > MAX_UNCOMPRESSED:
            raise ValueError("IPA is unexpectedly large")
        corrupt = package.testzip()
        if corrupt is not None:
            raise ValueError(f"IPA entry is corrupt: {corrupt}")
        tops = {
            PurePosixPath(item.filename).parts[1]
            for item in items
            if len(PurePosixPath(item.filename).parts) > 1 and PurePosixPath(item.filename).parts[0] == "Payload"
        }
        if len(tops) != 1 or not next(iter(tops)).endswith(".app") or next(iter(tops)) == ".app":
            raise ValueError("IPA must contain exactly one Payload/*.app bundle")
        app = "Payload/" + next(iter(tops))
        entries = {item.filename: item for item in items if not item.is_dir()}
        if not signed:
            for item in items:
                if "/_CodeSignature/" in item.filename or item.filename.endswith("embedded.mobileprovision"):
                    raise ValueError(f"IPA must be unsigned; found {item.filename}")
        else:
            required_sig_files = (
                f"{app}/_CodeSignature/CodeResources",
                f"{app}/Frameworks/WebRTC.framework/_CodeSignature/CodeResources",
                f"{app}/embedded.mobileprovision",
            )
            for sig_path in required_sig_files:
                if sig_path not in entries or entries[sig_path].file_size == 0:
                    raise ValueError(f"Signed IPA is missing non-empty {sig_path}")

        info_path = f"{app}/Info.plist"
        if info_path not in entries:
            raise ValueError(f"IPA is missing {info_path}")
        info = read_info(package, info_path)
        executable = check_info(
            info, entries, app, bundle_id, minimum_os, revision,
            marketing_version=marketing_version, build_number=build_number, version_name=version_name)

        assets_car = f"{app}/Assets.car"
        if assets_car not in entries or entries[assets_car].file_size == 0:
            raise ValueError(f"IPA is missing compiled asset catalog {assets_car}")

        privacy_path = f"{app}/PrivacyInfo.xcprivacy"
        if privacy_path not in entries:
            raise ValueError(f"IPA is missing {privacy_path}")
        check_privacy_manifest(read_info(package, privacy_path), privacy_path)

        main_path = f"{app}/{executable}"
        _, main_minimum, dylibs, rpaths = arm64_macho(package.read(main_path), main_path, MH_EXECUTE, "executable")
        if main_minimum != minimum:
            raise ValueError(f"{main_path}: iOS minimum {version_text(main_minimum)} does not match {minimum_os}")
        if WEBRTC_LOAD not in dylibs:
            raise ValueError(f"Main executable does not load {WEBRTC_LOAD}")
        if FRAMEWORKS_RPATH not in rpaths:
            raise ValueError(f"Main executable lacks {FRAMEWORKS_RPATH} run path")

        webrtc_path = f"{app}/Frameworks/WebRTC.framework/WebRTC"
        if webrtc_path not in entries:
            raise ValueError(f"{webrtc_path}: expected an arm64 Mach-O dynamic library")
        _, webrtc_minimum, _, _ = arm64_macho(package.read(webrtc_path), webrtc_path, MH_DYLIB, "dynamic library")
        if webrtc_minimum > minimum:
            raise ValueError(f"{webrtc_path}: iOS minimum {version_text(webrtc_minimum)} exceeds {minimum_os}")
        framework_info = f"{app}/Frameworks/WebRTC.framework/Info.plist"
        if framework_info not in entries:
            raise ValueError(f"IPA is missing {framework_info}")
        framework = read_info(package, framework_info)
        require_equal(framework, "CFBundleExecutable", "WebRTC", framework_info)
        require_equal(framework, "CFBundlePackageType", "FMWK", framework_info)
        try:
            framework_minimum = dotted(framework.get("MinimumOSVersion"))
        except ValueError as error:
            raise ValueError(f"{framework_info}: {error}") from None
        if framework_minimum > minimum:
            raise ValueError(f"{framework_info}: iOS minimum {version_text(framework_minimum)} exceeds {minimum_os}")
        if framework_minimum != webrtc_minimum:
            raise ValueError(f"{framework_info}: iOS minimum {version_text(framework_minimum)} does not match "
                             f"WebRTC binary minimum {version_text(webrtc_minimum)}")

        for notice in NOTICES:
            notice_path = f"{app}/{notice}"
            try:
                valid = notice_path in entries and bool(package.read(notice_path).decode("utf-8").strip())
            except UnicodeDecodeError:
                valid = False
            if not valid:
                raise ValueError(f"Missing notice {notice}")
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--minimum-os", required=True)
    parser.add_argument("--revision")
    parser.add_argument("--signed", action="store_true", help="Verify an App Store Connect signed IPA")
    arguments = parser.parse_args()
    try:
        sha256 = check_ipa(
            arguments.ipa,
            arguments.bundle_id,
            arguments.minimum_os,
            arguments.revision,
            signed=arguments.signed,
        )
    except (ValueError, zipfile.BadZipFile, OSError) as error:
        parser.exit(1, f"iPhone bundle check failed: {error}\n")
    label = "signed" if arguments.signed else "unsigned"
    print(f"Verified {label} iPhone IPA {sha256}")
