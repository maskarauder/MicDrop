import Foundation

/// One validated LAN discovery candidate (`DiscoveryRecord.kt:4-12`).
///
/// Every field is an untrusted hint from DNS-SD. Discovery never supplies trust: a candidate can only
/// re-target the endpoint of an existing v3 saved pairing whose host key equals `keyHint`.
public struct DiscoveredHost: Hashable, Sendable, Identifiable {
    /// Canonical private IPv4 address (validated by `LANEndpoint(host:port:)`).
    public let host: String
    /// TCP port 1...65535.
    public let port: Int
    /// The advertised TXT `id`: 64 lowercase hex of the host SPKI SHA-256. A hint, never a pin.
    public let keyHint: String

    public init(host: String, port: Int, keyHint: String) {
        self.host = host
        self.port = port
        self.keyHint = keyHint
    }

    public var id: String { "\(keyHint)/\(host):\(port)" }

    /// Thrown by `connection(for:)` when the candidate does not match the saved pairing
    /// (Kotlin `require(matches(saved))`).
    public enum ConnectionError: Error, Sendable, Equatable {
        case notSavedHost
    }

    /// `saved?.version == 3 && keyHint == hex(saved.fingerprint)` (`DiscoveryRecord.kt:5-6`).
    public func matches(_ saved: ConnectionLink?) -> Bool {
        guard let saved, saved.version == .paired else { return false }
        return keyHint == HexPin.encode(saved.pin)
    }

    /// A LAN paired record for this endpoint with the saved host key and client key (`DiscoveryRecord.kt:8-11`). Always
    /// a LAN record: no remote wrapper, version 3, empty token (discovery is LAN-only). The saved value is not mutated;
    /// the store remembers the new address only after authenticated Playing.
    public func connection(for saved: ConnectionLink) throws -> ConnectionLink {
        guard matches(saved) else { throw ConnectionError.notSavedHost }
        return try ConnectionLink.paired(
            host: host, port: port,
            hostKey: HexPin.encode(saved.pin), clientKey: saved.clientKey)
    }

    /// Discovered-row button label (`MainActivity.kt:1013-1014`, `strings.xml:59-60`). `saved` is the parsed saved
    /// connection captured when the discovery view was rendered. The key prefix is the first 12 characters of `keyHint`
    /// (Kotlin `take(12)`; the same for the ASCII hints `DiscoveryRecord.parse` produces).
    public func rowLabel(saved: ConnectionLink?) -> String {
        matches(saved)
            ? Strings.discoveredSaved(host: host, port: port)
            : Strings.discoveredHost(keyPrefix: String(keyHint.prefix(12)), host: host, port: port)
    }
}
