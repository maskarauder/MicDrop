# SPDX-License-Identifier: MPL-2.0
"""Unit tests for Android debug/release signing, AAB verification, and Google Play upload."""

import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import android_signing  # noqa: E402


def _parse_env_file(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            values[key] = val
    return values


def _build_signed_aab(
    target_path,
    keystore_path,
    store_password,
    alias,
    *,
    manifest_bytes=b"\x0a\x17com.maskarauder.micdrop",
    abi="arm64-v8a",
):
    with zipfile.ZipFile(target_path, "w") as bundle:
        bundle.writestr("BundleConfig.pb", b"\x08\x01")
        bundle.writestr("base/manifest/AndroidManifest.xml", manifest_bytes)
        bundle.writestr(f"base/lib/{abi}/libjingle_peerconnection_so.so", b"\x7fELF-mock")
    env = os.environ.copy()
    env["TEST_STOREPASS"] = store_password
    subprocess.run(
        [
            "jarsigner",
            "-keystore",
            str(keystore_path),
            "-storepass:env",
            "TEST_STOREPASS",
            str(target_path),
            alias,
        ],
        env=env,
        check=True,
        capture_output=True,
    )


class AndroidSigningTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.github_env = self.root / "github.env"
        self.github_out = self.root / "github.out"
        self.github_env.touch()
        self.github_out.touch()

    def tearDown(self):
        self.temp.cleanup()

    def _base_env(self):
        return {
            "PATH": os.environ.get("PATH", ""),
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_ENV": str(self.github_env),
            "GITHUB_OUTPUT": str(self.github_out),
        }

    def test_java_properties_roundtrip_with_special_characters(self):
        raw = android_signing.encode_java_properties(
            {
                "storeFile": r"C:\Users\runner\temp\upload.keystore",
                "storePassword": " leading=:#!\\pw\n",
                "keyAlias": "upload",
                "keyPassword": "p\u00e4ss",
            }
        )
        text = raw.decode("ascii")
        self.assertIn(r"storeFile=C\:\\Users\\runner\\temp\\upload.keystore", text)
        self.assertIn(r"storePassword=\ leading\=\:\#\!\\pw\n", text)
        self.assertIn(r"keyPassword=p\u00e4ss", text)

    def test_prepare_release_disposable_fallback_signs_and_verifies_aab(self):
        with mock.patch.dict(os.environ, self._base_env(), clear=True):
            android_signing.prepare_release()
            env_out = _parse_env_file(self.github_env)
            gh_out = _parse_env_file(self.github_out)
            self.assertEqual(gh_out["release_signer"], "false")
            props_path = Path(env_out["MICDROP_RELEASE_SIGNING_PROPS"])
            self.assertTrue(props_path.is_file())

            props = _parse_env_file(props_path)
            keystore = Path(props["storeFile"].replace("\\:", ":").replace("\\\\", "\\"))
            aab = self.root / "app-release.aab"
            _build_signed_aab(aab, keystore, props["storePassword"], props["keyAlias"])

            os.environ.update(env_out)
            android_signing.verify_aab(aab)
            android_signing.cleanup()
            self.assertFalse(props_path.exists())
            self.assertFalse(keystore.exists())

    def test_prepare_release_configured_secret_sets_release_signer_true(self):
        ks = self.root / "configured-upload.p12"
        pw = "UploadSecret#2026!"
        child_env = os.environ.copy()
        child_env["KS_PW"] = pw
        subprocess.run(
            [
                "keytool",
                "-genkeypair",
                "-keystore",
                str(ks),
                "-storetype",
                "PKCS12",
                "-alias",
                "micdrop-upload",
                "-storepass:env",
                "KS_PW",
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "365",
                "-dname",
                "CN=MicDrop Upload,O=Maskarauder,C=US",
                "-noprompt",
            ],
            env=child_env,
            check=True,
            capture_output=True,
        )
        env = self._base_env()
        env["MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64"] = base64.b64encode(ks.read_bytes()).decode("ascii")
        env["MICDROP_ANDROID_UPLOAD_STORE_PASSWORD"] = pw
        env["MICDROP_ANDROID_UPLOAD_KEY_ALIAS"] = "micdrop-upload"

        with mock.patch.dict(os.environ, env, clear=True):
            android_signing.prepare_release()
            env_out = _parse_env_file(self.github_env)
            gh_out = _parse_env_file(self.github_out)
            self.assertEqual(gh_out["release_signer"], "true")

            aab = self.root / "configured.aab"
            _build_signed_aab(aab, ks, pw, "micdrop-upload")
            android_signing.verify_aab(aab, expected_sha256=env_out["MICDROP_RELEASE_KEYSTORE_SHA256"])

    def test_prepare_release_rejects_partial_secrets(self):
        env = self._base_env()
        env["MICDROP_ANDROID_UPLOAD_STORE_PASSWORD"] = "only-password"
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaisesRegex(ValueError, "Incomplete Android upload signing"):
                android_signing.prepare_release()

    def test_prepare_release_preserves_password_whitespace(self):
        ks = self.root / "whitespace-upload.jks"
        store_password = " StoreSecret#2026! "
        key_password = "\t KeySecret#2026!\t "
        child_env = os.environ.copy()
        child_env.update(STORE_PW=store_password, KEY_PW=key_password)
        subprocess.run(
            [
                "keytool", "-genkeypair", "-keystore", str(ks),
                "-storetype", "JKS", "-alias", "upload",
                "-storepass:env", "STORE_PW", "-keypass:env", "KEY_PW",
                "-keyalg", "RSA", "-keysize", "2048", "-validity", "365",
                "-dname", "CN=Test,O=Test,C=US", "-noprompt",
            ],
            env=child_env,
            check=True,
            capture_output=True,
        )
        env = self._base_env()
        env.update(
            MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64=base64.b64encode(ks.read_bytes()).decode("ascii"),
            MICDROP_ANDROID_UPLOAD_STORE_PASSWORD=store_password,
            MICDROP_ANDROID_UPLOAD_KEY_ALIAS="upload",
        )
        # An omitted key password inherits the exact store password; a supplied
        # password retains even whitespace-only contents instead of falling back.
        for supplied_key_password in (None, key_password, "      "):
            with self.subTest(key_password=supplied_key_password):
                configured_env = dict(env)
                if supplied_key_password is not None:
                    configured_env["MICDROP_ANDROID_UPLOAD_KEY_PASSWORD"] = supplied_key_password
                with mock.patch.dict(os.environ, configured_env, clear=True):
                    android_signing.prepare_release()
                    env_out = _parse_env_file(self.github_env)
                    self.assertEqual(_parse_env_file(self.github_out)["release_signer"], "true")
                    props = Path(env_out["MICDROP_RELEASE_SIGNING_PROPS"]).read_text(encoding="ascii")
                    self.assertIn("storePassword=\\ StoreSecret\\#2026\\! \n", props)
                    expected_key = {
                        None: "\\ StoreSecret\\#2026\\! ",
                        key_password: "\\t KeySecret\\#2026\\!\\t ",
                        "      ": "\\      ",
                    }[supplied_key_password]
                    self.assertIn(f"keyPassword={expected_key}\n", props)
                    os.environ.update(env_out)
                    android_signing.cleanup()

    def test_verify_aab_rejects_debug_leaks_and_wrong_signer(self):
        ks1 = self.root / "k1.p12"
        ks2 = self.root / "k2.p12"
        for ks in (ks1, ks2):
            subprocess.run(
                [
                    "keytool",
                    "-genkeypair",
                    "-keystore",
                    str(ks),
                    "-storetype",
                    "PKCS12",
                    "-alias",
                    "upload",
                    "-storepass",
                    "password123",
                    "-keyalg",
                    "RSA",
                    "-keysize",
                    "2048",
                    "-validity",
                    "365",
                    "-dname",
                    "CN=Test,O=Test,C=US",
                    "-noprompt",
                ],
                check=True,
                capture_output=True,
            )
        expected = android_signing.certificate_digest(ks1, alias="upload", store_password="password123")

        wrong_signer_aab = self.root / "wrong-signer.aab"
        _build_signed_aab(wrong_signer_aab, ks2, "password123", "upload")
        with self.assertRaisesRegex(RuntimeError, "does not match configured upload keystore"):
            android_signing.verify_aab(wrong_signer_aab, expected_sha256=expected)

        dev_leak_aab = self.root / "dev-leak.aab"
        _build_signed_aab(
            dev_leak_aab,
            ks1,
            "password123",
            "upload",
            manifest_bytes=b"com.maskarauder.micdrop.dev",
        )
        with self.assertRaisesRegex(ValueError, "applicationIdSuffix"):
            android_signing.verify_aab(dev_leak_aab, expected_sha256=expected)

        adb_leak_aab = self.root / "adb-leak.aab"
        _build_signed_aab(
            adb_leak_aab,
            ks1,
            "password123",
            "upload",
            manifest_bytes=b"com.maskarauder.micdrop AdbControlActivity",
        )
        with self.assertRaisesRegex(ValueError, "AdbControlActivity"):
            android_signing.verify_aab(adb_leak_aab, expected_sha256=expected)

        tampered_aab = self.root / "tampered.aab"
        _build_signed_aab(tampered_aab, ks1, "password123", "upload")
        with zipfile.ZipFile(tampered_aab, "a") as bundle:
            bundle.writestr("base/assets/injected.txt", b"unsigned")
        with self.assertRaisesRegex(RuntimeError, "unsigned"):
            android_signing.verify_aab(tampered_aab, expected_sha256=expected)

    def test_upload_play_executes_edits_bundle_track_commit_transaction(self):
        key_pem = self.root / "sa.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(key_pem)],
            check=True,
            capture_output=True,
        )
        sa_json = json.dumps(
            {
                "type": "service_account",
                "client_email": "play-ci@micdrop-test.iam.gserviceaccount.com",
                "private_key": key_pem.read_text(encoding="utf-8"),
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        ).encode("utf-8")
        aab = self.root / "upload.aab"
        aab.write_bytes(b"signed-aab-bytes")

        calls = []

        class FakeResponse:
            def __init__(self, payload):
                self._raw = json.dumps(payload).encode("utf-8")

            def read(self):
                return self._raw

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

        def fake_opener(request, timeout=300):
            calls.append((request.get_method(), request.full_url, request.data))
            if request.full_url == "https://oauth2.googleapis.com/token":
                return FakeResponse({"access_token": "ya29.mock-token"})
            if request.full_url.endswith("/edits"):
                return FakeResponse({"id": "edit-42"})
            if "/bundles?uploadType=media" in request.full_url:
                self.assertEqual(request.data, b"signed-aab-bytes")
                return FakeResponse({"versionCode": 5})
            if "/tracks/internal" in request.full_url:
                body = json.loads(request.data.decode("utf-8"))
                self.assertEqual(
                    body,
                    {"track": "internal", "releases": [{"versionCodes": ["5"], "status": "completed"}]},
                )
                return FakeResponse({"track": "internal"})
            if request.full_url.endswith("/edits/edit-42:commit"):
                return FakeResponse({"id": "edit-42"})
            raise AssertionError(f"Unexpected URL: {request.full_url}")

        env = self._base_env()
        env["GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64"] = base64.b64encode(sa_json).decode("ascii")
        with mock.patch.dict(os.environ, env, clear=True):
            version_code = android_signing.upload_play(
                aab,
                "com.maskarauder.micdrop",
                "internal",
                "completed",
                opener=fake_opener,
            )
        self.assertEqual(version_code, 5)
        self.assertEqual([c[0] for c in calls], ["POST", "POST", "POST", "PUT", "POST"])


if __name__ == "__main__":
    unittest.main()
