import Crypto
import Foundation
import MicDropCore
import SwiftASN1
import X509

/// What the phone pins for a Windows host (Android `PublicIdentity.trust`).
public enum HostPin: Sendable, Hashable {
    /// Paired (v3): SHA-256 of the host's canonical P-256 SPKI DER (`host_key`), 32 bytes.
    case publicKey([UInt8])
    /// Legacy v1/v2: SHA-256 of the whole leaf certificate DER (`fingerprint`), 32 bytes.
    case certificate([UInt8])

    /// The 32 pinned bytes.
    public var bytes: [UInt8] {
        switch self {
        case .publicKey(let bytes), .certificate(let bytes):
            return bytes
        }
    }

    /// `true` for the paired SPKI pin (which also enables the KU/EKU/critical/self-signature checks).
    public var isPublicKey: Bool {
        if case .publicKey = self { return true }
        return false
    }
}

/// Why a host certificate was rejected (8 and).
///
/// Every case is a TLS failure of the Windows layer: `notYetValid`/`expired` map to the `certificate_time` problem
/// (`CERTIFICATE_TIME`), all others to `identity` (`TLS_IDENTITY`). The `description` mirrors Android's internal
/// exception messages; it is never shown to the user and contains no pins, addresses or secrets.
public enum HostTrustFailure: Error, Sendable, Hashable, CustomStringConvertible {
    /// Chain length is not exactly 1 (`PublicIdentity.kt:32`).
    case chainLength
    /// The leaf key is not ECDSA P-256 (`PublicIdentity.kt:15-21`).
    case unsupportedKey
    /// The SPKI (v3) or leaf-DER (v1/v2) SHA-256 differs from the pin (`PublicIdentity.kt:36`).
    case pinMismatch
    /// `now < notValidBefore` (Java `checkValidity`, `PublicIdentity.kt:37`).
    case notYetValid
    /// `now > notValidAfter` (both ends inclusive, Java `checkValidity`).
    case expired
    /// A critical extension outside `HostTrustVerifier.supportedCriticalExtensionOIDs`
    /// (`PublicIdentity.kt:39`).
    case unsupportedCriticalExtension
    /// KeyUsage present without digitalSignature (`PublicIdentity.kt:40`).
    case keyUsage
    /// ExtendedKeyUsage present without serverAuth or anyExtendedKeyUsage (`PublicIdentity.kt:41-44`).
    case extendedKeyUsage
    /// The certificate signature does not verify under its own public key (`PublicIdentity.kt:45`).
    case badSignature
    /// No SAN `iPAddress` equals the 4 bytes of the link host (`RemoteHttp.kt:35-39`; LAN uses the
    /// platform hostname verifier with the same verdict).
    case addressMismatch
    /// The DER does not parse as an X.509 certificate (or an extension used by a check is malformed).
    case malformed

    /// `true` for the validity-window failures (`CERTIFICATE_TIME`, problem `certificate_time`); every other case is
    /// problem `identity`.
    public var isCertificateTime: Bool {
        switch self {
        case .notYetValid, .expired:
            return true
        default:
            return false
        }
    }

    /// Android-equivalent internal message (diagnostics only, never user-visible).
    public var description: String {
        switch self {
        case .chainLength: return "One pinned host certificate required"
        case .unsupportedKey: return "P-256 identity required"
        case .pinMismatch: return "Host identity changed"
        case .notYetValid: return "Host certificate not yet valid"
        case .expired: return "Host certificate expired"
        case .unsupportedCriticalExtension: return "Unsupported certificate"
        case .keyUsage: return "Signing key required"
        case .extendedKeyUsage: return "Server certificate required"
        case .badSignature: return "Host certificate signature invalid"
        case .addressMismatch: return "Windows certificate address mismatch"
        case .malformed: return "Malformed host certificate"
        }
    }
}

/// Verifies the Windows host certificate inside the NIOSSL custom verification callback and again after the handshake.
/// Never consults system trust.
public struct HostTrustVerifier: Sendable {
    /// The pin from the connection link (`ConnectionLink.hostPin`).
    public let pin: HostPin
    /// The paired record's private LAN IPv4; its 4 octets must appear as a SAN `iPAddress`
    /// on LAN and through the remote tunnel alike (`RemoteHttp.kt:35-39`).
    public let host: PrivateIPv4

