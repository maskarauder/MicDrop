import Foundation
import MicDropTestSupport
import XCTest

/// Shape of the Go identity fixtures that the identity tests read in place. A Go-side fixture change fails here first,
/// naming the fixture, instead of inside a fingerprint or certificate assertion.
final class IdentityFixtureContractTests: XCTestCase {
    func testHostPublicKeyFixtureIsAnUncompressedP256SubjectPublicKeyInfo() throws {
        let fixture = try object("internal/identity/testdata/host_public_key_v1.json")
        XCTAssertEqual(fixture["algorithm"] as? String, "ECDSA_P256")
        let spki = try XCTUnwrap(fixture["subject_public_key_info_der_hex"] as? String)
        XCTAssertTrue(isLowercaseHex(spki))
        // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING { 0x04 || X || Y } }: 91 bytes.
        XCTAssertEqual(spki.count, 182)
        XCTAssertTrue(spki.hasPrefix("3059301306072a8648ce3d020106082a8648ce3d03010703420004"))
        let digest = try XCTUnwrap(fixture["sha256_hex"] as? String)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(isLowercaseHex(digest))
    }

    func testHostCertificateFixtureHasThreeDERCertificatesAndAPin() throws {
        let fixture = try object("internal/identity/testdata/host_certificates_v1.json")
        XCTAssertNotNil(fixture["description"] as? String)
        let digest = try XCTUnwrap(fixture["sha256_hex"] as? String)
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(isLowercaseHex(digest))
        for key in ["initial", "renewed", "expired"] {
            let text = try XCTUnwrap(fixture[key] as? String, key)
            let der = try XCTUnwrap(Data(base64Encoded: text), key)
            XCTAssertTrue(isSingleDERSequence(Array(der)), key)
        }
    }

    private func object(_ path: String) throws -> [String: Any] {
        let data = try RepositoryFixtures.data(path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
    }

    private func isLowercaseHex(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// One DER SEQUENCE whose definite length covers exactly the remaining bytes.
    private func isSingleDERSequence(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x30 else { return false }
        let first = Int(bytes[1])
        if first < 0x80 { return bytes.count == 2 + first }
        let count = first & 0x7F
        guard (1...3).contains(count), bytes.count >= 2 + count else { return false }
        let length = bytes[2..<(2 + count)].reduce(0) { (value: Int, byte: UInt8) in value << 8 | Int(byte) }
        return bytes.count == 2 + count + length
    }
}
