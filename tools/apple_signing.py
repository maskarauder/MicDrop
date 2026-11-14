# SPDX-License-Identifier: MPL-2.0
"""Prepare ephemeral Apple signing/notarization in CI, verify signatures, upload to TestFlight, and clean up.

Secrets are read only from environment variables, validated before tool invocation, never written into
the repository checkout, redacted from any error diagnostics, and removed in an `if: always()` cleanup step.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

MAX_SECRET_B64_LEN = 256 * 1024
TEAM_ID_RE = re.compile(r"^[A-Z0-9]{10}$")
API_KEY_ID_RE = re.compile(r"^[A-Z0-9]{6,20}$")
ISSUER_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
PROFILE_UUID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")
IDENTITY_LINE_RE = re.compile(r'\b([0-9A-F]{40})\s+"([^"]+)"')


def _redact(text, sensitive):
    if not text:
        return ""
    result = text
    for item in sensitive:
        if item:
            result = result.replace(item, "[REDACTED]")
    return result


def _tool_display_name(str_args):
    tool_name = Path(str_args[0]).name
    if tool_name == "xcrun" and len(str_args) > 1:
        return f"xcrun {str_args[1]}"
    return tool_name


def run_tool(arguments, *, redact=(), env=None, timeout=300, accepted_returncodes=(0,)):
    str_args = [str(a) for a in arguments]
    tool_name = _tool_display_name(str_args)
    try:
        proc = subprocess.run(
            str_args,
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode("utf-8", errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        err = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        detail = _redact((err or out).strip(), redact)
        if len(detail) > 2000:
            detail = detail[-2000:]
        msg = f"{tool_name} timed out after {timeout}s"
        if detail:
            msg = f"{msg}: {detail}"
        raise RuntimeError(msg) from None
    except OSError as exc:
        detail = _redact(str(exc), redact)
        raise RuntimeError(f"{tool_name} could not be started: {detail}") from None

    if proc.returncode not in accepted_returncodes:
        detail = _redact((proc.stderr or proc.stdout or "").strip(), redact)
        if len(detail) > 2000:
            detail = detail[-2000:]
        msg = f"{tool_name} failed (exit {proc.returncode})"
        if detail:
            msg = f"{msg}: {detail}"
        raise RuntimeError(msg)
    return proc


def _clean_env(name):
    return os.environ.get(name, "").strip()


def _decode_b64_secret(env_name):
    compact = "".join(os.environ.get(env_name, "").split())
    if not compact:
        return b""
    if len(compact) > MAX_SECRET_B64_LEN:
        raise ValueError(f"{env_name} exceeds the maximum supported base64 length")
    try:
        data = base64.b64decode(compact, validate=True)
    except ValueError as exc:
        raise ValueError(f"{env_name} is not valid base64") from exc
    if not data:
        raise ValueError(f"{env_name} decoded to empty bytes")
    return data


def _validate_team_id(team_id):
    if not TEAM_ID_RE.fullmatch(team_id):
        raise ValueError("APPLE_TEAM_ID must be a 10-character uppercase alphanumeric Apple Team ID")


def _stage_api_key(work_dir):
    """Validate optional App Store Connect API key secrets and write AuthKey_<ID>.p8 if present."""
    key_b64 = "".join(os.environ.get("APPLE_API_PRIVATE_KEY_BASE64", "").split())
    key_id = _clean_env("APPLE_API_KEY_ID")
    issuer_id = _clean_env("APPLE_API_ISSUER_ID")

    present = [
        name
        for name, val in (
            ("APPLE_API_PRIVATE_KEY_BASE64", key_b64),
            ("APPLE_API_KEY_ID", key_id),
            ("APPLE_API_ISSUER_ID", issuer_id),
        )
        if val
    ]
    if not present:
        return None
    if len(present) != 3:
        missing = sorted(
            {"APPLE_API_PRIVATE_KEY_BASE64", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID"} - set(present)
        )
        raise ValueError(f"Incomplete App Store Connect API configuration; missing: {', '.join(missing)}")

    if not API_KEY_ID_RE.fullmatch(key_id):
        raise ValueError("APPLE_API_KEY_ID has an invalid format")
    if not ISSUER_UUID_RE.fullmatch(issuer_id):
        raise ValueError("APPLE_API_ISSUER_ID must be a UUID")

    p8_bytes = _decode_b64_secret("APPLE_API_PRIVATE_KEY_BASE64")
    if b"BEGIN PRIVATE KEY" not in p8_bytes:
        raise ValueError("APPLE_API_PRIVATE_KEY_BASE64 does not decode to an unencrypted PKCS#8 (.p8) key")

    keys_dir = work_dir / "private_keys"
    keys_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    p8_path = keys_dir / f"AuthKey_{key_id}.p8"
    p8_path.write_bytes(p8_bytes)
    p8_path.chmod(0o600)
    return {
        "api_key_id": key_id,
        "api_issuer_id": issuer_id,
        "api_key_path": str(p8_path),
        "private_keys_dir": str(keys_dir),
    }


def _list_user_keychains():
    proc = run_tool(["security", "list-keychains", "-d", "user"])
    paths = re.findall(r'"([^"]+)"', proc.stdout)
    if not paths:
        paths = [line.strip().strip('"') for line in proc.stdout.splitlines() if line.strip()]
    return paths


def _create_ephemeral_keychain(work_dir, p12_bytes, p12_password):
    kc_password = secrets.token_urlsafe(32)
    kc_path = work_dir / "micdrop-signing.keychain-db"
    p12_path = work_dir / "signing-cert.p12"
    redact = (kc_password, p12_password)

    previous_keychains = _list_user_keychains()
    try:
        p12_path.write_bytes(p12_bytes)
        p12_path.chmod(0o600)

        run_tool(["security", "create-keychain", "-p", kc_password, kc_path], redact=redact)
        run_tool(["security", "set-keychain-settings", "-lut", "21600", kc_path], redact=redact)
        run_tool(["security", "unlock-keychain", "-p", kc_password, kc_path], redact=redact)
        run_tool(
            ["security", "list-keychains", "-d", "user", "-s", kc_path, *previous_keychains],
            redact=redact,
        )
        run_tool(
            [
                "security",
                "import",
                p12_path,
                "-k",
                kc_path,
                "-P",
                p12_password,
                "-T",
                "/usr/bin/codesign",
                "-T",
                "/usr/bin/security",
                "-T",
                "/usr/bin/productbuild",
            ],
            redact=redact,
        )
        run_tool(
            [
                "security",
                "set-key-partition-list",
                "-S",
                "apple-tool:,apple:,codesign:",
                "-s",
                "-k",
                kc_password,
                kc_path,
            ],
            redact=redact,
        )
    finally:
        p12_path.unlink(missing_ok=True)

    return kc_path, previous_keychains


def _find_signing_identity(kc_path, *, prefixes, team_id):
    proc = run_tool(["security", "find-identity", "-v", "-p", "codesigning", kc_path])
    matches = []
    for sha1, label in IDENTITY_LINE_RE.findall(proc.stdout):
        if any(label.startswith(prefix) for prefix in prefixes) and f"({team_id})" in label:
            matches.append((sha1, label))
    if not matches:
        all_proc = run_tool(["security", "find-identity", "-p", "codesigning", kc_path])
        hint = ""
        if "CSSMERR_TP_NOT_TRUSTED" in all_proc.stdout:
            hint = " (certificate chain is missing its intermediate Apple CA in the .p12)"
        expected = " or ".join(prefixes)
        raise ValueError(
            f"No valid '{expected}' signing identity for team {team_id} found in imported .p12{hint}"
        )
    return matches[0]


def _write_state_and_github_vars(work_dir, state, *, env_vars=None, outputs=None):
    state_path = work_dir / "state.json"
    state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    state_path.chmod(0o600)

    gh_env = os.environ.get("GITHUB_ENV")
    if gh_env:
        with Path(gh_env).open("a", encoding="utf-8") as handle:
            handle.write(f"MICDROP_APPLE_SIGNING_STATE={state_path}\n")
            for key, value in (env_vars or {}).items():
                handle.write(f"{key}={value}\n")

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out and outputs:
        with Path(gh_out).open("a", encoding="utf-8") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")

    return state_path


def _load_state():
    state_file = os.environ.get("MICDROP_APPLE_SIGNING_STATE", "").strip()
    if not state_file:
        raise ValueError("MICDROP_APPLE_SIGNING_STATE is not set; run prepare-macos or prepare-ios first")
    path = Path(state_file)
    if not path.is_file():
        raise ValueError(f"Apple signing state file is missing: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def _make_work_dir():
    runner_temp = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
    path = Path(tempfile.mkdtemp(prefix="micdrop-apple-signing-", dir=runner_temp))
    path.chmod(0o700)
    return path


def _cleanup_state_dict(state):
    prev_kcs = state.get("previous_keychains")
    if isinstance(prev_kcs, list) and prev_kcs:
        subprocess.run(
            ["security", "list-keychains", "-d", "user", "-s", *prev_kcs],
            capture_output=True,
            text=True,
        )
    kc_path = state.get("keychain_path")
    if kc_path:
        subprocess.run(["security", "delete-keychain", str(kc_path)], capture_output=True, text=True)
    for prof in state.get("installed_profiles", []):
        Path(prof).unlink(missing_ok=True)
    work_dir = state.get("work_dir")
    if work_dir:
        shutil.rmtree(work_dir, ignore_errors=True)


def prepare_macos():
    team_id = _clean_env("APPLE_TEAM_ID")
    p12_b64 = "".join(os.environ.get("APPLE_DEV_ID_P12_BASE64", "").split())
    p12_pw = os.environ.get("APPLE_DEV_ID_P12_PASSWORD", "")

    work_dir = _make_work_dir()
    state = {"mode": "macos", "work_dir": str(work_dir), "signed": False, "notarized": False}
    try:
        platform_vars = [
            name
            for name, val in (
                ("APPLE_DEV_ID_P12_BASE64", p12_b64),
                ("APPLE_DEV_ID_P12_PASSWORD", p12_pw),
            )
            if val
        ]
        if not platform_vars:
            _write_state_and_github_vars(
                work_dir,
                state,
                outputs={"signed": "false", "notarized": "false"},
            )
            print(
                "::notice::APPLE_DEV_ID_P12_BASE64 is not configured in this context; "
                "using ad-hoc macOS code signing without notarization."
            )
            return

        sign_vars = [*platform_vars, *(("APPLE_TEAM_ID",) if team_id else ())]
        if len(sign_vars) != 3:
            missing = sorted(
                {"APPLE_TEAM_ID", "APPLE_DEV_ID_P12_BASE64", "APPLE_DEV_ID_P12_PASSWORD"} - set(sign_vars)
            )
            raise ValueError(f"Incomplete macOS Developer ID configuration; missing: {', '.join(missing)}")

        _validate_team_id(team_id)
        p12_bytes = _decode_b64_secret("APPLE_DEV_ID_P12_BASE64")
        api_info = _stage_api_key(work_dir)

        kc_path, prev_kcs = _create_ephemeral_keychain(work_dir, p12_bytes, p12_pw)
        state["keychain_path"] = str(kc_path)
        state["previous_keychains"] = prev_kcs

        cert_sha1, cert_label = _find_signing_identity(
            kc_path, prefixes=("Developer ID Application:",), team_id=team_id
        )
        state.update(
            {
                "signed": True,
                "team_id": team_id,
                "cert_sha1": cert_sha1,
                "cert_label": cert_label,
                "notarized": api_info is not None,
            }
        )
        if api_info:
            state.update(api_info)

        _write_state_and_github_vars(
            work_dir,
            state,
            outputs={
                "signed": "true",
                "notarized": "true" if api_info else "false",
            },
        )
        print(f"Prepared macOS Developer ID signing ({cert_label}, SHA-1 {cert_sha1})")
        if not api_info:
            print("::notice::App Store Connect API secrets are not set; skipping Apple notarization.")
    except Exception:
        _cleanup_state_dict(state)
        raise


def sign_macos(paths):
    state = _load_state()
    for raw in paths:
        target = Path(raw)
        if not target.exists():
            raise FileNotFoundError(f"Cannot sign missing path: {target}")
        if state.get("signed"):
            run_tool(
                [
                    "codesign",
                    "--force",
                    "--options",
                    "runtime",
                    "--timestamp",
                    "--keychain",
                    state["keychain_path"],
                    "--sign",
                    state["cert_sha1"],
                    target,
                ]
            )
            print(f"Signed {target} with Developer ID ({state['cert_sha1'][:12]}...)")
        else:
            run_tool(["codesign", "--force", "--sign", "-", target])
            print(f"Ad-hoc signed {target}")


def notarize_macos(target, *, staple=False):
    state = _load_state()
    target = Path(target)
    if not target.exists():
        raise FileNotFoundError(f"Cannot notarize missing path: {target}")
    if not state.get("notarized"):
        print(f"Notarization not configured; skipping notarization for {target}")
        return

    credentials = [
        "--key", state["api_key_path"],
        "--key-id", state["api_key_id"],
        "--issuer", state["api_issuer_id"],
    ]
    sensitive = (
        Path(state["api_key_path"]).read_text(encoding="utf-8").strip(),
        _clean_env("APPLE_API_PRIVATE_KEY_BASE64"),
    )
    evidence_root = _clean_env("MICDROP_NOTARIZATION_EVIDENCE_DIR")
    evidence_dir = Path(evidence_root) / target.name if evidence_root else None
    receipt = {"target": target.name, "id": "", "status": "Upload unconfirmed", "sha256": ""}

    def record_status(status):
        receipt["status"] = status
        if evidence_dir:
            receipt_temp = evidence_dir / "submission.json.tmp"
            receipt_temp.write_text(
                json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
            )
            receipt_temp.replace(evidence_dir / "submission.json")

    temp_zip_dir = Path(tempfile.mkdtemp(prefix="micdrop-notarize-", dir=state["work_dir"]))
    try:
        if target.is_file() and target.suffix == ".zip":
            submit_zip = target
        else:
            submit_zip = temp_zip_dir / "notarize-upload.zip"
            run_tool(["ditto", "-c", "-k", "--keepParent", target, submit_zip])

        if evidence_dir:
            evidence_dir.mkdir(parents=True, exist_ok=True)
            # Preserve only the signed upload and an allowlisted receipt, never
            # signing state or credentials. Save before waiting so a cancelled
            # runner can retain the same bytes without creating a new submission.
            retained_zip = evidence_dir / "upload.zip"
            shutil.copyfile(submit_zip, retained_zip)
            digest = hashlib.sha256()
            with retained_zip.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            receipt["sha256"] = digest.hexdigest()
            record_status("Upload unconfirmed")

        proc = run_tool(
            [
                "xcrun",
                "notarytool",
                "submit",
                submit_zip,
                *credentials,
                "--output-format",
                "json",
            ],
            redact=sensitive,
            timeout=600,
        )
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("xcrun notarytool submit returned unreadable JSON") from exc

        sub_id = payload.get("id", "") if isinstance(payload, dict) else ""
        if not isinstance(sub_id, str) or not ISSUER_UUID_RE.fullmatch(sub_id):
            raise RuntimeError("xcrun notarytool submit returned no valid submission UUID")
        receipt["id"] = sub_id
        record_status("Uploaded")
        # A wait timeout does not cancel Apple's processing. Keep the upload's ID
        # visible immediately, and wait on that same submission without reuploading.
        print(f"Apple notarization submission {sub_id} for {target.name}: uploaded; waiting up to 60m", flush=True)
        try:
            proc = run_tool(
                [
                    "xcrun", "notarytool", "wait", sub_id, *credentials,
                    "--timeout", "60m", "--output-format", "json",
                ],
                redact=sensitive,
                timeout=3700,
                accepted_returncodes=(0, 124),
            )
        except RuntimeError as exc:
            record_status("Result unconfirmed")
            raise RuntimeError(
                f"Apple notarization result unconfirmed for {target.name} (id={sub_id}); "
                f"check this submission before retrying: {exc}"
            ) from None
        if proc.returncode == 124:
            record_status("In Progress")
            raise RuntimeError(
                f"Apple notarization still pending for {target.name} after waiting 60m (id={sub_id}); "
                "the wait timed out, not the submission. Check this submission before retrying."
            )
        record_status("Result unconfirmed")
        try:
            payload = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"xcrun notarytool wait returned unreadable JSON (id={sub_id})") from exc
        status = payload.get("status", "") if isinstance(payload, dict) else ""
        if isinstance(payload, dict) and payload.get("id", sub_id) != sub_id:
            raise RuntimeError(f"xcrun notarytool wait returned a different submission ID (expected {sub_id})")
        status = _redact(str(status), sensitive)
        record_status(status if status in ("Accepted", "Invalid", "Rejected", "In Progress") else "Result unconfirmed")
        print(f"Apple notarization submission {sub_id} for {target.name}: status={status}", flush=True)
        if status == "In Progress":
            raise RuntimeError(
                f"Apple notarization still pending for {target.name} (id={sub_id}); "
                "check this submission before retrying."
            )
        if status not in ("Accepted", "Invalid", "Rejected"):
            raise RuntimeError(f"Apple notarization returned an unknown status for {target.name} (id={sub_id})")
        if status != "Accepted":
            log_text = ""
            if sub_id:
                try:
                    log_proc = subprocess.run(
                        [
                            "xcrun",
                            "notarytool",
                            "log",
                            sub_id,
                            *credentials,
                        ],
                        capture_output=True,
                        text=True,
                        timeout=120,
                    )
                    log_text = _redact((log_proc.stdout or log_proc.stderr or "").strip(), sensitive)
                except (subprocess.TimeoutExpired, OSError):
                    log_text = "(timed out or failed retrieving notarytool log)"
            raise RuntimeError(
                f"Apple notarization rejected {target.name} (status={status!r}, id={sub_id}):\n{log_text}"
            )
    finally:
        shutil.rmtree(temp_zip_dir, ignore_errors=True)

    if staple:
        run_tool(["xcrun", "stapler", "staple", target])
        run_tool(["xcrun", "stapler", "validate", target])
        print(f"Stapled and validated notarization ticket on {target}")


def _verify_developer_id_metadata(target, expected_team_id):
    proc = run_tool(["codesign", "-dv", "--verbose=4", target])
    details = (proc.stderr or "") + "\n" + (proc.stdout or "")
    if "Authority=Developer ID Application:" not in details:
        raise RuntimeError(f"{target}: missing Developer ID Application authority")
    if f"TeamIdentifier={expected_team_id}" not in details:
        raise RuntimeError(f"{target}: TeamIdentifier does not match {expected_team_id}")
    if "(runtime)" not in details:
        raise RuntimeError(f"{target}: Hardened Runtime flag is not enabled")
    if "Timestamp=" not in details:
        raise RuntimeError(f"{target}: secure timestamp is missing")


def verify_macos_app(app_path):
    state = _load_state()
    app_path = Path(app_path)
    run_tool(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app_path])
    if state.get("signed"):
        _verify_developer_id_metadata(
            app_path / "Contents" / "Frameworks" / "libmicdrop_rtc.dylib", state["team_id"]
        )
        _verify_developer_id_metadata(app_path, state["team_id"])
    if state.get("notarized"):
        run_tool(["xcrun", "stapler", "validate", app_path])
        run_tool(["spctl", "--assess", "--type", "execute", "--verbose=4", app_path])
        print(f"Verified Developer ID signature, stapled ticket, and Gatekeeper assessment for {app_path}")
    elif state.get("signed"):
        print(f"Verified Developer ID signature for {app_path}")
    else:
        print(f"Verified ad-hoc signature for {app_path}")


def verify_macos_binaries(paths):
    state = _load_state()
    for raw in paths:
        target = Path(raw)
        run_tool(["codesign", "--verify", "--strict", "--verbose=2", target])
        if state.get("signed"):
            _verify_developer_id_metadata(target, state["team_id"])
    mode = "Developer ID" if state.get("signed") else "ad-hoc"
    print(f"Verified {mode} signatures for {', '.join(str(p) for p in paths)}")


def prepare_ios(bundle_id):
    team_id = _clean_env("APPLE_TEAM_ID")
    p12_b64 = "".join(os.environ.get("APPLE_DIST_P12_BASE64", "").split())
    p12_pw = os.environ.get("APPLE_DIST_P12_PASSWORD", "")
    prof_b64 = "".join(os.environ.get("APPLE_IOS_PROVISION_PROFILE_BASE64", "").split())

    work_dir = _make_work_dir()
    state = {
        "mode": "ios",
        "work_dir": str(work_dir),
        "bundle_id": bundle_id,
        "signed": False,
        "can_upload_testflight": False,
        "installed_profiles": [],
    }
    try:
        platform_vars = [
            name
            for name, val in (
                ("APPLE_DIST_P12_BASE64", p12_b64),
                ("APPLE_DIST_P12_PASSWORD", p12_pw),
                ("APPLE_IOS_PROVISION_PROFILE_BASE64", prof_b64),
            )
            if val
        ]
        if not platform_vars:
            _write_state_and_github_vars(
                work_dir,
                state,
                outputs={"signed": "false", "can_upload_testflight": "false"},
            )
            print(
                "::notice::APPLE_DIST_P12_BASE64 / APPLE_IOS_PROVISION_PROFILE_BASE64 are not configured "
                "in this context; skipping signed App Store archive."
            )
            return

        sign_vars = [*platform_vars, *(("APPLE_TEAM_ID",) if team_id else ())]
        if len(sign_vars) != 4:
            missing = sorted(
                {
                    "APPLE_TEAM_ID",
                    "APPLE_DIST_P12_BASE64",
                    "APPLE_DIST_P12_PASSWORD",
                    "APPLE_IOS_PROVISION_PROFILE_BASE64",
                }
                - set(sign_vars)
            )
            raise ValueError(f"Incomplete iOS signing configuration; missing: {', '.join(missing)}")

        _validate_team_id(team_id)
        p12_bytes = _decode_b64_secret("APPLE_DIST_P12_BASE64")
        prof_bytes = _decode_b64_secret("APPLE_IOS_PROVISION_PROFILE_BASE64")
        api_info = _stage_api_key(work_dir)

        kc_path, prev_kcs = _create_ephemeral_keychain(work_dir, p12_bytes, p12_pw)
        state["keychain_path"] = str(kc_path)
        state["previous_keychains"] = prev_kcs

        cert_sha1, cert_label = _find_signing_identity(
            kc_path,
            prefixes=("Apple Distribution:", "iPhone Distribution:"),
            team_id=team_id,
        )

        raw_prof_path = work_dir / "input.mobileprovision"
        try:
            raw_prof_path.write_bytes(prof_bytes)
            raw_prof_path.chmod(0o600)
            cms_proc = run_tool(["security", "cms", "-D", "-i", raw_prof_path])
            prof_plist = plistlib.loads(cms_proc.stdout.encode("utf-8"))
        finally:
            raw_prof_path.unlink(missing_ok=True)

        prof_uuid = prof_plist.get("UUID", "")
        prof_name = prof_plist.get("Name", "")
        prof_teams = prof_plist.get("TeamIdentifier", [])
        raw_prefixes = prof_plist.get("ApplicationIdentifierPrefix")
        entitlements = prof_plist.get("Entitlements", {})
        if not isinstance(entitlements, dict):
            raise ValueError("Provisioning profile Entitlements is invalid")
        app_identifier = entitlements.get("application-identifier", "")
        ent_team = entitlements.get("com.apple.developer.team-identifier")

        if not isinstance(prof_uuid, str) or not PROFILE_UUID_RE.fullmatch(prof_uuid):
            raise ValueError("Provisioning profile has an invalid UUID")
        if not isinstance(prof_name, str) or not prof_name.strip():
            raise ValueError("Provisioning profile is missing Name")
        if not isinstance(prof_teams, list) or team_id not in prof_teams:
            raise ValueError(f"Provisioning profile TeamIdentifier does not match {team_id}")
        if ent_team is not None and ent_team != team_id:
            raise ValueError(
                f"Provisioning profile com.apple.developer.team-identifier is {ent_team!r}; expected {team_id!r}"
            )
        if raw_prefixes is not None:
            if (
                not isinstance(raw_prefixes, list)
                or not raw_prefixes
                or any(not isinstance(p, str) or not TEAM_ID_RE.fullmatch(p) for p in raw_prefixes)
            ):
                raise ValueError("Provisioning profile has an invalid ApplicationIdentifierPrefix")
            allowed_prefixes = list(dict.fromkeys(raw_prefixes))
        else:
            allowed_prefixes = [team_id]

        allowed_app_ids = [f"{prefix}.{bundle_id}" for prefix in allowed_prefixes]
        if not isinstance(app_identifier, str) or app_identifier not in allowed_app_ids:
            expected_desc = " or ".join(repr(item) for item in allowed_app_ids)
            raise ValueError(
                f"Provisioning profile application-identifier is {app_identifier!r}; expected {expected_desc}"
            )
        if entitlements.get("get-task-allow") is True:
            raise ValueError(
                "Provisioning profile has get-task-allow=true (Development); "
                "use an App Store Connect distribution profile"
            )

        exp = prof_plist.get("ExpirationDate")
        if isinstance(exp, datetime):
            exp_utc = exp if exp.tzinfo is not None else exp.replace(tzinfo=timezone.utc)
            if exp_utc <= datetime.now(timezone.utc):
                raise ValueError(f"Provisioning profile {prof_name!r} ({prof_uuid}) has expired")

        dev_certs = prof_plist.get("DeveloperCertificates", [])
        prof_cert_sha1s = {
            hashlib.sha1(cert).hexdigest().upper()
            for cert in dev_certs
            if isinstance(cert, bytes)
        }
        if cert_sha1 not in prof_cert_sha1s:
            raise ValueError(
                f"Imported Apple Distribution certificate ({cert_sha1}) is not included in "
                f"provisioning profile {prof_name!r} ({prof_uuid})"
            )

        home = Path.home()
        profile_dirs = (
            home / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles",
            home / "Library" / "MobileDevice" / "Provisioning Profiles",
        )
        for folder in profile_dirs:
            folder.mkdir(parents=True, exist_ok=True)
            dest = folder / f"{prof_uuid}.mobileprovision"
            dest.write_bytes(prof_bytes)
            dest.chmod(0o600)
            state["installed_profiles"].append(str(dest))

        export_options = {
            "destination": "export",
            "manageAppVersionAndBuildNumber": False,
            "method": "app-store-connect",
            "provisioningProfiles": {bundle_id: prof_uuid},
            "signingCertificate": cert_sha1,
            "signingStyle": "manual",
            "stripSwiftSymbols": True,
            "teamID": team_id,
            "uploadSymbols": True,
        }
        export_plist_path = work_dir / "ExportOptions.plist"
        export_plist_path.write_bytes(plistlib.dumps(export_options, fmt=plistlib.FMT_XML, sort_keys=True))
        export_plist_path.chmod(0o600)

        state.update(
            {
                "signed": True,
                "team_id": team_id,
                "cert_sha1": cert_sha1,
                "cert_label": cert_label,
                "profile_uuid": prof_uuid,
                "profile_name": prof_name,
                "export_options_plist": str(export_plist_path),
                "can_upload_testflight": api_info is not None,
            }
        )
        if api_info:
            state.update(api_info)

        _write_state_and_github_vars(
            work_dir,
            state,
            env_vars={
                "MICDROP_APPLE_KEYCHAIN": str(kc_path),
                "MICDROP_IOS_TEAM_ID": team_id,
                "MICDROP_IOS_SIGN_IDENTITY": cert_sha1,
                "MICDROP_IOS_PROFILE_SPECIFIER": prof_uuid,
                "MICDROP_IOS_EXPORT_OPTIONS": str(export_plist_path),
            },
            outputs={
                "signed": "true",
                "can_upload_testflight": "true" if api_info else "false",
            },
        )
        print(
            f"Prepared iOS App Store signing ({cert_label}, profile {prof_name!r} [{prof_uuid}])"
        )
    except Exception:
        _cleanup_state_dict(state)
        raise


def upload_testflight(ipa_path):
    state = _load_state()
    ipa_path = Path(ipa_path)
    if not ipa_path.is_file():
        raise FileNotFoundError(f"Signed IPA is missing: {ipa_path}")
    if not state.get("can_upload_testflight"):
        raise ValueError(
            "TestFlight upload requires APPLE_API_PRIVATE_KEY_BASE64, APPLE_API_KEY_ID, and APPLE_API_ISSUER_ID"
        )

    child_env = dict(os.environ)
    child_env["API_PRIVATE_KEYS_DIR"] = state["private_keys_dir"]

    for action in ("--validate-app", "--upload-app"):
        proc = run_tool(
            [
                "xcrun",
                "altool",
                action,
                "-f",
                ipa_path,
                "--type",
                "ios",
                "--apiKey",
                state["api_key_id"],
                "--apiIssuer",
                state["api_issuer_id"],
                "--output-format",
                "json",
            ],
            env=child_env,
            timeout=900,
        )
        if proc.stdout.strip():
            try:
                report = json.loads(proc.stdout)
                errors = report.get("product-errors")
                if errors:
                    raise RuntimeError(f"xcrun altool {action} reported product-errors: {errors}")
            except json.JSONDecodeError:
                pass
        print(f"Completed xcrun altool {action} for {ipa_path.name}")


def cleanup():
    state_file = os.environ.get("MICDROP_APPLE_SIGNING_STATE", "").strip()
    if not state_file:
        return
    path = Path(state_file)
    if not path.is_file():
        return
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        path.unlink(missing_ok=True)
        return
    _cleanup_state_dict(state)
    print("Removed ephemeral Apple signing keychain, profiles, and temporary keys.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("prepare-macos", help="Import macOS Developer ID cert and optional notarization key")

    sign_cmd = sub.add_parser("sign-macos", help="Sign Mach-O binaries or MicDrop.app")
    sign_cmd.add_argument("paths", nargs="+", type=Path)

    notarize_cmd = sub.add_parser("notarize-macos", help="Submit zip/app/dir to Apple notarytool")
    notarize_cmd.add_argument("target", type=Path)
    notarize_cmd.add_argument("--staple", action="store_true")

    verify_app_cmd = sub.add_parser("verify-macos-app", help="Verify MicDrop.app signature and Gatekeeper")
    verify_app_cmd.add_argument("app", type=Path)

    verify_bin_cmd = sub.add_parser("verify-macos-binaries", help="Verify standalone Mach-O signatures")
    verify_bin_cmd.add_argument("paths", nargs="+", type=Path)

    prep_ios_cmd = sub.add_parser("prepare-ios", help="Import iOS Apple Distribution cert and profile")
    prep_ios_cmd.add_argument("--bundle-id", required=True)

    tf_cmd = sub.add_parser("upload-testflight", help="Validate and upload signed IPA to TestFlight")
    tf_cmd.add_argument("ipa", type=Path)

    sub.add_parser("cleanup", help="Delete ephemeral keychain, installed profiles, and temporary files")

    args = parser.parse_args(argv)
    try:
        if args.command == "prepare-macos":
            prepare_macos()
        elif args.command == "sign-macos":
            sign_macos(args.paths)
        elif args.command == "notarize-macos":
            notarize_macos(args.target, staple=args.staple)
        elif args.command == "verify-macos-app":
            verify_macos_app(args.app)
        elif args.command == "verify-macos-binaries":
            verify_macos_binaries(args.paths)
        elif args.command == "prepare-ios":
            prepare_ios(args.bundle_id)
        elif args.command == "upload-testflight":
            upload_testflight(args.ipa)
        elif args.command == "cleanup":
            cleanup()
    except subprocess.SubprocessError:
        sys.stderr.write("Apple signing failed: subprocess error (command details suppressed)\n")
        raise SystemExit(1) from None
    except (ValueError, OSError, RuntimeError) as exc:
        sys.stderr.write(f"Apple signing failed: {exc}\n")
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
