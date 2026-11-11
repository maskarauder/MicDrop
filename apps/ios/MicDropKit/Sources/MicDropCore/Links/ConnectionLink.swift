import Foundation

/// Control-plane protocol version carried by a connection link (table).
///
/// - `v1`: `micdrop://v1/…`, bearer token, no offer nonce, never saved.
/// - `v2`: `micdrop://v2/…`, bearer token, `expires_at`, saved after first playback.
/// - `paired` (protocol 3): `micdrop://paired/v1/…` (optionally `remote/v1`-wrapped), mutual TLS,
///   no `Authorization`; the only version that can be remote or use the microphone.
public enum LinkVersion: Int, Sendable, Hashable, Comparable, CaseIterable {
    case v1 = 1
    case v2 = 2
    case paired = 3

    public static func < (lhs: LinkVersion, rhs: LinkVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A parsed connection link: Android `LanInvitation` (`LanInvitation.kt:8-9`), (and 10 use this type:
/// `link.endpoint.host.description`, `Int(link.endpoint.port)`, `HexPin.encode(link.pin)`, `link.clientKey`,
/// `link.remote`).
///
/// `description`, `debugDescription` and reflection never include the token, pins or route.
public struct ConnectionLink: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{

    /// Link-format validation failure shared by every link validator in this module (Base64 and strict-JSON failures
    /// are mapped onto it by the link parsers; field accessor failures surface as `StrictJSONObject.Failure`).
    /// Classified `SETUP_FAILED`, non-retryable. Never carries input text.
    public enum FormatError: Error, Equatable, Sendable {
        /// Trimmed link longer than 4096 UTF-16 units (`LanInvitation.kt:34`).
        case tooLong
        /// No supported prefix ("Unsupported connection link", `LanInvitation.kt:49`).
        case unsupportedLink
        /// Payload is not Java-compatible base64url.
        case base64
        /// Decoded payload over 2048 bytes (3072 for `remote/v1`).
        case payloadTooLarge
        /// Payload is not a strict JSON object.
        case json
        /// Wrong member set or count.
        case keySet
        /// Host or port invalid.
        case endpoint
        /// Pin not `^[0-9a-f]{64}$`.
        case pin
        /// Token or secret shape invalid.
        case token
        /// `expires_at` outside `1…253402300799`, or present/absent for the wrong version.
        case expiry
        /// Remote route URL invalid.
        case remoteURL
        /// Remote wrapper's `connection` is not a paired or pairing link.
        case remoteInner
        /// Version mismatch (e.g. `remote/v1` around a non-v3 link, `pairedRecord()` on v1/v2).
        case version
        /// Field combination invalid for the version (e.g. a token on a paired link).
        case fields
    }

    /// Maximum trimmed link length (`PairingClient.kt:24`, `LanInvitation.kt:34`, `RemoteConnection.kt:28`).
    public static let maxLinkLength = 4096
    /// Maximum decoded payload for `pair/v1`, `paired/v1`, `v1`, `v2` (`LanInvitation.kt:40,52`).
    public static let maxPayloadBytes = 2048
    /// Local saved paired record prefix, matched case-sensitively (`LanInvitation.kt:38`).
    public static let pairedPrefix = "micdrop://paired/v1/"
    /// Legacy prefixes, matched case-sensitively, both 13 characters (`LanInvitation.kt:46-51`).
    public static let v1Prefix = "micdrop://v1/"
    public static let v2Prefix = "micdrop://v2/"

    public let version: LinkVersion
    public let endpoint: LANEndpoint
    /// Bearer token for v1/v2 (43-char base64url); `""` for paired.
    public let token: String
    /// 32 bytes: v1/v2 SHA-256 of the leaf certificate DER; paired: host SPKI SHA-256 (`host_key`).
    public let pin: [UInt8]
    /// v2 only (`1…253402300799`); otherwise 0.
    public let expiresAt: Int64
    /// Paired only: this phone's SPKI fingerprint (64 lowercase hex); otherwise `""`.
    public let clientKey: String
    /// Paired only: rendezvous route when the record was `remote/v1`-wrapped.
    public let remote: RemoteRoute?

    /// Validating initializer. Rules per version:
    /// - v1: token `^[A-Za-z0-9_-]{43}$`, `expiresAt == 0`, `clientKey == ""`, no route;
    /// - v2: as v1 but `expiresAt` in `1…253402300799` (`LanInvitation.kt:64-71`);
    /// - paired: `token == ""`, `expiresAt == 0`, `clientKey` a valid hex pin (`LanInvitation.kt:85-89`).
    /// `pin` must be 32 bytes. Throws `FormatError`.
    public init(
        version: LinkVersion, endpoint: LANEndpoint, token: String, pin: [UInt8],
        expiresAt: Int64, clientKey: String, remote: RemoteRoute?
    ) throws {
        guard pin.count == HexPin.byteCount else {
            throw FormatError.pin
        }
        switch version {
        case .v1, .v2:
            guard Base64URL.isUnpaddedToken(token) else { throw FormatError.token }
            if version == .v2 {
                guard UnixTime.expiryRange.contains(expiresAt) else { throw FormatError.expiry }
            } else {
                guard expiresAt == 0 else { throw FormatError.expiry }
            }
            guard clientKey.isEmpty, remote == nil else { throw FormatError.fields }
        case .paired:
            guard token.isEmpty, expiresAt == 0 else { throw FormatError.fields }
            guard HexPin.isValid(clientKey) else { throw FormatError.pin }
        }
        self.init(
            unchecked: version, endpoint: endpoint, token: token, pin: pin,
            expiresAt: expiresAt, clientKey: clientKey, remote: remote)
    }

    private init(
        unchecked version: LinkVersion, endpoint: LANEndpoint, token: String, pin: [UInt8],
        expiresAt: Int64, clientKey: String, remote: RemoteRoute?
    ) {
        self.version = version
        self.endpoint = endpoint
        self.token = token
        self.pin = pin
        self.expiresAt = expiresAt
        self.clientKey = clientKey
        self.remote = remote
    }

    /// `HexPin.encode(pin)`: the `host_key` (paired) or certificate `fingerprint` (v1/v2).
    public var pinHex: String { HexPin.encode(pin) }

    /// Only v2 expires: `version == .v2 && now >= expiresAt` (`LanInvitation.kt:10`).
    public func isExpired(now: Int64 = UnixTime.now()) -> Bool {
        version == .v2 && now >= expiresAt
    }

    /// Local saved record `micdrop://paired/v1/<b64url JSON>` with members in Android order `host, port, host_key,
    /// client_key`, wrapped in `remote/v1` when routed (`LanInvitation.kt:22-29`; test vector). Paired links only;
    /// throws `FormatError.version` otherwise.
    public func pairedRecord() throws -> String {
        guard version == .paired else {
            throw FormatError.version
        }
        let json = StrictJSONObject.encode([
            "host": .string(endpoint.host.description),
            "port": .integer(Int64(endpoint.port)),
            "host_key": .string(pinHex),
            "client_key": .string(clientKey),
        ])
        let record = ConnectionLink.pairedPrefix + Base64URL.encodeUnpadded(Array(json.utf8))
        return remote?.wrap(record) ?? record
    }

    /// The same link at a new LAN endpoint. **Keeps** the remote route (Change Windows address on a remote pairing must
    /// preserve the route, because the remote path checks the IP SAN against this LAN address). Discovery reconnect
    /// uses `ConnectionLink.paired(...)` instead, which produces a LAN record (parity).
    public func withEndpoint(_ endpoint: LANEndpoint) -> ConnectionLink {
        ConnectionLink(
            unchecked: version, endpoint: endpoint, token: token, pin: pin,
            expiresAt: expiresAt, clientKey: clientKey, remote: remote)
    }

    /// The same link with `remote` replaced (Kotlin `copy(remote = …)`). Callers guarantee the
    /// link is paired when `remote != nil` (`LanInvitation.kt:35-37`, `PairingClient.kt:14`).
    func withRemote(_ remote: RemoteRoute?) -> ConnectionLink {
        ConnectionLink(
            unchecked: version, endpoint: endpoint, token: token, pin: pin,
            expiresAt: expiresAt, clientKey: clientKey, remote: remote)
    }

    /// Parses `micdrop://v1/`, `micdrop://v2/`, `micdrop://paired/v1/` and a `remote/v1` wrapper around a paired record
    /// (`LanInvitation.parse`, `LanInvitation.kt:32-62`). A `remote/v1` around a pairing invitation is rejected here
    /// (`unsupportedLink`); route it with `PairingInvitation.isPairingLink` first.
    ///
    /// Order: Kotlin `trim()`; length ≤ 4096; remote unwrap (inner must be paired); paired
    /// record (exactly `host, port, host_key, client_key`, `port` an integer literal); legacy
    /// (exactly `host, port, token, fingerprint` [+ `expires_at` for v2, an integer literal in range]).
    public static func parse(_ value: String) throws -> ConnectionLink {
        let text = trimmed(value)
        guard text.utf16.count <= maxLinkLength else {
            throw FormatError.tooLong
        }
        if let unwrapped = try RemoteRoute.unwrap(text) {
            let inner = try parse(unwrapped.inner)
            guard inner.version == .paired else {
                throw FormatError.version
            }
            return inner.withRemote(unwrapped.route)
        }
        if hasASCIIPrefix(text, pairedPrefix) {
            let json = try payloadObject(
                text, droppingPrefixBytes: pairedPrefix.utf8.count,
                maxBytes: maxPayloadBytes)
            try requireKeys(json, ["host", "port", "host_key", "client_key"])
            let port = try json.integer("port")
            return try paired(
                host: json.string("host"), port: Int(exactly: port) ?? -1,
                hostKey: json.string("host_key"), clientKey: json.string("client_key"))
        }
        let version: LinkVersion
        if hasASCIIPrefix(text, v1Prefix) {
            version = .v1
        } else if hasASCIIPrefix(text, v2Prefix) {
            version = .v2
        } else {
            throw FormatError.unsupportedLink
        }
        let json = try payloadObject(
            text, droppingPrefixBytes: v1Prefix.utf8.count,
            maxBytes: maxPayloadBytes)
        var expected: Set<String> = ["host", "port", "token", "fingerprint"]
        if version == .v2 {
            expected.insert("expires_at")
        }
        try requireKeys(json, expected)
        var expiresAt: Int64 = 0
        if version == .v2 {
            expiresAt = try json.integer("expires_at")
            guard UnixTime.expiryRange.contains(expiresAt) else {
                throw FormatError.expiry
            }
        }
        let host = try json.string("host")
        let port = try json.integer("port")
        let token = try json.string("token")
        let fingerprint = try json.string("fingerprint")
        // fromFields (`LanInvitation.kt:64-71`): endpoint, token regex, pin.
        let endpoint = try LANEndpoint(host: host, port: Int(exactly: port) ?? -1)
        guard Base64URL.isUnpaddedToken(token) else {
            throw FormatError.token
        }
        return try ConnectionLink(
            version: version, endpoint: endpoint, token: token,
            pin: HexPin.decode(fingerprint), expiresAt: expiresAt,
            clientKey: "", remote: nil)
    }

    /// Paired (v3) LAN link (`LanInvitation.paired`, `LanInvitation.kt:85-89`): validates the
    /// endpoint, then `clientKey`, then `hostKey` (both `^[0-9a-f]{64}$`); token `""`, expiry 0,
    /// no remote route.
    public static func paired(host: String, port: Int, hostKey: String, clientKey: String) throws -> ConnectionLink {
        let endpoint = try LANEndpoint(host: host, port: port)
        _ = try HexPin.decode(clientKey)
        let pin = try HexPin.decode(hostKey)
        return ConnectionLink(
            unchecked: .paired, endpoint: endpoint, token: "", pin: pin,
            expiresAt: 0, clientKey: clientKey, remote: nil)
    }

    /// `ConnectionLink.validateEndpoint(host:port:)` = `LANEndpoint(host:port:)`; used by Change Windows address.
    @discardableResult
    public static func validateEndpoint(host: String, port: Int) throws -> LANEndpoint {
        try LANEndpoint(host: host, port: port)
    }

    /// Kotlin `String.trim()`: removes leading and trailing characters for which Kotlin `Char.isWhitespace()` is true
    /// (`Character.isWhitespace || Character.isSpaceChar`): Unicode space/line/paragraph separators (including no-break
    /// spaces) and U+0009…U+000D, U+001C…U+001F. Every link parse and the resume digest begin with it.
    public static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isKotlinWhitespace($0) }),
            let last = scalars.lastIndex(where: { !isKotlinWhitespace($0) })
        else {
            return ""
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }

    public var description: String { "Connection link v\(version.rawValue)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: [Any]()) }

    // MARK: - Module helpers shared by the link parsers

    private static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F:
            return true
        default:
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                return true
            default:
                return false
            }
        }
    }

    /// Byte-wise ASCII prefix match. `caseInsensitive` folds only ASCII letters (Kotlin
    /// `startsWith(…, ignoreCase = true)` also folds non-ASCII letters such as U+0131 to ASCII;
    /// iOS rejects those hand-made links, which Go never produces).
    static func hasASCIIPrefix(_ text: String, _ prefix: String, caseInsensitive: Bool = false) -> Bool {
        let textBytes = text.utf8
        let prefixBytes = prefix.utf8
        guard textBytes.count >= prefixBytes.count else {
            return false
        }
        for (actual, expected) in zip(textBytes, prefixBytes) {
            if actual == expected {
                continue
            }
            if caseInsensitive, lowercasedASCII(actual) == lowercasedASCII(expected) {
                continue
            }
            return false
        }
        return true
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// Decodes the base64url payload after an ASCII prefix of `droppingPrefixBytes` bytes,
    /// enforces `maxBytes`, and parses it as a strict JSON object. Maps codec failures to
    /// `FormatError.base64` / `.payloadTooLarge` / `.json`.
    static func payloadObject(_ text: String, droppingPrefixBytes count: Int, maxBytes: Int) throws -> StrictJSONObject
    {
        let raw: [UInt8]
        do {
            raw = try Base64URL.decode(utf8: Array(text.utf8.dropFirst(count)))
        } catch {
            throw FormatError.base64
        }
        guard raw.count <= maxBytes else {
            throw FormatError.payloadTooLarge
        }
        do {
            return try StrictJSONObject(utf8: raw)
        } catch {
            throw FormatError.json
        }
    }

    /// Exact member set; maps a mismatch to `FormatError.keySet`.
    static func requireKeys(_ json: StrictJSONObject, _ expected: Set<String>) throws {
        guard json.count == expected.count, json.keys == expected else {
            throw FormatError.keySet
        }
    }
}
