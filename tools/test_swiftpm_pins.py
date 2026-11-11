"""Swift package pin and notice contracts; no Swift toolchain or network needed."""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from check_swiftpm_pins import check_compare, check_lock, load_pins, notice_headers

ROOT = Path(__file__).resolve().parents[1]
NIO = "21de5f08c1a166a6dd293d0e587ad977bf8dac5d"
ASN1 = "3b6410f7dee09eb33cdd26260c5fd47fda19b0e2"
# 11 §3.2: every package the iPhone app resolves, with its pinned release commit.
EXPECTED_PINS = {
    "swift-asn1": ("1.7.3", ASN1),
    "swift-atomics": ("1.3.1", "0442cb5a3f98ab802acb777929fdb446bda11a34"),
    "swift-certificates": ("1.21.0", "ff86b924ead66f853b8baf91f3c41926a8f36177"),
    "swift-collections": ("1.7.1", "98ef3c98609a1e31b7e157b5b619579001a789d6"),
    "swift-crypto": ("4.5.2", "da9d28d69ebe3894b18376c8f2395c2f37b8448f"),
    "swift-nio": ("2.103.0", NIO),
    "swift-nio-ssl": ("2.37.5", "322f3c2a4a21df31c84ca416bf65ee5e9059e440"),
    "swift-nio-transport-services": ("1.28.0", "67787bb645a5e67d2edcdfbe48a216cc549222d5"),
    "swift-system": ("1.8.1", "869129b7bf4ecc57b97d0193ad29690ca2134750"),
}


def pin(identity, version, revision, location=None, **state):
    return {
        "identity": identity,
        "kind": "remoteSourceControl",
        "location": location or f"https://github.com/apple/{identity}.git",
        "state": {"revision": revision, "version": version, **state},
    }


def resolved(pins, version=3, origin="a" * 64):
    document = {"pins": pins, "version": version}
    if origin is not None:
        document["originHash"] = origin
    return document


def notices(*headers):
    lines = ["MicDrop iPhone dependencies."]
    for identity, version, revision in headers:
        lines += ["", f"== {identity} {version} ({revision}) ==", f"https://github.com/apple/{identity}/tree/{version}"]
    lines += ["", "== BoringSSL (" + "b" * 40 + ") ==", "", "== Apache License, Version 2.0 =="]
    return "\n".join(lines) + "\n"


class SwiftPackagePinsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.pins = [pin("swift-nio", "2.103.0", NIO), pin("swift-asn1", "1.7.3", ASN1)]
        self.headers = [("swift-asn1", "1.7.3", ASN1), ("swift-nio", "2.103.0", NIO)]

    def write(self, name, content):
        path = self.root / name
        path.write_text(content if isinstance(content, str) else json.dumps(content, indent=2), encoding="utf-8")
        return path

    def lock(self, document=None, headers=None):
        return check_lock(self.write("Package.resolved", document or resolved(self.pins)),
                          self.write("ios-notices.txt", notices(*(self.headers if headers is None else headers))))

    def test_valid_v3_file_with_matching_notices_passes_lock(self):
        self.assertEqual(2, self.lock())
        self.assertEqual(("https://github.com/apple/swift-nio", "2.103.0", NIO),
                         load_pins(self.root / "Package.resolved")["swift-nio"])

    def test_v2_file_without_origin_hash_is_accepted(self):
        self.assertEqual(2, self.lock(resolved(self.pins, version=2, origin=None)))

    def test_unsupported_versions_and_missing_pins_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsupported Package.resolved version"):
            self.lock(resolved(self.pins, version=1))
        with self.assertRaisesRegex(ValueError, "has no pins"):
            self.lock({"version": 3, "object": {}})

    def test_branch_pin_is_rejected(self):
        self.pins[0] = pin("swift-nio", "2.103.0", NIO, branch="main")
        with self.assertRaisesRegex(ValueError, "Package pin swift-nio must be an exact release"):
            self.lock()
        self.pins[0] = pin("swift-nio", "2.103", NIO)
        with self.assertRaisesRegex(ValueError, "exact release"):
            self.lock()

    def test_location_outside_apple_is_rejected(self):
        self.pins[0] = pin("swift-nio", "2.103.0", NIO, location="https://github.com/someone/swift-nio.git")
        with self.assertRaisesRegex(ValueError, "Package pin swift-nio is not from github.com/apple"):
            self.lock()
        self.pins[0] = pin("swift-nio", "2.103.0", NIO, location="http://github.com/apple/swift-nio.git")
        with self.assertRaisesRegex(ValueError, "github.com/apple"):
            self.lock()

    def test_identity_must_match_location(self):
        self.pins[0] = pin("swift-nio", "2.103.0", NIO, location="https://github.com/apple/swift-nio-ssl.git")
        with self.assertRaisesRegex(ValueError, "Package pin swift-nio does not match its location"):
            self.lock()

    def test_local_and_duplicate_pins_are_rejected(self):
        self.pins[0]["kind"] = "fileSystem"
        with self.assertRaisesRegex(ValueError, "is not a remote source-control pin"):
            self.lock()
        self.pins[0] = pin("swift-asn1", "1.7.3", ASN1)
        with self.assertRaisesRegex(ValueError, "Duplicate package pin swift-asn1"):
            self.lock()

    def test_uppercase_revision_is_rejected(self):
        self.pins[0] = pin("swift-nio", "2.103.0", NIO.upper())
        with self.assertRaisesRegex(ValueError, "Package pin swift-nio has an invalid revision"):
            self.lock()

    def test_notices_missing_one_package_fail(self):
        with self.assertRaisesRegex(ValueError, "Notices omit swift-nio"):
            self.lock(headers=self.headers[:1])

    def test_notice_for_an_unpinned_package_fails(self):
        extra = ("swift-system", "1.8.1", "869129b7bf4ecc57b97d0193ad29690ca2134750")
        with self.assertRaisesRegex(ValueError, "Notices list unpinned swift-system"):
            self.lock(headers=self.headers + [extra])

    def test_notice_version_differing_from_its_pin_fails(self):
        with self.assertRaisesRegex(ValueError, "Notices for swift-nio do not match its pin"):
            self.lock(headers=[self.headers[0], ("swift-nio", "2.102.0", NIO)])
        with self.assertRaisesRegex(ValueError, "Notices for swift-nio do not match its pin"):
            self.lock(headers=[self.headers[0], ("swift-nio", "2.103.0", ASN1)])

    def test_duplicate_notice_header_fails(self):
        with self.assertRaisesRegex(ValueError, "Duplicate notice for swift-nio"):
            self.lock(headers=self.headers + [self.headers[1]])

    def test_other_section_headers_are_not_pins(self):
        headers = notice_headers(self.write("ios-notices.txt", notices(*self.headers)))
        self.assertEqual({"swift-asn1": ("1.7.3", ASN1), "swift-nio": ("2.103.0", NIO)}, headers)

    def test_compare_ignores_origin_hash_but_rejects_a_different_revision(self):
        committed = self.write("committed.json", resolved(self.pins, origin="a" * 64))
        actual = self.write("actual.json", resolved(list(reversed(self.pins)), origin="c" * 64))
        check_compare(actual, committed)
        changed = [pin("swift-nio", "2.103.0", "f" * 40), self.pins[1]]
        actual = self.write("actual.json", resolved(changed))
        with self.assertRaisesRegex(ValueError, "^Resolved packages differ: swift-nio$"):
            check_compare(actual, committed)

    def test_compare_reports_added_and_removed_packages(self):
        committed = self.write("committed.json", resolved(self.pins))
        actual = self.write("actual.json", resolved(self.pins[:1] + [
            pin("swift-system", "1.8.1", "869129b7bf4ecc57b97d0193ad29690ca2134750")]))
        with self.assertRaisesRegex(ValueError, "^Resolved packages differ: swift-asn1, swift-system$"):
            check_compare(actual, committed)

    def test_compare_treats_git_suffix_and_case_as_equal(self):
        committed = self.write("committed.json", resolved(self.pins))
        locations = [pin("swift-nio", "2.103.0", NIO, location="https://github.com/apple/swift-nio"),
                     pin("swift-asn1", "1.7.3", ASN1, location="https://github.com/apple/Swift-ASN1.git")]
        check_compare(self.write("actual.json", resolved(locations)), committed)

    def test_command_line_reports_failures_with_exit_status_one(self):
        resolved_path = self.write("Package.resolved", resolved(self.pins))
        notices_path = self.write("ios-notices.txt", notices(*self.headers[:1]))
        script = Path(__file__).with_name("check_swiftpm_pins.py")
        run = subprocess.run([sys.executable, str(script), "lock", str(resolved_path), str(notices_path)],
                             capture_output=True, text=True)
        self.assertEqual(1, run.returncode)
        self.assertEqual("Swift package pin check failed: Notices omit swift-nio\n", run.stderr)
        self.write("ios-notices.txt", notices(*self.headers))
        run = subprocess.run([sys.executable, str(script), "lock", str(resolved_path), str(notices_path)],
                             capture_output=True, text=True)
        self.assertEqual(0, run.returncode, run.stderr)
        self.assertEqual("Verified 2 Swift package pins and notices\n", run.stdout)
        run = subprocess.run([sys.executable, str(script), "compare", str(resolved_path), str(resolved_path)],
                             capture_output=True, text=True)
        self.assertEqual("Verified Xcode package resolution matches the committed pins\n", run.stdout)


class RepositoryPinsTest(unittest.TestCase):
    """Keeps Package.swift, the bundled notices and (once committed) Package.resolved in step."""

    notices_path = ROOT / "third_party/ios-assets/ios-notices.txt"
    resolved_path = ROOT / "apps/ios/MicDropKit/Package.resolved"

    def test_bundled_notices_list_every_expected_pin(self):
        self.assertEqual(EXPECTED_PINS, notice_headers(self.notices_path))
        text = self.notices_path.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("MicDrop iPhone dependencies. Sources are unmodified; versions and "
                                        "revisions are pinned in apps/ios/MicDropKit/Package.resolved.\n"))
        self.assertNotIn("\r", text)
        self.assertEqual(1, text.count("\n== Apache License, Version 2.0 ==\n"))
        self.assertTrue(text.rstrip().endswith("limitations under the License."))

    def test_package_manifest_uses_exact_apple_versions_with_notices(self):
        manifest = (ROOT / "apps/ios/MicDropKit/Package.swift").read_text(encoding="utf-8")
        declared = re.findall(r'\.package\(url: "https://github\.com/apple/([a-z0-9-]+)\.git", exact: "([0-9.]+)"\)',
                              manifest)
        self.assertEqual(6, len(declared))
        self.assertEqual(6, manifest.count(".package("))
        for identity, version in declared:
            self.assertEqual(EXPECTED_PINS[identity][0], version, identity)

    @unittest.skipUnless(resolved_path.exists(), "Package.resolved is not committed yet (bootstrap in CI)")
    def test_committed_resolution_matches_notices(self):
        self.assertEqual(len(EXPECTED_PINS), check_lock(self.resolved_path, self.notices_path))


if __name__ == "__main__":
    unittest.main()
