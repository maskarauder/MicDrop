# SPDX-License-Identifier: MPL-2.0
"""Unit tests for tools/apple_signing.py using mocked macOS security/codesign/xcrun tools."""

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import apple_signing as signing  # noqa: E402

TEAM_ID = "AB12CD34EF"
LEGACY_PREFIX = "9988776655"
BUNDLE_ID = "com.maskarauder.micdrop"
FAKE_CERT_DER = b"fake-apple-distribution-der-certificate"
FAKE_CERT_SHA1 = hashlib.sha1(FAKE_CERT_DER).hexdigest().upper()
DEV_ID_SHA1 = "0123456789ABCDEF0123456789ABCDEF01234567"
FAKE_P12_B64 = base64.b64encode(b"fake-pkcs12-bundle").decode("ascii")
FAKE_P8_B64 = base64.b64encode(
    b"-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----\n"
).decode("ascii")
API_KEY_ID = "KEY1234567"
API_ISSUER_ID = "11111111-2222-3333-4444-555555555555"
PROFILE_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
NOTARY_SUBMISSION_ID = "12345678-1234-4321-abcd-0123456789ab"


def make_profile_plist(
    *,
    team_id=TEAM_ID,
    app_id_prefix=None,
    prefixes=None,
    app_id_entitlement=None,
    team_entitlement=None,
    bundle_id=BUNDLE_ID,
    get_task_allow=False,
    expired=False,
    certs=None,
):
    exp = datetime.now(timezone.utc) + (timedelta(days=-2) if expired else timedelta(days=360))
    effective_prefix = team_id if app_id_prefix is None else app_id_prefix
    payload = {
        "UUID": PROFILE_UUID,
        "Name": "MicDrop App Store",
        "TeamIdentifier": [team_id],
        "ApplicationIdentifierPrefix": [effective_prefix] if prefixes is None else prefixes,
        "ExpirationDate": exp.replace(tzinfo=None),
        "DeveloperCertificates": [FAKE_CERT_DER] if certs is None else certs,
        "Entitlements": {
            "application-identifier": (
                f"{effective_prefix}.{bundle_id}" if app_id_entitlement is None else app_id_entitlement
            ),
            "com.apple.developer.team-identifier": team_id if team_entitlement is None else team_entitlement,
            "get-task-allow": get_task_allow,
        },
    }
    return plistlib.dumps(payload, fmt=plistlib.FMT_XML).decode("utf-8")


class AppleSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.runner_temp = self.base / "runner_temp"
        self.home = self.base / "home"
        self.runner_temp.mkdir()
        self.home.mkdir()
        self.gh_env = self.base / "github_env.txt"
        self.gh_out = self.base / "github_out.txt"
        self.gh_env.write_text("", encoding="utf-8")
        self.gh_out.write_text("", encoding="utf-8")

    def base_env(self, **extra):
        env = {
            "HOME": str(self.home),
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_ENV": str(self.gh_env),
            "GITHUB_OUTPUT": str(self.gh_out),
        }
        env.update(extra)
        return env

    def read_kv(self, path):
        result = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                result[k] = v
        return result

    def test_macos_fallback_when_unconfigured(self):
        calls = []

        def fake_run(args, **kwargs):
            calls.append([str(a) for a in args])
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        app_dir = self.base / "MicDrop.app"
        app_dir.mkdir()
        with patch.dict(os.environ, self.base_env(), clear=True), patch("subprocess.run", side_effect=fake_run):
            signing.prepare_macos()
            outputs = self.read_kv(self.gh_out)
            self.assertEqual(outputs, {"signed": "false", "notarized": "false"})
            env_vars = self.read_kv(self.gh_env)
            os.environ.update(env_vars)

            signing.sign_macos([app_dir])
            signing.notarize_macos(app_dir, staple=True)
            signing.verify_macos_app(app_dir)
            signing.cleanup()

        self.assertIn(["codesign", "--force", "--sign", "-", str(app_dir)], calls)
        self.assertIn(
            ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_dir)],
            calls,
        )
        self.assertFalse(any("notarytool" in cmd for cmd in calls))

    def test_platform_specific_signing_does_not_break_other_platform(self):
        # iOS-only secrets + shared APPLE_TEAM_ID + shared App Store Connect API key must NOT break macOS fallback.
        ios_only_env = self.base_env(
            APPLE_TEAM_ID=TEAM_ID,
            APPLE_DIST_P12_BASE64=FAKE_P12_B64,
            APPLE_DIST_P12_PASSWORD="ios-dist-password",
            APPLE_IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms-envelope").decode("ascii"),
            APPLE_API_PRIVATE_KEY_BASE64=FAKE_P8_B64,
            APPLE_API_KEY_ID=API_KEY_ID,
            APPLE_API_ISSUER_ID=API_ISSUER_ID,
        )
        with patch.dict(os.environ, ios_only_env, clear=True):
            signing.prepare_macos()
            self.assertEqual(self.read_kv(self.gh_out), {"signed": "false", "notarized": "false"})
            os.environ.update(self.read_kv(self.gh_env))
            signing.cleanup()

        # Reset output files before testing macOS-only secrets in prepare_ios().
        self.gh_env.write_text("", encoding="utf-8")
        self.gh_out.write_text("", encoding="utf-8")
        macos_only_env = self.base_env(
            APPLE_TEAM_ID=TEAM_ID,
            APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64,
            APPLE_DEV_ID_P12_PASSWORD="macos-dev-id-password",
            APPLE_API_PRIVATE_KEY_BASE64=FAKE_P8_B64,
            APPLE_API_KEY_ID=API_KEY_ID,
            APPLE_API_ISSUER_ID=API_ISSUER_ID,
        )
        with patch.dict(os.environ, macos_only_env, clear=True):
            signing.prepare_ios(BUNDLE_ID)
            self.assertEqual(
                self.read_kv(self.gh_out),
                {"signed": "false", "can_upload_testflight": "false"},
            )
            os.environ.update(self.read_kv(self.gh_env))
            signing.cleanup()

        # Platform-specific secrets with missing APPLE_TEAM_ID still fail closed.
        with patch.dict(
            os.environ,
            self.base_env(APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64, APPLE_DEV_ID_P12_PASSWORD="pw"),
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "APPLE_TEAM_ID"):
                signing.prepare_macos()

        with patch.dict(
            os.environ,
            self.base_env(
                APPLE_DIST_P12_BASE64=FAKE_P12_B64,
                APPLE_DIST_P12_PASSWORD="pw",
                APPLE_IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms").decode("ascii"),
            ),
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "APPLE_TEAM_ID"):
                signing.prepare_ios(BUNDLE_ID)

    def test_partial_secrets_fail_closed_and_passwords_are_redacted(self):
        with patch.dict(
            os.environ,
            self.base_env(APPLE_TEAM_ID=TEAM_ID, APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64),
            clear=True,
        ):
            with self.assertRaisesRegex(ValueError, "APPLE_DEV_ID_P12_PASSWORD"):
                signing.prepare_macos()

        secret_pw = "SuperSecretP12Pass!99"

        def failing_import(args, **kwargs):
            cmd = [str(a) for a in args]
            if cmd[:2] == ["security", "list-keychains"]:
                return subprocess.CompletedProcess(args, 0, stdout='    "/Users/runner/Library/Keychains/login.keychain-db"\n', stderr="")
            if cmd[:2] == ["security", "import"]:
                return subprocess.CompletedProcess(
                    args, 1, stdout="", stderr=f"security: SecKeychainItemImport failed for {secret_pw}"
                )
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.dict(
            os.environ,
            self.base_env(
                APPLE_TEAM_ID=TEAM_ID,
                APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64,
                APPLE_DEV_ID_P12_PASSWORD=secret_pw,
            ),
            clear=True,
        ), patch("subprocess.run", side_effect=failing_import):
            with self.assertRaises(RuntimeError) as ctx:
                signing.prepare_macos()
            self.assertNotIn(secret_pw, str(ctx.exception))
            self.assertIn("[REDACTED]", str(ctx.exception))

    def test_timeout_redacts_keychain_and_p12_passwords_in_main_stderr(self):
        secret_pw = "UltraSecretP12Password!42"
        captured_keychain_pw = []

        def timeout_during_keychain_and_import(args, **kwargs):
            cmd = [str(a) for a in args]
            if cmd[:2] == ["security", "list-keychains"] and "-s" not in cmd:
                return subprocess.CompletedProcess(args, 0, stdout='    "/Users/runner/login.keychain-db"\n', stderr="")
            if cmd[:2] == ["security", "create-keychain"]:
                pw_idx = cmd.index("-p") + 1
                captured_keychain_pw.append(cmd[pw_idx])
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
            if cmd[:2] == ["security", "import"]:
                kc_pw = captured_keychain_pw[0]
                raise subprocess.TimeoutExpired(
                    cmd=cmd,
                    timeout=300,
                    output="",
                    stderr=f"stalled importing p12={secret_pw} keychain={kc_pw}",
                )
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        stderr_buf = io.StringIO()
        with patch.dict(
            os.environ,
            self.base_env(
                APPLE_TEAM_ID=TEAM_ID,
                APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64,
                APPLE_DEV_ID_P12_PASSWORD=secret_pw,
            ),
            clear=True,
        ), patch("subprocess.run", side_effect=timeout_during_keychain_and_import), patch(
            "sys.stderr", stderr_buf
        ):
            with self.assertRaises(SystemExit) as exit_ctx:
                signing.main(["prepare-macos"])

        self.assertEqual(exit_ctx.exception.code, 1)
        self.assertEqual(len(captured_keychain_pw), 1)
        err_text = stderr_buf.getvalue()
        self.assertIn("security timed out after 300s", err_text)
        self.assertIn("[REDACTED]", err_text)
        self.assertNotIn(secret_pw, err_text)
        self.assertNotIn(captured_keychain_pw[0], err_text)
        self.assertNotIn("-P", err_text)

    def test_macos_developer_id_sign_notarize_verify_and_failure_log(self):
        calls = []
        notarize_status = {"value": "Accepted"}

        def fake_run(args, **kwargs):
            cmd = [str(a) for a in args]
            calls.append(cmd)
            if cmd[:2] == ["security", "list-keychains"] and "-s" not in cmd:
                return subprocess.CompletedProcess(args, 0, stdout='    "/Users/runner/login.keychain-db"\n', stderr="")
            if cmd[:2] == ["security", "find-identity"]:
                out = f'  1) {DEV_ID_SHA1} "Developer ID Application: Noah Seymour ({TEAM_ID})"\n'
                return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
            if cmd[:3] == ["xcrun", "notarytool", "submit"]:
                out = json.dumps({"id": NOTARY_SUBMISSION_ID, "message": "Successfully uploaded file"})
                return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
            if cmd[:3] == ["xcrun", "notarytool", "wait"]:
                self.assertEqual(cmd[3], NOTARY_SUBMISSION_ID)
                out = json.dumps({"id": NOTARY_SUBMISSION_ID, "status": notarize_status["value"]})
                return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
            if cmd[:3] == ["xcrun", "notarytool", "log"]:
                return subprocess.CompletedProcess(args, 0, stdout='{"issues":[{"message":"unsigned nested binary"}]}', stderr="")
            if cmd[:2] == ["codesign", "-dv"]:
                err = (
                    f"Authority=Developer ID Application: Noah Seymour ({TEAM_ID})\n"
                    f"TeamIdentifier={TEAM_ID}\n"
                    "CodeDirectory v=20500 size=1024 flags=0x10000(runtime)\n"
                    "Timestamp=Nov 13, 2026 at 21:00:00\n"
                )
                return subprocess.CompletedProcess(args, 0, stdout="", stderr=err)
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        app_dir = self.base / "MicDrop.app"
        (app_dir / "Contents" / "Frameworks").mkdir(parents=True)
        dylib = app_dir / "Contents" / "Frameworks" / "libmicdrop_rtc.dylib"
        dylib.write_bytes(b"dylib")

        env = self.base_env(
            APPLE_TEAM_ID=TEAM_ID,
            APPLE_DEV_ID_P12_BASE64=FAKE_P12_B64,
            APPLE_DEV_ID_P12_PASSWORD="p12-password",
            APPLE_API_PRIVATE_KEY_BASE64=FAKE_P8_B64,
            APPLE_API_KEY_ID=API_KEY_ID,
            APPLE_API_ISSUER_ID=API_ISSUER_ID,
        )
        with patch.dict(os.environ, env, clear=True), patch("subprocess.run", side_effect=fake_run):
            signing.prepare_macos()
            self.assertEqual(self.read_kv(self.gh_out), {"signed": "true", "notarized": "true"})
            os.environ.update(self.read_kv(self.gh_env))
            state = json.loads(Path(os.environ["MICDROP_APPLE_SIGNING_STATE"]).read_text(encoding="utf-8"))
            # Raw .p12 file must already be deleted after import.
            self.assertFalse((Path(state["work_dir"]) / "signing-cert.p12").exists())
            self.assertTrue(Path(state["api_key_path"]).is_file())

            signing.sign_macos([dylib, app_dir])
            signing.notarize_macos(app_dir, staple=True)
            signing.verify_macos_app(app_dir)
            signing.verify_macos_binaries([dylib])

            # Test notarization rejection fetches notarytool log automatically.
            notarize_status["value"] = "Invalid"
            with self.assertRaisesRegex(RuntimeError, "unsigned nested binary"):
                signing.notarize_macos(app_dir, staple=False)

            signing.cleanup()
            self.assertFalse(Path(state["work_dir"]).exists())

        submits = [cmd for cmd in calls if cmd[:3] == ["xcrun", "notarytool", "submit"]]
        waits = [cmd for cmd in calls if cmd[:3] == ["xcrun", "notarytool", "wait"]]
        self.assertEqual(len(submits), 2)
        self.assertEqual(len(waits), 2)
        self.assertTrue(all("--wait" not in cmd for cmd in submits))
        self.assertTrue(all(cmd[cmd.index("--timeout") + 1] == "60m" for cmd in waits))

    def test_notary_wait_keeps_one_submission_and_safe_exact_byte_evidence(self):
        target = self.base / "MicDrop.zip"
        archive = b"exact signed payload bytes for notarization"
        target.write_bytes(archive)
        key_path = self.base / "AuthKey.p8"
        key_text = "-----BEGIN PRIVATE KEY-----\nprivate-test-key\n-----END PRIVATE KEY-----"
        key_path.write_text(key_text, encoding="utf-8")
        key_b64 = base64.b64encode(key_text.encode()).decode("ascii")
        evidence_root = self.base / "evidence"
        evidence_dir = evidence_root / target.name
        state = {
            "notarized": True,
            "work_dir": str(self.runner_temp),
            "api_key_path": str(key_path),
            "api_key_id": API_KEY_ID,
            "api_issuer_id": API_ISSUER_ID,
        }
        cases = (
            ("accepted", None, "Accepted"),
            ("invalid", "(?s)rejected.*unsigned nested binary", "Invalid"),
            ("timeout", "still pending.*60m", "In Progress"),
            ("pending", "still pending", "In Progress"),
            ("process_timeout", "result unconfirmed.*timed out", "Result unconfirmed"),
            ("wait_failure", "result unconfirmed.*failed", "Result unconfirmed"),
            ("unknown", "unknown status", "Result unconfirmed"),
            ("mismatched_id", "different submission ID", "Result unconfirmed"),
            ("malformed_result", "unreadable JSON", "Result unconfirmed"),
        )
        for case, error_pattern, expected_status in cases:
            calls = []
            stdout = io.StringIO()

            def fake_run(args, **kwargs):
                cmd = [str(a) for a in args]
                calls.append(cmd)
                if cmd[:3] == ["xcrun", "notarytool", "submit"]:
                    self.assertNotIn("--wait", cmd)
                    return subprocess.CompletedProcess(args, 0, stdout=json.dumps({"id": NOTARY_SUBMISSION_ID}), stderr="")
                if cmd[:3] == ["xcrun", "notarytool", "wait"]:
                    self.assertEqual(cmd[3], NOTARY_SUBMISSION_ID)
                    self.assertEqual(kwargs["timeout"], 3700)
                    self.assertEqual(cmd[cmd.index("--timeout") + 1], "60m")
                    # The UUID and exact upload must already be persisted before
                    # waiting, including if a runner is killed during this call.
                    self.assertIn(NOTARY_SUBMISSION_ID, stdout.getvalue())
                    prior = json.loads((evidence_dir / "submission.json").read_text())
                    self.assertEqual(prior["id"], NOTARY_SUBMISSION_ID)
                    self.assertEqual(prior["status"], "Uploaded")
                    self.assertEqual((evidence_dir / "upload.zip").read_bytes(), archive)
                    if case == "process_timeout":
                        raise subprocess.TimeoutExpired(cmd, 3700, output=key_text.encode(), stderr=key_b64.encode())
                    if case == "wait_failure":
                        return subprocess.CompletedProcess(args, 1, stdout="", stderr=f"failed {key_text} {key_b64}")
                    if case == "malformed_result":
                        return subprocess.CompletedProcess(args, 0, stdout="not JSON", stderr="")
                    status = {"accepted": "Accepted", "invalid": "Invalid", "unknown": "Unexpected"}.get(case, "In Progress")
                    wait_id = PROFILE_UUID if case == "mismatched_id" else NOTARY_SUBMISSION_ID
                    return subprocess.CompletedProcess(
                        args, 124 if case == "timeout" else 0,
                        stdout=json.dumps({"id": wait_id, "status": status}),
                        stderr=key_text if case == "timeout" else "",
                    )
                if cmd[:3] == ["xcrun", "notarytool", "log"]:
                    return subprocess.CompletedProcess(args, 0, stdout=f"unsigned nested binary {key_text} {key_b64}", stderr="")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with self.subTest(case=case), patch.dict(
                os.environ,
                {"MICDROP_NOTARIZATION_EVIDENCE_DIR": str(evidence_root), "APPLE_API_PRIVATE_KEY_BASE64": key_b64},
                clear=True,
            ), patch.object(signing, "_load_state", return_value=state), patch("subprocess.run", side_effect=fake_run), patch("sys.stdout", stdout):
                error_text = ""
                if error_pattern:
                    with self.assertRaisesRegex(RuntimeError, error_pattern) as exc:
                        signing.notarize_macos(target, staple=True)
                    error_text = str(exc.exception)
                    self.assertIn(NOTARY_SUBMISSION_ID, error_text)
                else:
                    signing.notarize_macos(target, staple=True)

                receipt_text = (evidence_dir / "submission.json").read_text()
                receipt = json.loads(receipt_text)
                self.assertEqual(receipt, {
                    "target": target.name, "id": NOTARY_SUBMISSION_ID,
                    "status": expected_status, "sha256": hashlib.sha256(archive).hexdigest(),
                })
                self.assertEqual((evidence_dir / "upload.zip").read_bytes(), archive)
                self.assertEqual(sorted(p.name for p in evidence_dir.iterdir()), ["submission.json", "upload.zip"])
                for secret in (key_text, key_b64, str(key_path), API_KEY_ID, API_ISSUER_ID):
                    self.assertNotIn(secret, receipt_text)
                for secret in (key_text, key_b64):
                    self.assertNotIn(secret, error_text + stdout.getvalue())
                self.assertEqual(sum(cmd[:3] == ["xcrun", "notarytool", "submit"] for cmd in calls), 1)
                self.assertEqual(sum(cmd[:3] == ["xcrun", "notarytool", "wait"] for cmd in calls), 1)
                staple_calls = [cmd for cmd in calls if cmd[:2] == ["xcrun", "stapler"]]
                self.assertEqual(len(staple_calls), 2 if case == "accepted" else 0)
                log_calls = [cmd for cmd in calls if cmd[:3] == ["xcrun", "notarytool", "log"]]
                self.assertEqual(len(log_calls), 1 if case == "invalid" else 0)
                self.assertEqual(list(self.runner_temp.iterdir()), [])

    def test_ios_prepare_export_options_testflight_upload_and_cleanup(self):
        calls = []
        envs_seen = []
        profile_xml = make_profile_plist()

        def fake_run(args, **kwargs):
            cmd = [str(a) for a in args]
            calls.append(cmd)
            if kwargs.get("env") is not None:
                envs_seen.append(kwargs["env"])
            if cmd[:2] == ["security", "list-keychains"] and "-s" not in cmd:
                return subprocess.CompletedProcess(args, 0, stdout='    "/Users/runner/login.keychain-db"\n', stderr="")
            if cmd[:2] == ["security", "find-identity"]:
                out = f'  1) {FAKE_CERT_SHA1} "Apple Distribution: Noah Seymour ({TEAM_ID})"\n'
                return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
            if cmd[:3] == ["security", "cms", "-D"]:
                return subprocess.CompletedProcess(args, 0, stdout=profile_xml, stderr="")
            if cmd[:2] == ["xcrun", "altool"]:
                return subprocess.CompletedProcess(args, 0, stdout='{"tool-version":"26.0"}', stderr="")
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        ipa_file = self.base / "MicDrop-signed.ipa"
        ipa_file.write_bytes(b"signed-ipa")

        env = self.base_env(
            APPLE_TEAM_ID=TEAM_ID,
            APPLE_DIST_P12_BASE64=FAKE_P12_B64,
            APPLE_DIST_P12_PASSWORD="dist-password",
            APPLE_IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms-envelope").decode("ascii"),
            APPLE_API_PRIVATE_KEY_BASE64=FAKE_P8_B64,
            APPLE_API_KEY_ID=API_KEY_ID,
            APPLE_API_ISSUER_ID=API_ISSUER_ID,
        )
        with patch.dict(os.environ, env, clear=True), patch("subprocess.run", side_effect=fake_run):
            signing.prepare_ios(BUNDLE_ID)
            self.assertEqual(
                self.read_kv(self.gh_out),
                {"signed": "true", "can_upload_testflight": "true"},
            )
            gh_vars = self.read_kv(self.gh_env)
            os.environ.update(gh_vars)

            export_opts = plistlib.loads(Path(gh_vars["MICDROP_IOS_EXPORT_OPTIONS"]).read_bytes())
            self.assertEqual(export_opts["method"], "app-store-connect")
            self.assertEqual(export_opts["destination"], "export")
            self.assertIs(export_opts["manageAppVersionAndBuildNumber"], False)
            self.assertEqual(export_opts["provisioningProfiles"], {BUNDLE_ID: PROFILE_UUID})
            self.assertEqual(export_opts["signingCertificate"], FAKE_CERT_SHA1)
            self.assertEqual(export_opts["teamID"], TEAM_ID)

            xcode_prof = (
                self.home
                / "Library"
                / "Developer"
                / "Xcode"
                / "UserData"
                / "Provisioning Profiles"
                / f"{PROFILE_UUID}.mobileprovision"
            )
            legacy_prof = (
                self.home
                / "Library"
                / "MobileDevice"
                / "Provisioning Profiles"
                / f"{PROFILE_UUID}.mobileprovision"
            )
            self.assertTrue(xcode_prof.is_file())
            self.assertTrue(legacy_prof.is_file())

            signing.upload_testflight(ipa_file)
            self.assertEqual(len(envs_seen), 2)
            self.assertTrue(envs_seen[0]["API_PRIVATE_KEYS_DIR"].endswith("private_keys"))

            signing.cleanup()
            self.assertFalse(xcode_prof.exists())
            self.assertFalse(legacy_prof.exists())

    def test_ios_accepts_legacy_application_identifier_prefix(self):
        legacy_xml = make_profile_plist(team_id=TEAM_ID, app_id_prefix=LEGACY_PREFIX)

        def fake_run(args, **kwargs):
            cmd = [str(a) for a in args]
            if cmd[:2] == ["security", "list-keychains"] and "-s" not in cmd:
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
            if cmd[:2] == ["security", "find-identity"]:
                out = f'  1) {FAKE_CERT_SHA1} "Apple Distribution: Noah Seymour ({TEAM_ID})"\n'
                return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
            if cmd[:3] == ["security", "cms", "-D"]:
                return subprocess.CompletedProcess(args, 0, stdout=legacy_xml, stderr="")
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        env = self.base_env(
            APPLE_TEAM_ID=TEAM_ID,
            APPLE_DIST_P12_BASE64=FAKE_P12_B64,
            APPLE_DIST_P12_PASSWORD="dist-password",
            APPLE_IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms").decode("ascii"),
        )
        with patch.dict(os.environ, env, clear=True), patch("subprocess.run", side_effect=fake_run):
            signing.prepare_ios(BUNDLE_ID)
            self.assertEqual(
                self.read_kv(self.gh_out),
                {"signed": "true", "can_upload_testflight": "false"},
            )
            gh_vars = self.read_kv(self.gh_env)
            os.environ.update(gh_vars)
            export_opts = plistlib.loads(Path(gh_vars["MICDROP_IOS_EXPORT_OPTIONS"]).read_bytes())
            self.assertEqual(export_opts["teamID"], TEAM_ID)
            self.assertEqual(export_opts["provisioningProfiles"], {BUNDLE_ID: PROFILE_UUID})
            signing.cleanup()

    def test_ios_rejects_mismatched_bundle_id_or_development_profile_or_wrong_cert(self):
        for label, xml_str, err_pattern in (
            ("wrong bundle", make_profile_plist(bundle_id="com.example.other"), "application-identifier"),
            (
                "unlisted prefix",
                make_profile_plist(
                    prefixes=[LEGACY_PREFIX],
                    app_id_entitlement=f"1122334455.{BUNDLE_ID}",
                ),
                "application-identifier",
            ),
            (
                "wildcard app id",
                make_profile_plist(
                    app_id_prefix=LEGACY_PREFIX,
                    app_id_entitlement=f"{LEGACY_PREFIX}.*",
                ),
                "application-identifier",
            ),
            (
                "mismatched team entitlement",
                make_profile_plist(team_entitlement="ZZZZ999999"),
                "com.apple.developer.team-identifier",
            ),
            ("dev profile", make_profile_plist(get_task_allow=True), "get-task-allow=true"),
            ("expired", make_profile_plist(expired=True), "expired"),
            ("wrong cert", make_profile_plist(certs=[b"other-cert"]), "not included in provisioning profile"),
        ):
            def fake_run(args, xml=xml_str, **kwargs):
                cmd = [str(a) for a in args]
                if cmd[:2] == ["security", "list-keychains"] and "-s" not in cmd:
                    return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
                if cmd[:2] == ["security", "find-identity"]:
                    out = f'  1) {FAKE_CERT_SHA1} "Apple Distribution: Noah Seymour ({TEAM_ID})"\n'
                    return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
                if cmd[:3] == ["security", "cms", "-D"]:
                    return subprocess.CompletedProcess(args, 0, stdout=xml, stderr="")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            env = self.base_env(
                APPLE_TEAM_ID=TEAM_ID,
                APPLE_DIST_P12_BASE64=FAKE_P12_B64,
                APPLE_DIST_P12_PASSWORD="dist-password",
                APPLE_IOS_PROVISION_PROFILE_BASE64=base64.b64encode(b"cms").decode("ascii"),
            )
            with self.subTest(case=label), patch.dict(os.environ, env, clear=True), patch(
                "subprocess.run", side_effect=fake_run
            ):
                with self.assertRaisesRegex(ValueError, err_pattern):
                    signing.prepare_ios(BUNDLE_ID)


if __name__ == "__main__":
    unittest.main()
