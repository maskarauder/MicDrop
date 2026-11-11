"""Validate the shared release identity and upgrade ordering."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATH = "internal/version/version.properties"
VERSION_RE = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?"
NULL_REVISION = "0" * 40


def is_null_revision(revision):
    return revision == NULL_REVISION


def parse(text):
    fields = {}
    for line in text.strip().splitlines():
        key, separator, value = line.strip().partition("=")
        if not separator or key in fields or key not in {"version", "android_version_code"}:
            raise ValueError("Invalid or duplicate version metadata field")
        fields[key] = value
    match = re.fullmatch(VERSION_RE, fields.get("version", ""))
    if not match or len(fields["version"]) > 64 or any(int(n) > 65535 for n in match.groups()):
        raise ValueError("Use MAJOR.MINOR.PATCH[-alpha.N|-beta.N|-rc.N], with Windows-compatible numbers")
    code = fields.get("android_version_code", "")
    if not re.fullmatch(r"[1-9][0-9]{0,9}", code) or int(code) > 2100000000:
        raise ValueError("Android version code must be 1..2100000000")
    return {"version": fields["version"], "android_version_code": int(code)}


def read(root=ROOT):
    return parse((root / VERSION_PATH).read_text(encoding="utf-8"))


def check_upgrade(current, previous):
    if current["android_version_code"] < previous["android_version_code"]:
        raise ValueError("Android version code must not decrease")
    if current["version"] != previous["version"] and current["android_version_code"] <= previous["android_version_code"]:
        raise ValueError("Increase android_version_code whenever the release version changes")


def previous_at(revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Previous revision must be a full commit SHA")
    subprocess.run(["git", "cat-file", "-e", revision + "^{commit}"], cwd=ROOT, check=True)
    names = subprocess.check_output(["git", "ls-tree", "--name-only", revision, VERSION_PATH], cwd=ROOT, text=True)
    if not names.strip():
        # The development builds before shared versioning used these values.
        return {"version": "0.1.0-dev", "android_version_code": 1}
    return parse(subprocess.check_output(["git", "show", revision + ":" + VERSION_PATH], cwd=ROOT, text=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous")
    args = parser.parse_args()
    current = read()
    if args.previous and not is_null_revision(args.previous):
        check_upgrade(current, previous_at(args.previous))
    notes = ROOT / "docs" / "releases" / (current["version"] + ".md")
    if not notes.is_file() or not 1 <= len(notes.read_bytes()) <= 32768:
        raise SystemExit("Add release notes for the shared version (at most 32 KiB)")
    print(json.dumps(current))
