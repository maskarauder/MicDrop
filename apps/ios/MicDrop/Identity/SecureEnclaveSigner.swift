// Secure Enclave phone signer ("Key").
//
// Android counterpart: the non-exportable AndroidKeyStore EC key (`AndroidIdentity.kt:31-43`).
// `SecureEnclave.*` exists only in CryptoKit, so this type lives in the app target behind
// `#if canImport(CryptoKit)`. On Apple platforms swift-crypto's `Crypto` re-exports CryptoKit
// (`CRYPTO_IN_SWIFTPM` without `FORCE_BUILD_API`), so `P256.Signing.PublicKey` here is the same
// type MicDropIdentity's `PhoneSigner` uses.

#if canImport(CryptoKit)
    import CryptoKit
    import Foundation
    import MicDropIdentity
    import Security
    import X509

    /// A `PhoneSigner` backed by a Secure Enclave P-256 key.
    ///
    /// The key is created with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `.privateKeyUsage` only (no
    /// `.userPresence`/biometry), so signing never prompts and works while the device is locked after first unlock
    /// (cross-spec requirement). The value is immutable; the wrapped key handle is safe to use from any thread.
    public struct SecureEnclaveSigner: PhoneSigner, @unchecked Sendable {
        public let privateKey: SecureEnclave.P256.Signing.PrivateKey

        public init(privateKey: SecureEnclave.P256.Signing.PrivateKey) {
            self.privateKey = privateKey
        }

        /// Restores the key from the SE-wrapped blob stored in the identity record (`"key"` field). The blob is usable
        /// only on this device; never log or export it.
        public init(dataRepresentation: Data) throws {
            self.privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
        }

        /// `SecureEnclave.isAvailable` (false in the Simulator and on unusual hardware; the vault then falls back to a
        /// software key).
        public static var isAvailable: Bool { SecureEnclave.isAvailable }

        /// Generates a new SE key: `compactRepresentable: false`, access control `SecAccessControlCreateWithFlags(nil,
        /// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)`.
        public static func generate() throws -> SecureEnclaveSigner {
            var error: Unmanaged<CFError>?
            guard
                let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
                )
            else {
                if let error { throw error.takeRetainedValue() as Error }
                throw PhoneIdentityError.unreadable
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
            return SecureEnclaveSigner(privateKey: key)
        }

        /// SE-wrapped key blob for the Keychain identity record.
        public var dataRepresentation: Data { privateKey.dataRepresentation }

        // MARK: PhoneSigner

        public var publicKey: P256.Signing.PublicKey { privateKey.publicKey }

        /// Signs `message` (the unhashed TLS 1.3 CertificateVerify content, or certificate TBS bytes): CryptoKit hashes
        /// with SHA-256 internally. Blocks for milliseconds; callers on a NIO event loop must hop to a background queue
        /// first.
        public func signSHA256(_ message: Data) throws -> P256.Signing.ECDSASignature {
            try privateKey.signature(for: message)
        }

        /// swift-certificates wrapper used to self-sign the phone certificate.
        public var certificatePrivateKey: Certificate.PrivateKey { Certificate.PrivateKey(privateKey) }
    }
#endif
