#!/usr/bin/python3
"""Grant one service account read access to two selected Caddy certificate files.

The timer repairs ACLs after Caddy atomically replaces a file with mode 0600.
Open without following symlinks, then modify ACLs through the opened descriptor:
a concurrent replacement cannot redirect a privileged chmod to an unrelated file.
No file contents, credentials or certificate identities are printed.
"""

import argparse
import os
from pathlib import PurePosixPath
import pwd
import stat
import subprocess
import sys

CADDY_ROOT = PurePosixPath("/var/lib/caddy")


def checked_path(value):
    path = PurePosixPath(value)
    if not path.is_absolute() or ".." in path.parts or not path.is_relative_to(CADDY_ROOT):
        raise ValueError("certificate paths must be below /var/lib/caddy")
    if path == CADDY_ROOT:
        raise ValueError("a certificate file is required")
    return path


def set_access(fd, uid, permissions):
    subprocess.run(["/usr/bin/setfacl", "-m", f"u:{uid}:{permissions}",
                    f"/proc/self/fd/{fd}"], pass_fds=(fd,), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def grant_file(path, uid):
    # Keep each descriptor open until the next component is resolved beneath it.
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:-1], start=1):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory)
            os.close(directory)
            directory = child
            # / and /var/lib retain their normal system permissions. Only the
            # Caddy subtree gets traversal, without directory listing or writes.
            if index >= len(CADDY_ROOT.parts) - 1:
                set_access(directory, uid, "--x")
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("certificate must be a regular, singly linked file")
            set_access(descriptor, uid, "r--")
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise ValueError("run the access helper as root")
        cert, key = checked_path(args.cert), checked_path(args.key)
        if cert == key or cert.parent != key.parent:
            raise ValueError("use distinct certificate/key files in one Caddy directory")
        uid = pwd.getpwnam("micdrop").pw_uid
        if uid == 0:
            raise ValueError("micdrop must be unprivileged")
        grant_file(cert, uid)
        grant_file(key, uid)
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        print("Caddy certificate access refresh failed. Check the configured paths, "
              "micdrop account, regular files and acl package; the timer will retry.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
