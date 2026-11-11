"""Derive the iPhone bundle versions from the shared release identity (D047).

Prints GitHub Actions environment lines for xcodebuild:
- MICDROP_MARKETING_VERSION: CFBundleShortVersionString, MAJOR.MINOR.PATCH only, because
  iOS rejects pre-release suffixes there.
- MICDROP_BUILD_NUMBER: CFBundleVersion, the shared android_version_code, which only increases.
- MICDROP_VERSION_NAME: the full shared version, shown in reports and diagnostics.
"""
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_version  # noqa: E402


def bundle_versions(identity):
    name = identity["version"]
    return {
        "MICDROP_MARKETING_VERSION": name.split("-", 1)[0],
        "MICDROP_BUILD_NUMBER": str(identity["android_version_code"]),
        "MICDROP_VERSION_NAME": name,
    }


def env_lines(versions):
    return "".join(f"{key}={value}\n" for key, value in versions.items())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=release_version.ROOT)
    args = parser.parse_args()
    sys.stdout.write(env_lines(bundle_versions(release_version.read(args.root))))
