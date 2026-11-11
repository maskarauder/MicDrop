import Foundation
import MicDropTestSupport
import XCTest

/// Shape of the public loopback TLS fixture that the transport tests read in place from the Android test tree. It is a
/// public test key: it is read only by tests and is never bundled in the app.
final class TransportFixtureContractTests: XCTestCase {
    private let path = "apps/android/pairing-check/src/androidTest/assets/public-test-tls.json"

    func testPublicTestTLSFixtureHasADERCertificateAndPKCS8Key() throws {
        let data = try RepositoryFixtures.data(path)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
        let warning = try XCTUnwrap(fixture["warning"] as? String)
        XCTAssertTrue(warning.hasPrefix("PUBLIC TEST KEY."), warning)
        for key in ["certificate", "private_key_pkcs8"] {
            let text = try XCTUnwrap(fixture[key] as? String, key)
            let der = try XCTUnwrap(Data(base64Encoded: text), key)
            XCTAssertTrue(isSingleDERSequence(Array(der)), key)
        }
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
