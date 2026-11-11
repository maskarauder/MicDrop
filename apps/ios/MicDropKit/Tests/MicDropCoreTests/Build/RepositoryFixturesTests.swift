import MicDropTestSupport
import XCTest

/// fixtures are read in place from the repository checkout.
final class RepositoryFixturesTests: XCTestCase {
    func testRootIsTheRepositoryCheckout() throws {
        let module = try RepositoryFixtures.text("go.mod")
        XCTAssertTrue(module.hasPrefix("module "), "go.mod at \(RepositoryFixtures.root.path)")
    }

    func testPairingQRFixtureIsReadWithNormalizedLineEndings() throws {
        let text = try RepositoryFixtures.text("apps/windows-host/testdata/pairing-qr.txt")
        XCTAssertFalse(text.contains("\r"))
        let firstLine = try XCTUnwrap(text.split(separator: "\n", omittingEmptySubsequences: false).first)
        XCTAssertTrue(firstLine.hasPrefix("micdrop://pair/v1/"))
    }

    func testIdentityFixturesAreAvailableAsData() throws {
        for path in [
            "internal/identity/testdata/host_public_key_v1.json",
            "internal/identity/testdata/host_certificates_v1.json",
            "apps/android/pairing-check/src/androidTest/assets/public-test-tls.json",
        ] {
            let data = try RepositoryFixtures.data(path)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), path)
        }
    }

    func testMissingFixtureNamesThePath() {
        XCTAssertThrowsError(try RepositoryFixtures.data("internal/identity/testdata/absent.json")) { error in
            guard case .fixtureMissing(let path)? = error as? RepositoryFixtures.FixtureError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(path.hasSuffix("absent.json"))
        }
    }
}
