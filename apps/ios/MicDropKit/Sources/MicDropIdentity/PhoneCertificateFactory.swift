import Crypto
import Foundation
import SwiftASN1
import X509

/// Builds and inspects the phone's self-signed TLS client certificate (Android `AndroidIdentity.kt:31-43`).
///
/// The Windows host (`internal/pairing/tls.go:16-39`) accepts exactly one certificate that is
/// self-signed by its own ECDSA P-256 key, inside `NotBefore <= now < NotAfter`, with
/// digitalSignature in KeyUsage and clientAuth in ExtendedKeyUsage when present, a positive
/// serial and no unhandled critical extension. Subject, issuer and lifetime are not checked by
/// Windows; the host pins only the SPKI, so re-issuing from the same key keeps the pairing.
public enum PhoneCertificateFactory {
    /// Errors from inspecting a stored phone certificate (and from `make`'s self-check).
    public enum Failure: Error, Sendable, Hashable {
        /// The stored DER does not parse as an X.509 certificate.
        case malformed
        /// The certificate key is not P-256.
        case unsupportedKey
        /// The certificate SPKI differs from the signer's public key, or (in `make`) the signer's
        /// private-key operations do not verify under its public key.
        case keyMismatch
    }

    /// Why the Windows host would reject a phone certificate: Go `ClientKey` (`internal/pairing/tls.go:16-39`) plus Go
    /// x509 parsing. Returned by `hostRejection(of:now:)`; thrown by `make` when the freshly built certificate fails
    /// it.
    public enum HostRejection: Error, Sendable, Hashable, CustomStringConvertible {
        /// The DER does not parse (Go `x509.ParseCertificate` fails), or an extension that a rule
        /// reads does not decode.
        case malformed
        /// The key is not ECDSA P-256 (`identity.PublicKeyFingerprint`, `identity.go:55-58`).
        case unsupportedKey
        /// The serial number is zero (Go 1.23+ rejects negative serials while parsing; a negative
        /// serial does not parse here either, so it is `.malformed`).
        case serialNumber
        /// `now < NotBefore` (`tls.go:21`).
        case notYetValid
        /// `now >= NotAfter`: Go's `NotAfter` is exclusive (`tls.go:21`).
        case expired
        /// A critical extension other than keyUsage, basicConstraints or extKeyUsage (`tls.go:21`
        /// `UnhandledCriticalExtensions`; this subset of Go's handled set is deliberately stricter).
        case unhandledCriticalExtension
        /// KeyUsage has some bit set but not digitalSignature (`tls.go:21`).
        case keyUsage
        /// ExtendedKeyUsage lists usages but neither clientAuth nor anyExtendedKeyUsage
        /// (`tls.go:24-34`; stricter than Go, which ignores OIDs it does not know).
        case extendedKeyUsage
        /// The signature does not verify under the certificate's own key (`tls.go:35`).
        case badSignature

        /// Internal text (diagnostics only, never user-visible).
        public var description: String {
            switch self {
            case .malformed: return "Malformed phone certificate"
            case .unsupportedKey: return "P-256 phone key required"
            case .serialNumber: return "Positive phone certificate serial required"
            case .notYetValid: return "Phone certificate not yet valid"
            case .expired: return "Phone certificate expired"
            case .unhandledCriticalExtension: return "Unhandled critical phone certificate extension"
            case .keyUsage: return "Phone certificate signing usage required"
            case .extendedKeyUsage: return "Phone certificate client usage required"
            case .badSignature: return "Phone certificate is not self-signed by its key"
            }
        }
    }

    /// Critical extensions a phone certificate may carry (dotted OIDs): keyUsage,
    /// basicConstraints, extKeyUsage. Go handles each of them unconditionally.
    public static let hostHandledCriticalExtensionOIDs: Set<String> = [
        "2.5.29.15",  // keyUsage
        "2.5.29.19",  // basicConstraints
        "2.5.29.37",  // extKeyUsage
    ]

    /// Subject and issuer common name: `CN=MicDrop iPhone` (Android `CN=MicDrop Android`).
    public static let commonName = "MicDrop iPhone"
    /// `notValidBefore = now − 300 s` (`AndroidIdentity.kt:40`).
    public static let notBeforeSkew: TimeInterval = 300
    /// `notValidAfter = now + 10 × 365 days` = 315 360 000 s (`AndroidIdentity.kt:41`).
    public static let lifetime: TimeInterval = 315_360_000
    /// Re-issue from the same key when within 30 days of `notValidAfter`.
    public static let reissueMargin: TimeInterval = 30 * 86_400

