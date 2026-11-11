import Crypto
import Foundation
import MicDropTestSupport
import SwiftASN1
import X509

/// Fixed instants used across the identity tests (no wall clock in assertions).
enum TestTime {
    /// 2020-01-01T00:00:00Z: `notValidBefore` of every fixture certificate.
    static let fixtureStart = Date(timeIntervalSince1970: 1_577_836_800)
    /// 2021-01-01T00:00:00Z: `notValidAfter` of the `expired` fixture certificate.
    static let expiredEnd = Date(timeIntervalSince1970: 1_609_459_200)
    /// 2030-01-01T00:00:00Z: inside the `initial`/`renewed` window, after `expired`.
    static let inside = Date(timeIntervalSince1970: 1_893_456_000)
    /// 2040-01-01T00:00:00Z: `notValidAfter` of `initial` and `renewed`.
    static let fixtureEnd = Date(timeIntervalSince1970: 2_208_988_800)
    /// 2027-01-15T08:00:00Z: "now" for generated certificates (whole seconds, so DER times are exact).
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// The Go identity fixtures, read in place (`internal/identity/testdata`).
struct HostCertificateFixture {
    /// `sha256_hex`: the shared SPKI pin of `initial`, `renewed` and `expired`.
    let pinHex: String
    /// Serial 1, SAN 192.168.1.20, 2020-01-01 … 2040-01-01.
    let initial: [UInt8]
    /// Serial 2, SAN 10.0.0.20, same key and window.
    let renewed: [UInt8]
    /// Serial 3, SAN 192.168.1.20, 2020-01-01 … 2021-01-01.
    let expired: [UInt8]

    static let path = "internal/identity/testdata/host_certificates_v1.json"

    static func load() throws -> HostCertificateFixture {
        let object = try TestJSON.object(path)
        func certificate(_ key: String) throws -> [UInt8] {
            guard let text = object[key] as? String, let der = Data(base64Encoded: text) else {
                throw TestFailure("fixture field \(key) is not base64")
            }
            return Array(der)
        }
        guard let pin = object["sha256_hex"] as? String else {
            throw TestFailure("fixture field sha256_hex missing")
        }
        return HostCertificateFixture(
            pinHex: pin,
            initial: try certificate("initial"),
            renewed: try certificate("renewed"),
            expired: try certificate("expired"))
    }

    var pin: [UInt8] { TestHex.decode(pinHex) }
}

/// `internal/identity/testdata/host_public_key_v1.json`: the P-256 generator point as SPKI DER.
struct HostPublicKeyFixture {
    let subjectPublicKeyInfo: [UInt8]
    let sha256Hex: String

    static let path = "internal/identity/testdata/host_public_key_v1.json"

    static func load() throws -> HostPublicKeyFixture {
        let object = try TestJSON.object(path)
        guard let spki = object["subject_public_key_info_der_hex"] as? String,
            let digest = object["sha256_hex"] as? String
        else {
            throw TestFailure("host public key fixture fields missing")
        }
        return HostPublicKeyFixture(subjectPublicKeyInfo: TestHex.decode(spki), sha256Hex: digest)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum TestJSON {
    static func object(_ path: String) throws -> [String: Any] {
        let data = try RepositoryFixtures.data(path)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure("\(path) is not a JSON object")
        }
        return object
    }
}

enum TestHex {
    /// Lowercase or uppercase hex → bytes; traps on malformed test input.
    static func decode(_ text: String) -> [UInt8] {
        let digits = Array(text.utf8)
        precondition(digits.count % 2 == 0, "odd hex length")
        func value(_ digit: UInt8) -> UInt8 {
            switch digit {
            case 0x30...0x39: return digit - 0x30
            case 0x61...0x66: return digit - 0x61 + 10
            case 0x41...0x46: return digit - 0x41 + 10
            default: preconditionFailure("not hex")
            }
        }
        return stride(from: 0, to: digits.count, by: 2).map { value(digits[$0]) << 4 | value(digits[$0 + 1]) }
    }

    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }
}

/// Minimal DER builder for hand-made structures (RSA SPKI etc.).
enum TestDER {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else if count <= 0xFF {
            out += [0x81, UInt8(count)]
        } else {
            out += [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        }
        return out + content
    }

