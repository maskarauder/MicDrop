import Foundation
import XCTest

@testable import MicDropCore

/// TURN/TLS trust labels, counters, wire shape and input bounds (`TurnTlsTrust.kt:12-75`; host rules
/// `internal/diagnostics/tls_verification.go:13-25` and `internal/session/tls_diagnostics_test.go`).
final class TurnTLSTrustTests: XCTestCase {
    /// Deterministic generator for the invariant sweep (SplitMix64).
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// Go `TLSVerification.valid()` (`tls_verification.go:13-25`).
    private static func hostAccepts(_ snapshot: TurnTLSTrustSnapshot) -> Bool {
        guard snapshot.json()["version"] == .int(1), (0...1_000_000).contains(snapshot.checks),
            (0...snapshot.checks).contains(snapshot.failures)
        else { return false }
        if snapshot.checks == 0 { return snapshot.lastResult == .notChecked }
        return snapshot.lastResult != .notChecked && (snapshot.lastResult == .trusted || snapshot.failures > 0)
    }

    /// A minimal DER SEQUENCE of exactly `size` bytes with a three-octet length (0x10000…0xFFFFFF) and zero
    /// contents.
    private static func largeSequence(size: Int) -> Data {
        let length = size - 5
        let octets = [16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }
        return Data([0x30, 0x83] + octets) + Data(count: length)
    }

    /// Public test certificates (P-256 leaf and its intermediate), copied from the app tests'
    /// `TurnTLSTestCertificates` `ecServer` and `ecIntermediate`; used here for framing only.
    private static let leaf = """
        MIIB0jCCAXigAwIBAgICUgMwCgYIKoZIzj0EAwIwLDEqMCgGA1UEAwwhTWljRHJvcCBUVVJOIHRl
        c3QgRUMgaW50ZXJtZWRpYXRlMB4XDTI2MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowJjEkMCIG
        A1UEAwwbTWljRHJvcCBUVVJOIHRlc3QgRUMgc2VydmVyMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcD
        QgAE9fQ/EHnlneZDBziMbCq8RjFT1Gh5AuyyMkoJfzsfuSbiN5LzrIf+fb0FpoPxYujwgNFtxaY7
        +sReQjffLaZpBaOBjzCBjDAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAK
        BggrBgEFBQcDATAXBgNVHREEEDAOggx0dXJuLmludmFsaWQwHQYDVR0OBBYEFJ2+PUrdUZt5fLQm
        tTtu/uFhG12eMB8GA1UdIwQYMBaAFBz+cjUb/Cdg+nLzOaf2Id2xluQtMAoGCCqGSM49BAMCA0gA
        MEUCIQDrlEbyoxqldXXPthbNujwKzi/SJhTjEVOebCdQa8sCZwIgL6eD3tzEkzO6Gm5UdDIHml9z
        y6jHOGBoDoBSKdP1uOA=
        """
    private static let intermediate = """
        MIIBpTCCAUygAwIBAgICUgIwCgYIKoZIzj0EAwIwJDEiMCAGA1UEAwwZTWljRHJvcCBUVVJOIHRl
        c3QgRUMgcm9vdDAeFw0yNTAxMDEwMDAwMDBaFw00MDAxMDEwMDAwMDBaMCwxKjAoBgNVBAMMIU1p
        Y0Ryb3AgVFVSTiB0ZXN0IEVDIGludGVybWVkaWF0ZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
        BP8Ro+vOzPqEZixcRaALuLBIl4bJr81NKIZdyqH0QKY91sAOvjRVzLHPsEJgxQXMtc27yZoQEex0
        zGWA/udHKsGjZjBkMBIGA1UdEwEB/wQIMAYBAf8CAQAwDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQW
        BBQc/nI1G/wnYPpy8zmn9iHdsZbkLTAfBgNVHSMEGDAWgBQQA8U7K/BqYO/T+RTbzRU1ynADlDAK
        BggqhkjOPQQDAgNHADBEAiAcHRQ3bOl3wqVqqHeNZhnR1ryT0MY9GCOhEoO7+FEXRgIgTH2UfnzC
        YQXJ6R3uJZUJw5JF5Fg6Qm3OXhIIz+rD9pY=
        """

    private static func der(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
    }

    func testResultLabelsAreTheHostLabels() {
        XCTAssertEqual(TurnTLSTrustResult.notChecked.rawValue, "not_checked")
        XCTAssertEqual(TurnTLSTrustResult.trusted.rawValue, "trusted")
        XCTAssertEqual(TurnTLSTrustResult.invalidCertificate.rawValue, "invalid_certificate")
        XCTAssertEqual(TurnTLSTrustResult.rejected.rawValue, "rejected")
        XCTAssertEqual(TurnTLSTrustResult.unavailable.rawValue, "unavailable")
    }

