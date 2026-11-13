# SPDX-License-Identifier: MPL-2.0
"""Unit tests for tools/windows_signing.py."""

import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import windows_signing  # noqa: E402

TENANT_ID = "11111111-2222-3333-4444-555555555555"
CLIENT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
ENDPOINT = "https://eus.codesigning.azure.net/"
ACCOUNT = "micdrop-signing"
PROFILE = "micdrop-public"


def _make_jwt(sub, *, exp=None):
    header = base64.urlsafe_b64encode(b'{"alg":"RS256"}').rstrip(b"=").decode("ascii")
    claims = {"sub": sub}
    if exp is not None:
        claims["exp"] = exp
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode("utf-8")).rstrip(b"=").decode("ascii")
    sig = base64.urlsafe_b64encode(f"sig-{sub}-{exp}".encode("utf-8")).rstrip(b"=").decode("ascii")
    return f"{header}.{payload}.{sig}"


FAKE_JWT_1 = _make_jwt("github-prepare")
FAKE_JWT_2 = _make_jwt("github-attempt-1")
FAKE_JWT_3 = _make_jwt("github-attempt-2")


def _build_nupkg_bytes(entries):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    raw = buf.getvalue()
    return raw, hashlib.sha256(raw).hexdigest()


class _FakeHTTPResponse:
    def __init__(self, body_bytes):
        self._stream = io.BytesIO(body_bytes)

    def read(self, size=-1):
        return self._stream.read(size)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class WindowsSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.repo_root = self.root / "repo"
        self.repo_root.mkdir()
        self.gh_env = self.root / "github_env.txt"
        self.gh_out = self.root / "github_output.txt"

        sdk_bytes, sdk_sha = _build_nupkg_bytes(
            {
                "bin/10.0.28000.0/x64/signtool.exe": b"MZ-fake-signtool",
                "bin/10.0.28000.0/x64/mssign32.dll": b"MZ-fake-mssign32",
                "bin/10.0.28000.0/x86/signtool.exe": b"MZ-unused-x86",
            }
        )
        dlib_bytes, dlib_sha = _build_nupkg_bytes(
            {
                "bin/x64/Azure.CodeSigning.Dlib.dll": b"MZ-fake-dlib",
                "bin/x64/Azure.Identity.dll": b"MZ-fake-identity",
                "LICENSE.md": b"Microsoft Artifact Signing Client License\n",
            }
        )
        self.sdk_pkg = {**windows_signing.SDK_PACKAGE, "sha256": sdk_sha}
        self.dlib_pkg = {**windows_signing.DLIB_PACKAGE, "sha256": dlib_sha}
        self.nupkg_payloads = {
            self.sdk_pkg["url"]: sdk_bytes,
            self.dlib_pkg["url"]: dlib_bytes,
        }

    def _base_env(self, **extra):
        env = {
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_ENV": str(self.gh_env),
            "GITHUB_OUTPUT": str(self.gh_out),
            "GITHUB_RUN_ID": "98765",
            "GITHUB_RUN_ATTEMPT": "2",
        }
        for key in (
            "AZURE_TENANT_ID",
            "AZURE_CLIENT_ID",
            "AZURE_CLIENT_SECRET",
            "AZURE_SIGNING_ENDPOINT",
            "AZURE_SIGNING_ACCOUNT",
            "AZURE_SIGNING_CERT_PROFILE",
            "AZURE_SIGNING_PUBLISHER",
            "ACTIONS_ID_TOKEN_REQUEST_URL",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
            "MICDROP_WINDOWS_SIGNING_STATE",
        ):
            env[key] = ""
        env.update(extra)
        return env

    def test_unconfigured_prepare_and_noop_sign_verify_cleanup(self):
        target = self.root / "MicDrop.exe"
        target.write_bytes(b"MZ-unsigned")
        with patch.dict(os.environ, self._base_env(), clear=False):
            state = windows_signing.prepare(repo_root=self.repo_root)
            self.assertFalse(state["signed"])
            self.assertIn("signed=false\n", self.gh_out.read_text(encoding="utf-8"))
            state_line = self.gh_env.read_text(encoding="utf-8").strip()
            state_path = state_line.split("=", 1)[1]
            os.environ["MICDROP_WINDOWS_SIGNING_STATE"] = state_path

            # Both sign and non-strict verify are safe no-ops when unconfigured.
            windows_signing.sign_files([target])
            windows_signing.verify_files([target], require_signed=False)
            with self.assertRaisesRegex(ValueError, "signing was required"):
                windows_signing.verify_files([target], require_signed=True)

            windows_signing.cleanup()
            self.assertFalse(Path(state["work_dir"]).exists())

    def test_partial_or_invalid_inputs_fail_closed_and_clean_work_dir(self):
        partial_env = self._base_env(AZURE_TENANT_ID=TENANT_ID, AZURE_SIGNING_ACCOUNT=ACCOUNT)
        with patch.dict(os.environ, partial_env, clear=False):
            with self.assertRaisesRegex(ValueError, "AZURE_CLIENT_ID.*AZURE_SIGNING_CERT_PROFILE"):
                windows_signing.prepare(repo_root=self.repo_root)
        self.assertEqual(list(self.runner_temp.iterdir()), [])

        invalid_cases = [
            ({"AZURE_TENANT_ID": "not-a-uuid"}, "AZURE_TENANT_ID"),
            ({"AZURE_CLIENT_ID": "not-a-uuid"}, "AZURE_CLIENT_ID"),
            ({"AZURE_SIGNING_ENDPOINT": "http://eus.codesigning.azure.net"}, "AZURE_SIGNING_ENDPOINT"),
            ({"AZURE_SIGNING_ENDPOINT": "https://evil.example.com"}, "AZURE_SIGNING_ENDPOINT"),
            ({"AZURE_SIGNING_ENDPOINT": "https://eus.codesigning.azure.net/extra"}, "AZURE_SIGNING_ENDPOINT"),
            ({"AZURE_SIGNING_ACCOUNT": "../bad"}, "AZURE_SIGNING_ACCOUNT"),
            ({"AZURE_SIGNING_ACCOUNT": "a" * 64}, "AZURE_SIGNING_ACCOUNT"),
            ({"AZURE_SIGNING_CERT_PROFILE": "bad;profile"}, "AZURE_SIGNING_CERT_PROFILE"),
            ({"AZURE_SIGNING_CERT_PROFILE": "p" * 101}, "AZURE_SIGNING_CERT_PROFILE"),
            ({"AZURE_SIGNING_CERT_PROFILE": "ab"}, "AZURE_SIGNING_CERT_PROFILE"),
            ({"AZURE_SIGNING_PUBLISHER": 'Bad"Publisher'}, "AZURE_SIGNING_PUBLISHER"),
            ({}, "OIDC.*AZURE_CLIENT_SECRET"),
        ]
        base_valid = {
            "AZURE_TENANT_ID": TENANT_ID,
            "AZURE_CLIENT_ID": CLIENT_ID,
            "AZURE_SIGNING_ENDPOINT": ENDPOINT,
            "AZURE_SIGNING_ACCOUNT": ACCOUNT,
            "AZURE_SIGNING_CERT_PROFILE": PROFILE,
            "AZURE_CLIENT_SECRET": "super-secret-value",
        }
        for overrides, pattern in invalid_cases:
            case_env = dict(base_valid)
            if not overrides:
                case_env["AZURE_CLIENT_SECRET"] = ""
            else:
                case_env.update(overrides)
            with self.subTest(overrides=overrides), patch.dict(
                os.environ, self._base_env(**case_env), clear=False
            ):
                with self.assertRaisesRegex(ValueError, pattern):
                    windows_signing.prepare(repo_root=self.repo_root)
        self.assertEqual(list(self.runner_temp.iterdir()), [])

    def test_long_certificate_profile_names_up_to_100_chars_are_accepted(self):
        def fake_run(args, **kwargs):
            return subprocess.CompletedProcess(
                args, 0, stdout="Microsoft.NETCore.App 8.0.11 [C:\\dotnet]\n", stderr=""
            )

        def fake_urlopen(req, timeout=120):
            return _FakeHTTPResponse(self.nupkg_payloads[req.full_url])

        for account_len, profile_len in ((63, 64), (63, 100)):
            long_account = "a" + ("b" * (account_len - 2)) + "c"
            long_profile = "p" + ("q" * (profile_len - 2)) + "r"
            env = self._base_env(
                AZURE_TENANT_ID=TENANT_ID,
                AZURE_CLIENT_ID=CLIENT_ID,
                AZURE_CLIENT_SECRET="secret-val",
                AZURE_SIGNING_ENDPOINT=ENDPOINT,
                AZURE_SIGNING_ACCOUNT=long_account,
                AZURE_SIGNING_CERT_PROFILE=long_profile,
            )
            with self.subTest(account_len=account_len, profile_len=profile_len), patch.dict(
                os.environ, env, clear=False
            ), patch.object(windows_signing, "SDK_PACKAGE", self.sdk_pkg), patch.object(
                windows_signing, "DLIB_PACKAGE", self.dlib_pkg
            ), patch("urllib.request.urlopen", side_effect=fake_urlopen), patch(
                "subprocess.run", side_effect=fake_run
            ):
                state = windows_signing.prepare(repo_root=self.repo_root)
                self.assertEqual(state["account"], long_account)
                self.assertEqual(state["cert_profile"], long_profile)
                os.environ["MICDROP_WINDOWS_SIGNING_STATE"] = str(Path(state["work_dir"]) / "state.json")
                windows_signing.cleanup()

    def test_oidc_prepare_refresh_sign_verify_and_cleanup(self):
        oidc_requests = []
        jwt_tokens = [FAKE_JWT_1, FAKE_JWT_2, FAKE_JWT_3]

        class FakeOpener:
            def open(self, req, timeout=30):
                oidc_requests.append((req.full_url, req.get_header("Authorization")))
                token = jwt_tokens[min(len(oidc_requests) - 1, len(jwt_tokens) - 1)]
                return _FakeHTTPResponse(json.dumps({"value": token}).encode("utf-8"))

        tool_calls = []
        tokens_seen_by_signtool = []

        def fake_run(args, capture_output=True, text=True, env=None, timeout=180):
            str_args = [str(a) for a in args]
            tool_calls.append((str_args, env))
            if Path(str_args[0]).name == "dotnet":
                return subprocess.CompletedProcess(
                    str_args, 0, stdout="Microsoft.NETCore.App 8.0.11 [C:\\dotnet]\n", stderr=""
                )
            if str_args[1] == "sign":
                staged_token = Path(env["AZURE_FEDERATED_TOKEN_FILE"]).read_text(encoding="utf-8")
                tokens_seen_by_signtool.append(staged_token)
                if len(tokens_seen_by_signtool) == 1:
                    return subprocess.CompletedProcess(
                        str_args, 1, stdout="", stderr=f"Transient TSA timeout ({staged_token})"
                    )
                return subprocess.CompletedProcess(str_args, 0, stdout="Successfully signed\n", stderr="")
            if str_args[1] == "verify":
                return subprocess.CompletedProcess(
                    str_args, 0, stdout="Successfully verified: MicDrop.exe\nNumber of errors: 0\n", stderr=""
                )
            raise AssertionError(f"Unexpected tool invocation: {str_args}")

        def fake_urlopen(req, timeout=120):
            return _FakeHTTPResponse(self.nupkg_payloads[req.full_url])

        env = self._base_env(
            AZURE_TENANT_ID=TENANT_ID,
            AZURE_CLIENT_ID=CLIENT_ID,
            AZURE_SIGNING_ENDPOINT=ENDPOINT,
            AZURE_SIGNING_ACCOUNT=ACCOUNT,
            AZURE_SIGNING_CERT_PROFILE=PROFILE,
            ACTIONS_ID_TOKEN_REQUEST_URL="https://token.actions.githubusercontent.com/id?job=1",
            ACTIONS_ID_TOKEN_REQUEST_TOKEN="gh-oidc-req-secret",
        )
        target = self.root / "MicDrop.exe"
        target.write_bytes(b"MZ-app")

        with patch.dict(os.environ, env, clear=False), patch.object(
            windows_signing, "SDK_PACKAGE", self.sdk_pkg
        ), patch.object(windows_signing, "DLIB_PACKAGE", self.dlib_pkg), patch(
            "urllib.request.build_opener", return_value=FakeOpener()
        ), patch(
            "urllib.request.urlopen", side_effect=fake_urlopen
        ), patch(
            "subprocess.run", side_effect=fake_run
        ):
            state = windows_signing.prepare(repo_root=self.repo_root)
            self.assertTrue(state["signed"])
            self.assertEqual(state["auth_mode"], "oidc")
            self.assertEqual(state["endpoint"], "https://eus.codesigning.azure.net")
            self.assertEqual(state["publisher"], "Noah Seymour")

            metadata = json.loads(Path(state["metadata_path"]).read_text(encoding="utf-8"))
            self.assertEqual(metadata["CorrelationId"], "github:98765:2")
            self.assertNotIn("WorkloadIdentityCredential", metadata["ExcludeCredentials"])
            self.assertIn("EnvironmentCredential", metadata["ExcludeCredentials"])

            os.environ["MICDROP_WINDOWS_SIGNING_STATE"] = str(Path(state["work_dir"]) / "state.json")
            windows_signing.sign_files([target], retry_delays=(0.0,))

            # OIDC token was fetched once in prepare and refreshed before EACH signing attempt (2 attempts).
            self.assertEqual(len(oidc_requests), 3)
            self.assertEqual(tokens_seen_by_signtool, [FAKE_JWT_2, FAKE_JWT_3])
            self.assertIn("audience=api%3A%2F%2FAzureADTokenExchange", oidc_requests[0][0])
            self.assertEqual(oidc_requests[0][1], "Bearer gh-oidc-req-secret")
            self.assertEqual(Path(state["oidc_token_file"]).read_text(encoding="utf-8"), FAKE_JWT_3)

            # Verify child env passed to signtool.exe had AZURE_FEDERATED_TOKEN_FILE and no AZURE_CLIENT_SECRET.
            sign_call_args, sign_env = [c for c in tool_calls if len(c[0]) > 1 and c[0][1] == "sign"][-1]
            self.assertEqual(sign_env["AZURE_TENANT_ID"], TENANT_ID)
            self.assertEqual(sign_env["AZURE_CLIENT_ID"], CLIENT_ID)
            self.assertEqual(sign_env["AZURE_FEDERATED_TOKEN_FILE"], state["oidc_token_file"])
            self.assertNotIn("AZURE_CLIENT_SECRET", sign_env)
            self.assertIn("http://timestamp.acs.microsoft.com", sign_call_args)

            windows_signing.verify_files([target], require_signed=True)
            windows_signing.cleanup()
            self.assertFalse(Path(state["work_dir"]).exists())

    def test_oidc_refreshes_expired_token_across_slow_retries_and_rejects_expired_staged_jwt(self):
        clock = {"now": 1_700_000_000.0}
        minted = []

        class ClockOpener:
            def open(self, req, timeout=30):
                idx = len(minted) + 1
                # GitHub Actions OIDC assertions expire after 5 minutes (300s).
                jwt_token = _make_jwt(f"attempt-{idx}", exp=int(clock["now"]) + 300)
                minted.append(jwt_token)
                return _FakeHTTPResponse(json.dumps({"value": jwt_token}).encode("utf-8"))

        sign_calls = []

        def fake_run(args, capture_output=True, text=True, env=None, timeout=180):
            str_args = [str(a) for a in args]
            if Path(str_args[0]).name == "dotnet":
                return subprocess.CompletedProcess(
                    str_args, 0, stdout="Microsoft.NETCore.App 8.0.11 [C:\\dotnet]\n", stderr=""
                )
            if str_args[1] == "sign":
                token = Path(env["AZURE_FEDERATED_TOKEN_FILE"]).read_text(encoding="utf-8")
                exp = windows_signing._jwt_expiration_epoch(token)
                self.assertIsNotNone(exp)
                # Every SignTool attempt must receive a fresh, unexpired OIDC token!
                self.assertGreater(exp, clock["now"], "SignTool was given an expired OIDC token")
                sign_calls.append(token)
                if len(sign_calls) == 1:
                    # Simulate a slow transient timeout that outlives the 5-minute OIDC assertion.
                    clock["now"] += 360.0
                    return subprocess.CompletedProcess(str_args, 1, stdout="", stderr="slow transient failure")
                clock["now"] += 45.0
                return subprocess.CompletedProcess(str_args, 0, stdout="Successfully signed\n", stderr="")
            if str_args[1] == "verify":
                return subprocess.CompletedProcess(
                    str_args, 0, stdout="Successfully verified\nNumber of errors: 0\n", stderr=""
                )
            raise AssertionError(f"Unexpected call: {str_args}")

        def fake_urlopen(req, timeout=120):
            return _FakeHTTPResponse(self.nupkg_payloads[req.full_url])

        exe = self.root / "MicDrop.exe"
        dll = self.root / "micdrop_rtc.dll"
        exe.write_bytes(b"MZ-exe")
        dll.write_bytes(b"MZ-dll")

        env = self._base_env(
            AZURE_TENANT_ID=TENANT_ID,
            AZURE_CLIENT_ID=CLIENT_ID,
            AZURE_SIGNING_ENDPOINT=ENDPOINT,
            AZURE_SIGNING_ACCOUNT=ACCOUNT,
            AZURE_SIGNING_CERT_PROFILE=PROFILE,
            ACTIONS_ID_TOKEN_REQUEST_URL="https://token.actions.githubusercontent.com/id?job=1",
            ACTIONS_ID_TOKEN_REQUEST_TOKEN="gh-oidc-req-secret",
        )
        with patch.dict(os.environ, env, clear=False), patch.object(
            windows_signing, "SDK_PACKAGE", self.sdk_pkg
        ), patch.object(windows_signing, "DLIB_PACKAGE", self.dlib_pkg), patch(
            "urllib.request.build_opener", return_value=ClockOpener()
        ), patch(
            "urllib.request.urlopen", side_effect=fake_urlopen
        ), patch(
            "subprocess.run", side_effect=fake_run
        ), patch(
            "windows_signing.time.time", side_effect=lambda: clock["now"]
        ), patch(
            "windows_signing.time.sleep", side_effect=lambda secs: clock.__setitem__("now", clock["now"] + secs)
        ):
            state = windows_signing.prepare(repo_root=self.repo_root)
            os.environ["MICDROP_WINDOWS_SIGNING_STATE"] = str(Path(state["work_dir"]) / "state.json")
            windows_signing.sign_files([exe, dll], retry_delays=(5.0,))
            # 1 prepare + 2 attempts for exe + 1 attempt for dll = 4 distinct minted tokens.
            self.assertEqual(len(minted), 4)
            self.assertEqual(len(set(sign_calls)), 3)

            # Without GitHub OIDC request vars, an expired pre-staged JWT is rejected before SignTool runs.
            os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] = ""
            os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = ""
            clock["now"] += 1000.0
            with self.assertRaisesRegex(ValueError, "expired"):
                windows_signing.sign_files([exe], retry_delays=())

            windows_signing.cleanup()

    def test_client_secret_mode_and_error_redaction_including_timeout(self):
        secret_value = "entra-client-secret-xyz-987"
        mode = {"timeout": False}

        def fake_run(args, capture_output=True, text=True, env=None, timeout=180):
            str_args = [str(a) for a in args]
            if Path(str_args[0]).name == "dotnet":
                return subprocess.CompletedProcess(
                    str_args, 0, stdout="Microsoft.NETCore.App 9.0.1 [C:\\dotnet]\n", stderr=""
                )
            if str_args[1] == "sign":
                self.assertEqual(env.get("AZURE_CLIENT_SECRET"), secret_value)
                self.assertNotIn("AZURE_FEDERATED_TOKEN_FILE", env)
                if mode["timeout"]:
                    raise subprocess.TimeoutExpired(
                        cmd=str_args,
                        timeout=timeout,
                        stderr=f"Timed out with secret={secret_value}",
                    )
                return subprocess.CompletedProcess(
                    str_args, 1, stdout=f"Auth error with secret={secret_value}", stderr=""
                )
            raise AssertionError(f"Unexpected call: {str_args}")

        def fake_urlopen(req, timeout=120):
            return _FakeHTTPResponse(self.nupkg_payloads[req.full_url])

        env = self._base_env(
            AZURE_TENANT_ID=TENANT_ID,
            AZURE_CLIENT_ID=CLIENT_ID,
            AZURE_CLIENT_SECRET=secret_value,
            AZURE_SIGNING_ENDPOINT=ENDPOINT,
            AZURE_SIGNING_ACCOUNT=ACCOUNT,
            AZURE_SIGNING_CERT_PROFILE=PROFILE,
            AZURE_SIGNING_PUBLISHER="Noah Seymour",
        )
        target = self.root / "micdrop_rtc.dll"
        target.write_bytes(b"MZ-dll")

        with patch.dict(os.environ, env, clear=False), patch.object(
            windows_signing, "SDK_PACKAGE", self.sdk_pkg
        ), patch.object(windows_signing, "DLIB_PACKAGE", self.dlib_pkg), patch(
            "urllib.request.urlopen", side_effect=fake_urlopen
        ), patch(
            "subprocess.run", side_effect=fake_run
        ):
            state = windows_signing.prepare(repo_root=self.repo_root)
            self.assertEqual(state["auth_mode"], "client_secret")
            metadata = json.loads(Path(state["metadata_path"]).read_text(encoding="utf-8"))
            self.assertNotIn("EnvironmentCredential", metadata["ExcludeCredentials"])
            self.assertIn("WorkloadIdentityCredential", metadata["ExcludeCredentials"])

            os.environ["MICDROP_WINDOWS_SIGNING_STATE"] = str(Path(state["work_dir"]) / "state.json")
            os.environ["AZURE_CLIENT_SECRET"] = ""
            with self.assertRaises(RuntimeError) as ctx:
                windows_signing.sign_files([target], retry_delays=())
            self.assertNotIn(secret_value, str(ctx.exception))
            self.assertIn("[REDACTED]", str(ctx.exception))

            mode["timeout"] = True
            stderr_buf = io.StringIO()
            with patch("sys.stderr", stderr_buf), patch("windows_signing.time.sleep"):
                with self.assertRaises(SystemExit) as exit_ctx:
                    windows_signing.main(["sign", str(target)])
            self.assertEqual(exit_ctx.exception.code, 1)
            self.assertIn("signtool.exe timed out", stderr_buf.getvalue())
            self.assertIn("[REDACTED]", stderr_buf.getvalue())
            self.assertNotIn(secret_value, stderr_buf.getvalue())

            windows_signing.cleanup()
            self.assertFalse(Path(state["work_dir"]).exists())

    def test_nuget_checksum_mismatch_and_unsafe_zip_entry_are_rejected(self):
        bad_pkg = {**self.sdk_pkg, "sha256": "0" * 64}
        with patch(
            "urllib.request.urlopen",
            side_effect=lambda req, timeout=120: _FakeHTTPResponse(self.nupkg_payloads[req.full_url]),
        ):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                windows_signing._download_verified_nupkg(bad_pkg, self.repo_root / ".deps/cache")

        traversal_bytes, traversal_sha = _build_nupkg_bytes(
            {"bin/x64/../../escape.dll": b"MZ-bad"}
        )
        archive = self.root / "bad.nupkg"
        archive.write_bytes(traversal_bytes)
        bad_dlib = {**self.dlib_pkg, "sha256": traversal_sha}
        with self.assertRaisesRegex(ValueError, "Unsafe path"):
            windows_signing._extract_verified_nupkg(archive, bad_dlib, self.repo_root / ".deps/windows-signing")

    def test_dotnet_below_8_is_rejected(self):
        def old_dotnet(args, **kwargs):
            return subprocess.CompletedProcess(
                args, 0, stdout="Microsoft.NETCore.App 6.0.36 [C:\\dotnet]\n", stderr=""
            )

        with patch("subprocess.run", side_effect=old_dotnet):
            with self.assertRaisesRegex(ValueError, r"\.NET 8\.0\+"):
                windows_signing._check_dotnet_runtime()


if __name__ == "__main__":
    unittest.main()