    /// DER of a new self-signed v3 certificate for `signer`: serial `01`, subject = issuer = `CN=MicDrop iPhone`,
    /// validity `now − 300 s … now + 315 360 000 s`, `ecdsaWithSHA256`, extensions
    /// `Critical(KeyUsage(digitalSignature))` and non-critical `ExtendedKeyUsage([clientAuth])`, no SAN.
    ///
    /// Before returning, the result is checked the way Windows will check it (verify after create, like Go's
    /// `internal/identity/store.go:176-182`): it must re-parse, carry exactly `signer.publicKey` and pass
    /// `hostRejection(of:now:)` at `now`; and one `signSHA256` probe over the TBS bytes must verify under
    /// `signer.publicKey` with SHA-256, which proves the TLS CertificateVerify contract of (the signer hashes the
    /// message itself).
    /// - Throws: swift-certificates / swift-asn1 errors while building; `Failure.keyMismatch` when
    ///   `certificatePrivateKey` or `signSHA256` does not belong to `publicKey`; `HostRejection`
    ///   when Windows would reject the certificate; any error thrown by `signSHA256`.
    public static func make(signer: any PhoneSigner, now: Date) throws -> [UInt8] {
        let name = try DistinguishedName {
            CommonName(PhoneCertificateFactory.commonName)
        }
        var extensions = Certificate.Extensions()
        try extensions.append(Certificate.Extension(KeyUsage(digitalSignature: true), critical: true))
        let usages: [ExtendedKeyUsage.Usage] = [.clientAuth]
        try extensions.append(Certificate.Extension(ExtendedKeyUsage(usages), critical: false))
        let serial: [UInt8] = [0x01]
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: serial),
            publicKey: Certificate.PublicKey(signer.publicKey),
            notValidBefore: now.addingTimeInterval(-notBeforeSkew),
            notValidAfter: now.addingTimeInterval(lifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: signer.certificatePrivateKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = serializer.serializedBytes

        // A certificate private key that is not the signer's key yields a signature that does not
        // verify under the embedded public key.
        try verifyMatches(der, signer: signer)
        if let rejection = hostRejection(of: der, now: now) {
            if rejection == .badSignature {
                throw Failure.keyMismatch
            }
            throw rejection
        }
        let probe = Data(certificate.tbsCertificateBytes)
        let signature = try signer.signSHA256(probe)
        guard signer.publicKey.isValidSignature(signature, for: probe) else {
            throw Failure.keyMismatch
        }
        return der
    }

    /// `nil` when the Windows host would accept `certificateDER` as the phone's client
    /// certificate at `now`, else the first failing rule in Go's order (`tls.go:16-39`): parse,
    /// serial, validity (`NotBefore <= now < NotAfter`), critical extensions, KeyUsage,
    /// ExtendedKeyUsage, self-signature, P-256 key. Rules that are stricter than Go are noted on
    /// `HostRejection`; nothing Go rejects is accepted here.
    public static func hostRejection(of certificateDER: [UInt8], now: Date) -> HostRejection? {
        let certificate: Certificate
        do {
            certificate = try parse(certificateDER)
        } catch Failure.unsupportedKey {
            return .unsupportedKey
        } catch {
            return .malformed
        }
        guard certificate.serialNumber.bytes.contains(where: { $0 != 0 }) else {
            return .serialNumber
        }
        if now < certificate.notValidBefore {
            return .notYetValid
        }
        if now >= certificate.notValidAfter {
            return .expired
        }
        for item in certificate.extensions where item.critical {
            guard hostHandledCriticalExtensionOIDs.contains(item.oid.description) else {
                return .unhandledCriticalExtension
            }
        }
        do {
            // Go: `c.KeyUsage != 0 && c.KeyUsage&x509.KeyUsageDigitalSignature == 0`; an
            // all-zero KeyUsage counts as absent.
            if let usage = try certificate.extensions.keyUsage, usage != KeyUsage(), !usage.digitalSignature {
                return .keyUsage
            }
            if let usages = try certificate.extensions.extendedKeyUsage, !usages.isEmpty,
                !usages.contains(ExtendedKeyUsage.Usage.clientAuth),
                !usages.contains(ExtendedKeyUsage.Usage.any)
            {
                return .extendedKeyUsage
            }
        } catch {
            return .malformed
        }
        guard certificate.publicKey.isValidSignature(certificate.signature, for: certificate) else {
            return .badSignature
        }
        guard P256.Signing.PublicKey(certificate.publicKey) != nil else {
            return .unsupportedKey
        }
        return nil
    }

    /// The stored certificate's validity window.
    /// - Throws: `Failure.malformed`.
    public static func validity(of certificateDER: [UInt8]) throws -> (notBefore: Date, notAfter: Date) {
        let certificate = try parse(certificateDER)
        return (certificate.notValidBefore, certificate.notValidAfter)
    }

    /// `true` when the stored certificate must be re-issued from the same key: `now` is before `notValidBefore`, or
    /// `now >= notValidAfter − 30 days` (recommended deviation).
    /// - Throws: `Failure.malformed` (the identity is then unreadable, never silently replaced).
    public static func needsReissue(_ certificateDER: [UInt8], now: Date) throws -> Bool {
        let window = try validity(of: certificateDER)
        return now < window.notBefore || now >= window.notAfter.addingTimeInterval(-reissueMargin)
    }

    /// Requires the stored certificate's canonical SPKI fingerprint to equal the signer's (`load(expecting:)`;
    /// `AndroidIdentity.kt:59`).
    /// - Throws: `Failure.malformed`, `.unsupportedKey` or `.keyMismatch`.
    public static func verifyMatches(_ certificateDER: [UInt8], signer: any PhoneSigner) throws {
        let certificate = try parse(certificateDER)
        guard let key = P256.Signing.PublicKey(certificate.publicKey) else {
            throw Failure.unsupportedKey
        }
        guard SPKIFingerprint.digest(key) == SPKIFingerprint.digest(signer.publicKey) else {
            throw Failure.keyMismatch
        }
    }

    private static func parse(_ certificateDER: [UInt8]) throws -> Certificate {
        do {
            return try Certificate(derEncoded: certificateDER)
        } catch let error as CertificateError where error.code == .unsupportedPublicKeyAlgorithm {
            throw Failure.unsupportedKey
        } catch {
            throw Failure.malformed
        }
    }
}
