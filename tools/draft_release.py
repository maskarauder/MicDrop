"""Stage verified runner artifacts and assemble an unpublished development prerelease.

No command publishes a release, replaces an asset, or deletes a release/tag.
The upload path uses GitHub Releases directly, not Actions artifact storage.
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
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from check_ios_bundle import check_ipa
from ios_version import bundle_versions
from macos_app_bundle import DEFAULT_BUNDLE_ID as MACOS_BUNDLE_ID, DEFAULT_MIN_MACOS, check_app_zip
from package_unix_host import PLATFORMS as UNIX_HOST_PLATFORMS, check_host_tarball
from release_version import ROOT, VERSION_PATH, parse, read
from store_artifact import KIND, anchor_nonlink, reject_links
from windows_payload import PORTABLE, INSTALLER_ONLY

SHA = r"[0-9a-f]{40}"
DIGEST = r"[0-9a-f]{64}"
IOS_BUNDLE_ID = "com.maskarauder.micdrop"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def retained(root, name, run_id, attempt, sha):
    root_dir, root_parent = anchor_nonlink(root)
    directory = root_dir / name / f"{run_id}-{attempt}"
    reject_links(directory / "manifest.json", stop=root_parent)
    metadata = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    expected = {"kind": KIND, "name": name, "run_id": str(run_id), "attempt": str(attempt), "sha": sha}
    if any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError(f"Retained {name} does not match the selected build/attempt/commit")
    files = {}
    for entry in metadata["files"]:
        relative = PurePosixPath(entry["path"])
        if (relative.is_absolute() or ".." in relative.parts or "\\" in str(relative)
                or ":" in str(relative) or str(relative) in ("", ".")
                or str(relative).casefold() in {p.casefold() for p in files}):
            raise ValueError("Unsafe or duplicate retained file path")
        path = directory / "files" / relative
        reject_links(path, stop=root_parent)
        if not path.is_file() or path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
            raise ValueError(f"Retained artifact checksum mismatch: {name}/{relative}")
        files[str(relative)] = path
    if not files:
        raise ValueError(f"Empty retained artifact: {name}")
    return files


def run_command(arguments):
    result = subprocess.run([str(a) for a in arguments], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f"Package verification failed: {Path(arguments[0]).name}")
    return result.stdout


def _extract_verified_host_tarball(tar_path, destination):
    with tarfile.open(tar_path, mode="r:gz") as archive:
        for member in archive.getmembers():
            target = destination / member.name.rstrip("/")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                if os.name != "nt":
                    os.chmod(target, member.mode & 0o777)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(member)
                with target.open("wb") as out:
                    if stream is not None:
                        shutil.copyfileobj(stream, out)
                if os.name != "nt":
                    os.chmod(target, member.mode & 0o777)


def _extract_verified_app_zip(zip_path, destination):
    with zipfile.ZipFile(zip_path) as archive:
        for item in archive.infolist():
            target = destination / item.filename.rstrip("/")
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                if os.name != "nt":
                    os.chmod(target, 0o755)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as src, target.open("wb") as out:
                    shutil.copyfileobj(src, out)
                if os.name != "nt":
                    perms = (item.external_attr >> 16) & 0o777
                    os.chmod(target, perms if perms else 0o644)


def _inspect_windows_authenticode(targets, command):
    quoted = ", ".join("'" + str(Path(p)).replace("'", "''") + "'" for p in targets)
    ps_script = (
        "$ErrorActionPreference = 'Stop'; "
        f"$paths = @({quoted}); "
        "$out = foreach ($p in $paths) { "
        "$sig = Get-AuthenticodeSignature -LiteralPath $p; "
        "$cert = $sig.SignerCertificate; "
        "$ts = $sig.TimeStamperCertificate; "
        "[ordered]@{ "
        "file = [IO.Path]::GetFileName($p); "
        "status = [string]$sig.Status; "
        "status_message = [string]$sig.StatusMessage; "
        "subject = if ($null -ne $cert) { [string]$cert.Subject } else { '' }; "
        "issuer = if ($null -ne $cert) { [string]$cert.Issuer } else { '' }; "
        "sha256 = if ($null -ne $cert) { $cert.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant() } else { '' }; "
        "timestamped = ($null -ne $ts) "
        "} }; "
        "ConvertTo-Json -InputObject @($out) -Compress"
    )
    raw = command(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", ps_script])
    records = json.loads(raw)
    if isinstance(records, dict):
        records = [records]
    if not isinstance(records, list) or len(records) != len(targets):
        raise ValueError("Unexpected Authenticode inspection output for Windows packages")
    statuses = [rec.get("status") for rec in records]
    if all(status == "NotSigned" for status in statuses):
        return {"signing": "unsigned Windows development packages"}
    if any(status == "NotSigned" for status in statuses):
        raise ValueError("Inconsistent Windows Authenticode signing state across setup and runtime binaries")
    subjects = set()
    issuers = set()
    for rec in records:
        if rec.get("status") != "Valid":
            raise ValueError(
                f"Invalid Windows Authenticode signature on {rec.get('file')}: "
                f"{rec.get('status')} ({rec.get('status_message')})"
            )
        if rec.get("timestamped") is not True:
            raise ValueError(
                f"Windows Authenticode signature on {rec.get('file')} is missing an RFC 3161 timestamp"
            )
        cert_sha = rec.get("sha256", "")
        subject = rec.get("subject", "").strip()
        issuer = rec.get("issuer", "").strip()
        if not re.fullmatch(DIGEST, cert_sha) or not subject:
            raise ValueError(f"Missing signer certificate metadata on {rec.get('file')}")
        subjects.add(subject)
        issuers.add(issuer)
    if len(subjects) != 1:
        raise ValueError("Mismatched Windows Authenticode signer subjects across Windows packages")
    return {
        "signing": "Authenticode-signed and timestamped Windows x64 installer and portable payload",
        "signer_subject": next(iter(subjects)),
        "signer_issuer": next(iter(issuers)),
        "certificate_sha256": records[-1]["sha256"],
    }


def stage(platform, root, output, run_id, attempt, sha, identity, command=run_command, *, ios_ipa=None):
    if not re.fullmatch(SHA, sha) or not str(run_id).isdecimal() or not str(attempt).isdecimal():
        raise ValueError("Invalid build identity")
    if ios_ipa is not None and platform != "ios":
        raise ValueError("An explicit IPA is only supported for ios")
    output, output_parent = anchor_nonlink(output)
    reject_links(output, stop=output_parent)
    output.mkdir(parents=True, exist_ok=False)
    prefix = "MicDrop-" + identity["version"]
    packages = []
    info = {"schema": 1, **identity, "source_sha": sha, "build_run_id": str(run_id), "build_attempt": str(attempt)}
    if platform == "windows":
        host = retained(root, "windows-x64-harness", run_id, attempt, sha)
        installer = retained(root, "windows-x64-installer", run_id, attempt, sha)
        payload = json.loads(installer["payload-manifest.json"].read_text(encoding="utf-8"))
        if (payload.get("schema") != 1 or payload.get("platform") != "windows-x64"
                or payload.get("app_version") != identity["version"] or payload.get("build_revision") != sha):
            raise ValueError("Installer payload version/commit does not match the build")
        actual = json.loads(command([host["MicDrop.exe"], "version"]))
        if any(actual.get(k) != v for k, v in {**identity, "revision": sha, "modified": False, "platform": "windows/amd64"}.items()):
            raise ValueError("Embedded Windows build identity mismatch: MicDrop.exe")
        setup_name = f"{prefix}-{sha}-windows-x64-setup.exe"
        setup = output / f"{prefix}-windows-x64-setup.exe"
        shutil.copyfile(installer[setup_name], setup)
        packages.append(setup)
        portable = output / f"{prefix}-windows-x64-portable.zip"
        # Both packages must satisfy the source-controlled allowlist, even if
        # a stale installer manifest or runner directory contains extra files.
        entries = payload["files"]
        names = [entry["path"] for entry in entries]
        if len(names) != len(set(names)) or set(names) != set(PORTABLE) | INSTALLER_ONLY:
            raise ValueError("Installer payload differs from the release allowlist")
        selected = {}
        for entry in entries:
            name = entry["path"]
            if name in INSTALLER_ONLY:
                continue
            if name not in host:
                raise ValueError(f"Portable package is missing {name}")
            if digest(host[name]) != entry["sha256"] or host[name].stat().st_size != entry["size"]:
                raise ValueError("Portable and installer payloads differ")
            selected[name] = host[name]
        with zipfile.ZipFile(portable, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, path in sorted(selected.items()):
                item = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                item.compress_type = zipfile.ZIP_DEFLATED
                item.create_system = 3
                item.external_attr = 0o100644 << 16
                with archive.open(item, "w") as target, path.open("rb") as source:
                    shutil.copyfileobj(source, target)
        packages.append(portable)
        info.update(_inspect_windows_authenticode([host["MicDrop.exe"], host["micdrop_rtc.dll"], setup], command))
    elif platform == "linux":
        files = retained(root, "linux-x64-host", run_id, attempt, sha)
        tarball = files["MicDrop-linux-x64-host.tar.gz"]
        check_host_tarball(tarball, platform="linux-x64")
        with tempfile.TemporaryDirectory() as extracted_name:
            extracted = Path(extracted_name)
            _extract_verified_host_tarball(tarball, extracted)
            top_dir = UNIX_HOST_PLATFORMS["linux-x64"]["top_dir"]
            actual = json.loads(command([extracted / top_dir / "micdrop-host", "version"]))
        if any(actual.get(k) != v for k, v in {**identity, "revision": sha, "modified": False, "platform": "linux/amd64"}.items()):
            raise ValueError("Embedded Linux build identity mismatch: micdrop-host")
        target = output / f"{prefix}-linux-x64-host.tar.gz"
        shutil.copyfile(tarball, target)
        packages.append(target)
        info["signing"] = "unsigned Linux x64 CLI and GTK3 desktop bundle"
    elif platform == "macos":
        app_files = retained(root, "macos-arm64-app", run_id, attempt, sha)
        host_files = retained(root, "macos-arm64-host", run_id, attempt, sha)
        app_zip = app_files["MicDrop-macos-arm64-app.zip"]
        host_tar = host_files["MicDrop-macos-arm64-host.tar.gz"]
        check_app_zip(
            app_zip,
            bundle_id=MACOS_BUNDLE_ID,
            minimum_os=DEFAULT_MIN_MACOS,
            revision=sha[:12],
            shared_identity=identity,
        )
        check_host_tarball(host_tar, platform="macos-arm64", minimum_macos=DEFAULT_MIN_MACOS)
        with tempfile.TemporaryDirectory() as extracted_name:
            extracted = Path(extracted_name)
            app_root = extracted / "app"
            host_root = extracted / "host"
            _extract_verified_app_zip(app_zip, app_root)
            _extract_verified_host_tarball(host_tar, host_root)
            app_bundle = app_root / "MicDrop.app"
            app_exe = app_bundle / "Contents/MacOS/MicDrop"
            top_dir = UNIX_HOST_PLATFORMS["macos-arm64"]["top_dir"]
            cli_exe = host_root / top_dir / "micdrop-host"
            cli_dylib = host_root / top_dir / UNIX_HOST_PLATFORMS["macos-arm64"]["rtc_lib"]
            command(["codesign", "--verify", "--deep", "--strict", app_bundle])
            command(["codesign", "--verify", "--strict", cli_dylib, cli_exe])
            stapled = (app_bundle / "Contents" / "CodeResources").is_file()
            if stapled:
                command(["xcrun", "stapler", "validate", app_bundle])
                macos_signing = "Developer ID signed and Apple-notarized macOS arm64 app bundle and CLI host"
            else:
                macos_signing = "ad-hoc signed macOS arm64 app bundle and CLI host"
            expected_embed = {**identity, "revision": sha, "modified": False, "platform": "darwin/arm64"}
            app_actual = json.loads(command([app_exe, "version"]))
            if any(app_actual.get(k) != v for k, v in expected_embed.items()):
                raise ValueError("Embedded macOS build identity mismatch: MicDrop.app")
            cli_actual = json.loads(command([cli_exe, "version"]))
            if any(cli_actual.get(k) != v for k, v in expected_embed.items()):
                raise ValueError("Embedded macOS build identity mismatch: micdrop-host")
        app_target = output / f"{prefix}-macos-arm64-app.zip"
        shutil.copyfile(app_zip, app_target)
        packages.append(app_target)
        host_target = output / f"{prefix}-macos-arm64-host.tar.gz"
        shutil.copyfile(host_tar, host_target)
        packages.append(host_target)
        info.update({
            "bundle_id": MACOS_BUNDLE_ID,
            "minimum_os": DEFAULT_MIN_MACOS,
            "signing": macos_signing,
        })
    elif platform == "android":
        files = retained(root, "android-apk", run_id, attempt, sha)
        apk = files["app-debug.apk"]
        sdk = Path(os.environ["ANDROID_HOME"]) / "build-tools" / "35.0.0"
        badging = command([sdk / "aapt2", "dump", "badging", apk])
        match = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", badging, re.MULTILINE)
        if not match or match.groups() != ("com.maskarauder.micdrop.dev", str(identity["android_version_code"]), identity["version"]):
            raise ValueError("APK package/version does not match release identity")
        report = command([sdk / "apksigner", "verify", "--print-certs", apk])
        signers = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$", report, re.MULTILINE)
        if len(signers) != 1:
            raise ValueError("Expected one verified APK signer")
        target = output / f"{prefix}-android-arm64-dev.apk"
        shutil.copyfile(apk, target)
        packages.append(target)
        info.update({"application_id": match[1], "signing": "existing development identity", "certificate_sha256": signers[0].lower()})
    elif platform == "ios":
        if ios_ipa is None:
            files = retained(root, "ios-ipa", run_id, attempt, sha)
            ipa = files["MicDrop.ipa"]
            provenance = "runner-retained artifact"
        else:
            ipa, ipa_parent = anchor_nonlink(ios_ipa)
            reject_links(ipa, stop=ipa_parent)
            if not ipa.is_file():
                raise ValueError("Downloaded IPA is missing or is not a file")
            provenance = "downloaded; bundle identity checked locally"
        versions = bundle_versions(identity)
        check_ipa(
            ipa,
            IOS_BUNDLE_ID,
            "17.0",
            sha[:12],
            marketing_version=versions["MICDROP_MARKETING_VERSION"],
            build_number=versions["MICDROP_BUILD_NUMBER"],
            version_name=versions["MICDROP_VERSION_NAME"],
        )
        target = output / f"{prefix}-ios-arm64-unsigned.ipa"
        shutil.copyfile(ipa, target)
        packages.append(target)
        info.update({
            "bundle_id": IOS_BUNDLE_ID,
            "minimum_os": "17.0",
            "signing": "unsigned iPhone bundle (sideload with Apple ID)",
            "ipa_provenance": provenance,
        })
    else:
        raise ValueError("Unknown platform")
    info["assets"] = [{"name": p.name, "bytes": p.stat().st_size, "sha256": digest(p)} for p in packages]
    metadata = output / f"{prefix}-{platform}-build.json"
    write_json(metadata, info)
    return packages + [metadata]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise ValueError("Unexpected API redirect; credentials were not forwarded")


class GitHub:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not token:
            raise ValueError("GitHub repository and token are required")
        self.repository = repository
        self.base = "https://api.github.com/repos/" + repository
        self.token = token

    def request(self, method, path, data=None, file=None):
        url = path if path.startswith("https://") else self.base + path
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc not in {"api.github.com", "uploads.github.com"}:
            raise ValueError("Unexpected GitHub API origin")
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "MicDrop-draft-release"}
        if file:
            headers.update({"Content-Type": "application/octet-stream", "Content-Length": str(file.stat().st_size)})
            payload = file.open("rb")
        else:
            headers["Content-Type"] = "application/json"
            payload = json.dumps(data).encode() if data is not None else None
        try:
            request = urllib.request.Request(url, data=payload, headers=headers, method=method)
            with urllib.request.build_opener(NoRedirect).open(request, timeout=90) as response:
                raw = response.read(16 * 1024 * 1024 + 1)
                if len(raw) > 16 * 1024 * 1024:
                    raise ValueError("GitHub API response exceeds size limit")
                return json.loads(raw)
        except urllib.error.HTTPError as error:
            if method == "GET" and error.code == 404:
                return None
            raise ValueError(f"GitHub {method} {parsed.path} failed with HTTP {error.code}") from None
        finally:
            if file:
                payload.close()

    def listing(self, path):
        result = []
        for page in range(1, 21):
            values = self.request("GET", f"{path}?per_page=100&page={page}")
            if not isinstance(values, list):
                raise ValueError("Invalid GitHub list response")
            result.extend(values)
            if len(values) < 100:
                return result
        raise ValueError("GitHub pagination exceeded supported bound")


def source_file(api, sha, path):
    value = api.request("GET", f"/contents/{path}?ref={sha}")
    if not value or value.get("encoding") != "base64" or value.get("size", 0) > 32768:
        raise ValueError(f"Missing or oversized source file: {path}")
    return base64.b64decode(value["content"], validate=False).decode("utf-8")


def source_run(api, run_id):
    if not str(run_id).isdecimal() or int(run_id) <= 0:
        raise ValueError("Build run ID must be a positive number")
    run = api.request("GET", f"/actions/runs/{run_id}")
    if (not run or run.get("status") != "completed" or run.get("conclusion") != "success"
            or run.get("event") not in {"push", "workflow_dispatch"} or run.get("head_branch") != "main"
            or run.get("path") != ".github/workflows/build.yml"
            or run.get("head_repository", {}).get("full_name") != api.repository
            or not re.fullmatch(SHA, run.get("head_sha", ""))):
        raise ValueError("Select a successful main-branch Build and audio contracts run from this repository")
    comparison = api.request("GET", f"/compare/{run['head_sha']}...main")
    if not comparison or comparison.get("status") not in {"identical", "ahead"}:
        raise ValueError("Selected build is no longer on main's history")
    identity = parse(source_file(api, run["head_sha"], VERSION_PATH))
    notes = source_file(api, run["head_sha"], f"docs/releases/{identity['version']}.md")
    tag = "v" + identity["version"]
    ref = api.request("GET", "/git/ref/tags/" + tag)
    if ref and (ref.get("object", {}).get("type") != "commit" or ref.get("object", {}).get("sha") != run["head_sha"]):
        raise ValueError("An existing tag does not point directly at the selected commit")
    return run, identity, notes


def marker(run):
    return f"<!-- micdrop-draft-v1 source={run['head_sha']} run={run['id']} attempt={run['run_attempt']} -->"


def release_body(run, identity, notes, complete):
    status = "Packages verified; draft awaits human review." if complete else "INCOMPLETE: package uploads/verification are still pending. Do not publish."
    return (marker(run) + "\n\n" + status + "\n\n" + notes.strip() + "\n\n"
            + "Package signing: Windows x64 (`MicDrop.exe`, `micdrop_rtc.dll`, and setup/uninstaller) is Authenticode-signed and timestamped; "
            + "macOS arm64 (`com.maskarauder.micdrop.mac`) is Developer ID signed and Apple-notarized; "
            + "Linux x64 is unsigned; Android uses the existing development signer (`com.maskarauder.micdrop.dev`); "
            + "any included iPhone `.ipa` (`com.maskarauder.micdrop`) is unsigned for Apple ID sideloading (TestFlight builds are distributed via App Store Connect). "
            + "First-party source is MPL-2.0; provide recipients with matching source and notices.\n\n"
            + f"Source: `{run['head_sha']}` · Android version code: `{identity['android_version_code']}`\n\n"
            + f"Verified build: {run['html_url']} (attempt {run['run_attempt']}).\n")


def owned_draft(api, release_id, run, identity):
    release = api.request("GET", f"/releases/{release_id}")
    if (not release or release.get("draft") is not True or release.get("prerelease") is not True
            or release.get("tag_name") != "v" + identity["version"]
            or release.get("target_commitish") != run["head_sha"]
            or marker(run) not in release.get("body", "")):
        raise ValueError("Refusing to modify a published, unrelated or different-build release")
    return release


def prepare(api, run, identity, notes):
    existing = [r for r in api.listing("/releases") if r["tag_name"] == "v" + identity["version"]]
    if len(existing) > 1:
        raise ValueError("More than one release has this tag")
    if existing:
        return owned_draft(api, existing[0]["id"], run, identity)
    return api.request("POST", "/releases", {"tag_name": "v" + identity["version"],
        "target_commitish": run["head_sha"], "name": "MicDrop " + identity["version"],
        "body": release_body(run, identity, notes, False), "draft": True, "prerelease": True,
        "make_latest": "false"})


def upload(api, release_id, run, identity, path):
    release = owned_draft(api, release_id, run, identity)
    expected = "sha256:" + digest(path)
    assets = api.listing(f"/releases/{release_id}/assets")
    matches = [a for a in assets if a["name"] == path.name]
    if matches:
        if len(matches) != 1 or matches[0].get("state") != "uploaded" or matches[0].get("digest") != expected or matches[0].get("size") != path.stat().st_size:
            raise ValueError(f"Existing asset differs or upload is incomplete: {path.name}; nothing was overwritten")
        return
    if (path.name.endswith(("-ios-arm64-unsigned.ipa", "-ios-build.json"))
            and any(a["name"] in {"release-manifest.json", "SHA256SUMS"} for a in assets)):
        raise ValueError("Include iPhone assets before finalization; existing manifests cannot be replaced")
    url = release["upload_url"].split("{")[0] + "?" + urllib.parse.urlencode({"name": path.name})
    asset = api.request("POST", url, file=path)
    if asset.get("state") != "uploaded" or asset.get("digest") != expected or asset.get("size") != path.stat().st_size:
        raise ValueError("Uploaded asset failed GitHub digest verification")


def finish(api, release_id, run, identity, notes, output):
    release = owned_draft(api, release_id, run, identity)
    if release["body"] not in {release_body(run, identity, notes, False), release_body(run, identity, notes, True)}:
        raise ValueError("Release notes were edited manually; refusing to overwrite them")
    prefix = "MicDrop-" + identity["version"]
    required = {
        prefix + suffix
        for suffix in (
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
    }
    optional_ios = {prefix + suffix for suffix in ("-ios-arm64-unsigned.ipa", "-ios-build.json")}
    assets = api.listing(f"/releases/{release_id}/assets")
    allowed = required | optional_ios | {"release-manifest.json", "SHA256SUMS"}
    names = {a["name"] for a in assets}
    if (len(names) != len(assets) or not required <= names or not names <= allowed
            or (bool(names & optional_ios) and not optional_ios <= names)):
        raise ValueError("Release has missing or unexpected assets")
    packaged = required | (optional_ios if optional_ios <= names else set())
    files = []
    for asset in sorted(assets, key=lambda a: a["name"]):
        if asset["name"] not in packaged:
            continue
        if asset.get("state") != "uploaded" or not re.fullmatch("sha256:" + DIGEST, asset.get("digest", "")):
            raise ValueError("Release asset is incomplete or has no SHA-256 digest")
        files.append({"name": asset["name"], "bytes": asset["size"], "sha256": asset["digest"][7:]})
    output.mkdir(parents=True, exist_ok=False)
    manifest = output / "release-manifest.json"
    write_json(manifest, {"schema": 1, **identity, "source_sha": run["head_sha"], "build_run_id": str(run["id"]),
                          "build_attempt": str(run["run_attempt"]), "assets": files})
    upload(api, release_id, run, identity, manifest)
    sums = output / "SHA256SUMS"
    sums.write_text("".join(f"{f['sha256']}  {f['name']}\n" for f in files)
                    + f"{digest(manifest)}  release-manifest.json\n", encoding="utf-8")
    upload(api, release_id, run, identity, sums)
    owned_draft(api, release_id, run, identity)
    # GitHub resets a draft's pending tag to untagged-* if an update omits it.
    # Never change publication state, including if a human publishes during this request.
    updated = api.request("PATCH", f"/releases/{release_id}", {
        "tag_name": "v" + identity["version"], "body": release_body(run, identity, notes, True)})
    if updated.get("draft") is not True:
        raise ValueError("Release was published during finalization; its publication state was not changed")
    if updated.get("tag_name") != "v" + identity["version"]:
        raise ValueError("Draft tag changed during finalization")


def artifact_root():
    repo_id = os.environ["GITHUB_REPOSITORY_ID"]
    if not repo_id.isdecimal():
        raise ValueError("Invalid repository ID")
    return Path(os.environ["RUNNER_TEMP"]).parent / "micdrop-artifacts" / repo_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["stage", "prepare", "upload", "finish"])
    parser.add_argument("--platform", choices=["windows", "linux", "macos", "android", "ios"])
    parser.add_argument("--ios-ipa", type=Path,
                        help="Downloaded unsigned IPA for iOS stage/upload, built from the selected source commit")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", default="1")
    parser.add_argument("--sha")
    parser.add_argument("--release-id")
    parser.add_argument("--output", type=Path, default=Path("build/draft-release"))
    args = parser.parse_args()
    if args.ios_ipa is not None and (args.platform != "ios" or args.operation not in {"stage", "upload"}):
        parser.error("--ios-ipa is only supported for ios stage/upload")
    if args.operation == "stage":
        paths = stage(args.platform, None if args.ios_ipa is not None else artifact_root(),
                      args.output, args.run_id, args.attempt, args.sha or "", read(), ios_ipa=args.ios_ipa)
        print("Verified local draft assets: " + ", ".join(p.name for p in paths))
        return
    api = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"])
    run, identity, notes = source_run(api, args.run_id)
    if args.operation == "prepare":
        release = prepare(api, run, identity, notes)
        with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as out:
            out.write(f"release_id={release['id']}\nsource_sha={run['head_sha']}\nrun_attempt={run['run_attempt']}\n")
    else:
        if not args.release_id or not args.release_id.isdecimal():
            raise ValueError("Release ID is required")
        if args.operation == "upload":
            if read() != identity:
                raise ValueError("Checkout and selected build version differ")
            paths = stage(args.platform, None if args.ios_ipa is not None else artifact_root(),
                          args.output, run["id"], run["run_attempt"], run["head_sha"], identity, ios_ipa=args.ios_ipa)
            for path in paths:
                upload(api, args.release_id, run, identity, path)
        else:
            finish(api, args.release_id, run, identity, notes, args.output)
    print("Draft release only; publication remains a manual action.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
