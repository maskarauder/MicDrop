import Foundation

/// 64-character lowercase hex pins: host key, client key and the v1/v2 leaf-certificate fingerprint (Android
/// `LanInvitation.pinBytes`, `LanInvitation.kt:81-84`; encoding `PublicIdentity.kt:24`; Go
/// `internal/pairing/manager.go:27`).
public enum HexPin {
    /// Decoded pin length in bytes (SHA-256).
    public static let byteCount = 32

    /// Encoded pin length in characters.
    public static let textLength = 64

    /// True when `text` fully matches `^[0-9a-f]{64}$` (uppercase is rejected).
    public static func isValid(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count == textLength else {
            return false
        }
        return bytes.allSatisfy { nibble($0) != nil }
    }

    /// Decodes `^[0-9a-f]{64}$` to 32 bytes. Throws `ConnectionLink.FormatError.pin`.
    public static func decode(_ text: String) throws -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count == textLength else {
            throw ConnectionLink.FormatError.pin
        }
        var output: [UInt8] = []
        output.reserveCapacity(byteCount)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                throw ConnectionLink.FormatError.pin
            }
            output.append(high << 4 | low)
            index += 2
        }
        return output
    }

    /// Lowercase hex, two characters per byte (`%02x`). Used for pins, fingerprints and digests.
    public static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Value of a lowercase hex digit, or nil.
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30  // 0-9
        case 0x61...0x66: return byte - 0x61 + 10  // a-f
        default: return nil
        }
    }
}
