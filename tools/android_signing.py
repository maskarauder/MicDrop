"""Prepare CI Android development signing and verify the APK against that certificate."""
import argparse
import base64
import hashlib
import os
import re
import subprocess
import tempfile
from pathlib import Path


def command(arguments):
    result = subprocess.run(arguments, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed; check the debug signing configuration")
    return result.stdout


def certificate_digest(keystore):
    certificate = command(["keytool", "-exportcert", "-keystore", str(keystore),
                           "-alias", "androiddebugkey", "-storepass", "android"])
    return hashlib.sha256(certificate).hexdigest()


def prepare():
    encoded = "".join(os.environ.get("MICDROP_DEBUG_KEYSTORE_BASE64", "").split())
    directory = Path(tempfile.mkdtemp(prefix="micdrop-debug-signer-", dir=os.environ["RUNNER_TEMP"]))
    keystore = directory / "debug.keystore"
    try:
        if encoded:
            if len(encoded) > 48 * 1024:
                raise ValueError("Debug keystore secret exceeds the supported size")
            keystore.write_bytes(base64.b64decode(encoded, validate=True))
        else:
            # Compile and exercise signing even without a configured secret,
            # but never publish this disposable certificate's APK for installation.
            command(["keytool", "-genkeypair", "-keystore", str(keystore), "-storetype", "JKS",
                     "-alias", "androiddebugkey", "-storepass", "android", "-keypass", "android",
                     "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
                     "-dname", "CN=MicDrop CI Fixture,O=MicDrop,C=US", "-noprompt"])
        keystore.chmod(0o600)
        certificate_digest(keystore)  # Validate password, alias and certificate before Gradle.
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            output.write(f"MICDROP_DEBUG_KEYSTORE={keystore}\n")
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"stable_signer={'true' if encoded else 'false'}\n")
    except Exception:
        keystore.unlink(missing_ok=True)
        directory.rmdir()
        raise
    if not encoded:
        print("::notice::MICDROP_DEBUG_KEYSTORE_BASE64 is not configured. Signing is tested with "
              "a disposable key; app-debug.apk will not be published until the secret is set.")


def verify(apk, apksigner):
    expected = certificate_digest(Path(os.environ["MICDROP_DEBUG_KEYSTORE"]))
    report = command([apksigner, "verify", "--print-certs", str(apk)]).decode("utf-8")
    signers = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$",
                         report, re.MULTILINE)
    if len(signers) != 1 or signers[0].lower() != expected:
        raise RuntimeError("APK certificate does not match the configured debug keystore")
    print(f"Verified Android development APK certificate SHA-256: {expected}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("prepare")
    check = commands.add_parser("verify")
    check.add_argument("apk", type=Path)
    check.add_argument("apksigner")
    arguments = parser.parse_args()
    if arguments.operation == "prepare":
        prepare()
    else:
        verify(arguments.apk, arguments.apksigner)
