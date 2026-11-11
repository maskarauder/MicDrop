"""Prepare the explicit Windows release payload after building the desktop app.

The console diagnostic host may coexist in build/host for CI, but is not part
of the public installer or portable ZIP. Both consume windows_payload.json.
"""
# SPDX-License-Identifier: MPL-2.0
import json
from pathlib import Path
import shutil

from store_artifact import anchor_nonlink, reject_links

ROOT = Path(__file__).resolve().parents[1]
POLICY = json.loads(Path(__file__).with_suffix(".json").read_text(encoding="utf-8"))
PORTABLE = POLICY["portable"]
INSTALLER_ONLY = set(POLICY["installer_only"])


def prepare(root=ROOT):
    root, root_parent = anchor_nonlink(root)
    output = root / "build/host"
    # Validate all inputs before copying anything. Missing notices fail the build.
    for name, source in PORTABLE.items():
        reject_links(root / source, stop=root_parent)
        reject_links(output / name, stop=root_parent)
        if not (root / source).is_file():
            raise ValueError(f"Missing Windows package input: {source}")
    output.mkdir(parents=True, exist_ok=True)
    for name, source in PORTABLE.items():
        if (root / source).resolve() != (output / name).resolve():
            shutil.copyfile(root / source, output / name)


if __name__ == "__main__":
    prepare()
