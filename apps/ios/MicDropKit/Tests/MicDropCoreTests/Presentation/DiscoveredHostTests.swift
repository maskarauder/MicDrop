import XCTest

@testable import MicDropCore

/// `DiscoveredHost` (`DiscoveryRecord.kt:4-12`, `MainActivity.kt:1013-1014`).
final class DiscoveredHostTests: XCTestCase {
    private let host = PresentationFixtures.pairedHost

    func testIdentifierNamesKeyAndEndpoint() {
        XCTAssertEqual(host.id, PresentationFixtures.pin + "/192.168.1.20:9844")
        let moved = DiscoveredHost(host: "192.168.1.21", port: 9844, keyHint: PresentationFixtures.pin)
        XCTAssertNotEqual(host.id, moved.id)
        XCTAssertEqual(Set([host, host, moved]).count, 2)
    }

    func testRowLabelsDistinguishTheSavedCandidate() throws {
        let saved = try PresentationFixtures.savedLink()
        XCTAssertEqual(host.rowLabel(saved: saved), "Saved Windows candidate \u{00B7} 192.168.1.20:9844")
        XCTAssertEqual(host.rowLabel(saved: nil), "Windows \u{00B7} abababababab \u{00B7} 192.168.1.20:9844")
        let other = try ConnectionLink.paired(
            host: "10.0.0.20", port: 9845, hostKey: PresentationFixtures.otherPin,
            clientKey: PresentationFixtures.client)
        XCTAssertEqual(host.rowLabel(saved: other), "Windows \u{00B7} abababababab \u{00B7} 192.168.1.20:9844")
        XCTAssertEqual(
            PresentationFixtures.unknownHost.rowLabel(saved: saved),
            "Windows \u{00B7} ffffffffffff \u{00B7} 192.168.1.30:9844")
    }

    func testMatchesOnlyTheExactSavedHostKey() throws {
        let saved = try PresentationFixtures.savedLink()
        XCTAssertTrue(host.matches(saved))
        let uppercase = DiscoveredHost(host: host.host, port: host.port, keyHint: PresentationFixtures.pin.uppercased())
        XCTAssertFalse(uppercase.matches(saved), "the hint must equal lowercase hex of the saved pin")
        let truncated = DiscoveredHost(
            host: host.host, port: host.port, keyHint: String(PresentationFixtures.pin.prefix(12)))
        XCTAssertFalse(truncated.matches(saved))
        XCTAssertFalse(DiscoveredHost(host: host.host, port: host.port, keyHint: "").matches(saved))
    }

    func testConnectionKeepsTheSavedClientKeyAtTheNewEndpoint() throws {
        let saved = try PresentationFixtures.savedLink()
        let moved = try host.connection(for: saved)
        XCTAssertEqual(moved.endpoint, try LANEndpoint(host: "192.168.1.20", port: 9844))
        XCTAssertEqual(moved.pinHex, PresentationFixtures.pin)
        XCTAssertEqual(moved.clientKey, PresentationFixtures.client)
        XCTAssertEqual(moved.expiresAt, 0)
        XCTAssertFalse(moved.isExpired(now: Int64.max))
        // Re-targeting the same address reproduces the saved record exactly.
        let same = DiscoveredHost(host: "10.0.0.20", port: 9845, keyHint: PresentationFixtures.pin)
        XCTAssertEqual(try same.connection(for: saved), saved)
    }

    func testAnUnvalidatedCandidateCannotProduceAnInvalidRecord() throws {
        let saved = try PresentationFixtures.savedLink()
        for (address, port) in [("8.8.8.8", 9844), ("192.168.1.20", 0), ("192.168.1.20", 65536), ("fc00::1", 9844)] {
            let candidate = DiscoveredHost(host: address, port: port, keyHint: PresentationFixtures.pin)
            XCTAssertTrue(candidate.matches(saved))
            XCTAssertThrowsError(try candidate.connection(for: saved), "\(address):\(port)") { error in
                XCTAssertEqual(error as? ConnectionLink.FormatError, .endpoint)
            }
        }
    }
}
