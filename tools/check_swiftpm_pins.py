"""Check that Swift package pins are exact github.com/apple releases with matching bundled notices."""
import argparse
import json
import re
from pathlib import Path

LOCATION = re.compile(r"^https://github\.com/apple/[A-Za-z0-9._-]+?(\.git)?$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
NOTICE_HEADER = re.compile(
    r"^== (?P<identity>[a-z0-9-]+) (?P<version>\d+\.\d+\.\d+) \((?P<revision>[0-9a-f]{40})\) ==$")


def normalized_location(location):
    location = location.lower()
    return location[:-4] if location.endswith(".git") else location


def load_pins(path):
    """Map identity to (normalized location, version, revision); `originHash` is not part of the result."""
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("version") not in (2, 3):
        raise ValueError("Unsupported Package.resolved version")
    pins = document.get("pins")
    if not isinstance(pins, list):
        raise ValueError("Package.resolved has no pins")
    result = {}
    for pin in pins:
        if not isinstance(pin, dict) or not isinstance(pin.get("identity"), str):
            raise ValueError("Package.resolved has a pin without an identity")
        identity = pin["identity"]
        if identity in result:
            raise ValueError(f"Duplicate package pin {identity}")
        if pin.get("kind") != "remoteSourceControl":
            raise ValueError(f"Package pin {identity} is not a remote source-control pin")
        location = pin.get("location")
        if not isinstance(location, str) or not LOCATION.match(location):
            raise ValueError(f"Package pin {identity} is not from github.com/apple")
        location = normalized_location(location)
        if identity != location.rsplit("/", 1)[-1]:
            raise ValueError(f"Package pin {identity} does not match its location")
        state = pin.get("state")
        state = state if isinstance(state, dict) else {}
        version = state.get("version")
        if "branch" in state or not isinstance(version, str) or not VERSION.match(version):
            raise ValueError(f"Package pin {identity} must be an exact release")
        revision = state.get("revision")
        if not isinstance(revision, str) or not REVISION.match(revision):
            raise ValueError(f"Package pin {identity} has an invalid revision")
        result[identity] = (location, version, revision)
    return result


def notice_headers(path):
    """Map identity to (version, revision) from the machine-checkable notice headers."""
    headers = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        match = NOTICE_HEADER.match(line)
        if not match:
            continue
        identity = match["identity"]
        if identity in headers:
            raise ValueError(f"Duplicate notice for {identity}")
        headers[identity] = (match["version"], match["revision"])
    return headers


def check_lock(resolved, notices):
    pins = load_pins(resolved)
    headers = notice_headers(notices)
    problems = []
    for identity in sorted(pins.keys() | headers.keys()):
        if identity not in headers:
            problems.append(f"Notices omit {identity}")
        elif identity not in pins:
            problems.append(f"Notices list unpinned {identity}")
        elif headers[identity] != pins[identity][1:]:
            problems.append(f"Notices for {identity} do not match its pin")
    if problems:
        raise ValueError("; ".join(problems))
    return len(pins)


def check_compare(actual, committed):
    actual_pins, committed_pins = load_pins(actual), load_pins(committed)
    different = sorted(identity for identity in actual_pins.keys() | committed_pins.keys()
                       if actual_pins.get(identity) != committed_pins.get(identity))
    if different:
        raise ValueError("Resolved packages differ: " + ", ".join(different))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    lock = commands.add_parser("lock", help="check a Package.resolved against the bundled notices")
    lock.add_argument("resolved", type=Path)
    lock.add_argument("notices", type=Path)
    compare = commands.add_parser("compare", help="check that two Package.resolved files pin the same packages")
    compare.add_argument("actual", type=Path)
    compare.add_argument("committed", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "lock":
            count = check_lock(arguments.resolved, arguments.notices)
            print(f"Verified {count} Swift package pins and notices")
        else:
            check_compare(arguments.actual, arguments.committed)
            print("Verified Xcode package resolution matches the committed pins")
    except (ValueError, OSError, json.JSONDecodeError) as error:
        parser.exit(1, f"Swift package pin check failed: {error}\n")