    func testSnapshotJSONIsTheHostExtensionShape() {
        let json = TurnTLSTrustSnapshot(checks: 1, failures: 0, lastResult: .trusted).json()
        XCTAssertEqual(
            String(decoding: json.encoded(), as: UTF8.self),
            #"{"version":1,"checks":1,"failures":0,"last_result":"trusted"}"#)
        XCTAssertEqual(json.keys, ["version", "checks", "failures", "last_result"])
    }

    func testTextNamesTheIPhoneFallbackAndWhatItDoesNotProve() {
        XCTAssertEqual(
            TurnTLSTrustSnapshot(checks: 3, failures: 1, lastResult: .rejected).text(),
            "iPhone TURN/TLS trust fallback: checks=3 \u{00B7} failures=1 \u{00B7} last=rejected\n"
                + "Certificate-chain checks do not prove hostname validation, TURN allocation or media delivery.")
    }

    func testCountersStartUncheckedAndCountEveryNonTrustedResultAsFailure() {
        let counters = TurnTLSTrustCounters()
        XCTAssertEqual(counters.snapshot(), TurnTLSTrustSnapshot(checks: 0, failures: 0, lastResult: .notChecked))
        XCTAssertTrue(counters.record(.trusted))
        XCTAssertFalse(counters.record(.rejected))
        XCTAssertEqual(counters.snapshot(), TurnTLSTrustSnapshot(checks: 2, failures: 1, lastResult: .rejected))
        XCTAssertFalse(counters.record(.invalidCertificate))
        XCTAssertFalse(counters.record(.unavailable))
        XCTAssertEqual(counters.snapshot(), TurnTLSTrustSnapshot(checks: 4, failures: 3, lastResult: .unavailable))
        XCTAssertFalse(counters.record(.notChecked), "not a check result")
        XCTAssertEqual(counters.snapshot(), TurnTLSTrustSnapshot(checks: 4, failures: 3, lastResult: .unavailable))
    }

    func testCountersSaturateAtTheHostBound() {
        let counters = TurnTLSTrustCounters(checks: 1_000_000, failures: 999_999, lastResult: .trusted)
        XCTAssertFalse(counters.record(.rejected))
        XCTAssertEqual(
            counters.snapshot(), TurnTLSTrustSnapshot(checks: 1_000_000, failures: 1_000_000, lastResult: .rejected))
        XCTAssertTrue(counters.record(.trusted))
        XCTAssertEqual(
            counters.snapshot(), TurnTLSTrustSnapshot(checks: 1_000_000, failures: 1_000_000, lastResult: .trusted))
    }

    func testEverySnapshotOfARandomSequenceIsAcceptedByTheHost() {
        var generator = SeededGenerator(state: 0x4D69_6344_726F_7054)
        let results: [TurnTLSTrustResult] = [.trusted, .invalidCertificate, .rejected, .unavailable]
        let counters = TurnTLSTrustCounters()
        XCTAssertTrue(Self.hostAccepts(counters.snapshot()))
        var invalid = 0
        for _ in 0..<10_000 {
            counters.record(results.randomElement(using: &generator) ?? .trusted)
            if !Self.hostAccepts(counters.snapshot()) { invalid += 1 }
        }
        XCTAssertEqual(invalid, 0)
        XCTAssertEqual(counters.snapshot().checks, 10_000)
    }

    func testConcurrentRecordsAreAllCounted() {
        let counters = TurnTLSTrustCounters()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            counters.record(index.isMultiple(of: 2) ? .trusted : .rejected)
        }
        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.checks, 1_000)
        XCTAssertEqual(snapshot.failures, 500)
        XCTAssertTrue(Self.hostAccepts(snapshot))
    }

    func testInputBoundsAndFramingRejectMalformedChains() throws {
        let server = try Self.der(Self.leaf)
        // Framed elements: only the size bound rejects them.
        let oversized = Self.largeSequence(size: 1_048_577)
        let remainder = Self.largeSequence(size: 1_048_577 - server.count)
        XCTAssertTrue(TurnTLSTrustInput.isSingleSequence(oversized))
        XCTAssertTrue(TurnTLSTrustInput.isSingleSequence(remainder))
        let rejected: [(String, [Data])] = [
            ("empty chain", []),
            ("empty certificate", [Data()]),
            ("17 certificates", Array(repeating: Data([0x30, 0x00]), count: 17)),
            ("over 1 MiB", [oversized]),
            ("over 1 MiB in total", [server, remainder]),
            ("not a SEQUENCE", [Data([0x01, 0x02, 0x03])]),
            ("trailing byte", [server + Data([0x00])]),
            ("two SEQUENCEs", [Data([0x30, 0x00, 0x30, 0x00])]),
            ("truncated", [Data([0x30, 0x05, 0x00])]),
            ("indefinite length", [Data([0x30, 0x80, 0x00, 0x00])]),
            ("five length octets", [Data([0x30, 0x85, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])]),
            ("non-minimal one-octet length", [Data([0x30, 0x81, 0x05]) + Data(count: 5)]),
            ("leading zero length octet", [Data([0x30, 0x82, 0x00, 0x05]) + Data(count: 5)]),
            ("valid leaf, malformed second", [server, Data([0x01])]),
        ]
        for (name, chain) in rejected {
            XCTAssertFalse(TurnTLSTrustInput.isAcceptable(chain), name)
        }
    }

    func testInputAcceptsFramedCertificatesWithinBounds() throws {
        let server = try Self.der(Self.leaf)
        let intermediate = try Self.der(Self.intermediate)
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([server]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([intermediate]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([server, intermediate]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([Data([0x30, 0x00])]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable(Array(repeating: Data([0x30, 0x00]), count: 16)))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([Data([0x30, 0x81, 0x80]) + Data(count: 0x80)]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([Data([0x30, 0x82, 0x01, 0x00]) + Data(count: 0x100)]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([Self.largeSequence(size: 1_048_576)]))
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([server, Self.largeSequence(size: 1_048_576 - server.count)]))
        // Slices keep their own indices.
        XCTAssertTrue(TurnTLSTrustInput.isAcceptable([(Data([0xFF]) + server).dropFirst()]))
    }
}