    /// A syntactically valid rsaEncryption SPKI (512-bit modulus, e = 65537).
    static func rsaSubjectPublicKeyInfo() -> [UInt8] {
        let modulus: [UInt8] = [0x00, 0xC1] + [UInt8](repeating: 0x5A, count: 62) + [0x0B]
        let rsaPublicKey = tlv(0x30, tlv(0x02, modulus) + tlv(0x02, [0x01, 0x00, 0x01]))
        let algorithm = tlv(0x30, tlv(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) + [0x05, 0x00])
        return tlv(0x30, algorithm + tlv(0x03, [0x00] + rsaPublicKey))
    }
}

/// Builds test certificates with swift-certificates (host shape and variations).
enum TestCertificates {
    /// The address bytes of 192.168.1.20 / 10.0.0.20.
    static let lanAddress: [UInt8] = [192, 168, 1, 20]
    static let otherAddress: [UInt8] = [10, 0, 0, 20]

    static func ipSAN(_ addresses: [[UInt8]], critical: Bool) throws -> Certificate.Extension {
        let names = SubjectAlternativeNames(
            addresses.map { GeneralName.ipAddress(ASN1OctetString(contentBytes: $0[...])) })
        return try Certificate.Extension(names, critical: critical)
    }

    static func keyUsage(_ usage: KeyUsage, critical: Bool = true) throws -> Certificate.Extension {
        try Certificate.Extension(usage, critical: critical)
    }

    static func extendedKeyUsage(_ usages: [ExtendedKeyUsage.Usage], critical: Bool = false) throws
        -> Certificate.Extension
    {
        try Certificate.Extension(ExtendedKeyUsage(usages), critical: critical)
    }

    static func basicConstraints(critical: Bool = true) throws -> Certificate.Extension {
        try Certificate.Extension(BasicConstraints.notCertificateAuthority, critical: critical)
    }

    /// An extension swift-certificates does not interpret: `oid` with an ASN.1 NULL value.
    static func opaque(_ oid: ASN1ObjectIdentifier, critical: Bool, value: [UInt8] = [0x05, 0x00])
        -> Certificate.Extension
    {
        Certificate.Extension(oid: oid, critical: critical, value: value[...])
    }

    /// The extensions of a Windows paired-host certificate (`internal/identity/identity.go:88-91`;
    /// empty subject, so Go marks the SAN critical; BasicConstraintsValid → critical CA:false).
    static func goHostExtensions(address: [UInt8] = lanAddress) throws -> [Certificate.Extension] {
        [
            try keyUsage(KeyUsage(digitalSignature: true), critical: true),
            try extendedKeyUsage([.serverAuth]),
            try basicConstraints(critical: true),
            try ipSAN([address], critical: true),
        ]
    }

    /// DER of a certificate for `publicKey`, signed by `issuerKey` (self-signed when they match).
    static func make(
        publicKey: Certificate.PublicKey,
        issuerKey: Certificate.PrivateKey,
        subject: DistinguishedName = DistinguishedName(),
        notBefore: Date = TestTime.now.addingTimeInterval(-300),
        notAfter: Date = TestTime.now.addingTimeInterval(86_400),
        serial: [UInt8] = [0x01],
        signatureAlgorithm: Certificate.SignatureAlgorithm = .ecdsaWithSHA256,
        extensions: [Certificate.Extension]
    ) throws -> [UInt8] {
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: serial),
            publicKey: publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: subject,
            subject: subject,
            signatureAlgorithm: signatureAlgorithm,
            extensions: try Certificate.Extensions(extensions),
            issuerPrivateKey: issuerKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    /// Self-signed P-256 certificate (default: Go host shape at `TestTime.now`).
    static func selfSigned(
        _ key: P256.Signing.PrivateKey,
        subject: DistinguishedName = DistinguishedName(),
        notBefore: Date = TestTime.now.addingTimeInterval(-300),
        notAfter: Date = TestTime.now.addingTimeInterval(86_400),
        serial: [UInt8] = [0x01],
        signatureAlgorithm: Certificate.SignatureAlgorithm = .ecdsaWithSHA256,
        extensions: [Certificate.Extension]? = nil
    ) throws -> [UInt8] {
        try make(
            publicKey: Certificate.PublicKey(key.publicKey),
            issuerKey: Certificate.PrivateKey(key),
            subject: subject,
            notBefore: notBefore,
            notAfter: notAfter,
            serial: serial,
            signatureAlgorithm: signatureAlgorithm,
            extensions: try extensions ?? goHostExtensions())
    }

    static func pin(of key: P256.Signing.PrivateKey) -> [UInt8] {
        Array(SHA256.hash(data: key.publicKey.derRepresentation))
    }
}
