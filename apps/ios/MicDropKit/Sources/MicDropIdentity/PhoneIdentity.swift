import Crypto
import Foundation

/// Which key store backs the phone identity; recorded verbatim as `protection` in the identity Keychain item JSON.
///
/// Placement note: declared in MicDropIdentity (not the app) because MicDropTransport's
/// `ControlTLS.setup(for:identity:)` takes a `PhoneIdentity`; the app target owns only the Keychain-backed
/// loading/creation (`CredentialVault`).
public enum IdentityProtection: String, Codable, Sendable {
    case secureEnclave = "secure_enclave"
    case keychainSoftware = "keychain_software"
}

/// A loaded, self-consistent phone identity: the signing key and its self-signed certificate. Built by the app's
/// `CredentialVault`; consumed by `ControlTLS` (client certificate + `PhoneTLSKey`) and by pairing (`client_key`).
public struct PhoneIdentity: Sendable {
    /// `client_key`: 64 lowercase hex of the SHA-256 of the signer's canonical SPKI DER.
    public let fingerprint: String
    /// The phone's self-signed leaf certificate (DER), the only certificate sent to Windows.
    public let certificateDER: [UInt8]
    /// Secure Enclave or software key.
    public let protection: IdentityProtection
    /// The private key operations.
    public let signer: any PhoneSigner

    /// Validating initializer: requires `certificateDER` to parse and carry exactly the signer's P-256 public key
    /// (`load(expecting:)`); `fingerprint` is derived from the signer. The caller still compares `fingerprint` with the
    /// saved record's `client_key`.
    /// - Throws: `PhoneCertificateFactory.Failure`.
    public init(certificateDER: [UInt8], protection: IdentityProtection, signer: any PhoneSigner) throws {
        try PhoneCertificateFactory.verifyMatches(certificateDER, signer: signer)
        self.fingerprint = signer.fingerprintHex
        self.certificateDER = certificateDER
        self.protection = protection
        self.signer = signer
    }
}
