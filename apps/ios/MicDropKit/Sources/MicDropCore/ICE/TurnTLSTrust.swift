import Foundation

/// Result of one TURN/TLS platform-trust fallback check (Kotlin `TurnTlsTrustResult`, `TurnTlsTrust.kt:12-15`).
/// Raw values are the fixed `last_result` labels the host accepts (`internal/diagnostics/tls_verification.go`).
public enum TurnTLSTrustResult: String, Sendable {
    /// No chain has been checked in this session.
    case notChecked = "not_checked"
    case trusted = "trusted"
    /// Out-of-bounds or malformed input, rejected before platform trust is consulted.
    case invalidCertificate = "invalid_certificate"
    /// Platform trust evaluated the chain and did not trust it.
    case rejected = "rejected"
    /// Platform trust could not evaluate the chain.
    case unavailable = "unavailable"
}

/// Session totals of the fallback callback (`TurnTlsTrust.kt:17-22`): checked chains, not TLS connections or
/// media packets. Zero checks can mean that WebRTC's bundled roots sufficed or that no TURN/TLS connection
/// reached certificate validation.
public struct TurnTLSTrustSnapshot: Sendable, Equatable {
    public let checks: Int
    public let failures: Int
    public let lastResult: TurnTLSTrustResult

    public init(checks: Int, failures: Int, lastResult: TurnTLSTrustResult) {
        self.checks = checks
        self.failures = failures
        self.lastResult = lastResult
    }

    /// The report's `tls_certificate_verification` object, Kotlin key order (`TurnTlsTrust.kt:18-19`). The
    /// host decodes exactly these members (`tls_verification.go:6-25`, `DisallowUnknownFields`).
    public func json() -> DiagnosticJSON {
        .object([
            (key: "version", value: .int(1)),
            (key: "checks", value: .int(Int64(checks))),
            (key: "failures", value: .int(Int64(failures))),
            (key: "last_result", value: .string(lastResult.rawValue)),
        ])
    }

    /// Copy-report lines (`TurnTlsTrust.kt:20-21`, with the "iPhone" substitution).
    public func text() -> String {
        "iPhone TURN/TLS trust fallback: checks=\(checks) · failures=\(failures) · last=\(lastResult.rawValue)\n"
            + "Certificate-chain checks do not prove hostname validation, TURN allocation or media delivery."
    }
}

/// Thread-safe, saturating counters of one session's fallback checks (`TurnTlsTrust.kt:33-35, 69-75`).
/// The app's certificate verifier records from WebRTC's network thread; the session worker takes snapshots.
/// Every snapshot satisfies the host rules: checks == 0 iff `not_checked`, failures ≤ checks ≤ 1 000 000, and
/// a result other than `trusted` implies failures > 0.
public final class TurnTLSTrustCounters: @unchecked Sendable {
    /// Host bound for `checks` and `failures`.
    public static let maxCount = 1_000_000

    private let lock = NSLock()
    private var checks: Int
    private var failures: Int
    private var lastResult: TurnTLSTrustResult

    public convenience init() {
        self.init(checks: 0, failures: 0, lastResult: .notChecked)
    }

    /// Seeded state (tests).
    init(checks: Int, failures: Int, lastResult: TurnTLSTrustResult) {
        self.checks = checks
        self.failures = failures
        self.lastResult = lastResult
    }

    /// Counts one check and returns whether the chain is trusted (the verifier's callback result).
    /// `.notChecked` is not a check result; it is ignored and returns false.
    @discardableResult
    public func record(_ result: TurnTLSTrustResult) -> Bool {
        guard result != .notChecked else { return false }
        lock.lock()
        defer { lock.unlock() }
        checks = min(checks + 1, Self.maxCount)
        if result != .trusted { failures = min(failures + 1, Self.maxCount) }
        lastResult = result
        return result == .trusted
    }

    public func snapshot() -> TurnTLSTrustSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TurnTLSTrustSnapshot(checks: checks, failures: failures, lastResult: lastResult)
    }
}

/// Input bounds and strict framing applied before platform trust (`TurnTlsTrust.kt:38-53`). Counts and sizes
/// only; certificate contents are never inspected beyond the outer DER header.
public enum TurnTLSTrustInput {
    public static let maxCertificates = 16
    /// Sum of all certificate sizes.
    public static let maxTotalBytes: Int64 = 1_048_576

    /// 1…16 non-empty certificates of at most 1 MiB in total, each exactly one minimally encoded DER
    /// SEQUENCE with no trailing bytes. iOS cannot re-encode a certificate, so this framing check
    /// approximates Android's `input.available() == 0 && encoded.contentEquals(der)`.
    public static func isAcceptable(_ chain: [Data]) -> Bool {
        guard (1...maxCertificates).contains(chain.count), !chain.contains(where: \.isEmpty),
            chain.reduce(Int64(0), { $0 + Int64($1.count) }) <= maxTotalBytes
        else { return false }
        return chain.allSatisfy(isSingleSequence)
    }

    /// Tag 0x30, then a short-form length or a minimal long form of one to four octets (no leading zero
    /// octet; one octet only for lengths ≥ 0x80). Indefinite length (0x80) and longer forms are rejected,
    /// and header plus length must equal the element size.
    static func isSingleSequence(_ der: Data) -> Bool {
        let start = der.startIndex
        guard der.count >= 2, der[start] == 0x30 else { return false }
        let first = der[start + 1]
        guard first >= 0x80 else { return 2 + Int(first) == der.count }
        let octets = Int(first & 0x7f)
        guard (1...4).contains(octets), der.count >= 2 + octets, der[start + 2] != 0 else { return false }
        var length = 0
        for offset in 0..<octets { length = length << 8 | Int(der[start + 2 + offset]) }
        guard octets > 1 || length >= 0x80 else { return false }
        return 2 + octets + length == der.count
    }
}
