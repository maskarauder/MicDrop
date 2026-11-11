"""Retain explicit CI outputs outside checkout/runner-temp cleanup, without a cloud quota."""

import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time


KIND = "micdrop-ci-artifact-v1"


def component(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", value):
        raise ValueError(f"Invalid artifact path component: {value!r}")
    return value


def is_link(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def reject_links(path, stop=None):
    limit = None if stop is None else Path(stop)
    for entry in (path, *path.parents):
        if entry == limit:
            return
        if is_link(entry):
            raise ValueError(f"Artifact paths must not traverse links: {entry}")


def anchor_nonlink(path):
    candidate = Path(path)
    if not candidate.is_absolute():
        base = Path.cwd().resolve()
        target = base / candidate
        reject_links(target, stop=base)
        return target, base
    if is_link(candidate):
        raise ValueError(f"Artifact paths must not traverse links: {candidate}")
    parent = candidate.parent.resolve()
    return parent / candidate.name, parent


def collect_files(workspace, patterns):
    workspace = Path(workspace).resolve()
    files = set()

    def visit(path):
        reject_links(path, stop=workspace)
        if not path.resolve().is_relative_to(workspace):
            raise ValueError(f"Artifact is outside the checkout: {path}")
        if path.is_dir():
            for child in sorted(path.iterdir()):
                visit(child)
        elif path.is_file():
            files.add(path)
        else:
            raise ValueError(f"Artifact is not a regular file or directory: {path}")

    for pattern in patterns.splitlines():
        pattern = pattern.strip()
        if not pattern:
            continue
        relative = Path(pattern)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Use checkout-relative artifact paths: {pattern}")
        for match in sorted(glob.glob(str(workspace / pattern), recursive=True)):
            visit(Path(match))
    return sorted(files)


def prune(root, current, days, now):
    """Only delete our completed copies, never arbitrary folders or symlink targets."""
    entries = []
    for child in root.iterdir():
        if not re.fullmatch(r"[0-9]+-[0-9]+", child.name) or is_link(child):
            continue
        manifest = child / "manifest.json"
        if not child.is_dir() or is_link(manifest):
            continue
        try:
            metadata = json.loads(manifest.read_text(encoding="utf-8"))
            created = float(metadata["created_unix"])
            if metadata.get("kind") != KIND:
                continue
        except (OSError, ValueError, KeyError, TypeError):
            continue
        entries.append((created, child))
    older = sorted((entry for entry in entries if entry[1] != current), reverse=True)
    for index, (created, child) in enumerate(older):
        if index >= 9 or now - created > days * 86400:
            shutil.rmtree(child)


def store(workspace, root, name, run_id, attempt, patterns, days=14, now=None):
    workspace = Path(workspace).resolve()
    if not 1 <= days <= 90:
        raise ValueError("Artifact retention must be between 1 and 90 days")
    if not run_id.isdecimal() or not attempt.isdecimal():
        raise ValueError("Run ID and attempt must be decimal numbers")
    files = collect_files(workspace, patterns)
    if not files:
        return None
    root_dir, root_parent = anchor_nonlink(root)
    destination_root = root_dir / component(name)
    reject_links(destination_root, stop=root_parent)
    destination_root.mkdir(parents=True, exist_ok=True)
    destination = destination_root / f"{run_id}-{attempt}"
    if destination.exists() or is_link(destination):
        raise FileExistsError(f"Artifact already exists: {destination}")
    now = time.time() if now is None else now
    common = Path(os.path.commonpath([str(path.parent) for path in files]))
    inventory = []
    # A failed copy never replaces a previously retained artifact or starts pruning.
    with tempfile.TemporaryDirectory(prefix=".pending-", dir=destination_root) as staging_name:
        staging = Path(staging_name)
        for source in files:
            relative = source.relative_to(common)
            target = staging / "files" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            with target.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            inventory.append({"path": relative.as_posix(), "bytes": target.stat().st_size,
                              "sha256": digest})
        metadata = {"kind": KIND, "created_unix": now, "run_id": run_id,
                    "attempt": attempt, "name": name, "sha": os.getenv("GITHUB_SHA"),
                    "ref": os.getenv("GITHUB_REF"), "files": inventory}
        (staging / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        staging.rename(destination)
    prune(destination_root, destination, days, now)
    return destination


def main():
    name = component(os.environ["MICDROP_ARTIFACT_NAME"])
    missing = os.environ.get("MICDROP_ARTIFACT_MISSING", "warn")
    if missing not in ("warn", "error"):
        raise ValueError("if-no-files-found must be warn or error")
    root = (Path(os.environ["RUNNER_TEMP"]).parent / "micdrop-artifacts" /
            component(os.environ["GITHUB_REPOSITORY_ID"]))
    run_id = os.environ["GITHUB_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    destination = store(os.environ["GITHUB_WORKSPACE"], root, name,
                        run_id, attempt,
                        os.environ["MICDROP_ARTIFACT_PATHS"],
                        int(os.environ.get("MICDROP_ARTIFACT_DAYS", "14")))
    if destination is None:
        if missing == "error":
            raise FileNotFoundError(f"No files found for artifact {name}")
        print(f"::warning::No files found for artifact {name}")
    else:
        print(f"Retained {name} ({run_id}-{attempt})")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(f"\n**{name}** retained (`{run_id}-{attempt}`). "
                          f"See `manifest.json` for file hashes and build identity.\n")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"has-files={'true' if destination else 'false'}\n")
        if destination:
            output.write(f"local-path={destination}\n")


if __name__ == "__main__":
    main()
