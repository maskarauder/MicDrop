import Foundation

/// Base64url codec for MicDrop links and tokens.
///
/// Decoding mirrors `java.util.Base64.getUrlDecoder()` (Android `PairingClient.kt:27`, `LanInvitation.kt:39,51`,
/// `RemoteConnection.kt:29`): URL-safe alphabet only, `=` padding optional but correct and terminal when present, a
/// final group of exactly one character rejected, non-zero trailing pad bits accepted. Encoding is always unpadded,
/// like Go `base64.RawURLEncoding` and Android `Base64.getUrlEncoder().withoutPadding()`.
public enum Base64URL {
    /// Decoding failure. Never carries the input text (it may be a credential).
    public enum Failure: Error, Equatable, Sendable {
        /// A byte outside `A–Z a–z 0–9 - _` (and not padding), including `+`, `/` and whitespace.
        case invalidCharacter
        /// Padding in the wrong place or with the wrong count (Java "wrong 4-byte ending unit").
        case invalidPadding
        /// A dangling single character in the final unit (Java "not enough valid bits").
        case invalidLength
        /// Bytes after a terminating padding sequence (Java "incorrect ending byte").
        case trailingBytes
    }

    private static let alphabet: [UInt8] =
        Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Maps a byte to its 6-bit value, or -1 when it is not in the URL-safe alphabet.
    private static let decodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in alphabet.enumerated() {
            table[Int(byte)] = Int8(index)
        }
        return table
    }()

    private static let padding: UInt8 = 0x3D  // "="

    /// Decodes with Java `Base64.getUrlDecoder()` semantics.
    public static func decode(_ text: Substring) throws -> [UInt8] {
        try decode(utf8: Array(text.utf8))
    }

    /// Decodes with Java `Base64.getUrlDecoder()` semantics.
    public static func decode(_ text: String) throws -> [UInt8] {
        try decode(utf8: Array(text.utf8))
    }

    /// Decodes UTF-8 bytes with Java `Base64.getUrlDecoder()` semantics. Any byte ≥ 0x80 is
    /// an invalid character (Java decodes the ISO-8859-1 bytes of the string, where every
    /// non-ASCII character is likewise outside the alphabet).
    ///
    /// Port of `java.util.Base64.Decoder.decode0` (non-MIME, URL alphabet).
    public static func decode(utf8 bytes: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count / 4 * 3 + 2)
        var bits: UInt32 = 0
        var shift = 18
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            index += 1
            let value = decodeTable[Int(byte)]
            if value < 0 {
                if byte == padding {
                    // "="    shift == 18: unnecessary padding
                    // "x="   shift == 12: dangling single character (rejected below)
                    // "xx="  shift == 6: requires a second "="
                    if shift == 18 {
                        throw Failure.invalidPadding
                    }
                    if shift == 6 {
                        guard index < count, bytes[index] == padding else {
                            throw Failure.invalidPadding
                        }
                        index += 1
                    }
                    break
                }
                throw Failure.invalidCharacter
            }
            bits |= UInt32(value) << UInt32(shift)
            shift -= 6
            if shift < 0 {
                output.append(UInt8(truncatingIfNeeded: bits >> 16))
                output.append(UInt8(truncatingIfNeeded: bits >> 8))
                output.append(UInt8(truncatingIfNeeded: bits))
                shift = 18
                bits = 0
            }
        }
        switch shift {
        case 6:
            output.append(UInt8(truncatingIfNeeded: bits >> 16))
        case 0:
            output.append(UInt8(truncatingIfNeeded: bits >> 16))
            output.append(UInt8(truncatingIfNeeded: bits >> 8))
        case 12:
            throw Failure.invalidLength
        default:
            break
        }
        if index < count {
            throw Failure.trailingBytes
        }
        return output
    }

    /// Unpadded base64url (Go `RawURLEncoding`, Android `getUrlEncoder().withoutPadding()`).
    public static func encodeUnpadded<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var pending = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            pending += 1
            if pending == 3 {
                output.append(alphabet[Int((buffer >> 18) & 0x3F)])
                output.append(alphabet[Int((buffer >> 12) & 0x3F)])
                output.append(alphabet[Int((buffer >> 6) & 0x3F)])
                output.append(alphabet[Int(buffer & 0x3F)])
                buffer = 0
                pending = 0
            }
        }
        if pending == 1 {
            buffer <<= 16
            output.append(alphabet[Int((buffer >> 18) & 0x3F)])
            output.append(alphabet[Int((buffer >> 12) & 0x3F)])
        } else if pending == 2 {
            buffer <<= 8
            output.append(alphabet[Int((buffer >> 18) & 0x3F)])
            output.append(alphabet[Int((buffer >> 12) & 0x3F)])
            output.append(alphabet[Int((buffer >> 6) & 0x3F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Remote role token rule (`RemoteConnection.kt:15-16`; Go `RawURLEncoding.Strict()` in
    /// `internal/rendezvous/config.go:44-47`): decodes to exactly 32 bytes and re-encodes unpadded to the identical
    /// text (canonical).
    public static func isCanonical32ByteToken(_ text: String) -> Bool {
        guard let bytes = try? decode(text), bytes.count == 32 else {
            return false
        }
        return encodeUnpadded(bytes) == text
    }

    /// Pairing secret / v1-v2 bearer token shape `^[A-Za-z0-9_-]{43}$` (`PairingClient.kt:38`, `LanInvitation.kt:69`;
    /// Go `manager.go:29`). Shape only: the value is not decoded (Android checks only the regex).
    public static func isUnpaddedToken(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count == 43 else {
            return false
        }
        return bytes.allSatisfy { decodeTable[Int($0)] >= 0 }
    }
}