    public init(pin: HostPin, host: PrivateIPv4) {
        self.pin = pin
        self.host = host
    }

    /// Verifier for a parsed connection link: `pin = link.hostPin`, `host = link.endpoint.host`.
    public init(link: ConnectionLink) {
        self.init(pin: link.hostPin, host: link.endpoint.host)
    }

    /// Critical extension OIDs (dotted form) understood by Android/Conscrypt; any other critical extension rejects a
    /// paired host certificate. Must include SAN, KU, BC and EKU because real Go host certificates mark SAN/KU/BC
    /// critical.
    public static let supportedCriticalExtensionOIDs: Set<String> = [
        "2.16.840.1.113730.1.1",  // netscape-cert-type
        "2.5.29.15",  // keyUsage
        "2.5.29.17",  // subjectAltName
        "2.5.29.19",  // basicConstraints
        "2.5.29.30",  // nameConstraints
        "2.5.29.32",  // certificatePolicies
        "2.5.29.33",  // policyMappings
        "2.5.29.36",  // policyConstraints
        "2.5.29.37",  // extKeyUsage
        "2.5.29.54",  // inhibitAnyPolicy
    ]

    /// Verdict for the peer chain (leaf first, DER). `nil` = trusted.
    ///
    /// Order and outcome are normative (for `.publicKey`, for `.certificate`; Android `PublicIdentity.kt:31-46`
    /// followed by the IP SAN check of `RemoteHttp.kt:35-39`): the first failing step wins.
    ///
    /// Paired (`.publicKey`):
    /// 1. exactly one certificate (`.chainLength`);
    /// 2. the leaf parses (`.malformed`), its key is P-256 (`.unsupportedKey`) and the SHA-256 of
    ///    its canonical SPKI equals the pin in constant time (`.pinMismatch`);
    /// 3. `notValidBefore <= now <= notValidAfter`, both ends inclusive like Java
    ///    `checkValidity` (`.notYetValid` / `.expired`);
    /// 4. every critical extension is in `supportedCriticalExtensionOIDs`
    ///    (`.unsupportedCriticalExtension`);
    /// 5. KeyUsage, when present, has digitalSignature (`.keyUsage`);
    /// 6. ExtendedKeyUsage, when present, has serverAuth or anyExtendedKeyUsage (`.extendedKeyUsage`);
    /// 7. the signature verifies under the certificate's own key with ECDSA SHA-256/384/512
    ///    (`.badSignature`);
    /// 8. some SAN `iPAddress` is exactly the 4 bytes of `host`; no CN or DNS fallback
    ///    (`.addressMismatch`).
    ///
    /// Legacy (`.certificate`): steps 1, then SHA-256 of the whole leaf DER equals the pin in
    /// constant time (`.pinMismatch`), then the leaf parses (`.malformed`), then steps 3 and 8.
    /// No key-type, KU/EKU, critical-extension or signature checks (`PublicIdentity.kt:38`).
    ///
    /// A KeyUsage, ExtendedKeyUsage or SAN extension whose value does not decode is `.malformed`.
    public func verify(chainDER: [[UInt8]], now: Date) -> HostTrustFailure? {
        // Step 1 (`PublicIdentity.kt:32`).
        guard chainDER.count == 1 else {
            return .chainLength
        }
        let leaf = chainDER[0]

        let certificate: Certificate
        switch pin {
        case .publicKey(let expected):
            // Step 2 (`PublicIdentity.kt:34,36`): Android derives the SPKI fingerprint (P-256 only)
            // before comparing, so a non-P-256 leaf is "P-256 identity required", not a mismatch.
            switch Self.parse(leaf) {
            case .success(let parsed):
                certificate = parsed
            case .failure(let failure):
                return failure
            }
            let actual: [UInt8]
            do {
                actual = try SPKIFingerprint.digest(certificate: certificate)
            } catch {
                return .unsupportedKey
            }
            guard Self.constantTimeEqual(actual, expected) else {
                return .pinMismatch
            }
        case .certificate(let expected):
            // Step 2 for v1/v2 (`PublicIdentity.kt:35-36`): the pin covers the whole leaf DER.
            let actual = Array(SHA256.hash(data: leaf))
            guard Self.constantTimeEqual(actual, expected) else {
                return .pinMismatch
            }
            switch Self.parse(leaf) {
            case .success(let parsed):
                certificate = parsed
            case .failure(let failure):
                return failure
            }
        }

        // Step 3 (`PublicIdentity.kt:37`, Java `checkValidity`: both ends inclusive).
        if now < certificate.notValidBefore {
            return .notYetValid
        }
        if now > certificate.notValidAfter {
            return .expired
        }

        // Steps 4-7, paired only (`PublicIdentity.kt:38-46`).
        if pin.isPublicKey, let failure = Self.pairedUseFailure(certificate) {
            return failure
        }

        // Step 8 (LAN: the platform hostname verifier, `PairingClient.kt:81`; remote:
        // `RemoteHttp.kt:35-39`). Both accept only an `iPAddress` SAN equal to the link host.
        return Self.addressFailure(certificate, host: host)
    }

