# SPDX-License-Identifier: MPL-2.0
"""Prepare ephemeral Windows Authenticode cloud signing in CI, sign PE files, verify signatures, and clean up.

Supports Microsoft Azure Artifact Signing (Trusted Signing) via SignTool + Azure.CodeSigning.Dlib with either:
- GitHub Actions OIDC federated credentials (`WorkloadIdentityCredential`, recommended, secretless), or
- Microsoft Entra client secrets (`EnvironmentCredential`, when `AZURE_CLIENT_SECRET` is provided).

Secrets and OIDC tokens are read only from environment variables, validated before tool invocation, never
written into the repository checkout, redacted from any error diagnostics, and removed in an `if: always()`
cleanup step.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
ACCOUNT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{1,61}[A-Za-z0-9]$")
CERT_PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{1,98}[A-Za-z0-9]$")
ENDPOINT_HOST_RE = re.compile(r"^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.codesigning\.azure\.net$")
JWT_RE = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")
DOTNET_RUNTIME_RE = re.compile(r"^Microsoft\.NETCore\.App\s+(\d+)\.\d+", re.MULTILINE)

MAX_CLIENT_SECRET_LEN = 4096
MAX_NUGET_BYTES = 64 * 1024 * 1024
DEFAULT_PUBLISHER = "Noah Seymour"
TIMESTAMP_URL = "http://timestamp.acs.microsoft.com"
OIDC_AUDIENCE = "api://AzureADTokenExchange"

SDK_PACKAGE = {
    "id": "microsoft.windows.sdk.buildtools",
    "version": "10.0.28000.2957",
    "url": (
        "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/"
        "10.0.28000.2957/microsoft.windows.sdk.buildtools.10.0.28000.2957.nupkg"
    ),
    "sha256": "b7163fc6f636172726d0985963e4f7f11c41afe1c7fdfe78f8051877360ed696",
    "bin_prefix": "bin/10.0.28000.0/x64/",
    "extract_dir": "sdk-10.0.28000.2957-x64",
    "required_file": "signtool.exe",
}

DLIB_PACKAGE = {
    "id": "microsoft.artifactsigning.client",
    "version": "1.0.146",
    "url": (
        "https://api.nuget.org/v3-flatcontainer/microsoft.artifactsigning.client/"
        "1.0.146/microsoft.artifactsigning.client.1.0.146.nupkg"
    ),
    "sha256": "7761e5d8f31e54b764da21d33cd8b0a2940e1b05526c7dfcb5e94b0431426f70",
    "bin_prefix": "bin/x64/",
    "extract_dir": "artifact-signing-dlib-1.0.146-x64",
    "required_file": "Azure.CodeSigning.Dlib.dll",
}

ALL_AZURE_CREDENTIALS = (
    "EnvironmentCredential",
    "ManagedIdentityCredential",
    "WorkloadIdentityCredential",
    "SharedTokenCacheCredential",
    "VisualStudioCredential",
    "VisualStudioCodeCredential",
    "AzureCliCredential",
    "AzurePowerShellCredential",
    "AzureDeveloperCliCredential",
    "InteractiveBrowserCredential",
)

REPO_ROOT = Path(__file__).resolve().parents[1]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Unexpected redirect while requesting OIDC token; bearer token was not forwarded")


def _redact(text, sensitive):
    if not text:
        return ""
    result = text
    for item in sensitive:
        if item:
            result = result.replace(item, "[REDACTED]")
    return result


def _tool_output_detail(stdout, stderr, sensitive):
    parts = []
    for output in (stdout, stderr):
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        if output and output.strip():
            parts.append(_redact(output.strip(), sensitive))
    if not parts:
        return ""

    # Keep the exception headline and final context from each stream. Redact before
    # truncation so cutting through a credential cannot leave part of it exposed.
    budget = (32000 - (len(parts) - 1)) // len(parts)
    marker = "\n... [output truncated] ...\n"
    head = (budget - len(marker)) * 3 // 4
    tail = budget - len(marker) - head
    return "\n".join(
        part if len(part) <= budget else part[:head] + marker + part[-tail:]
        for part in parts
    )


def run_tool(arguments, *, redact=(), env=None, timeout=180):
    str_args = [str(a) for a in arguments]
    tool_name = Path(str_args[0]).name
    try:
        proc = subprocess.run(
            str_args,
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        detail = _tool_output_detail(exc.stdout, exc.stderr, redact)
        msg = f"{tool_name} timed out after {timeout}s"
        if detail:
            msg = f"{msg}: {detail}"
        raise RuntimeError(msg) from None
    except OSError as exc:
        detail = _redact(str(exc), redact)
        raise RuntimeError(f"{tool_name} could not be started: {detail}") from None

    if proc.returncode != 0:
        detail = _tool_output_detail(proc.stdout, proc.stderr, redact)
        msg = f"{tool_name} failed (exit {proc.returncode})"
        if detail:
            msg = f"{msg}: {detail}"
        raise RuntimeError(msg)
    return proc


def _clean_env(name):
    return os.environ.get(name, "").strip()


def _validate_endpoint(raw_endpoint):
    endpoint = raw_endpoint.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(endpoint)
    host = (parsed.hostname or "").lower()
    if (
        parsed.scheme != "https"
        or not host
        or parsed.netloc != host
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or not ENDPOINT_HOST_RE.fullmatch(host)
    ):
        raise ValueError(
            "AZURE_SIGNING_ENDPOINT must be a regional HTTPS Artifact Signing URI such as "
            "'https://eus.codesigning.azure.net'"
        )
    return f"https://{host}"


def _validate_publisher(raw_publisher):
    publisher = raw_publisher.strip() if raw_publisher and raw_publisher.strip() else DEFAULT_PUBLISHER
    if len(publisher) > 120 or any(ord(ch) < 32 or ch in {'"', ";", "#"} for ch in publisher):
        raise ValueError(
            "AZURE_SIGNING_PUBLISHER contains unsupported control or Inno Setup preprocessor characters"
        )
    return publisher


def _check_dotnet_runtime():
    proc = run_tool(["dotnet", "--list-runtimes"], timeout=30)
    majors = [int(match) for match in DOTNET_RUNTIME_RE.findall(proc.stdout)]
    if not any(major >= 8 for major in majors):
        raise ValueError(
            "Azure.CodeSigning.Dlib requires the x64 .NET 8.0+ runtime (Microsoft.NETCore.App >= 8.0)"
        )


def _sha256_file(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def _download_verified_nupkg(package, cache_dir):
    cache_dir.mkdir(parents=True, exist_ok=True)
    expected = package["sha256"]
    archive = cache_dir / f"{expected}-{package['id']}-{package['version']}.nupkg"
    if archive.is_file() and _sha256_file(archive) == expected:
        return archive

    parsed = urllib.parse.urlsplit(package["url"])
    if parsed.scheme != "https":
        raise ValueError(f"NuGet package URL must use HTTPS: {package['id']}")

    partial = cache_dir / f"{archive.name}.partial.{os.getpid()}"
    hasher = hashlib.sha256()
    total = 0
    try:
        req = urllib.request.Request(package["url"], headers={"User-Agent": "MicDrop-windows-signing"})
        with urllib.request.urlopen(req, timeout=120) as resp, partial.open("wb") as out:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_NUGET_BYTES:
                    raise ValueError(f"Downloaded NuGet archive exceeds size limit: {package['id']}")
                hasher.update(chunk)
                out.write(chunk)
        actual = hasher.hexdigest()
        if actual != expected:
            raise ValueError(
                f"NuGet package SHA-256 mismatch for {package['id']} {package['version']}: "
                f"expected {expected}, got {actual}"
            )
        os.replace(partial, archive)
    finally:
        partial.unlink(missing_ok=True)
    return archive


def _extract_verified_nupkg(archive, package, tools_root):
    dest_dir = tools_root / package["extract_dir"]
    staging_dir = tools_root / f".staging-{package['extract_dir']}-{os.getpid()}"
    if staging_dir.exists():
        shutil.rmtree(staging_dir)
    staging_dir.mkdir(parents=True, exist_ok=True)
    prefix = package["bin_prefix"]

    try:
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                entry_name = info.filename.replace("\\", "/")
                if entry_name == "LICENSE.md":
                    rel = PurePosixPath("LICENSE.md")
                elif entry_name.startswith(prefix):
                    rel = PurePosixPath(entry_name[len(prefix):])
                else:
                    continue
                if (
                    not str(rel)
                    or str(rel) == "."
                    or rel.is_absolute()
                    or ".." in rel.parts
                    or ":" in str(rel)
                ):
                    raise ValueError(f"Unsafe path inside NuGet package {package['id']}: {info.filename}")
                target = staging_dir / Path(*rel.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)

        required = staging_dir / package["required_file"]
        if not required.is_file():
            raise ValueError(
                f"Verified NuGet package {package['id']} did not contain expected binary {package['required_file']}"
            )
        if dest_dir.exists():
            shutil.rmtree(dest_dir)
        os.replace(staging_dir, dest_dir)
    finally:
        if staging_dir.exists():
            shutil.rmtree(staging_dir, ignore_errors=True)

    return dest_dir / package["required_file"]


def ensure_signing_tools(repo_root=REPO_ROOT):
    deps_root = Path(repo_root) / ".deps"
    cache_dir = deps_root / "cache"
    tools_root = deps_root / "windows-signing"
    tools_root.mkdir(parents=True, exist_ok=True)

    sdk_archive = _download_verified_nupkg(SDK_PACKAGE, cache_dir)
    signtool_path = _extract_verified_nupkg(sdk_archive, SDK_PACKAGE, tools_root)

    dlib_archive = _download_verified_nupkg(DLIB_PACKAGE, cache_dir)
    dlib_path = _extract_verified_nupkg(dlib_archive, DLIB_PACKAGE, tools_root)
    return signtool_path, dlib_path


def _fetch_github_oidc_token(request_url, request_token, token_file):
    parsed = urllib.parse.urlsplit(request_url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("ACTIONS_ID_TOKEN_REQUEST_URL must use HTTPS")

    sep = "&" if parsed.query else "?"
    full_url = f"{request_url}{sep}{urllib.parse.urlencode({'audience': OIDC_AUDIENCE})}"
    req = urllib.request.Request(
        full_url,
        headers={
            "Authorization": f"Bearer {request_token}",
            "Accept": "application/json; api-version=2.0",
            "User-Agent": "MicDrop-windows-signing",
        },
        method="GET",
    )
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=30) as resp:
            raw = resp.read(256 * 1024 + 1)
            if len(raw) > 256 * 1024:
                raise ValueError("GitHub OIDC token response exceeded size limit")
            payload = json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(
            f"GitHub OIDC token request failed with HTTP {exc.code}; "
            "ensure the job declares 'permissions: id-token: write'"
        ) from None
    except urllib.error.URLError as exc:
        reason = _redact(str(exc.reason), (request_token,))
        raise RuntimeError(f"GitHub OIDC token request failed: {reason}") from None

    jwt_value = payload.get("value", "") if isinstance(payload, dict) else ""
    if not isinstance(jwt_value, str) or not JWT_RE.fullmatch(jwt_value.strip()):
        raise ValueError("GitHub OIDC token endpoint did not return a valid JWT")
    jwt_value = jwt_value.strip()
    token_file.write_text(jwt_value, encoding="utf-8")
    try:
        token_file.chmod(0o600)
    except OSError:
        pass
    return jwt_value


def _jwt_expiration_epoch(jwt_token):
    parts = jwt_token.split(".")
    if len(parts) != 3:
        return None
    payload_b64 = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        raw = base64.urlsafe_b64decode(payload_b64.encode("ascii"))
        claims = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(claims, dict):
        return None
    exp = claims.get("exp")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)):
        return None
    return float(exp)


def _make_work_dir():
    runner_temp = os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()
    path = Path(tempfile.mkdtemp(prefix="micdrop-windows-signing-", dir=runner_temp))
    try:
        path.chmod(0o700)
    except OSError:
        pass
    return path


def _write_state_and_github_vars(work_dir, state, *, env_vars=None, outputs=None):
    state_path = work_dir / "state.json"
    state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        state_path.chmod(0o600)
    except OSError:
        pass

    gh_env = os.environ.get("GITHUB_ENV")
    if gh_env:
        with Path(gh_env).open("a", encoding="utf-8") as handle:
            handle.write(f"MICDROP_WINDOWS_SIGNING_STATE={state_path}\n")
            for key, value in (env_vars or {}).items():
                handle.write(f"{key}={value}\n")

    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out and outputs:
        with Path(gh_out).open("a", encoding="utf-8") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")

    return state_path


def _load_state():
    state_file = _clean_env("MICDROP_WINDOWS_SIGNING_STATE")
    if not state_file:
        raise ValueError("MICDROP_WINDOWS_SIGNING_STATE is not set; run 'windows_signing.py prepare' first")
    path = Path(state_file)
    if not path.is_file():
        raise ValueError(f"Windows signing state file is missing: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def prepare(*, repo_root=REPO_ROOT):
    tenant_id = _clean_env("AZURE_TENANT_ID")
    client_id = _clean_env("AZURE_CLIENT_ID")
    client_secret = os.environ.get("AZURE_CLIENT_SECRET", "").strip()
    raw_endpoint = _clean_env("AZURE_SIGNING_ENDPOINT")
    account = _clean_env("AZURE_SIGNING_ACCOUNT")
    cert_profile = _clean_env("AZURE_SIGNING_CERT_PROFILE")
    publisher = _validate_publisher(os.environ.get("AZURE_SIGNING_PUBLISHER", ""))

    core_vars = {
        "AZURE_TENANT_ID": tenant_id,
        "AZURE_CLIENT_ID": client_id,
        "AZURE_SIGNING_ENDPOINT": raw_endpoint,
        "AZURE_SIGNING_ACCOUNT": account,
        "AZURE_SIGNING_CERT_PROFILE": cert_profile,
    }
    present_core = [name for name, val in core_vars.items() if val]

    work_dir = _make_work_dir()
    if not present_core and not client_secret:
        state = {
            "signed": False,
            "work_dir": str(work_dir),
            "publisher": publisher,
        }
        _write_state_and_github_vars(
            work_dir,
            state,
            outputs={"signed": "false"},
        )
        print(
            "::notice::Azure Artifact Signing secrets are not configured in this context; "
            "leaving Windows packages unsigned."
        )
        return state

    try:
        missing = sorted(name for name, val in core_vars.items() if not val)
        if missing:
            raise ValueError(
                f"Incomplete Azure Artifact Signing configuration; missing: {', '.join(missing)}"
            )

        if not UUID_RE.fullmatch(tenant_id):
            raise ValueError("AZURE_TENANT_ID must be a valid Entra directory/tenant UUID")
        if not UUID_RE.fullmatch(client_id):
            raise ValueError("AZURE_CLIENT_ID must be a valid Entra application (client) UUID")
        endpoint = _validate_endpoint(raw_endpoint)
        if not ACCOUNT_NAME_RE.fullmatch(account):
            raise ValueError("AZURE_SIGNING_ACCOUNT has an invalid Azure resource name format")
        if not CERT_PROFILE_NAME_RE.fullmatch(cert_profile):
            raise ValueError("AZURE_SIGNING_CERT_PROFILE has an invalid certificate profile format")

        oidc_url = _clean_env("ACTIONS_ID_TOKEN_REQUEST_URL")
        oidc_req_token = _clean_env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")

        oidc_token_file = None
        client_secret_file = None
        if client_secret:
            if len(client_secret) > MAX_CLIENT_SECRET_LEN or any(ch in client_secret for ch in ("\r", "\n", "\x00")):
                raise ValueError("AZURE_CLIENT_SECRET has an invalid format or length")
            auth_mode = "client_secret"
            allowed_cred = "EnvironmentCredential"
            client_secret_file = work_dir / "client-secret.txt"
            client_secret_file.write_text(client_secret, encoding="utf-8")
            try:
                client_secret_file.chmod(0o600)
            except OSError:
                pass
        elif oidc_url and oidc_req_token:
            auth_mode = "oidc"
            allowed_cred = "WorkloadIdentityCredential"
            oidc_token_file = work_dir / "oidc-token.jwt"
            _fetch_github_oidc_token(oidc_url, oidc_req_token, oidc_token_file)
        else:
            raise ValueError(
                "Windows signing requires either GitHub Actions OIDC ('permissions: id-token: write' with "
                "an Entra federated credential) or AZURE_CLIENT_SECRET"
            )

        _check_dotnet_runtime()
        signtool_path, dlib_path = ensure_signing_tools(repo_root=repo_root)

        correlation_id = "micdrop-local"
        run_id = _clean_env("GITHUB_RUN_ID")
        run_attempt = _clean_env("GITHUB_RUN_ATTEMPT") or "1"
        if run_id:
            correlation_id = f"github:{run_id}:{run_attempt}"

        metadata = {
            "Endpoint": endpoint,
            "CodeSigningAccountName": account,
            "CertificateProfileName": cert_profile,
            "CorrelationId": correlation_id,
            "ExcludeCredentials": [c for c in ALL_AZURE_CREDENTIALS if c != allowed_cred],
        }
        metadata_path = work_dir / "metadata.json"
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        try:
            metadata_path.chmod(0o600)
        except OSError:
            pass

        state = {
            "signed": True,
            "auth_mode": auth_mode,
            "work_dir": str(work_dir),
            "tenant_id": tenant_id,
            "client_id": client_id,
            "endpoint": endpoint,
            "account": account,
            "cert_profile": cert_profile,
            "publisher": publisher,
            "signtool_path": str(signtool_path),
            "dlib_path": str(dlib_path),
            "metadata_path": str(metadata_path),
            "oidc_token_file": str(oidc_token_file) if oidc_token_file else "",
            "client_secret_file": str(client_secret_file) if client_secret_file else "",
        }
        _write_state_and_github_vars(
            work_dir,
            state,
            env_vars={"MICDROP_WINDOWS_PUBLISHER": publisher},
            outputs={"signed": "true", "auth_mode": auth_mode},
        )
        print(
            f"Prepared Windows Authenticode signing via Azure Artifact Signing "
            f"(account={account}, profile={cert_profile}, auth={auth_mode})."
        )
        return state
    except Exception:
        shutil.rmtree(work_dir, ignore_errors=True)
        raise


def _check_target_file(path):
    target = Path(path)
    if target.is_symlink() or not target.is_file():
        raise ValueError(f"Signing target must be an existing regular file: {target}")
    return target


def sign_files(paths, *, retry_delays=(2.0, 5.0)):
    state = _load_state()
    if not state.get("signed"):
        print("Windows Authenticode signing is unconfigured; skipping SignTool.")
        return

    signtool = Path(state["signtool_path"])
    dlib = Path(state["dlib_path"])
    metadata = Path(state["metadata_path"])
    for tool_file in (signtool, dlib, metadata):
        if not tool_file.is_file():
            raise ValueError(f"Required Windows signing file is missing: {tool_file}")

    child_env = os.environ.copy()
    child_env.pop("AZURE_CLIENT_SECRET", None)
    child_env.pop("AZURE_FEDERATED_TOKEN_FILE", None)
    child_env["AZURE_TENANT_ID"] = state["tenant_id"]
    child_env["AZURE_CLIENT_ID"] = state["client_id"]

    sensitive = []
    auth_mode = state["auth_mode"]
    token_file = None
    oidc_url = ""
    oidc_req_token = ""
    if auth_mode == "oidc":
        token_file = Path(state["oidc_token_file"])
        oidc_url = _clean_env("ACTIONS_ID_TOKEN_REQUEST_URL")
        oidc_req_token = _clean_env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
        if oidc_req_token:
            sensitive.append(oidc_req_token)
        if token_file.is_file():
            existing_jwt = token_file.read_text(encoding="utf-8").strip()
            if existing_jwt:
                sensitive.append(existing_jwt)
        elif not (oidc_url and oidc_req_token):
            raise ValueError("OIDC token file is missing and GitHub OIDC request variables are unavailable")
        child_env["AZURE_FEDERATED_TOKEN_FILE"] = str(token_file)
    elif auth_mode == "client_secret":
        secret_file = Path(state["client_secret_file"])
        if not secret_file.is_file():
            raise ValueError("Client secret staging file is missing")
        secret_val = secret_file.read_text(encoding="utf-8")
        if not secret_val:
            raise ValueError("Client secret staging file is empty")
        sensitive.append(secret_val)
        child_env["AZURE_CLIENT_SECRET"] = secret_val
    else:
        raise ValueError(f"Unsupported Windows signing auth_mode: {auth_mode}")

    targets = [_check_target_file(p) for p in paths]
    for target in targets:
        cmd = [
            signtool,
            "sign",
            "/v",
            "/fd",
            "SHA256",
            "/tr",
            TIMESTAMP_URL,
            "/td",
            "SHA256",
            "/dlib",
            dlib,
            "/dmdf",
            metadata,
            target,
        ]
        attempt = 0
        while True:
            if auth_mode == "oidc":
                if oidc_url and oidc_req_token:
                    jwt_val = _fetch_github_oidc_token(oidc_url, oidc_req_token, token_file)
                    if jwt_val not in sensitive:
                        sensitive.append(jwt_val)
                    exp = _jwt_expiration_epoch(jwt_val)
                    if exp is not None and exp <= time.time():
                        raise ValueError("Fetched GitHub OIDC token is already expired")
                elif token_file.is_file():
                    jwt_val = token_file.read_text(encoding="utf-8").strip()
                    if not JWT_RE.fullmatch(jwt_val):
                        raise ValueError("Staged OIDC token file does not contain a valid JWT")
                    if jwt_val not in sensitive:
                        sensitive.append(jwt_val)
                    exp = _jwt_expiration_epoch(jwt_val)
                    if exp is not None and exp <= time.time():
                        raise ValueError(
                            "OIDC federated token has expired and GitHub OIDC request variables are unavailable to renew it"
                        )
                else:
                    raise ValueError("OIDC token file is missing and GitHub OIDC request variables are unavailable")
            try:
                run_tool(cmd, redact=tuple(sensitive), env=child_env, timeout=180)
                break
            except RuntimeError:
                if attempt >= len(retry_delays):
                    raise
                delay = retry_delays[attempt]
                attempt += 1
                if delay > 0:
                    time.sleep(delay)

        # Immediately verify Authenticode chain and RFC 3161 timestamp before the signed file is consumed.
        run_tool([signtool, "verify", "/pa", "/tw", "/v", target], timeout=60)
        print(f"Signed and verified Windows PE binary: {target.name}")


def verify_files(paths, *, require_signed=False):
    state = _load_state()
    if not state.get("signed"):
        if require_signed:
            raise ValueError("Windows Authenticode signing was required, but signing secrets were not configured")
        print("Windows Authenticode signing is unconfigured; skipping signature verification.")
        return

    signtool = Path(state["signtool_path"])
    if not signtool.is_file():
        raise ValueError(f"SignTool binary is missing: {signtool}")

    targets = [_check_target_file(p) for p in paths]
    for target in targets:
        proc = run_tool([signtool, "verify", "/pa", "/tw", "/v", target], timeout=60)
        if "Number of errors: 0" not in proc.stdout and "Successfully verified" not in proc.stdout:
            raise RuntimeError(f"SignTool did not confirm verification for {target.name}")
        print(f"Verified Authenticode signature and timestamp: {target.name}")


def cleanup():
    state_file = _clean_env("MICDROP_WINDOWS_SIGNING_STATE")
    if not state_file:
        return
    path = Path(state_file)
    work_dir = path.parent
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("work_dir"):
                work_dir = Path(data["work_dir"])
        except Exception:
            pass
    if work_dir.exists() and work_dir.name.startswith("micdrop-windows-signing-"):
        for secret_name in ("oidc-token.jwt", "client-secret.txt", "metadata.json", "state.json"):
            candidate = work_dir / secret_name
            if candidate.is_file():
                try:
                    candidate.write_bytes(b"\x00" * min(candidate.stat().st_size, 8192))
                except OSError:
                    pass
                candidate.unlink(missing_ok=True)
        shutil.rmtree(work_dir, ignore_errors=True)
        print("Removed ephemeral Windows signing workspace.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("prepare", help="Validate Azure signing configuration and download pinned SignTool + Dlib")

    sign_parser = sub.add_parser("sign", help="Sign and timestamp one or more Windows PE binaries")
    sign_parser.add_argument("paths", nargs="+", help="PE files (.exe / .dll / uninstaller) to sign")

    verify_parser = sub.add_parser("verify", help="Verify Authenticode signatures and RFC 3161 timestamps")
    verify_parser.add_argument("--require-signed", action="store_true", help="Fail if signing was skipped")
    verify_parser.add_argument("paths", nargs="+", help="PE files to verify")

    sub.add_parser("cleanup", help="Remove ephemeral OIDC tokens, secrets, and signing metadata")

    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            prepare()
        elif args.command == "sign":
            sign_files(args.paths)
        elif args.command == "verify":
            verify_files(args.paths, require_signed=args.require_signed)
        elif args.command == "cleanup":
            cleanup()
    except subprocess.SubprocessError:
        print("::error::Windows signing failed: subprocess error (command details suppressed)", file=sys.stderr)
        raise SystemExit(1) from None
    except (ValueError, RuntimeError, OSError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
