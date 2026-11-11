import Crypto
import Foundation
import MicDropCore
import MicDropIdentity
import SwiftASN1
import X509
import XCTest

/// host certificate verification. Ports `PairingIdentityTest.kt:25-43`
/// (`trustsRenewedPublicKeyAndRejectsWrongPinAndExpiredCertificate`) against the Go fixture
/// `internal/identity/testdata/host_certificates_v1.json`, plus every step and its order.
final class HostTrustVerifierTests: XCTestCase {
    private let lan = try! PrivateIPv4(validating: "192.168.1.20")
    private let other = try! PrivateIPv4(validating: "10.0.0.20")

    private func paired(_ pin: [UInt8], host: PrivateIPv4? = nil) -> HostTrustVerifier {
        HostTrustVerifier(pin: .publicKey(pin), host: host ?? lan)
    }

    // MARK: - Fixture (PairingIdentityTest.kt:25-43)

    func testFixtureTrustsInitialAndRenewedLeafWithTheSamePinnedKey() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertNotEqual(fixture.initial, fixture.renewed)
        XCTAssertNil(paired(fixture.pin).verify(chainDER: [fixture.initial], now: TestTime.inside))
        // `renewed` carries SAN 10.0.0.20 (same key, new leaf).
        XCTAssertNil(paired(fixture.pin, host: other).verify(chainDER: [fixture.renewed], now: TestTime.inside))
    }

    func testFixtureRejectsZeroPinExpiredCertificateAndEmptyChain() throws {
        let fixture = try HostCertificateFixture.load()
        let zero = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(paired(zero).verify(chainDER: [fixture.initial], now: TestTime.inside), .pinMismatch)
        XCTAssertEqual(paired(fixture.pin).verify(chainDER: [fixture.expired], now: TestTime.inside), .expired)
        XCTAssertEqual(paired(fixture.pin).verify(chainDER: [], now: TestTime.inside), .chainLength)
    }

    func testFixtureSANMustMatchTheLinkHost() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertEqual(
            paired(fixture.pin, host: other).verify(chainDER: [fixture.initial], now: TestTime.inside),
            .addressMismatch)
        XCTAssertEqual(
            paired(fixture.pin).verify(chainDER: [fixture.renewed], now: TestTime.inside), .addressMismatch)
    }

    func testFixtureValidityWindowIsInclusiveAtBothEnds() throws {
        let fixture = try HostCertificateFixture.load()
        let verifier = paired(fixture.pin)
        XCTAssertNil(verifier.verify(chainDER: [fixture.expired], now: TestTime.fixtureStart))
        XCTAssertNil(verifier.verify(chainDER: [fixture.expired], now: TestTime.expiredEnd))
        XCTAssertEqual(
            verifier.verify(chainDER: [fixture.expired], now: TestTime.fixtureStart.addingTimeInterval(-1)),
            .notYetValid)
        XCTAssertEqual(
            verifier.verify(chainDER: [fixture.expired], now: TestTime.expiredEnd.addingTimeInterval(1)), .expired)
        XCTAssertNil(verifier.verify(chainDER: [fixture.initial], now: TestTime.fixtureEnd))
        XCTAssertEqual(
            verifier.verify(chainDER: [fixture.initial], now: TestTime.fixtureEnd.addingTimeInterval(1)), .expired)
    }

    func testChainOfTwoIsRejectedEvenWhenTheLeafIsTrusted() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertEqual(
            paired(fixture.pin).verify(chainDER: [fixture.initial, fixture.renewed], now: TestTime.inside),
            .chainLength)
        XCTAssertEqual(
            paired(fixture.pin).verify(chainDER: [fixture.initial, fixture.initial], now: TestTime.inside),
            .chainLength)
    }

    func testPinOfWrongLengthNeverMatches() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertEqual(
            paired(Array(fixture.pin.prefix(31))).verify(chainDER: [fixture.initial], now: TestTime.inside),
            .pinMismatch)
        XCTAssertEqual(
            paired(fixture.pin + [0]).verify(chainDER: [fixture.initial], now: TestTime.inside), .pinMismatch)
        XCTAssertEqual(paired([]).verify(chainDER: [fixture.initial], now: TestTime.inside), .pinMismatch)
    }

    // MARK: - Legacy v1/v2

    func testLegacyPinIsTheSHA256OfTheWholeLeaf() throws {
        let fixture = try HostCertificateFixture.load()
        let leafPin = TestHex.sha256(fixture.initial)
        XCTAssertEqual(
            TestHex.encode(leafPin), "1d2c62b3db1e754b1799d05082d980ffada94300516b28260017ab252ea372b8")
        let legacy = HostTrustVerifier(pin: .certificate(leafPin), host: lan)
        XCTAssertNil(legacy.verify(chainDER: [fixture.initial], now: TestTime.inside))
        // Same key, different leaf: a certificate pin does not follow key renewals.
        XCTAssertEqual(
            HostTrustVerifier(pin: .certificate(leafPin), host: other)
                .verify(chainDER: [fixture.renewed], now: TestTime.inside),
            .pinMismatch)
        // The SPKI pin is not a certificate pin.
        XCTAssertEqual(
            HostTrustVerifier(pin: .certificate(fixture.pin), host: lan)
                .verify(chainDER: [fixture.initial], now: TestTime.inside),
            .pinMismatch)
        XCTAssertEqual(legacy.verify(chainDER: [], now: TestTime.inside), .chainLength)
    }

    func testLegacyChecksValidityAndAddress() throws {
        let fixture = try HostCertificateFixture.load()
        let expiredPin = TestHex.sha256(fixture.expired)
        XCTAssertEqual(
            HostTrustVerifier(pin: .certificate(expiredPin), host: lan)
                .verify(chainDER: [fixture.expired], now: TestTime.inside),
            .expired)
        XCTAssertEqual(
            HostTrustVerifier(pin: .certificate(expiredPin), host: lan)
                .verify(chainDER: [fixture.expired], now: TestTime.fixtureStart.addingTimeInterval(-1)),
            .notYetValid)
        XCTAssertEqual(
            HostTrustVerifier(pin: .certificate(TestHex.sha256(fixture.initial)), host: other)
                .verify(chainDER: [fixture.initial], now: TestTime.inside),
            .addressMismatch)
    }

    func testLegacySkipsKeyTypeUsageCriticalAndSignatureChecks() throws {
        // `PublicIdentity.kt:38`: only paired links run steps 4-7; v1/v2 pin the exact leaf bytes.
        let key = P384.Signing.PrivateKey()
        let stranger = P384.Signing.PrivateKey()
        let der = try TestCertificates.make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(stranger),
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: [
                TestCertificates.opaque([1, 3, 6, 1, 4, 1, 55555, 1], critical: true),
                try TestCertificates.keyUsage(KeyUsage(keyCertSign: true)),
                try TestCertificates.extendedKeyUsage([.clientAuth]),
                try TestCertificates.ipSAN([TestCertificates.lanAddress], critical: false),
            ])
        let legacy = HostTrustVerifier(pin: .certificate(TestHex.sha256(der)), host: lan)
        XCTAssertNil(legacy.verify(chainDER: [der], now: TestTime.now))
    }

    func testLegacyMalformedLeafWithMatchingPinIsMalformed() {
        let garbage: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x01]
        let legacy = HostTrustVerifier(pin: .certificate(TestHex.sha256(garbage)), host: lan)
        XCTAssertEqual(legacy.verify(chainDER: [garbage], now: TestTime.now), .malformed)
    }

    // MARK: - Paired steps 2-8 with generated certificates

    func testGoShapedHostCertificateIsTrusted() throws {
        // identity.go:79-101: empty subject, critical SAN/KU/BasicConstraints, EKU serverAuth,
        // 128-bit random serial + 1, now − 5 min … now + 24 h.
        let key = P256.Signing.PrivateKey()
        let der = try TestCertificates.selfSigned(
            key,
            notBefore: TestTime.now.addingTimeInterval(-300),
            notAfter: TestTime.now.addingTimeInterval(86_400),
            serial: [0x5F] + [UInt8](repeating: 0xA7, count: 15))
        let parsed = try Certificate(derEncoded: der)
        XCTAssertEqual(parsed.subject, DistinguishedName())
        XCTAssertEqual(
            parsed.extensions.filter { $0.critical }.map { $0.oid.description }.sorted(),
            ["2.5.29.15", "2.5.29.17", "2.5.29.19"])
        XCTAssertNil(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now))
    }

    func testNonP256LeafIsUnsupportedKeyBeforeThePinCompare() throws {
        let key = P384.Signing.PrivateKey()
        let der = try TestCertificates.make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(key),
            signatureAlgorithm: .ecdsaWithSHA384,
            extensions: try TestCertificates.goHostExtensions())
        XCTAssertEqual(
            paired([UInt8](repeating: 0, count: 32)).verify(chainDER: [der], now: TestTime.now),
            .unsupportedKey)
    }

    func testEd25519LeafIsUnsupportedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let der = try TestCertificates.make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(key),
            signatureAlgorithm: .ed25519,
            extensions: try TestCertificates.goHostExtensions())
        XCTAssertEqual(
            paired([UInt8](repeating: 0, count: 32)).verify(chainDER: [der], now: TestTime.now),
            .unsupportedKey)
    }

    func testMalformedLeafIsMalformed() {
        let verifier = paired([UInt8](repeating: 0, count: 32))
        XCTAssertEqual(verifier.verify(chainDER: [[]], now: TestTime.now), .malformed)
        XCTAssertEqual(verifier.verify(chainDER: [[0x30, 0x00]], now: TestTime.now), .malformed)
        XCTAssertEqual(verifier.verify(chainDER: [[UInt8](repeating: 0xFF, count: 64)], now: TestTime.now), .malformed)
    }

    func testTruncatedFixtureLeafIsMalformed() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertEqual(
            paired(fixture.pin).verify(chainDER: [Array(fixture.initial.dropLast())], now: TestTime.inside),
            .malformed)
    }

    func testEverySupportedCriticalExtensionIsAccepted() throws {
        let key = P256.Signing.PrivateKey()
        // The parsed ones are real values; the others are only checked by OID (BoringSSL's
        // `X509_supported_extension` list) and carry an empty SEQUENCE.
        let opaqueOIDs: [ASN1ObjectIdentifier] = [
            [2, 16, 840, 1, 113730, 1, 1], [2, 5, 29, 30], [2, 5, 29, 32], [2, 5, 29, 33], [2, 5, 29, 36],
            [2, 5, 29, 54],
        ]
        var extensions = try TestCertificates.goHostExtensions()
        extensions[1] = try TestCertificates.extendedKeyUsage([.serverAuth], critical: true)
        for oid in opaqueOIDs {
            extensions.append(TestCertificates.opaque(oid, critical: true, value: [0x30, 0x00]))
        }
        let der = try TestCertificates.selfSigned(key, extensions: extensions)
        let critical = Set(
            try Certificate(derEncoded: der).extensions.filter { $0.critical }.map { $0.oid.description })
        XCTAssertEqual(critical, HostTrustVerifier.supportedCriticalExtensionOIDs)
        XCTAssertNil(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now))
    }

    func testUnknownCriticalExtensionIsRejectedButNonCriticalIsIgnored() throws {
        let key = P256.Signing.PrivateKey()
        let unknown: ASN1ObjectIdentifier = [1, 3, 6, 1, 4, 1, 55555, 7]
        let critical = try TestCertificates.selfSigned(
            key,
            extensions: try TestCertificates.goHostExtensions() + [TestCertificates.opaque(unknown, critical: true)])
        XCTAssertEqual(
            paired(TestCertificates.pin(of: key)).verify(chainDER: [critical], now: TestTime.now),
            .unsupportedCriticalExtension)
        let plain = try TestCertificates.selfSigned(
            key,
            extensions: try TestCertificates.goHostExtensions() + [TestCertificates.opaque(unknown, critical: false)])
        XCTAssertNil(paired(TestCertificates.pin(of: key)).verify(chainDER: [plain], now: TestTime.now))
        // Critical CRL distribution points and authority key identifier are not in Conscrypt's list.
        for oid: ASN1ObjectIdentifier in [[2, 5, 29, 31], [2, 5, 29, 35], [2, 5, 29, 14]] {
            let der = try TestCertificates.selfSigned(
                key,
                extensions: try TestCertificates.goHostExtensions()
                    + [TestCertificates.opaque(oid, critical: true, value: [0x30, 0x00])])
            XCTAssertEqual(
                paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now),
                .unsupportedCriticalExtension, oid.description)
        }
    }

    func testKeyUsageWithoutDigitalSignatureIsRejected() throws {
        let key = P256.Signing.PrivateKey()
        var extensions = try TestCertificates.goHostExtensions()
        extensions[0] = try TestCertificates.keyUsage(KeyUsage(keyEncipherment: true, keyCertSign: true))
        let der = try TestCertificates.selfSigned(key, extensions: extensions)
        XCTAssertEqual(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now), .keyUsage)
        // Absent KeyUsage is accepted (`keyUsage?.getOrNull(0)` is null).
        extensions.remove(at: 0)
        let absent = try TestCertificates.selfSigned(key, extensions: extensions)
        XCTAssertNil(paired(TestCertificates.pin(of: key)).verify(chainDER: [absent], now: TestTime.now))
        // digitalSignature among other bits is accepted.
        extensions.insert(try TestCertificates.keyUsage(KeyUsage(digitalSignature: true, keyCertSign: true)), at: 0)
        let combined = try TestCertificates.selfSigned(key, extensions: extensions)
        XCTAssertNil(paired(TestCertificates.pin(of: key)).verify(chainDER: [combined], now: TestTime.now))
    }

    func testExtendedKeyUsageMustAllowServerAuth() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = paired(TestCertificates.pin(of: key))
        func certificate(_ usages: [ExtendedKeyUsage.Usage]?) throws -> [UInt8] {
            var extensions = try TestCertificates.goHostExtensions()
            if let usages {
                extensions[1] = try TestCertificates.extendedKeyUsage(usages)
            } else {
                extensions.remove(at: 1)
            }
            return try TestCertificates.selfSigned(key, extensions: extensions)
        }
        XCTAssertEqual(
            verifier.verify(chainDER: [try certificate([.clientAuth])], now: TestTime.now), .extendedKeyUsage)
        XCTAssertEqual(
            verifier.verify(chainDER: [try certificate([.codeSigning, .emailProtection])], now: TestTime.now),
            .extendedKeyUsage)
        XCTAssertEqual(
            verifier.verify(
                chainDER: [try certificate([ExtendedKeyUsage.Usage(oid: [1, 3, 6, 1, 4, 1, 55555, 9])])],
                now: TestTime.now),
            .extendedKeyUsage)
        XCTAssertNil(verifier.verify(chainDER: [try certificate([.clientAuth, .serverAuth])], now: TestTime.now))
        XCTAssertNil(verifier.verify(chainDER: [try certificate([.any])], now: TestTime.now))
        XCTAssertNil(verifier.verify(chainDER: [try certificate(nil)], now: TestTime.now))
    }

    func testSignatureByAnotherKeyIsRejected() throws {
        let key = P256.Signing.PrivateKey()
        let stranger = P256.Signing.PrivateKey()
        let der = try TestCertificates.make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(stranger),
            extensions: try TestCertificates.goHostExtensions())
        XCTAssertEqual(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now), .badSignature)
    }

    func testSelfSignatureWithSHA384AndSHA512IsAccepted() throws {
        let key = P256.Signing.PrivateKey()
        for algorithm: Certificate.SignatureAlgorithm in [.ecdsaWithSHA384, .ecdsaWithSHA512] {
            let der = try TestCertificates.selfSigned(key, signatureAlgorithm: algorithm)
            XCTAssertNil(
                paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now), "\(algorithm)")
        }
    }

    func testAddressMustBeAnExactFourByteIPSAN() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = paired(TestCertificates.pin(of: key))
        func certificate(_ san: Certificate.Extension?, subject: DistinguishedName = DistinguishedName()) throws
            -> [UInt8]
        {
            var extensions = Array(try TestCertificates.goHostExtensions().prefix(3))
            if let san { extensions.append(san) }
            return try TestCertificates.selfSigned(key, subject: subject, extensions: extensions)
        }
        // No SAN, even with the address as the subject CN.
        let cn = try DistinguishedName { CommonName("192.168.1.20") }
        XCTAssertEqual(
            verifier.verify(chainDER: [try certificate(nil, subject: cn)], now: TestTime.now), .addressMismatch)
        // A DNS name spelling the address does not count.
        let dns = try Certificate.Extension(SubjectAlternativeNames([.dnsName("192.168.1.20")]), critical: true)
        XCTAssertEqual(verifier.verify(chainDER: [try certificate(dns)], now: TestTime.now), .addressMismatch)
        // IPv4-mapped IPv6 (::ffff:192.168.1.20) is 16 bytes, not the link's 4.
        let mapped = try TestCertificates.ipSAN(
            [[UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + TestCertificates.lanAddress], critical: true)
        XCTAssertEqual(verifier.verify(chainDER: [try certificate(mapped)], now: TestTime.now), .addressMismatch)
        // Any one of several IP SANs may match.
        let several = try TestCertificates.ipSAN(
            [TestCertificates.otherAddress, [172, 16, 0, 1], TestCertificates.lanAddress], critical: true)
        XCTAssertNil(verifier.verify(chainDER: [try certificate(several)], now: TestTime.now))
        XCTAssertEqual(
            paired(TestCertificates.pin(of: key), host: try PrivateIPv4(validating: "192.168.1.21"))
                .verify(chainDER: [try certificate(several)], now: TestTime.now),
            .addressMismatch)
    }

    func testMalformedSANValueIsMalformed() throws {
        let key = P256.Signing.PrivateKey()
        var extensions = Array(try TestCertificates.goHostExtensions().prefix(3))
        extensions.append(TestCertificates.opaque([2, 5, 29, 17], critical: false, value: [0x04, 0x01, 0x00]))
        let der = try TestCertificates.selfSigned(key, extensions: extensions)
        XCTAssertEqual(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now), .malformed)
    }

    // MARK: - Order: the first failing step wins

    func testPinMismatchIsReportedBeforeExpiry() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertEqual(
            paired([UInt8](repeating: 1, count: 32)).verify(chainDER: [fixture.expired], now: TestTime.inside),
            .pinMismatch)
    }

    func testValidityIsReportedBeforeUseAndSignatureChecks() throws {
        let key = P256.Signing.PrivateKey()
        let stranger = P256.Signing.PrivateKey()
        let der = try TestCertificates.make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(stranger),
            notBefore: TestTime.now.addingTimeInterval(60),
            notAfter: TestTime.now.addingTimeInterval(86_400),
            extensions: [
                TestCertificates.opaque([1, 3, 6, 1, 4, 1, 55555, 2], critical: true),
                try TestCertificates.keyUsage(KeyUsage(keyCertSign: true)),
            ])
        XCTAssertEqual(paired(TestCertificates.pin(of: key)).verify(chainDER: [der], now: TestTime.now), .notYetValid)
    }

    func testCriticalThenKeyUsageThenExtendedKeyUsageThenSignatureThenAddress() throws {
        let key = P256.Signing.PrivateKey()
        let stranger = P256.Signing.PrivateKey()
        let verifier = paired(TestCertificates.pin(of: key))
        let unknown = TestCertificates.opaque([1, 3, 6, 1, 4, 1, 55555, 3], critical: true)
        let badKU = try TestCertificates.keyUsage(KeyUsage(keyCertSign: true))
        let badEKU = try TestCertificates.extendedKeyUsage([.clientAuth])
        let wrongSAN = try TestCertificates.ipSAN([TestCertificates.otherAddress], critical: true)
        func signedByStranger(_ extensions: [Certificate.Extension]) throws -> [UInt8] {
            try TestCertificates.make(
                publicKey: Certificate.PublicKey(key.publicKey), issuerKey: Certificate.PrivateKey(stranger),
                extensions: extensions)
        }
        XCTAssertEqual(
            verifier.verify(chainDER: [try signedByStranger([unknown, badKU, badEKU, wrongSAN])], now: TestTime.now),
            .unsupportedCriticalExtension)
        XCTAssertEqual(
            verifier.verify(chainDER: [try signedByStranger([badKU, badEKU, wrongSAN])], now: TestTime.now), .keyUsage)
        XCTAssertEqual(
            verifier.verify(chainDER: [try signedByStranger([badEKU, wrongSAN])], now: TestTime.now),
            .extendedKeyUsage)
        XCTAssertEqual(verifier.verify(chainDER: [try signedByStranger([wrongSAN])], now: TestTime.now), .badSignature)
        let selfSignedWrongSAN = try TestCertificates.selfSigned(key, extensions: [wrongSAN])
        XCTAssertEqual(verifier.verify(chainDER: [selfSignedWrongSAN], now: TestTime.now), .addressMismatch)
    }

    // MARK: - Link integration, throwing form, failure classification

    func testLinkVerifierUsesTheSPKIPinForPairedAndTheLeafPinForLegacy() throws {
        let fixture = try HostCertificateFixture.load()
        let pairedLink = try ConnectionLink.paired(
            host: "192.168.1.20", port: 9844, hostKey: fixture.pinHex, clientKey: String(repeating: "b", count: 64))
        XCTAssertEqual(pairedLink.hostPin, .publicKey(fixture.pin))
        XCTAssertTrue(pairedLink.hostPin.isPublicKey)
        let pairedVerifier = HostTrustVerifier(link: pairedLink)
        XCTAssertEqual(pairedVerifier.host, lan)
        XCTAssertNil(pairedVerifier.verify(chainDER: [fixture.initial], now: TestTime.inside))

        let leafPin = TestHex.sha256(fixture.initial)
        let legacyLink = try ConnectionLink(
            version: .v2, endpoint: try LANEndpoint(host: "192.168.1.20", port: 9844),
            token: String(repeating: "A", count: 43), pin: leafPin, expiresAt: 2_000_000_000, clientKey: "",
            remote: nil)
        XCTAssertEqual(legacyLink.hostPin, .certificate(leafPin))
        XCTAssertFalse(legacyLink.hostPin.isPublicKey)
        XCTAssertEqual(legacyLink.hostPin.bytes, leafPin)
        XCTAssertNil(HostTrustVerifier(link: legacyLink).verify(chainDER: [fixture.initial], now: TestTime.inside))
        // A v2 link whose fingerprint is the SPKI pin is a leaf-hash mismatch.
        let confused = try ConnectionLink(
            version: .v2, endpoint: try LANEndpoint(host: "192.168.1.20", port: 9844),
            token: String(repeating: "A", count: 43), pin: fixture.pin, expiresAt: 2_000_000_000, clientKey: "",
            remote: nil)
        XCTAssertEqual(
            HostTrustVerifier(link: confused).verify(chainDER: [fixture.initial], now: TestTime.inside), .pinMismatch)
    }

    func testValidateThrowsTheVerdict() throws {
        let fixture = try HostCertificateFixture.load()
        XCTAssertNoThrow(try paired(fixture.pin).validate(chainDER: [fixture.initial], now: TestTime.inside))
        XCTAssertThrowsError(try paired(fixture.pin).validate(chainDER: [fixture.expired], now: TestTime.inside)) {
            XCTAssertEqual($0 as? HostTrustFailure, .expired)
        }
        XCTAssertThrowsError(try paired(fixture.pin).validate(chainDER: [], now: TestTime.inside)) {
            XCTAssertEqual($0 as? HostTrustFailure, .chainLength)
        }
    }

    func testOnlyValidityFailuresAreCertificateTime() {
        let all: [HostTrustFailure] = [
            .chainLength, .unsupportedKey, .pinMismatch, .notYetValid, .expired, .unsupportedCriticalExtension,
            .keyUsage, .extendedKeyUsage, .badSignature, .addressMismatch, .malformed,
        ]
        XCTAssertEqual(all.filter { $0.isCertificateTime }, [.notYetValid, .expired])
    }

    func testFailureDescriptionsAreAndroidsInternalTexts() {
        // `PublicIdentity.kt:15-45`, `RemoteHttp.kt:38-39`.
        XCTAssertEqual(HostTrustFailure.chainLength.description, "One pinned host certificate required")
        XCTAssertEqual(HostTrustFailure.unsupportedKey.description, "P-256 identity required")
        XCTAssertEqual(HostTrustFailure.pinMismatch.description, "Host identity changed")
        XCTAssertEqual(HostTrustFailure.notYetValid.description, "Host certificate not yet valid")
        XCTAssertEqual(HostTrustFailure.expired.description, "Host certificate expired")
        XCTAssertEqual(HostTrustFailure.unsupportedCriticalExtension.description, "Unsupported certificate")
        XCTAssertEqual(HostTrustFailure.keyUsage.description, "Signing key required")
        XCTAssertEqual(HostTrustFailure.extendedKeyUsage.description, "Server certificate required")
        XCTAssertEqual(HostTrustFailure.addressMismatch.description, "Windows certificate address mismatch")
        XCTAssertEqual(HostTrustFailure.badSignature.description, "Host certificate signature invalid")
        XCTAssertEqual(HostTrustFailure.malformed.description, "Malformed host certificate")
        let texts = [
            HostTrustFailure.chainLength, .unsupportedKey, .pinMismatch, .notYetValid, .expired,
            .unsupportedCriticalExtension, .keyUsage, .extendedKeyUsage, .badSignature, .addressMismatch, .malformed,
        ].map { $0.description }
        XCTAssertEqual(Set(texts).count, texts.count)
    }

    func testSupportedCriticalExtensionsAreConscryptsList() {
        XCTAssertEqual(
            HostTrustVerifier.supportedCriticalExtensionOIDs,
            [
                "2.16.840.1.113730.1.1", "2.5.29.15", "2.5.29.17", "2.5.29.19", "2.5.29.30", "2.5.29.32",
                "2.5.29.33", "2.5.29.36", "2.5.29.37", "2.5.29.54",
            ])
    }
}
