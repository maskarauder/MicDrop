// Phone identity creation, loading and certificate re-issue (Android `AndroidIdentity.ensure`/`manager`,
// `AndroidIdentity.kt:27-77`).

import Foundation
import MicDropCore
import MicDropIdentity
import Security

extension CredentialVault {
    /// The Keychain identity record, UTF-8 JSON in this key order:
    /// `{"version":1,"protection":"secure_enclave"|"keychain_software","key":"<base64>", "certificate":"<base64
    /// DER>","created_at":<unix s>}`. `key` is the SE `dataRepresentation` or the software `rawRepresentation`; base64
    /// is standard padded Foundation base64. Never log or export a record.
    struct IdentityRecord: Equatable, Sendable {
        static let version: Int64 = 1
        static let keys: Set<String> = ["version", "protection", "key", "certificate", "created_at"]
        /// Generous bound for a 91-byte SPKI certificate plus an SE blob (rejects garbage early).
        static let maxBytes = 16_384

        var protection: IdentityProtection
        var key: Data
        var certificateDER: [UInt8]
        var createdAt: Int64

        /// Canonical encoding. All values are base64 / raw-value / integer text, so no JSON
        /// escaping is needed.
        func encoded() -> Data {
            let json =
                "{\"version\":\(Self.version),\"protection\":\"\(protection.rawValue)\","
                + "\"key\":\"\(key.base64EncodedString())\","
                + "\"certificate\":\"\(Data(certificateDER).base64EncodedString())\","
                + "\"created_at\":\(createdAt)}"
            return Data(json.utf8)
        }

        /// Strict decoding: exactly the five keys, integer `version == 1`, a known `protection`, canonical non-empty
        /// base64 for `key` and `certificate`, integer `created_at >= 0`. Any violation →
        /// `PhoneIdentityError.unreadable` (never replaced).
        static func decode(_ data: Data) throws -> IdentityRecord {
            guard data.count <= maxBytes else { throw PhoneIdentityError.unreadable }
            do {
                let object = try StrictJSONObject(utf8: [UInt8](data))
                guard Set(object.keys) == keys else { throw PhoneIdentityError.unreadable }
                let recordVersion = try object.integer("version")
                let protectionText = try object.string("protection")
                let keyText = try object.string("key")
                let certificateText = try object.string("certificate")
                let createdAt = try object.integer("created_at")
                guard recordVersion == version,
                    let protection = IdentityProtection(rawValue: protectionText),
                    let key = canonicalBase64(keyText),
                    let certificate = canonicalBase64(certificateText),
                    createdAt >= 0
                else { throw PhoneIdentityError.unreadable }
                return IdentityRecord(
                    protection: protection, key: key,
                    certificateDER: [UInt8](certificate), createdAt: createdAt)
            } catch {
                throw PhoneIdentityError.unreadable
            }
        }

        private static func canonicalBase64(_ text: String) -> Data? {
            guard !text.isEmpty, let data = Data(base64Encoded: text),
                data.base64EncodedString() == text
            else { return nil }
            return data
        }
    }

    /// A loaded identity plus the wall-clock window in which it may be returned from the cache
    /// without re-reading the Keychain: `notBefore <= now < reuseUntil` where
    /// `reuseUntil = notAfter − reissueMargin`.
    struct CachedIdentity: Sendable {
        var identity: PhoneIdentity
        var notBefore: Date
        var reuseUntil: Date
    }

    /// Re-issue a certificate this close to `notAfter` ("within 30 days of NotAfter"); the single definition is
    /// `PhoneCertificateFactory.reissueMargin` (MicDropIdentity).
    static let reissueMargin: TimeInterval = PhoneCertificateFactory.reissueMargin
}

