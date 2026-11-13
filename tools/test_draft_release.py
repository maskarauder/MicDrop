import base64
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import draft_release as release
import macos_app_bundle
import package_unix_host
import release_version as version
import store_artifact
from test_ios_bundle import APP, entries as ios_entries, info_plist as ios_info_plist
import test_macos_app_bundle
import test_package_unix_host

SHA = "a" * 40
IDENTITY = {"version": "0.1.0-beta.1", "android_version_code": 2}
REQUIRED_SUFFIXES = (
    "-windows-x64-setup.exe",
    "-windows-x64-portable.zip",
    "-windows-build.json",
    "-linux-x64-host.tar.gz",
    "-linux-build.json",
    "-macos-arm64-app.zip",
    "-macos-arm64-host.tar.gz",
    "-macos-build.json",
    "-android-arm64-dev.apk",
    "-android-build.json",
)
RUN = {"id": 42, "run_attempt": 1, "head_sha": SHA, "status": "completed", "conclusion": "success",
       "event": "push", "head_branch": "main", "path": ".github/workflows/build.yml",
       "head_repository": {"full_name": "test/MicDrop"}, "html_url": "https://github.com/test/MicDrop/actions/runs/42"}
NOTES = "Development preview."


class FakeGitHub:
    repository = "test/MicDrop"

    def __init__(self):
        self.run = copy.deepcopy(RUN)
        self.release = None
        self.assets = []
        self.writes = []
        self.tag = None

    def listing(self, path):
        return ([copy.deepcopy(self.release)] if self.release else []) if path == "/releases" else copy.deepcopy(self.assets)

    def request(self, method, path, data=None, file=None):
        if method == "GET":
            if path.startswith("/actions/runs/"):
                return self.run
            if path.startswith("/compare/"):
                return {"status": "ahead"}
            if path.startswith("/contents/"):
                text = "version=0.1.0-beta.1\nandroid_version_code=2\n" if version.VERSION_PATH in path else NOTES
                return {"encoding": "base64", "content": base64.b64encode(text.encode()).decode(), "size": len(text)}
            if path.startswith("/git/ref/"):
                return self.tag
            return copy.deepcopy(self.release)
        self.writes.append((method, path, data))
        if method == "POST" and path == "/releases":
            self.release = {"id": 7, "upload_url": "https://uploads.github.com/repos/test/MicDrop/releases/7/assets{?name,label}", **data}
            return copy.deepcopy(self.release)
        if file:
            asset = {"name": file.name, "state": "uploaded", "digest": "sha256:" + release.digest(file), "size": file.stat().st_size}
            self.assets.append(asset)
            return asset
        if method == "PATCH":
            # GitHub resets a draft's pending tag when an update omits it.
            self.release["tag_name"] = data.get("tag_name", "untagged-test")
        self.release.update(data)
        return copy.deepcopy(self.release)


class DraftReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / "work"
        self.workspace.mkdir()
        self.artifacts = self.root / "retained"

    def retain(self, name, files):
        folder = self.workspace / name
        folder.mkdir()
        for path, content in files.items():
            target = folder / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content if isinstance(content, bytes) else content.encode())
        with patch.dict(os.environ, {"GITHUB_SHA": SHA}):
            return store_artifact.store(self.workspace, self.artifacts, name, "42", "1", name + "/**/*")

    def windows(self, change=None):
        files = {name: name.encode() for name in release.PORTABLE}
        self.retain("windows-x64-harness", {**files, "windows-host.exe": b"cli",
            "M3_CLOSEOUT.md": b"internal history", "not-for-distribution.dpapi": b"unrelated"})
        entries = [{"path": name, "size": len(data), "sha256": release.hashlib.sha256(data).hexdigest()} for name, data in files.items()]
        entries.extend({"path": name, "size": 6, "sha256": "b" * 64} for name in release.INSTALLER_ONLY)
        if change:
            change(entries)
        self.retain("windows-x64-installer", {f"MicDrop-0.1.0-beta.1-{SHA}-windows-x64-setup.exe": b"setup",
            "payload-manifest.json": json.dumps({"schema": 1, "platform": "windows-x64",
                "app_version": IDENTITY["version"], "build_revision": SHA, "files": entries})})

    def windows_command(self, args):
        return json.dumps({**IDENTITY, "revision": SHA, "modified": False, "platform": "windows/amd64"})

    def test_portable_and_installer_share_verified_curated_payload(self):
        self.windows()
        first = release.stage("windows", self.artifacts, self.root / "out1", 42, 1, SHA, IDENTITY, self.windows_command)
        second = release.stage("windows", self.artifacts, self.root / "out2", 42, 1, SHA, IDENTITY, self.windows_command)
        self.assertEqual([release.digest(p) for p in first], [release.digest(p) for p in second])
        with zipfile.ZipFile(first[1]) as archive:
            self.assertEqual(set(archive.namelist()), {"MicDrop.exe", "micdrop_rtc.dll", "README.md", "BETA_TESTING.md",
                "LICENSE", "NOTICE", "WEBRTC-NOTICE.txt", "WEBRTC-VERSIONS.txt",
                "QR-CODE-NOTICE.txt", "DISCOVERY-NOTICES.txt", "WEBSOCKET-NOTICE.txt"})

    def assert_invalid_windows_manifest(self, change):
        self.windows(change)
        with self.assertRaisesRegex(ValueError, "allowlist|payloads differ"):
            release.stage("windows", self.artifacts, self.root / "out", 42, 1, SHA, IDENTITY, self.windows_command)

    def test_rejects_legacy_console_in_installer_manifest(self):
        self.assert_invalid_windows_manifest(lambda entries: entries.append(
            {"path": "windows-host.exe", "size": 3, "sha256": release.hashlib.sha256(b"cli").hexdigest()}))

    def test_rejects_private_file_even_when_manifest_and_artifact_agree(self):
        self.assert_invalid_windows_manifest(lambda entries: entries.append(
            {"path": "not-for-distribution.dpapi", "size": 9, "sha256": release.hashlib.sha256(b"unrelated").hexdigest()}))

    def test_rejects_missing_license(self):
        self.assert_invalid_windows_manifest(lambda entries: entries.remove(
            next(entry for entry in entries if entry["path"] == "LICENSE")))

    def test_rejects_missing_beta_guide(self):
        self.assert_invalid_windows_manifest(lambda entries: entries.remove(
            next(entry for entry in entries if entry["path"] == "BETA_TESTING.md")))

    def test_rejects_duplicate_manifest_entry(self):
        self.assert_invalid_windows_manifest(lambda entries: entries.append(entries[0].copy()))

    def test_rejects_different_installer_payload_bytes(self):
        self.assert_invalid_windows_manifest(lambda entries: entries[0].update(sha256="0" * 64))

    def test_rejects_tampering_wrong_build_paths_and_symlinks(self):
        directory = self.retain("android-apk", {"app-debug.apk": b"apk"})
        with self.assertRaises(ValueError):
            release.retained(self.artifacts, "android-apk", 42, 1, "b" * 40)
        manifest = directory / "manifest.json"
        original = json.loads(manifest.read_text())
        for path in ["../outside", "/absolute", "C:/windows", "nested\\escape"]:
            changed = copy.deepcopy(original)
            changed["files"][0]["path"] = path
            manifest.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                release.retained(self.artifacts, "android-apk", 42, 1, SHA)
        manifest.write_text(json.dumps(original))
        apk = directory / "files/app-debug.apk"
        apk.write_bytes(b"bad")
        with self.assertRaises(ValueError):
            release.retained(self.artifacts, "android-apk", 42, 1, SHA)
        apk.unlink()
        try:
            apk.symlink_to(manifest)
        except OSError:
            return  # Windows developer mode may not permit a symlink.
        with self.assertRaises(ValueError):
            release.retained(self.artifacts, "android-apk", 42, 1, SHA)

    def test_embedded_windows_version_must_match(self):
        self.windows()
        with self.assertRaises(ValueError):
            release.stage("windows", self.artifacts, self.root / "out", 42, 1, SHA, IDENTITY,
                          lambda args: json.dumps({**IDENTITY, "revision": "b" * 40, "modified": False, "platform": "windows/amd64"}))

    def test_android_version_and_signer_are_inspected(self):
        self.retain("android-apk", {"app-debug.apk": b"apk"})
        def command(args):
            if "badging" in args:
                return "package: name='com.maskarauder.micdrop.dev' versionCode='2' versionName='0.1.0-beta.1'"
            return "Signer #1 certificate SHA-256 digest: " + "c" * 64 + "\n"
        with patch.dict(os.environ, {"ANDROID_HOME": str(self.root)}):
            paths = release.stage("android", self.artifacts, self.root / "good", 42, 1, SHA, IDENTITY, command)
            self.assertEqual(json.loads(paths[-1].read_text())["certificate_sha256"], "c" * 64)
            with self.assertRaises(ValueError):
                release.stage("android", self.artifacts, self.root / "bad", 42, 1, SHA, IDENTITY,
                              lambda args: command(args).replace("versionCode='2'", "versionCode='1'"))

    def write_ipa(self, path, **info_overrides):
        defaults = {
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "2",
            "MicDropVersionName": "0.1.0-beta.1",
            "MicDropRevision": SHA[:12],
        }
        defaults.update(info_overrides)
        files = ios_entries(**{APP + "Info.plist": ios_info_plist(**defaults)})
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as package:
            for name, content in files.items():
                if content is None:
                    package.writestr(zipfile.ZipInfo(name), b"")
                else:
                    package.writestr(name, content)
        return path.read_bytes()

    def test_ios_bundle_and_version_are_inspected(self):
        ipa_path = self.root / "MicDrop.ipa"
        self.retain("ios-ipa", {"MicDrop.ipa": self.write_ipa(ipa_path)})
        paths = release.stage("ios", self.artifacts, self.root / "ios-good", 42, 1, SHA, IDENTITY)
        self.assertEqual([p.name for p in paths], [
            "MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa",
            "MicDrop-0.1.0-beta.1-ios-build.json",
        ])
        metadata = json.loads(paths[-1].read_text())
        self.assertEqual(metadata["bundle_id"], "com.maskarauder.micdrop")
        self.assertEqual(metadata["minimum_os"], "17.0")
        for overrides in (
            {"CFBundleShortVersionString": "0.2.0"},
            {"CFBundleVersion": "1"},
            {"MicDropVersionName": "0.1.0-beta.2"},
            {"MicDropRevision": "b" * 12},
        ):
            with self.subTest(overrides=overrides):
                shutil_dir = self.artifacts / "ios-ipa"
                if shutil_dir.exists():
                    for child in sorted(shutil_dir.rglob("*"), reverse=True):
                        if child.is_file():
                            child.unlink()
                        else:
                            child.rmdir()
                    shutil_dir.rmdir()
                folder = self.workspace / "ios-ipa"
                for child in sorted(folder.rglob("*"), reverse=True):
                    if child.is_file():
                        child.unlink()
                    else:
                        child.rmdir()
                folder.rmdir()
                self.retain("ios-ipa", {"MicDrop.ipa": self.write_ipa(ipa_path, **overrides)})
                with self.assertRaises(ValueError):
                    release.stage(
                        "ios", self.artifacts,
                        self.root / ("ios-bad-" + next(iter(overrides))),
                        42, 1, SHA, IDENTITY)

    def test_downloaded_ipa_can_be_uploaded_without_runner_retention(self):
        ipa_path = self.root / "downloaded.ipa"
        self.write_ipa(ipa_path)
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        args = ["draft_release.py", "upload", "--platform", "ios", "--ios-ipa", str(ipa_path),
                "--run-id", "42", "--release-id", "7", "--output", str(self.root / "ios-upload")]
        with patch("sys.argv", args), patch.object(release, "GitHub", return_value=api), \
                patch.object(release, "read", return_value=IDENTITY), \
                patch.object(release, "artifact_root", side_effect=AssertionError("No VM artifacts for downloaded IPA")), \
                patch.dict(os.environ, {"GITHUB_REPOSITORY": api.repository, "GH_TOKEN": "test-only"}):
            release.main()
        self.assertEqual({asset["name"] for asset in api.assets}, {
            "MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa", "MicDrop-0.1.0-beta.1-ios-build.json"})
        metadata = json.loads((self.root / "ios-upload/MicDrop-0.1.0-beta.1-ios-build.json").read_text())
        self.assertEqual(metadata["ipa_provenance"], "downloaded; bundle identity checked locally")
        self.assertEqual(metadata["source_sha"], SHA)
        for overrides in ({"MicDropRevision": "b" * 12}, {"CFBundleVersion": "1"},
                          {"CFBundleShortVersionString": "0.2.0"}, {"MicDropVersionName": "0.1.0-beta.2"}):
            with self.subTest(overrides=overrides):
                self.write_ipa(ipa_path, **overrides)
                with self.assertRaises(ValueError):
                    release.stage("ios", None, self.root / ("download-bad-" + next(iter(overrides))),
                                  42, 1, SHA, IDENTITY, ios_ipa=ipa_path)

    def test_downloaded_ipa_is_rejected_for_other_platforms(self):
        with self.assertRaisesRegex(ValueError, "only supported for ios"):
            release.stage("android", self.artifacts, self.root / "wrong-platform", 42, 1, SHA, IDENTITY,
                          ios_ipa=self.root / "downloaded.ipa")

    def test_downloaded_ipa_can_be_staged_outside_a_runner(self):
        ipa = self.root / "downloaded.ipa"
        self.write_ipa(ipa)
        args = ["draft_release.py", "stage", "--platform", "ios", "--ios-ipa", str(ipa),
                "--run-id", "42", "--sha", SHA, "--output", str(self.root / "offline-ios")]
        with patch("sys.argv", args), patch.object(release, "read", return_value=IDENTITY), \
                patch.object(release, "GitHub", side_effect=AssertionError("Offline stage must not call GitHub")), \
                patch.object(release, "artifact_root", side_effect=AssertionError("No runner environment")):
            release.main()
        self.assertEqual((self.root / "offline-ios/MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa").read_bytes(),
                         ipa.read_bytes())

    def test_ios_assets_cannot_be_added_after_manifest_finalization(self):
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        api.assets.append({"name": "release-manifest.json", "state": "uploaded"})
        ipa = self.root / "MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa"
        ipa.write_bytes(b"ipa")
        before = len(api.writes)
        with self.assertRaisesRegex(ValueError, "before finalization"):
            release.upload(api, 7, RUN, IDENTITY, ipa)
        self.assertEqual(len(api.writes), before)
        # An exact retry of an already included iPhone package remains harmless.
        api.assets.append({"name": ipa.name, "state": "uploaded", "digest": "sha256:" + release.digest(ipa),
                           "size": ipa.stat().st_size})
        release.upload(api, 7, RUN, IDENTITY, ipa)
        self.assertEqual(len(api.writes), before)

    def test_only_successful_main_builds_can_be_promoted(self):
        api = FakeGitHub()
        self.assertEqual(release.source_run(api, 42)[1], IDENTITY)
        for field, value in [("conclusion", "failure"), ("status", "in_progress"), ("event", "pull_request"),
                             ("head_branch", "feature/foo"), ("path", ".github/workflows/other.yml"),
                             ("head_repository", {"full_name": "other/MicDrop"})]:
            api.run = {**copy.deepcopy(RUN), field: value}
            with self.assertRaises(ValueError):
                release.source_run(api, 42)
        api.run = copy.deepcopy(RUN)
        api.tag = {"object": {"type": "commit", "sha": "b" * 40}}
        with self.assertRaises(ValueError):
            release.source_run(api, 42)
        self.assertEqual(api.writes, [])

    def test_draft_creation_and_rerun_do_not_publish_or_replace(self):
        api = FakeGitHub()
        draft = release.prepare(api, RUN, IDENTITY, NOTES)
        self.assertTrue(draft["draft"])
        self.assertTrue(draft["prerelease"])
        self.assertEqual(release.prepare(api, RUN, IDENTITY, NOTES)["id"], draft["id"])
        path = self.root / "asset.apk"
        path.write_bytes(b"original")
        release.upload(api, 7, RUN, IDENTITY, path)
        release.upload(api, 7, RUN, IDENTITY, path)
        self.assertEqual(len(api.assets), 1)
        path.write_bytes(b"changed")
        with self.assertRaises(ValueError):
            release.upload(api, 7, RUN, IDENTITY, path)
        api.release["draft"] = False
        with self.assertRaises(ValueError):
            release.prepare(api, RUN, IDENTITY, NOTES)
        with self.assertRaises(ValueError):
            release.upload(api, 7, RUN, IDENTITY, path)
        self.assertFalse(any(method == "DELETE" for method, _, _ in api.writes))

    def test_incomplete_or_different_source_draft_is_not_finalized(self):
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        with self.assertRaises(ValueError):
            release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "finish")
        with self.assertRaises(ValueError):
            release.owned_draft(api, 7, {**RUN, "head_sha": "b" * 40}, IDENTITY)
        self.assertTrue(api.release["body"].startswith(release.marker(RUN)))
        self.assertIn("INCOMPLETE", api.release["body"])

    def make_unix_tarball(self, platform):
        stage_dir = self.root / f"stage-{platform}"
        if stage_dir.exists():
            for child in sorted(stage_dir.rglob("*"), reverse=True):
                child.unlink() if child.is_file() else child.rmdir()
            stage_dir.rmdir()
        stage_dir.mkdir(parents=True)
        exe = stage_dir / "micdrop-host"
        if platform == "linux-x64":
            exe.write_bytes(test_package_unix_host.fake_elf_x64(package_unix_host.ET_DYN))
            lib = stage_dir / "libmicdrop_rtc.so"
            lib.write_bytes(test_package_unix_host.fake_elf_x64(package_unix_host.ET_DYN))
        else:
            exe.write_bytes(test_macos_app_bundle.make_macho(macos_app_bundle.MH_EXECUTE))
            lib = stage_dir / "libmicdrop_rtc.dylib"
            lib.write_bytes(test_macos_app_bundle.make_macho(macos_app_bundle.MH_DYLIB))
        exe.chmod(0o755)
        lib.chmod(0o755)
        for notice in package_unix_host.REQUIRED_NOTICES:
            (stage_dir / notice).write_text(f"{notice}\n", encoding="utf-8")
        out_tar = self.root / f"MicDrop-{platform}-host.tar.gz"
        package_unix_host.package_host_tarball(stage_dir, out_tar, platform=platform)
        return out_tar.read_bytes()

    def make_macos_app_zip(self, *, revision=SHA[:12], identity=IDENTITY, stapled=False):
        src_dir = self.root / "macos-src"
        src_dir.mkdir(exist_ok=True)
        exe = src_dir / "MicDrop"
        dylib = src_dir / "libmicdrop_rtc.dylib"
        notice = src_dir / "WEBRTC-NOTICE.txt"
        versions = src_dir / "WEBRTC-VERSIONS.txt"
        exe.write_bytes(test_macos_app_bundle.make_macho(macos_app_bundle.MH_EXECUTE))
        dylib.write_bytes(test_macos_app_bundle.make_macho(macos_app_bundle.MH_DYLIB))
        notice.write_text("WebRTC notice\n", encoding="utf-8")
        versions.write_text("webrtc=m137\n", encoding="utf-8")
        app_out = self.root / "macos-build" / "MicDrop.app"
        zip_out = self.root / "macos-dist" / "MicDrop-macos-arm64-app.zip"
        macos_app_bundle.build_app_bundle(
            exe, dylib, notice, versions, app_out,
            revision=revision, shared_identity=identity,
        )
        if stapled:
            (app_out / "Contents" / "CodeResources").write_bytes(b"stapled-ticket")
        macos_app_bundle.zip_app_bundle(
            app_out, zip_out,
            revision=revision, shared_identity=identity,
        )
        return zip_out.read_bytes()

    def test_linux_host_tarball_and_version_are_inspected(self):
        self.retain("linux-x64-host", {"MicDrop-linux-x64-host.tar.gz": self.make_unix_tarball("linux-x64")})

        def linux_command(args):
            exe_path = Path(args[0])
            self.assertTrue(exe_path.is_file())
            self.assertTrue((exe_path.parent / "libmicdrop_rtc.so").is_file())
            return json.dumps({**IDENTITY, "revision": SHA, "modified": False, "platform": "linux/amd64"})

        paths = release.stage("linux", self.artifacts, self.root / "linux-good", 42, 1, SHA, IDENTITY, linux_command)
        self.assertEqual([p.name for p in paths], [
            "MicDrop-0.1.0-beta.1-linux-x64-host.tar.gz",
            "MicDrop-0.1.0-beta.1-linux-build.json",
        ])
        metadata = json.loads(paths[-1].read_text())
        self.assertEqual(metadata["signing"], "unsigned Linux x64 CLI and GTK3 desktop bundle")
        with self.assertRaisesRegex(ValueError, "Embedded Linux build identity mismatch"):
            release.stage("linux", self.artifacts, self.root / "linux-bad-rev", 42, 1, SHA, IDENTITY,
                          lambda args: json.dumps({**IDENTITY, "revision": "b" * 40, "modified": False, "platform": "linux/amd64"}))

    def test_macos_app_and_cli_host_are_inspected(self):
        self.retain("macos-arm64-app", {"MicDrop-macos-arm64-app.zip": self.make_macos_app_zip(stapled=True)})
        self.retain("macos-arm64-host", {"MicDrop-macos-arm64-host.tar.gz": self.make_unix_tarball("macos-arm64")})
        codesign_targets = []
        stapler_targets = []

        def macos_command(args):
            if args[0] == "codesign":
                codesign_targets.append([Path(a).name for a in args[1:] if not str(a).startswith("-")])
                for target in args[1:]:
                    if not str(target).startswith("-"):
                        self.assertTrue(Path(target).exists(), target)
                return ""
            if args[:3] == ["xcrun", "stapler", "validate"]:
                stapler_targets.append(Path(args[3]).name)
                return ""
            exe_path = Path(args[0])
            self.assertTrue(exe_path.is_file())
            return json.dumps({**IDENTITY, "revision": SHA, "modified": False, "platform": "darwin/arm64"})

        paths = release.stage("macos", self.artifacts, self.root / "macos-good", 42, 1, SHA, IDENTITY, macos_command)
        self.assertEqual([p.name for p in paths], [
            "MicDrop-0.1.0-beta.1-macos-arm64-app.zip",
            "MicDrop-0.1.0-beta.1-macos-arm64-host.tar.gz",
            "MicDrop-0.1.0-beta.1-macos-build.json",
        ])
        self.assertEqual(codesign_targets, [["MicDrop.app"], ["libmicdrop_rtc.dylib", "micdrop-host"]])
        self.assertEqual(stapler_targets, ["MicDrop.app"])
        metadata = json.loads(paths[-1].read_text())
        self.assertEqual(metadata["bundle_id"], "com.maskarauder.micdrop.mac")
        self.assertEqual(metadata["minimum_os"], "14.2")
        self.assertEqual(
            metadata["signing"],
            "Developer ID signed and Apple-notarized macOS arm64 app bundle and CLI host",
        )
        with self.assertRaisesRegex(ValueError, "Embedded macOS build identity mismatch"):
            release.stage(
                "macos", self.artifacts, self.root / "macos-bad-embed", 42, 1, SHA, IDENTITY,
                lambda args: "" if args[0] in {"codesign", "xcrun"} else json.dumps(
                    {**IDENTITY, "revision": SHA, "modified": True, "platform": "darwin/arm64"}),
            )
        # Also verify Info.plist revision mismatch is rejected before command execution.
        for folder in (self.artifacts / "macos-arm64-app", self.workspace / "macos-arm64-app"):
            for child in sorted(folder.rglob("*"), reverse=True):
                child.unlink() if child.is_file() else child.rmdir()
            folder.rmdir()
        self.retain("macos-arm64-app", {"MicDrop-macos-arm64-app.zip": self.make_macos_app_zip(revision="b" * 12)})
        with self.assertRaisesRegex(ValueError, "MicDropRevision"):
            release.stage("macos", self.artifacts, self.root / "macos-bad-plist", 42, 1, SHA, IDENTITY, macos_command)

    def test_complete_draft_gets_verified_checksums_but_remains_unpublished(self):
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        for suffix in REQUIRED_SUFFIXES:
            if suffix.startswith("-linux"):
                continue
            path = self.root / ("MicDrop-" + IDENTITY["version"] + suffix)
            path.write_bytes(suffix.encode())
            release.upload(api, 7, RUN, IDENTITY, path)
        with self.assertRaisesRegex(ValueError, "missing or unexpected assets"):
            release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "missing-linux")
        for suffix in REQUIRED_SUFFIXES:
            if not suffix.startswith("-linux"):
                continue
            path = self.root / ("MicDrop-" + IDENTITY["version"] + suffix)
            path.write_bytes(suffix.encode())
            release.upload(api, 7, RUN, IDENTITY, path)
        release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "done")
        self.assertTrue(api.release["draft"])
        self.assertEqual(api.release["tag_name"], "v" + IDENTITY["version"])
        self.assertNotIn("INCOMPLETE", api.release["body"])
        self.assertEqual(len(api.assets), len(REQUIRED_SUFFIXES) + 2)
        self.assertEqual(len((self.root / "done/SHA256SUMS").read_text().splitlines()), len(REQUIRED_SUFFIXES) + 1)
        assets = copy.deepcopy(api.assets)
        self.assertEqual(release.prepare(api, RUN, IDENTITY, NOTES)["id"], 7)
        release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "repeat")
        self.assertEqual(api.assets, assets)
        self.assertEqual([path for method, path, _ in api.writes if method == "POST"].count("/releases"), 1)
        api.release["body"] += "\nManual reviewer notes"
        with self.assertRaises(ValueError):
            release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "edited")

    def test_finalization_rejects_an_unexpected_returned_tag(self):
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        api.assets = [{"name": "MicDrop-" + IDENTITY["version"] + suffix,
                       "state": "uploaded", "digest": "sha256:" + "b" * 64, "size": 1}
                      for suffix in REQUIRED_SUFFIXES]
        request = api.request

        def reset_tag(method, path, data=None, file=None):
            response = request(method, path, data, file)
            if method == "PATCH":
                response["tag_name"] = "untagged-test"
            return response

        with patch.object(api, "request", side_effect=reset_tag):
            with self.assertRaisesRegex(ValueError, "tag changed"):
                release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "unexpected-tag")

    def test_optional_ios_assets_are_included_only_when_complete(self):
        api = FakeGitHub()
        release.prepare(api, RUN, IDENTITY, NOTES)
        for suffix in [*REQUIRED_SUFFIXES, "-ios-arm64-unsigned.ipa"]:
            path = self.root / ("MicDrop-" + IDENTITY["version"] + suffix)
            path.write_bytes(suffix.encode())
            release.upload(api, 7, RUN, IDENTITY, path)
        with self.assertRaisesRegex(ValueError, "missing or unexpected assets"):
            release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "half-ios")
        ios_meta = self.root / ("MicDrop-" + IDENTITY["version"] + "-ios-build.json")
        ios_meta.write_bytes(b"{}")
        release.upload(api, 7, RUN, IDENTITY, ios_meta)
        release.finish(api, 7, RUN, IDENTITY, NOTES, self.root / "with-ios")
        self.assertEqual(len(api.assets), len(REQUIRED_SUFFIXES) + 4)
        self.assertEqual(len((self.root / "with-ios/SHA256SUMS").read_text().splitlines()), len(REQUIRED_SUFFIXES) + 3)
        manifest = json.loads((self.root / "with-ios/release-manifest.json").read_text())
        self.assertIn("MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa", [a["name"] for a in manifest["assets"]])
        self.assertIn("MicDrop-0.1.0-beta.1-ios-build.json", [a["name"] for a in manifest["assets"]])

    def test_prepare_writes_run_attempt_and_tolerates_os_ancestor_symlinks(self):
        api = FakeGitHub()
        api.run["run_attempt"] = 3
        gh_out = self.root / "github_output.txt"
        args = ["draft_release.py", "prepare", "--run-id", "42"]
        with patch("sys.argv", args), patch.object(release, "GitHub", return_value=api), \
                patch.dict(os.environ, {"GITHUB_REPOSITORY": api.repository, "GH_TOKEN": "test-only",
                                        "GITHUB_OUTPUT": str(gh_out)}):
            release.main()
        self.assertEqual(
            gh_out.read_text(encoding="utf-8"),
            f"release_id=7\nsource_sha={SHA}\nrun_attempt=3\n",
        )
        real = self.root / "private_var"
        real.mkdir()
        alias = self.root / "var"
        try:
            alias.symlink_to(real, target_is_directory=True)
        except (OSError, NotImplementedError):
            return
        ipa_real = real / "downloaded.ipa"
        self.write_ipa(ipa_real)
        staged = release.stage("ios", None, alias / "ios-out", 42, 1, SHA, IDENTITY, ios_ipa=alias / "downloaded.ipa")
        self.assertEqual(staged[0].name, "MicDrop-0.1.0-beta.1-ios-arm64-unsigned.ipa")


class VersionTests(unittest.TestCase):
    def test_invalid_or_non_increasing_android_versions_are_rejected(self):
        for value in ["01.2.3", "1.2.3-beta.0", "65536.0.0", "1.2.3\nextra=value"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                version.parse(f"version={value}\nandroid_version_code=2")
        for code in ["0", "02", "2100000001"]:
            with self.subTest(code=code), self.assertRaises(ValueError):
                version.parse(f"version=1.2.3\nandroid_version_code={code}")
        with self.assertRaises(ValueError):
            version.check_upgrade({"version": "0.1.0-beta.2", "android_version_code": 2}, IDENTITY)
        with self.assertRaises(ValueError):
            version.check_upgrade({**IDENTITY, "android_version_code": 1}, IDENTITY)
        version.check_upgrade({"version": "0.1.0-beta.2", "android_version_code": 3}, IDENTITY)
        self.assertTrue(version.is_null_revision("0" * 40))
        self.assertFalse(version.is_null_revision(SHA))
        self.assertFalse(version.is_null_revision(None))


if __name__ == "__main__":
    unittest.main()
