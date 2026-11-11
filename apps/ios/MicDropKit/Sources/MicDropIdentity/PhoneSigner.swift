import Crypto
import Foundation
import X509

/// The phone's durable P-256 signing key.
///
/// Two implementations: `SoftwareSigner` (here; Simulator/CI fallback, raw key stored in the
/// Keychain by the app) and the app target's `SecureEnclaveSigner` (CryptoKit
/// `SecureEnclave.P256.Signing.PrivateKey`). Android counterpart: the Keystore alias
/// `micdrop.pairing.identity.v1` (`AndroidIdentity.kt:23-43`).
public protocol PhoneSigner: Sendable {
    /// The public half; its SPKI SHA-256 is this phone's `client_key`.
    var publicKey: P256.Signing.PublicKey { get }

    /// ECDSA P-256 over **SHA-256 of `message`** (the key hashes; callers pass the unhashed TLS 1.3 CertificateVerify
    /// content). `PhoneTLSKey` (MicDropTransport) returns `signature.derRepresentation` to BoringSSL. May block for
    /// milliseconds (Secure Enclave): never call it on a NIO event loop.
    func signSHA256(_ message: Data) throws -> P256.Signing.ECDSASignature

    /// The same key wrapped for swift-certificates, used to self-sign the phone certificate
    /// (`PhoneCertificateFactory.make`).
    var certificatePrivateKey: Certificate.PrivateKey { get }
}

extension PhoneSigner {
    /// `SPKIFingerprint.hex(publicKey)`: the 64-hex `client_key` of this phone.
    public var fingerprintHex: String {
        SPKIFingerprint.hex(publicKey)
    }
}

/// Software P-256 key (fallback when `SecureEnclave.isAvailable == false`, and the signer used by every Linux/CI
/// loopback test). The app stores `rawRepresentation` in the identity Keychain item with protection
/// `keychain_software`.
public struct SoftwareSigner: PhoneSigner {
    /// The wrapped swift-crypto key.
    public let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Restores a key from its 32-byte scalar (`P256.Signing.PrivateKey.rawRepresentation`).
    public init<Bytes: ContiguousBytes>(rawRepresentation: Bytes) throws {
        self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// A fresh random key.
    public static func generate() -> SoftwareSigner {
        SoftwareSigner(privateKey: P256.Signing.PrivateKey(compactRepresentable: false))
    }

    /// The 32-byte scalar to persist (Keychain only; never log or export).
    public var rawRepresentation: Data {
        privateKey.rawRepresentation
    }

    public var publicKey: P256.Signing.PublicKey {
        privateKey.publicKey
    }

    /// `P256.Signing.PrivateKey.signature(for:)` hashes with SHA-256 internally.
    public func signSHA256(_ message: Data) throws -> P256.Signing.ECDSASignature {
        try privateKey.signature(for: message)
    }

    public var certificatePrivateKey: Certificate.PrivateKey {
        Certificate.PrivateKey(privateKey)
    }
}