    /// Throwing form of `verify(chainDER:now:)`: throws the `HostTrustFailure` verdict.
    public func validate(chainDER: [[UInt8]], now: Date) throws {
        if let failure = verify(chainDER: chainDER, now: now) {
            throw failure
        }
    }

    /// swift-certificates parse of one DER certificate. A key algorithm swift-certificates does
    /// not model (for example DSA) is `.unsupportedKey`; every other parse error is `.malformed`.
    private static func parse(_ der: [UInt8]) -> Result<Certificate, HostTrustFailure> {
        do {
            return .success(try Certificate(derEncoded: der))
        } catch let error as CertificateError where error.code == .unsupportedPublicKeyAlgorithm {
            return .failure(.unsupportedKey)
        } catch {
            return .failure(.malformed)
        }
    }

    /// Steps 4-7 of for a paired host certificate, in order.
    private static func pairedUseFailure(_ certificate: Certificate) -> HostTrustFailure? {
        // Step 4 (`X509Certificate.hasUnsupportedCriticalExtension`, BoringSSL
        // `X509_supported_extension`).
        for item in certificate.extensions where item.critical {
            guard supportedCriticalExtensionOIDs.contains(item.oid.description) else {
                return .unsupportedCriticalExtension
            }
        }
        // Step 5 (`certificate.keyUsage?.getOrNull(0) == false`).
        do {
            if let usage = try certificate.extensions.keyUsage, !usage.digitalSignature {
                return .keyUsage
            }
        } catch {
            return .malformed
        }
        // Step 6: an EKU list without serverAuth (1.3.6.1.5.5.7.3.1) and without
        // anyExtendedKeyUsage (2.5.29.37.0) is rejected, including an empty list.
        do {
            if let usages = try certificate.extensions.extendedKeyUsage,
                !usages.contains(ExtendedKeyUsage.Usage.serverAuth),
                !usages.contains(ExtendedKeyUsage.Usage.any)
            {
                return .extendedKeyUsage
            }
        } catch {
            return .malformed
        }
        // Step 7 (`certificate.verify(certificate.publicKey)`): swift-certificates checks the
        // signature with the certificate's own algorithm (ECDSA SHA-256/384/512 for P-256).
        guard certificate.publicKey.isValidSignature(certificate.signature, for: certificate) else {
            return .badSignature
        }
        return nil
    }

    /// Step 8: some SAN `iPAddress` entry is exactly the 4 octets of `host`. A 16-byte
    /// (IPv4-mapped IPv6) entry, a DNS name or the subject CN never matches.
    private static func addressFailure(_ certificate: Certificate, host: PrivateIPv4) -> HostTrustFailure? {
        let names: SubjectAlternativeNames?
        do {
            names = try certificate.extensions.subjectAlternativeNames
        } catch {
            return .malformed
        }
        guard let names else {
            return .addressMismatch
        }
        for name in names {
            if case .ipAddress(let address) = name, address.bytes.elementsEqual(host.octets) {
                return nil
            }
        }
        return .addressMismatch
    }

    /// Java `MessageDigest.isEqual`: lengths differ → `false`; otherwise every byte is compared
    /// so the time does not depend on where the first difference is.
    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

extension ConnectionLink {
    /// The host pin this link requires: SPKI pin for paired (v3) links, leaf-certificate pin for legacy v1/v2. Declared
    /// here (not in MicDropCore) because `HostPin` lives in MicDropIdentity, which depends on MicDropCore.
    public var hostPin: HostPin {
        version == .paired ? .publicKey(pin) : .certificate(pin)
    }
}
