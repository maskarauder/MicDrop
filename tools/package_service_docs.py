"""Copy current operator guides with working links into the rendezvous artifact."""
# SPDX-License-Identifier: MPL-2.0
import os
from pathlib import Path
import posixpath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GUIDES = {
    "docs/REMOTE_ACCESS.md": "README.md",
    "docs/SERVICE_DEPLOYMENT.md": "SERVICE_DEPLOYMENT.md",
}


def render(text, source, revision):
    def link(match):
        target = match[1]
        if re.match(r"^[a-zA-Z][\w+.-]*:|^#|^/", target):
            return match[0]
        path, sep, anchor = target.partition("#")
        path = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
        destination = GUIDES.get(path)
        if destination is None:
            destination = f"https://github.com/maskarauder/MicDrop/blob/{revision}/{path}"
        return "](" + destination + (sep + anchor if sep else "") + ")"
    return re.sub(r"\]\(([^()\s]+)\)", link, text)


def main():
    revision = os.environ.get("GITHUB_SHA") or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("A full source revision is required for operator guide links")
    output = ROOT / "build/rendezvous"
    output.mkdir(parents=True, exist_ok=True)
    for source, destination in GUIDES.items():
        (output / destination).write_text(
            render((ROOT / source).read_text(encoding="utf-8"), source, revision), encoding="utf-8")


if __name__ == "__main__":
    main()
