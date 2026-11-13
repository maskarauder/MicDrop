"""Reject malformed, signed or incompletely embedded iPhone IPAs before publication."""
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from check_ios_bundle import (
    BUILD_VERSION, CPU_TYPE_ARM64, DYLIB_COMMAND, FAT_ARCH, FAT_HEADER, FAT_MAGIC, LC_BUILD_VERSION, LC_LOAD_DYLIB,
    LC_LOAD_WEAK_DYLIB, LC_RPATH, LC_VERSION_MIN_IPHONEOS, MACH_HEADER_64, MH_DYLIB, MH_EXECUTE, MH_MAGIC_64,
    PLATFORM_IOS, RPATH_COMMAND, VERSION_MIN, check_ipa)

APP = "Payload/MicDrop.app/"
WEBRTC = "@rpath/WebRTC.framework/WebRTC"
RPATH = "@executable_path/Frameworks"


def padded(raw, header_size):
    size = (header_size + len(raw) + 7) & ~7
    return size, raw.ljust(size - header_size, b"\0")


def encoded(version):
    return version[0] << 16 | version[1] << 8 | (version[2] if len(version) > 2 else 0)


def macho(filetype=MH_EXECUTE, minimum=(17, 0), dylibs=(WEBRTC,), rpaths=(RPATH,), cputype=CPU_TYPE_ARM64,
          platform=PLATFORM_IOS, weak=False, legacy_minimum=False):
    commands = []
    if legacy_minimum:
        commands.append(VERSION_MIN.pack(LC_VERSION_MIN_IPHONEOS, VERSION_MIN.size, encoded(minimum), encoded((26, 5))))
    else:
        commands.append(BUILD_VERSION.pack(LC_BUILD_VERSION, BUILD_VERSION.size, platform, encoded(minimum),
                                           encoded((26, 5)), 0))
    for name in dylibs:
        size, raw = padded(name.encode() + b"\0", DYLIB_COMMAND.size)
        command = LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB
        commands.append(DYLIB_COMMAND.pack(command, size, DYLIB_COMMAND.size, 2, 0x10000, 0x10000) + raw)
    for path in rpaths:
        size, raw = padded(path.encode() + b"\0", RPATH_COMMAND.size)
        commands.append(RPATH_COMMAND.pack(LC_RPATH, size, RPATH_COMMAND.size) + raw)
    body = b"".join(commands)
    header = MACH_HEADER_64.pack(MH_MAGIC_64, cputype, 0, filetype, len(commands), len(body), 0, 0)
    return header + body + bytes(32)


def fat(thin, offset=0x4000):
    header = FAT_HEADER.pack(FAT_MAGIC, 1) + FAT_ARCH.pack(CPU_TYPE_ARM64, 0, offset, len(thin), 14)
    return header.ljust(offset, b"\0") + thin


def info_plist(**overrides):
    info = {
        "CFBundleExecutable": "MicDrop",
        "CFBundleIdentifier": "com.maskarauder.micdrop",
        "CFBundleIcons": {
            "CFBundlePrimaryIcon": {
                "CFBundleIconFiles": ["AppIcon60x60"],
                "CFBundleIconName": "AppIcon",
            }
        },
        "ITSAppUsesNonExemptEncryption": False,
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1],
        "UIBackgroundModes": ["audio"],
        "NSMicrophoneUsageDescription": "microphone",
        "NSCameraUsageDescription": "camera",
        "NSLocalNetworkUsageDescription": "local network",
        "NSBonjourServices": ["_micdrop._tcp"],
        "MicDropRevision": "local",
        "MicDropVersionName": "0.1.0-dev",
    }
    for key, value in overrides.items():
        if value is None:
            info.pop(key, None)
        else:
            info[key] = value
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY)


def framework_plist(**overrides):
    info = {"CFBundleExecutable": "WebRTC", "CFBundlePackageType": "FMWK", "MinimumOSVersion": "14.0"}
    for key, value in overrides.items():
        if value is None:
            info.pop(key, None)
        else:
            info[key] = value
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY)


COMMITTED_PRIVACY = (
    Path(__file__).resolve().parents[1] / "apps" / "ios" / "MicDrop" / "PrivacyInfo.xcprivacy"
).read_bytes()


