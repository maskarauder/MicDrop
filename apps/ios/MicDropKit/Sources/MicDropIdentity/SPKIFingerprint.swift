import Crypto
import Foundation
import SwiftASN1
import X509

/// SHA-256 of the canonical DER `SubjectPublicKeyInfo` of a P-256 key: the paired "host key" and "client key" (Go
/// `internal/identity/identity.go:54-66`, Android `PublicIdentity.kt:14-23`).
///
/// Peer keys are always re-encoded through `P256.Signing.PublicKey.derRepresentation` before
/// hashing (Go re-encodes canonically with `x509.MarshalPKIXPublicKey`); raw SPKI bytes taken
/// from a certificate are never hashed directly.
public enum SPKIFingerprint {
    /// The fixed 26-byte DER prefix of every canonical P-256 SPKI
    /// (`3059301306072a8648ce3d020106082a8648ce3d030107034200`), followed by the 65-byte uncompressed point `04 || X ||
    /// Y`.
    public static let p256Prefix: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// Length of a canonical P-256 SPKI DER (26-byte prefix + 65-byte point).
    public static let p256SPKILength = 91

    /// 32-byte SHA-256 of `key.derRepresentation`.
    public static func digest(_ key: P256.Signing.PublicKey) -> [UInt8] {
        Array(SHA256.hash(data: key.derRepresentation))
    }

    /// 64 lowercase hex characters of `digest(key)` (the `client_key` / `host_key` text form,
    /// `PublicIdentity.kt:24`).
    public static func hex(_ key: P256.Signing.PublicKey) -> String {
        lowercaseHex(digest(key))
    }

    /// Fingerprint of a peer certificate's public key.
    ///
    /// Parses the DER certificate, requires a P-256 key and re-encodes it canonically.
    /// - Throws: `HostTrustFailure.malformed` when the DER does not parse,
    ///   `HostTrustFailure.unsupportedKey` for any non-P-256 key
    ///   (Android `CertificateException("P-256 identity required")`).
    public static func digest(certificateDER: [UInt8]) throws -> [UInt8] {
        let certificate: Certificate
        do {
            certificate = try Certificate(derEncoded: certificateDER)
        } catch let error as CertificateError where error.code == .unsupportedPublicKeyAlgorithm {
            throw HostTrustFailure.unsupportedKey
        } catch {
            throw HostTrustFailure.malformed
        }
        return try digest(certificate: certificate)
    }

    /// Fingerprint of an already parsed certificate's public key.
    /// - Throws: `HostTrustFailure.unsupportedKey` for any non-P-256 key.
    public static func digest(certificate: Certificate) throws -> [UInt8] {
        guard let key = P256.Signing.PublicKey(certificate.publicKey) else {
            throw HostTrustFailure.unsupportedKey
        }
        return digest(key)
    }

    /// Fingerprint of a bare DER `SubjectPublicKeyInfo` (fixture
    /// `internal/identity/testdata/host_public_key_v1.json`), re-encoded canonically first.
    /// - Throws: `HostTrustFailure.unsupportedKey` when the bytes are not a valid P-256 SPKI.
    public static func digest(subjectPublicKeyInfoDER: [UInt8]) throws -> [UInt8] {
        let key: P256.Signing.PublicKey
        do {
            key = try P256.Signing.PublicKey(derRepresentation: subjectPublicKeyInfoDER)
        } catch {
            throw HostTrustFailure.unsupportedKey
        }
        return digest(key)
    }

    /// `%02x` per byte, lowercase (`PublicIdentity.kt:24`; Go `hex.EncodeToString`).
    static func lowercaseHex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return text
    }
}