extension CredentialVault.Core {
    /// `ensure()`: create only when the item is absent; when present, load it (failures throw, never replace). After
    /// creating, re-read and verify (Go's verify-after-publish discipline, `internal/identity/store.go:176-182`).
    func ensureIdentityUnlocked() throws -> PhoneIdentity {
        let present: Bool
        do {
            present = try identityItem.read() != nil
        } catch KeychainItem.Failure.status(let status) {
            throw PhoneIdentityError.keychain(status)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        if present { return try loadStoredIdentityUnlocked(expecting: nil) }
        let fingerprint = try createIdentityUnlocked()
        cached = nil
        return try loadStoredIdentityUnlocked(expecting: fingerprint)
    }

    /// `manager(expected)`: cached identity when inside its reuse window, else a full Keychain load verifying
    /// `expected`.
    func loadIdentityUnlocked(expecting fingerprint: String) throws -> PhoneIdentity {
        let current = now()
        if let cached, cached.identity.fingerprint == fingerprint,
            current >= cached.notBefore, current < cached.reuseUntil
        {
            return cached.identity
        }
        return try loadStoredIdentityUnlocked(expecting: fingerprint)
    }

    /// Reads and decodes the record, reconstructs the signer, verifies fingerprints
    /// (`expected == nil` skips only the expected-key comparison), re-issues the certificate when
    /// needed, updates the cache and returns the identity.
    func loadStoredIdentityUnlocked(expecting expected: String?) throws -> PhoneIdentity {
        let data: Data
        do {
            guard let stored = try identityItem.read() else { throw PhoneIdentityError.absent }
            data = stored
        } catch let error as PhoneIdentityError {
            throw error
        } catch KeychainItem.Failure.status(let status) {
            throw PhoneIdentityError.keychain(status)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        var record = try CredentialVault.IdentityRecord.decode(data)
        let signer = try makeSigner(for: record)
        let fingerprint = try verifiedFingerprint(record: record, signer: signer)
        if let expected, expected != fingerprint { throw PhoneIdentityError.mismatch }
        let window = try reissueIfNeeded(&record, signer: signer)
        // MicDropIdentity's validating init re-checks certificate SPKI == signer key and derives the
        // same fingerprint from the signer.
        let identity: PhoneIdentity
        do {
            identity = try PhoneIdentity(
                certificateDER: record.certificateDER,
                protection: record.protection, signer: signer)
        } catch PhoneCertificateFactory.Failure.keyMismatch {
            throw PhoneIdentityError.mismatch
        } catch {
            throw PhoneIdentityError.unreadable
        }
        guard identity.fingerprint == fingerprint else { throw PhoneIdentityError.mismatch }
        cached = CredentialVault.CachedIdentity(
            identity: identity, notBefore: window.notBefore,
            reuseUntil: window.notAfter.addingTimeInterval(-CredentialVault.reissueMargin))
        return identity
    }

    /// Creates and stores a new identity, returning its fingerprint ("Key", "Persistence", "Certificate"; Android
    /// `AndroidIdentity.ensure`, `AndroidIdentity.kt:28-43`).
    ///
    /// Secure Enclave when `secureEnclaveAvailable()`, else a software P-256 key whose
    /// `rawRepresentation` is stored (Simulator, unusual hardware). A Secure Enclave that is
    /// available but fails to generate is an error, never a silent software fallback. The
    /// certificate is `PhoneCertificateFactory.make` (`CN=MicDrop iPhone`, serial 1,
    /// `now − 300 s … now + 315 360 000 s`, critical KU digitalSignature, EKU clientAuth).
    /// The item is added, never overwritten, so creation is atomic: `errSecDuplicateItem` →
    /// `.unreadable`; other Keychain statuses → `.keychain(status)`.
    func createIdentityUnlocked() throws -> String {
        let created = now()
        let fresh = try makeNewSigner()
        let certificate: [UInt8]
        do {
            certificate = try PhoneCertificateFactory.make(signer: fresh.signer, now: created)
        } catch {
            throw PhoneIdentityError.creationFailed
        }
        let record = CredentialVault.IdentityRecord(
            protection: fresh.protection, key: fresh.key, certificateDER: certificate,
            createdAt: max(0, Int64(created.timeIntervalSince1970.rounded(.down))))
        let encoded = record.encoded()
        // A record the strict decoder would reject could never be loaded again; never store it.
        guard encoded.count <= CredentialVault.IdentityRecord.maxBytes else {
            throw PhoneIdentityError.creationFailed
        }
        do {
            try identityItem.add(encoded)
        } catch KeychainItem.Failure.status(let status) where status == errSecDuplicateItem {
            throw PhoneIdentityError.unreadable
        } catch KeychainItem.Failure.status(let status) {
            throw PhoneIdentityError.keychain(status)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        return fresh.signer.fingerprintHex
    }

    /// A new signing key and the record fields that persist it.
    private func makeNewSigner() throws -> (signer: any PhoneSigner, protection: IdentityProtection, key: Data) {
        #if canImport(CryptoKit)
            if secureEnclaveAvailable() {
                let enclave: SecureEnclaveSigner
                do {
                    enclave = try SecureEnclaveSigner.generate()
                } catch {
                    throw PhoneIdentityError.creationFailed
                }
                return (enclave, .secureEnclave, enclave.dataRepresentation)
            }
        #endif
        let software = SoftwareSigner.generate()
        return (software, .keychainSoftware, software.rawRepresentation)
    }

    /// Reconstructs the signer from the record's `key` for its `protection`: `secure_enclave` →
    /// `SecureEnclaveSigner(dataRepresentation:)` (the SE-wrapped blob is usable only on this device);
    /// `keychain_software` → `SoftwareSigner(rawRepresentation:)`. Any failure → `.unreadable` (never replaced).
    func makeSigner(for record: CredentialVault.IdentityRecord) throws -> any PhoneSigner {
        switch record.protection {
        case .secureEnclave:
            #if canImport(CryptoKit)
                do {
                    return try SecureEnclaveSigner(dataRepresentation: record.key)
                } catch {
                    throw PhoneIdentityError.unreadable
                }
            #else
                throw PhoneIdentityError.unreadable
            #endif
        case .keychainSoftware:
            do {
                return try SoftwareSigner(rawRepresentation: record.key)
            } catch {
                throw PhoneIdentityError.unreadable
            }
        }
    }

    /// Verifies certificate SPKI fingerprint == signer public-key fingerprint and returns it (load table;
    /// `AndroidIdentity.kt:59`). The certificate key is re-encoded canonically before hashing
    /// (`SPKIFingerprint.digest(certificateDER:)`). A certificate that does not parse or carries a non-P-256 key →
    /// `.unreadable`; differing keys → `.mismatch`.
    func verifiedFingerprint(record: CredentialVault.IdentityRecord, signer: any PhoneSigner) throws -> String {
        let keyFingerprint = signer.fingerprintHex
        let certificateFingerprint: String
        do {
            certificateFingerprint = try HexPin.encode(SPKIFingerprint.digest(certificateDER: record.certificateDER))
        } catch {
            throw PhoneIdentityError.unreadable
        }
        guard keyFingerprint == certificateFingerprint else { throw PhoneIdentityError.mismatch }
        return keyFingerprint
    }

    /// Returns the certificate validity window after re-issuing when needed: when `now < notBefore` or `now >= notAfter
    /// − 30 days` (`PhoneCertificateFactory.needsReissue`), build a new certificate from the **same key** and update
    /// the Keychain item (read-back verified); the fingerprint is unchanged because Windows pins the SPKI. `created_at`
    /// keeps the identity's creation time. Parse or issue failure → `.unreadable`; a Keychain status →
    /// `.keychain(status)`; any other write failure → `.unreadable`.
    func reissueIfNeeded(
        _ record: inout CredentialVault.IdentityRecord,
        signer: any PhoneSigner
    ) throws -> (notBefore: Date, notAfter: Date) {
        let current = now()
        let window: (notBefore: Date, notAfter: Date)
        let expiring: Bool
        do {
            window = try PhoneCertificateFactory.validity(of: record.certificateDER)
            expiring = try PhoneCertificateFactory.needsReissue(record.certificateDER, now: current)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        guard expiring else { return window }
        var renewed = record
        let renewedWindow: (notBefore: Date, notAfter: Date)
        do {
            renewed.certificateDER = try PhoneCertificateFactory.make(signer: signer, now: current)
            renewedWindow = try PhoneCertificateFactory.validity(of: renewed.certificateDER)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        do {
            try identityItem.write(renewed.encoded())
        } catch KeychainItem.Failure.status(let status) {
            throw PhoneIdentityError.keychain(status)
        } catch {
            throw PhoneIdentityError.unreadable
        }
        record = renewed
        return renewedWindow
    }
}
