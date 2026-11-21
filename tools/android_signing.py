# SPDX-License-Identifier: MPL-2.0
"""Prepare CI Android development/Play signing, verify APK/AAB signatures, upload to Play, and clean up."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

MAX_DEBUG_B64_LEN = 48 * 1024
MAX_UPLOAD_B64_LEN = 96 * 1024
MAX_SERVICE_ACCOUNT_B64_LEN = 64 * 1024
GOOGLE_OAUTH_TOKEN_URI = "https://oauth2.googleapis.com/token"
ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
ANDROID_PUBLISHER_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
ANDROID_PUBLISHER_UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
VALID_PLAY_TRACKS = ("internal", "alpha", "beta", "production")
VALID_PLAY_STATUSES = ("completed", "draft")
PEM_CERT_RE = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----"
)
PACKAGE_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")


def _redact(text, sensitive):
    if not text:
        return ""
    result = text
    for item in sensitive:
        if item:
            result = result.replace(item, "[REDACTED]")
    return result


def command(arguments, *, env=None, redact=(), timeout=120):
    str_args = [str(a) for a in arguments]
    tool_name = Path(str_args[0]).name
    try:
        result = subprocess.run(str_args, capture_output=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{tool_name} timed out after {timeout}s") from None
    except OSError as exc:
        raise RuntimeError(f"{tool_name} could not be started: {_redact(str(exc), redact)}") from None
    if result.returncode:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        stdout = result.stdout.decode("utf-8", errors="replace").strip()
        detail = _redact(stderr or stdout, redact)
        if len(detail) > 500:
            detail = detail[-500:]
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(f"{tool_name} failed; check the Android signing configuration{suffix}")
    return result.stdout


def encode_java_properties(mapping):
    """Serialize key/value pairs in exact java.util.Properties ISO-8859-1 format."""
    lines = []
    for key, value in mapping.items():
        lines.append(f"{_escape_prop(key, is_key=True)}={_escape_prop(value, is_key=False)}")
    return ("\n".join(lines) + "\n").encode("ascii")


def _escape_prop(text, *, is_key):
    out = []
    for index, ch in enumerate(str(text)):
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\f":
            out.append("\\f")
        elif ch == " " and (is_key or index == 0):
            out.append("\\ ")
        elif ch in ("=", ":", "#", "!"):
            out.append("\\" + ch)
        elif 0x20 <= code <= 0x7E:
            out.append(ch)
        else:
            out.append(f"\\u{code:04x}")
    return "".join(out)


def certificate_digest(keystore, alias="androiddebugkey", store_password="android"):
    child_env = os.environ.copy()
    child_env["MICDROP_KEYTOOL_STOREPASS"] = store_password
    certificate = command(
        [
            "keytool",
            "-exportcert",
            "-keystore",
            str(keystore),
            "-alias",
            alias,
            "-storepass:env",
            "MICDROP_KEYTOOL_STOREPASS",
        ],
        env=child_env,
        redact=(store_password,),
    )
    return hashlib.sha256(certificate).hexdigest()


def prepare():
    encoded = "".join(os.environ.get("MICDROP_DEBUG_KEYSTORE_BASE64", "").split())
    directory = Path(tempfile.mkdtemp(prefix="micdrop-debug-signer-", dir=os.environ["RUNNER_TEMP"]))
    directory.chmod(0o700)
    keystore = directory / "debug.keystore"
    try:
        if encoded:
            if len(encoded) > MAX_DEBUG_B64_LEN:
                raise ValueError("Debug keystore secret exceeds the supported size")
            keystore.write_bytes(base64.b64decode(encoded, validate=True))
        else:
            # Compile and exercise signing even without a configured secret,
            # but never publish this disposable certificate's APK for installation.
            command(
                [
                    "keytool",
                    "-genkeypair",
                    "-keystore",
                    str(keystore),
                    "-storetype",
                    "JKS",
                    "-alias",
                    "androiddebugkey",
                    "-storepass",
                    "android",
                    "-keypass",
                    "android",
                    "-keyalg",
                    "RSA",
                    "-keysize",
                    "2048",
                    "-validity",
                    "10000",
                    "-dname",
                    "CN=MicDrop CI Fixture,O=MicDrop,C=US",
                    "-noprompt",
                ]
            )
        keystore.chmod(0o600)
        certificate_digest(keystore)  # Validate password, alias and certificate before Gradle.
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as output:
            output.write(f"MICDROP_DEBUG_KEYSTORE={keystore}\n")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"stable_signer={'true' if encoded else 'false'}\n")
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise
    if not encoded:
        print(
            "::notice::MICDROP_DEBUG_KEYSTORE_BASE64 is not configured. Signing is tested with "
            "a disposable key; app-debug.apk will not be published until the secret is set."
        )


def prepare_release():
    encoded = "".join(os.environ.get("MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64", "").split())
    # Password whitespace is significant to keytool and Gradle; only normalize
    # the base64 transport and alias, never the secret values themselves.
    store_password = os.environ.get("MICDROP_ANDROID_UPLOAD_STORE_PASSWORD", "")
    key_alias = os.environ.get("MICDROP_ANDROID_UPLOAD_KEY_ALIAS", "").strip()
    key_password = os.environ.get("MICDROP_ANDROID_UPLOAD_KEY_PASSWORD", "")

    required = {
        "MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64": bool(encoded),
        "MICDROP_ANDROID_UPLOAD_STORE_PASSWORD": bool(store_password),
        "MICDROP_ANDROID_UPLOAD_KEY_ALIAS": bool(key_alias),
    }
    if any(required.values()) and not all(required.values()):
        missing = ", ".join(name for name, present in required.items() if not present)
        raise ValueError(f"Incomplete Android upload signing configuration; missing: {missing}")
    if key_password and not all(required.values()):
        raise ValueError(
            "MICDROP_ANDROID_UPLOAD_KEY_PASSWORD is set without complete upload keystore secrets"
        )

    configured = all(required.values())
    directory = Path(tempfile.mkdtemp(prefix="micdrop-release-signer-", dir=os.environ["RUNNER_TEMP"]))
    directory.chmod(0o700)
    keystore = directory / "upload.keystore"
    props_path = directory / "signing.properties"
    try:
        if configured:
            if len(encoded) > MAX_UPLOAD_B64_LEN:
                raise ValueError("Upload keystore secret exceeds the supported size")
            try:
                raw_keystore = base64.b64decode(encoded, validate=True)
            except ValueError as exc:
                raise ValueError("MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64 is not valid base64") from exc
            if not raw_keystore:
                raise ValueError("MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64 decoded to empty bytes")
            keystore.write_bytes(raw_keystore)
            effective_key_password = key_password or store_password
        else:
            store_password = secrets.token_urlsafe(24)
            effective_key_password = store_password
            key_alias = "upload"
            child_env = os.environ.copy()
            child_env["MICDROP_KEYTOOL_STOREPASS"] = store_password
            command(
                [
                    "keytool",
                    "-genkeypair",
                    "-keystore",
                    str(keystore),
                    "-storetype",
                    "PKCS12",
                    "-alias",
                    key_alias,
                    "-storepass:env",
                    "MICDROP_KEYTOOL_STOREPASS",
                    "-keyalg",
                    "RSA",
                    "-keysize",
                    "2048",
                    "-validity",
                    "10000",
                    "-dname",
                    "CN=MicDrop CI Upload Fixture,O=MicDrop,C=US",
                    "-noprompt",
                ],
                env=child_env,
                redact=(store_password,),
            )
        keystore.chmod(0o600)
        expected_sha256 = certificate_digest(keystore, alias=key_alias, store_password=store_password)
        props_path.write_bytes(
            encode_java_properties(
                {
                    "storeFile": str(keystore),
                    "storePassword": store_password,
                    "keyAlias": key_alias,
                    "keyPassword": effective_key_password,
                }
            )
        )
        props_path.chmod(0o600)
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as output:
            output.write(f"MICDROP_RELEASE_SIGNING_PROPS={props_path}\n")
            output.write(f"MICDROP_RELEASE_KEYSTORE_SHA256={expected_sha256}\n")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"release_signer={'true' if configured else 'false'}\n")
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise

    if not configured:
        print(
            "::notice::MICDROP_ANDROID_UPLOAD_KEYSTORE_BASE64 is not configured. Release bundle "
            "signing is exercised with a disposable key; app-release.aab will not be retained or uploaded."
        )


def verify(apk, apksigner):
    expected = certificate_digest(Path(os.environ["MICDROP_DEBUG_KEYSTORE"]))
    report = command([apksigner, "verify", "--print-certs", str(apk)]).decode("utf-8")
    signers = re.findall(
        r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$",
        report,
        re.MULTILINE,
    )
    if len(signers) != 1 or signers[0].lower() != expected:
        raise RuntimeError("APK certificate does not match the configured debug keystore")
    print(f"Verified Android development APK certificate SHA-256: {expected}")


def _jar_signer_sha256(archive_path):
    verify_out = command(["jarsigner", "-verify", str(archive_path)]).decode(
        "utf-8", errors="replace"
    )
    if (
        "jar verified." not in verify_out
        or "jar is unsigned" in verify_out
        or "unsigned entries" in verify_out
    ):
        raise RuntimeError("Android App Bundle is unsigned or contains unsigned entries")
    pem_out = command(["keytool", "-printcert", "-jarfile", str(archive_path), "-rfc"]).decode(
        "utf-8", errors="replace"
    )
    match = PEM_CERT_RE.search(pem_out)
    if not match:
        raise RuntimeError("Could not extract signing certificate from Android App Bundle")
    der = base64.b64decode("".join(match.group(1).split()), validate=True)
    return hashlib.sha256(der).hexdigest()


def verify_aab(aab_path, expected_sha256=None):
    aab_path = Path(aab_path)
    if not aab_path.is_file():
        raise ValueError(f"Android App Bundle not found: {aab_path}")
    expected = (expected_sha256 or os.environ.get("MICDROP_RELEASE_KEYSTORE_SHA256", "")).strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Missing or invalid expected SHA-256 digest for release AAB verification")

    with zipfile.ZipFile(aab_path) as bundle:
        names = set(bundle.namelist())
        if "BundleConfig.pb" not in names or "base/manifest/AndroidManifest.xml" not in names:
            raise ValueError("Android App Bundle is missing BundleConfig.pb or base/manifest/AndroidManifest.xml")

        manifest_bytes = bundle.read("base/manifest/AndroidManifest.xml")
        if b"com.maskarauder.micdrop" not in manifest_bytes:
            raise ValueError("Release AAB manifest does not declare com.maskarauder.micdrop")
        if b"com.maskarauder.micdrop.dev" in manifest_bytes:
            raise ValueError("Release AAB manifest leaked debug .dev applicationIdSuffix")
        if b"AdbControlActivity" in manifest_bytes or b"ADB_CONTROL" in manifest_bytes:
            raise ValueError("Release AAB manifest leaked debug-only AdbControlActivity")

        r8_meta_entry = "BUNDLE-METADATA/com.android.tools/r8.json"
        if r8_meta_entry not in names:
            raise ValueError(
                "Release AAB is missing R8 metadata (BUNDLE-METADATA/com.android.tools/r8.json); "
                "ensure isMinifyEnabled = true"
            )
        try:
            r8_meta = json.loads(bundle.read(r8_meta_entry).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise ValueError("Release AAB contains unreadable R8 metadata (r8.json)") from exc
        if not isinstance(r8_meta, dict):
            raise ValueError("Release AAB R8 metadata (r8.json) must be a JSON object")
        r8_options = r8_meta.get("options") or {}
        for flag in ("isObfuscationEnabled", "isOptimizationsEnabled", "isShrinkingEnabled"):
            if r8_options.get(flag) is not True:
                raise ValueError(f"Release AAB R8 metadata reports {flag} is not enabled")
        r8_stats = r8_meta.get("stats") or {}
        for stat_key, label in (
            ("noObfuscationPercentage", "obfuscation"),
            ("noOptimizationPercentage", "optimization"),
            ("noShrinkingPercentage", "shrinking"),
        ):
            unoptimized_pct = r8_stats.get(stat_key)
            if isinstance(unoptimized_pct, bool) or not isinstance(unoptimized_pct, (int, float)):
                raise ValueError(f"Release AAB R8 metadata is missing numeric stats.{stat_key}")
            if unoptimized_pct > 75.0:
                raise ValueError(
                    f"Release AAB DEX {label} coverage ({100.0 - unoptimized_pct:.2f}%) "
                    "is below Google Play's 25% minimum threshold"
                )

        mapping_entry = "BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map"
        if mapping_entry not in names or bundle.getinfo(mapping_entry).file_size == 0:
            raise ValueError(
                "Release AAB is missing non-empty R8 mapping file "
                "(BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map)"
            )

        native_libs = [
            name
            for name in names
            if name.endswith(".so")
            and len(PurePosixPath(name).parts) == 4
            and PurePosixPath(name).parts[0] == "base"
            and PurePosixPath(name).parts[1] == "lib"
        ]
        if not native_libs:
            raise ValueError("Release AAB contains no base/lib/<abi>/*.so native libraries")
        abis = {PurePosixPath(name).parts[2] for name in native_libs}
        if abis != {"arm64-v8a"}:
            raise ValueError(f"Release AAB contains unexpected ABIs: {sorted(abis)}")

    actual = _jar_signer_sha256(aab_path)
    if actual != expected:
        raise RuntimeError(
            f"AAB certificate SHA-256 ({actual}) does not match configured upload keystore ({expected})"
        )
    print(f"Verified Android Play AAB certificate SHA-256: {actual}")


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _mint_service_account_jwt(client_email, private_key_pem, now=None):
    issued_at = int(time.time() if now is None else now)
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode("utf-8"))
    claims = _b64url(
        json.dumps(
            {
                "iss": client_email,
                "scope": ANDROID_PUBLISHER_SCOPE,
                "aud": GOOGLE_OAUTH_TOKEN_URI,
                "iat": issued_at,
                "exp": issued_at + 300,
            },
            separators=(",", ":"),
        ).encode("utf-8")
    )
    signing_input = f"{header}.{claims}".encode("ascii")

    temp_root = os.environ.get("RUNNER_TEMP") or None
    key_dir = Path(tempfile.mkdtemp(prefix="micdrop-play-jwt-", dir=temp_root))
    key_dir.chmod(0o700)
    key_file = key_dir / "service-account.pem"
    try:
        key_file.write_text(private_key_pem, encoding="utf-8")
        key_file.chmod(0o600)
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key_file)],
            input=signing_input,
            capture_output=True,
            timeout=30,
        )
        if proc.returncode != 0:
            raise RuntimeError("openssl failed to sign Google Play service-account JWT")
        signature = _b64url(proc.stdout)
    finally:
        shutil.rmtree(key_dir, ignore_errors=True)
    return f"{header}.{claims}.{signature}"


def _load_play_service_account():
    compact = "".join(os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64", "").split())
    if not compact:
        raise ValueError(
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 is required to upload an AAB to Google Play"
        )
    if len(compact) > MAX_SERVICE_ACCOUNT_B64_LEN:
        raise ValueError("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 exceeds the supported size")
    try:
        raw = base64.b64decode(compact, validate=True)
        payload = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(
            "GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64 is not valid base64-encoded JSON"
        ) from exc

    if not isinstance(payload, dict) or payload.get("type") != "service_account":
        raise ValueError("Google Play credentials JSON must have type='service_account'")
    client_email = str(payload.get("client_email", "")).strip()
    private_key = str(payload.get("private_key", "")).strip()
    token_uri = str(payload.get("token_uri") or GOOGLE_OAUTH_TOKEN_URI).strip()
    if "@" not in client_email or "BEGIN PRIVATE KEY" not in private_key:
        raise ValueError("Google Play service-account JSON is missing client_email or private_key")
    if token_uri != GOOGLE_OAUTH_TOKEN_URI:
        raise ValueError(f"Unexpected Google OAuth token_uri: {token_uri}")
    return client_email, private_key


def _http_json(method, url, *, headers=None, body=None, content_type="application/json", opener=None):
    req_headers = dict(headers or {})
    data = body
    if body is not None and not isinstance(body, (bytes, bytearray)):
        data = json.dumps(body).encode("utf-8")
        req_headers.setdefault("Content-Type", content_type)
    elif body is not None:
        req_headers.setdefault("Content-Type", content_type)
    request = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    open_fn = opener or urllib.request.urlopen
    try:
        with open_fn(request, timeout=300) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace").strip()
        if len(err_body) > 600:
            err_body = err_body[:600]
        raise RuntimeError(f"Google Play API HTTP {exc.code} on {method} {url}: {err_body}") from None


def upload_play(aab_path, package_name, track, status, *, opener=None):
    aab_path = Path(aab_path)
    if not aab_path.is_file():
        raise ValueError(f"Android App Bundle not found: {aab_path}")
    if not PACKAGE_NAME_RE.fullmatch(package_name):
        raise ValueError(f"Invalid Android package name: {package_name}")
    if track not in VALID_PLAY_TRACKS:
        raise ValueError(f"Unsupported Google Play track: {track}")
    if status not in VALID_PLAY_STATUSES:
        raise ValueError(f"Unsupported Google Play release status: {status}")

    client_email, private_key = _load_play_service_account()
    assertion = _mint_service_account_jwt(client_email, private_key)
    form_body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("ascii")
    token_resp = _http_json(
        "POST",
        GOOGLE_OAUTH_TOKEN_URI,
        body=form_body,
        content_type="application/x-www-form-urlencoded",
        opener=opener,
    )
    access_token = str(token_resp.get("access_token", "")).strip()
    if not access_token:
        raise RuntimeError("Google OAuth token response did not contain an access_token")

    auth_headers = {"Authorization": f"Bearer {access_token}"}
    pkg = urllib.parse.quote(package_name, safe="")

    edit = _http_json("POST", f"{ANDROID_PUBLISHER_BASE}/{pkg}/edits", headers=auth_headers, body={}, opener=opener)
    edit_id = urllib.parse.quote(str(edit.get("id", "")).strip(), safe="")
    if not edit_id:
        raise RuntimeError("Google Play edits.insert did not return an edit id")

    bundle_resp = _http_json(
        "POST",
        f"{ANDROID_PUBLISHER_UPLOAD_BASE}/{pkg}/edits/{edit_id}/bundles?uploadType=media",
        headers=auth_headers,
        body=aab_path.read_bytes(),
        content_type="application/octet-stream",
        opener=opener,
    )
    version_code = bundle_resp.get("versionCode")
    if version_code is None:
        raise RuntimeError("Google Play bundles.upload did not return a versionCode")

    track_body = {
        "track": track,
        "releases": [
            {
                "versionCodes": [str(version_code)],
                "status": status,
            }
        ],
    }
    _http_json(
        "PUT",
        f"{ANDROID_PUBLISHER_BASE}/{pkg}/edits/{edit_id}/tracks/{track}",
        headers=auth_headers,
        body=track_body,
        opener=opener,
    )
    _http_json(
        "POST",
        f"{ANDROID_PUBLISHER_BASE}/{pkg}/edits/{edit_id}:commit",
        headers=auth_headers,
        body={},
        opener=opener,
    )
    print(
        f"Uploaded {aab_path.name} (versionCode={version_code}) to Google Play track '{track}' ({status})."
    )
    return int(version_code)


def cleanup():
    runner_temp = os.environ.get("RUNNER_TEMP", "").strip()
    resolved_root = Path(runner_temp).resolve() if runner_temp else None
    for env_var in ("MICDROP_DEBUG_KEYSTORE", "MICDROP_RELEASE_SIGNING_PROPS"):
        raw_path = os.environ.get(env_var, "").strip()
        if not raw_path:
            continue
        target_file = Path(raw_path)
        parent = target_file.resolve().parent if target_file.exists() else target_file.parent.resolve()
        if resolved_root is not None and resolved_root in parent.parents:
            shutil.rmtree(parent, ignore_errors=True)
        else:
            target_file.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("prepare")
    commands.add_parser("prepare-release")
    check = commands.add_parser("verify")
    check.add_argument("apk", type=Path)
    check.add_argument("apksigner")
    check_aab = commands.add_parser("verify-aab")
    check_aab.add_argument("aab", type=Path)
    upload = commands.add_parser("upload-play")
    upload.add_argument("--aab", type=Path, required=True)
    upload.add_argument("--package-name", default="com.maskarauder.micdrop")
    upload.add_argument("--track", choices=VALID_PLAY_TRACKS, required=True)
    upload.add_argument("--status", choices=VALID_PLAY_STATUSES, default="completed")
    commands.add_parser("cleanup")
    arguments = parser.parse_args(argv)

    if arguments.operation == "prepare":
        prepare()
    elif arguments.operation == "prepare-release":
        prepare_release()
    elif arguments.operation == "verify":
        verify(arguments.apk, arguments.apksigner)
    elif arguments.operation == "verify-aab":
        verify_aab(arguments.aab)
    elif arguments.operation == "upload-play":
        upload_play(arguments.aab, arguments.package_name, arguments.track, arguments.status)
    elif arguments.operation == "cleanup":
        cleanup()


if __name__ == "__main__":
    main()
