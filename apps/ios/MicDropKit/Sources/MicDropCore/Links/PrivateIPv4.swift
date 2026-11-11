import Foundation

/// A canonical private IPv4 address (Android `LanInvitation.validateEndpoint`, `LanInvitation.kt:73-80`; Go
/// `net.IP.IsPrivate()` + `To4()`, `internal/pairing/manager.go:115-117`).
///
/// Accepted: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, written in canonical dotted
/// decimal (no leading zeros, exactly four parts). Loopback, link-local, CGNAT and public
/// addresses are rejected.
public struct PrivateIPv4: Hashable, Sendable, CustomStringConvertible {
    /// The four address bytes in network order (used for the IP SAN check).
    public let octets: [UInt8]

    /// Canonical dotted form, e.g. `192.168.1.20`.
    public var description: String {
        octets.map { String($0) }.joined(separator: ".")
    }

    /// Validates `text` per -4:
    /// 1. full match `^[0-9]{1,3}(\.[0-9]{1,3}){3}$` (ASCII digits only);
    /// 2. equals its parts re-joined (rejects `192.168.001.20`);
    /// 3. each part 0…255;
    /// 4. private range only.
    /// Throws `ConnectionLink.FormatError.endpoint`.
    public init(validating text: String) throws {
        var parts: [Int] = []
        var current = 0
        var digits = 0
        for byte in text.utf8 {
            if byte == 0x2E {  // "."
                guard digits > 0, parts.count < 3 else {
                    throw ConnectionLink.FormatError.endpoint
                }
                parts.append(current)
                current = 0
                digits = 0
            } else if byte >= 0x30 && byte <= 0x39 {
                digits += 1
                guard digits <= 3 else {
                    throw ConnectionLink.FormatError.endpoint
                }
                current = current * 10 + Int(byte - 0x30)
            } else {
                throw ConnectionLink.FormatError.endpoint
            }
        }
        guard digits > 0 else {
            throw ConnectionLink.FormatError.endpoint
        }
        parts.append(current)
        guard parts.count == 4,
            parts.map({ String($0) }).joined(separator: ".") == text,
            parts.allSatisfy({ $0 <= 255 }),
            PrivateIPv4.isPrivate(parts)
        else {
            throw ConnectionLink.FormatError.endpoint
        }
        self.octets = parts.map { UInt8($0) }
    }

    /// Validates raw address bytes (4 bytes, private range). Throws
    /// `ConnectionLink.FormatError.endpoint`.
    public init(octets: [UInt8]) throws {
        guard octets.count == 4, PrivateIPv4.isPrivate(octets.map { Int($0) }) else {
            throw ConnectionLink.FormatError.endpoint
        }
        self.octets = octets
    }

    /// `10/8`, `172.16/12`, `192.168/16` (`LanInvitation.kt:77-78`).
    private static func isPrivate(_ parts: [Int]) -> Bool {
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }
}

/// A validated LAN control endpoint: private IPv4 host plus port 1…65535.
///
/// `ConnectionLink.validateEndpoint(host:port:)` is this initializer.
public struct LANEndpoint: Hashable, Sendable, CustomStringConvertible {
    public let host: PrivateIPv4
    public let port: UInt16

    /// `host:port`, as used in the saved-connection text and the HTTP `Host` header
    /// (`RemoteHttp.kt:47`, `SavedConnections.kt:58`).
    public var description: String { "\(host.description):\(port)" }

    /// Validates `host` and `port` in 1…65535. Throws `ConnectionLink.FormatError.endpoint`.
    public init(host: String, port: Int) throws {
        let address = try PrivateIPv4(validating: host)
        try self.init(host: address, port: port)
    }

    /// Validates `port` in 1…65535. Throws `ConnectionLink.FormatError.endpoint`.
    public init(host: PrivateIPv4, port: Int) throws {
        guard (1...65535).contains(port) else {
            throw ConnectionLink.FormatError.endpoint
        }
        self.host = host
        self.port = UInt16(port)
    }
}