def entries(**overrides):
    files = {
        "Payload/": None,
        APP: None,
        APP + "Info.plist": info_plist(),
        APP + "Assets.car": b"BOMStore-compiled-assets",
        APP + "PrivacyInfo.xcprivacy": COMMITTED_PRIVACY,
        APP + "MicDrop": macho(),
        APP + "Frameworks/": None,
        APP + "Frameworks/WebRTC.framework/": None,
        APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_DYLIB, (14, 0), dylibs=(), rpaths=()),
        APP + "Frameworks/WebRTC.framework/Info.plist": framework_plist(),
        APP + "NOTICE": b"MicDrop - license and source information",
        APP + "LICENSE": b"Mozilla Public License Version 2.0",
        APP + "ios-notices.txt": b"MicDrop iPhone dependencies.",
        APP + "webrtc-notice.txt": b"WebRTC notices",
    }
    for name, value in overrides.items():
        files[name.replace("__", "/")] = value
    return files


class IPhoneBundleTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "MicDrop.ipa"

    def write(self, files, symlinks=()):
        with zipfile.ZipFile(self.ipa, "w", zipfile.ZIP_DEFLATED) as package:
            for name, content in files.items():
                if content is False:
                    continue
                if content is None:
                    package.writestr(zipfile.ZipInfo(name), b"")
                else:
                    package.writestr(name, content)
            for name, target in symlinks:
                info = zipfile.ZipInfo(name)
                info.external_attr = 0o120777 << 16
                package.writestr(info, target)
        return self.ipa

    def check(self, files, revision=None, symlinks=(), *, signed=False):
        return check_ipa(
            self.write(files, symlinks),
            "com.maskarauder.micdrop",
            "17.0",
            revision,
            signed=signed,
        )

    def rejects(self, pattern, files, revision=None, symlinks=(), *, signed=False):
        with self.assertRaisesRegex(ValueError, pattern):
            self.check(files, revision, symlinks, signed=signed)

    def test_complete_valid_ipa_passes(self):
        files = entries()
        self.assertRegex(self.check(files, revision="local"), "^[0-9a-f]{64}$")
        files[APP + "Info.plist"] = info_plist(MicDropRevision="0123456789ab")
        self.check(files, revision="0123456789ab")

    def test_missing_background_audio_mode_is_rejected(self):
        self.rejects("Background audio mode is missing", entries(**{APP + "Info.plist": info_plist(UIBackgroundModes=["fetch"])}))
        self.rejects("Background audio mode is missing", entries(**{APP + "Info.plist": info_plist(UIBackgroundModes=None)}))

    def test_wrong_bundle_identifier_is_rejected(self):
        self.rejects("Info.plist CFBundleIdentifier is 'com.example.other'; expected 'com.maskarauder.micdrop'",
                     entries(**{APP + "Info.plist": info_plist(CFBundleIdentifier="com.example.other")}))

    def test_wrong_minimum_os_or_device_family_is_rejected(self):
        self.rejects("Info.plist MinimumOSVersion is '18.0'", entries(**{APP + "Info.plist": info_plist(MinimumOSVersion="18.0")}))
        self.rejects("Info.plist UIDeviceFamily is \\[1, 2\\]", entries(**{APP + "Info.plist": info_plist(UIDeviceFamily=[1, 2])}))

    def test_embedded_provisioning_profile_means_signed(self):
        self.rejects("IPA must be unsigned; found Payload/MicDrop.app/embedded.mobileprovision",
                     entries(**{APP + "embedded.mobileprovision": b"profile"}))
        self.rejects("must be unsigned", entries(**{APP + "_CodeSignature/CodeResources": b"seal"}))
        self.rejects("must be unsigned",
                     entries(**{APP + "Frameworks/WebRTC.framework/_CodeSignature/CodeResources": b"seal"}))

    def test_signed_ipa_requires_signatures_and_provisioning_profile(self):
        signed_files = entries(**{
            APP + "_CodeSignature/CodeResources": b"<plist><dict/></plist>",
            APP + "Frameworks/WebRTC.framework/_CodeSignature/CodeResources": b"<plist><dict/></plist>",
            APP + "embedded.mobileprovision": b"cms-profile-bytes",
            "Symbols/MicDrop.symbols": b"symbols",
        })
        self.assertRegex(self.check(signed_files, revision="local", signed=True), "^[0-9a-f]{64}$")
        for missing_key in (
            APP + "_CodeSignature/CodeResources",
            APP + "Frameworks/WebRTC.framework/_CodeSignature/CodeResources",
            APP + "embedded.mobileprovision",
        ):
            mutated = dict(signed_files)
            mutated[missing_key] = False
            self.rejects("Signed IPA is missing non-empty", mutated, signed=True)

    def test_export_compliance_app_icon_and_privacy_manifest_are_required(self):
        self.rejects("ITSAppUsesNonExemptEncryption must be false",
                     entries(**{APP + "Info.plist": info_plist(ITSAppUsesNonExemptEncryption=True)}))
        self.rejects("ITSAppUsesNonExemptEncryption must be false",
                     entries(**{APP + "Info.plist": info_plist(ITSAppUsesNonExemptEncryption=None)}))
        self.rejects("CFBundleIcons",
                     entries(**{APP + "Info.plist": info_plist(CFBundleIcons=None)}))
        self.rejects("Assets.car",
                     entries(**{APP + "Assets.car": False}))
        self.rejects("PrivacyInfo.xcprivacy",
                     entries(**{APP + "PrivacyInfo.xcprivacy": False}))
        bad_privacy = plistlib.dumps({
            "NSPrivacyTracking": True,
            "NSPrivacyTrackingDomains": [],
            "NSPrivacyCollectedDataTypes": [],
            "NSPrivacyAccessedAPITypes": [],
        })
        self.rejects("NSPrivacyTracking must be false",
                     entries(**{APP + "PrivacyInfo.xcprivacy": bad_privacy}))

    def test_traversal_entry_is_unsafe(self):
        self.rejects("IPA entry is unsafe: Payload/../x", entries(**{"Payload/../x": b"x"}))
        self.rejects("IPA entry is unsafe: /Payload/x", entries(**{"/Payload/x": b"x"}))
        self.rejects("IPA entry is unsafe: Other/x", entries(**{"Other/x": b"x"}))

    def test_symbolic_link_entry_is_rejected(self):
        self.rejects("IPA contains a symbolic link: Payload/MicDrop.app/link", entries(),
                     symlinks=[(APP + "link", "/etc/passwd")])

    def test_webrtc_binary_must_be_a_dynamic_library(self):
        self.rejects("WebRTC.framework/WebRTC: expected an arm64 Mach-O dynamic library",
                     entries(**{APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_EXECUTE, (14, 0))}))
        self.rejects("expected an arm64 Mach-O dynamic library",
                     entries(**{APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_DYLIB, cputype=0x01000007)}))
        self.rejects("expected an arm64 Mach-O dynamic library",
                     entries(**{APP + "Frameworks/WebRTC.framework/WebRTC": False}))

    def test_webrtc_minimum_above_app_minimum_is_rejected(self):
        self.rejects("WebRTC.framework/WebRTC: iOS minimum 18.0 exceeds 17.0",
                     entries(**{APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_DYLIB, (18, 0), dylibs=(), rpaths=())}))

    def test_main_binary_must_load_webrtc(self):
        self.rejects("Main executable does not load @rpath/WebRTC.framework/WebRTC",
                     entries(**{APP + "MicDrop": macho(dylibs=("/usr/lib/libSystem.B.dylib",))}))

    def test_weak_webrtc_load_is_accepted(self):
        self.check(entries(**{APP + "MicDrop": macho(weak=True)}))

    def test_main_binary_must_have_frameworks_run_path(self):
        self.rejects("Main executable lacks @executable_path/Frameworks run path",
                     entries(**{APP + "MicDrop": macho(rpaths=("/usr/lib/swift",))}))

    def test_main_binary_minimum_must_equal_app_minimum(self):
        self.rejects("MicDrop: iOS minimum 16.0 does not match 17.0", entries(**{APP + "MicDrop": macho(minimum=(16, 0))}))
        self.rejects("MicDrop: iOS minimum is missing", entries(**{APP + "MicDrop": macho(platform=7)}))
        self.check(entries(**{APP + "MicDrop": macho(legacy_minimum=True)}))

    def test_binary_minimum_includes_patch_component(self):
        self.check(entries(**{APP + "MicDrop": macho(minimum=(17, 0, 0))}))
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                self.rejects("MicDrop: iOS minimum 17.0.1 does not match 17.0", entries(**{
                    APP + "MicDrop": macho(minimum=(17, 0, 1), legacy_minimum=legacy)}))
        self.rejects("WebRTC: iOS minimum 17.0.1 exceeds 17.0", entries(**{
            APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_DYLIB, (17, 0, 1), dylibs=(), rpaths=()),
            APP + "Frameworks/WebRTC.framework/Info.plist": framework_plist(MinimumOSVersion="17.0.1")}))

    def test_main_binary_must_be_an_executable(self):
        self.rejects("MicDrop: expected an arm64 Mach-O executable", entries(**{APP + "MicDrop": macho(MH_DYLIB)}))
        self.rejects("Main executable Payload/MicDrop.app/MicDrop is missing", entries(**{APP + "MicDrop": False}))

    def test_revision_mismatch_is_rejected(self):
        self.rejects("Build revision local does not match 0123456789ab", entries(), revision="0123456789ab")
        self.rejects("Build revision \\$\\(MICDROP_REVISION\\) does not match",
                     entries(**{APP + "Info.plist": info_plist(MicDropRevision="$(MICDROP_REVISION)")}))

    def test_version_name_must_be_short_and_free_of_controls(self):
        self.rejects("MicDropVersionName", entries(**{APP + "Info.plist": info_plist(MicDropVersionName="a\u0007b")}))
        self.rejects("MicDropVersionName", entries(**{APP + "Info.plist": info_plist(MicDropVersionName="x" * 81)}))
        self.rejects("MicDropVersionName", entries(**{APP + "Info.plist": info_plist(MicDropVersionName=None)}))

    def test_missing_notice_is_rejected(self):
        self.rejects("Missing notice NOTICE", entries(**{APP + "NOTICE": False}))
        self.rejects("Missing notice LICENSE", entries(**{APP + "LICENSE": b"  \n"}))
        self.rejects("Missing notice ios-notices.txt", entries(**{APP + "ios-notices.txt": False}))
        self.rejects("Missing notice webrtc-notice.txt", entries(**{APP + "webrtc-notice.txt": b"  \n"}))
        self.rejects("Missing notice ios-notices.txt", entries(**{APP + "ios-notices.txt": b"\xff\xfe"}))

    def test_fat_binary_with_arm64_slice_is_accepted(self):
        self.check(entries(**{
            APP + "MicDrop": fat(macho()),
            APP + "Frameworks/WebRTC.framework/WebRTC": fat(macho(MH_DYLIB, (14, 0), dylibs=(), rpaths=())),
        }))

    def test_truncated_macho_is_malformed(self):
        self.rejects("MicDrop: malformed Mach-O", entries(**{APP + "MicDrop": macho()[:40]}))
        self.rejects("WebRTC: malformed Mach-O",
                     entries(**{APP + "Frameworks/WebRTC.framework/WebRTC": fat(macho(MH_DYLIB, (14, 0)))[:0x4010]}))
        broken = bytearray(macho())
        broken[MACH_HEADER_64.size + 4:MACH_HEADER_64.size + 8] = (4).to_bytes(4, "little")
        self.rejects("MicDrop: malformed Mach-O", entries(**{APP + "MicDrop": bytes(broken)}))

    def test_arbitrary_loads_are_rejected(self):
        self.rejects("Arbitrary network loads must stay disabled", entries(**{
            APP + "Info.plist": info_plist(NSAppTransportSecurity={"NSAllowsArbitraryLoads": True})}))
        self.check(entries(**{APP + "Info.plist": info_plist(NSAppTransportSecurity={"NSAllowsArbitraryLoads": False})}))

    def test_usage_descriptions_and_bonjour_service_are_required(self):
        for key in ("NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"):
            self.rejects(f"Info.plist is missing {key}", entries(**{APP + "Info.plist": info_plist(**{key: None})}))
        self.rejects("Bonjour service _micdrop._tcp is not declared",
                     entries(**{APP + "Info.plist": info_plist(NSBonjourServices=["_http._tcp"])}))

    def test_exactly_one_app_bundle(self):
        self.rejects("exactly one Payload/\\*.app bundle", entries(**{"Payload/Other.app/Info.plist": b"x"}))
        self.rejects("exactly one Payload/\\*.app bundle", entries(**{"Payload/readme.txt": b"x"}))

    def test_webrtc_framework_info_plist_is_required(self):
        self.rejects("IPA is missing Payload/MicDrop.app/Frameworks/WebRTC.framework/Info.plist",
                     entries(**{APP + "Frameworks/WebRTC.framework/Info.plist": False}))

    def test_webrtc_framework_info_plist_must_be_readable_dictionary(self):
        path = APP + "Frameworks/WebRTC.framework/Info.plist"
        for data in (b"not a plist", b"<plist><dict>"):
            with self.subTest(data=data):
                self.rejects("WebRTC.framework/Info.plist is unreadable", entries(**{path: data}))
        self.rejects("WebRTC.framework/Info.plist is not a dictionary", entries(**{path: plistlib.dumps([])}))

    def test_webrtc_framework_info_must_name_the_embedded_executable(self):
        path = APP + "Frameworks/WebRTC.framework/Info.plist"
        for name in (None, "", "MissingBinary", "../WebRTC", ["WebRTC"]):
            with self.subTest(name=name):
                self.rejects("WebRTC.framework/Info.plist CFBundleExecutable", entries(**{
                    path: framework_plist(CFBundleExecutable=name)}))

    def test_webrtc_framework_package_type_is_required(self):
        path = APP + "Frameworks/WebRTC.framework/Info.plist"
        for kind in (None, "APPL"):
            with self.subTest(kind=kind):
                self.rejects("WebRTC.framework/Info.plist CFBundlePackageType", entries(**{
                    path: framework_plist(CFBundlePackageType=kind)}))

    def test_webrtc_framework_minimum_must_be_readable_and_compatible(self):
        path = APP + "Frameworks/WebRTC.framework/Info.plist"
        for minimum in (None, "", "-1.0", "14.-1", "14.0.0.0", "14.x", 14):
            with self.subTest(minimum=minimum):
                self.rejects("WebRTC.framework/Info.plist: Unreadable iOS version", entries(**{
                    path: framework_plist(MinimumOSVersion=minimum)}))
        for minimum in ("18.0", "17.0.1"):
            with self.subTest(minimum=minimum):
                self.rejects("WebRTC.framework/Info.plist: iOS minimum .* exceeds 17.0", entries(**{
                    path: framework_plist(MinimumOSVersion=minimum)}))

    def test_webrtc_framework_minimum_must_match_binary(self):
        path = APP + "Frameworks/WebRTC.framework/Info.plist"
        self.rejects("WebRTC.framework/Info.plist: iOS minimum 14.0.1 does not match WebRTC binary minimum 14.0",
                     entries(**{path: framework_plist(MinimumOSVersion="14.0.1")}))
        for minimum in ("14", "14.0", "14.0.0"):
            with self.subTest(minimum=minimum):
                self.check(entries(**{path: framework_plist(MinimumOSVersion=minimum)}))
        self.check(entries(**{
            path: framework_plist(MinimumOSVersion="17.0.0"),
            APP + "Frameworks/WebRTC.framework/WebRTC": macho(MH_DYLIB, (17, 0, 0), dylibs=(), rpaths=())}))

    def test_unreadable_info_plist_is_rejected(self):
        self.rejects("Info.plist is unreadable", entries(**{APP + "Info.plist": b"<plist><dict>"}))

    def test_command_line_reports_the_first_failure(self):
        script = Path(__file__).with_name("check_ios_bundle.py")
        ipa = self.write(entries(**{APP + "ios-notices.txt": False}))
        run = subprocess.run([sys.executable, str(script), str(ipa), "--bundle-id", "com.maskarauder.micdrop",
                              "--minimum-os", "17.0"], capture_output=True, text=True)
        self.assertEqual(1, run.returncode)
        self.assertEqual("iPhone bundle check failed: Missing notice ios-notices.txt\n", run.stderr)
        ipa = self.write(entries())
        run = subprocess.run([sys.executable, str(script), str(ipa), "--bundle-id", "com.maskarauder.micdrop",
                              "--minimum-os", "17.0", "--revision", "local"], capture_output=True, text=True)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertRegex(run.stdout, "^Verified unsigned iPhone IPA [0-9a-f]{64}\n$")
        signed_ipa = self.write(entries(**{
            APP + "_CodeSignature/CodeResources": b"seal",
            APP + "Frameworks/WebRTC.framework/_CodeSignature/CodeResources": b"seal",
            APP + "embedded.mobileprovision": b"profile",
        }))
        run = subprocess.run([sys.executable, str(script), str(signed_ipa), "--bundle-id", "com.maskarauder.micdrop",
                              "--minimum-os", "17.0", "--revision", "local", "--signed"], capture_output=True, text=True)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertRegex(run.stdout, "^Verified signed iPhone IPA [0-9a-f]{64}\n$")
        ipa.write_bytes(b"not a zip")
        run = subprocess.run([sys.executable, str(script), str(ipa), "--bundle-id", "x", "--minimum-os", "17.0"],
                             capture_output=True, text=True)
        self.assertEqual(1, run.returncode)
        self.assertTrue(run.stderr.startswith("iPhone bundle check failed: "), run.stderr)


if __name__ == "__main__":
    unittest.main()
