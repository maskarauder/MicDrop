import Foundation

/// A five-minute, single-use pairing invitation `micdrop://pair/v1/<b64url JSON>`, optionally wrapped in
/// `micdrop://remote/v1/…` (Android `PairingInvitation`, `PairingClient.kt:11-41`; Go producer
/// `internal/pairing/manager.go:46-57`).
///
/// The secret is an enrollment credential: `description`, `debugDescription` and reflection
/// never include it, the host key or the route.
public struct PairingInvitation: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{

    /// Routing prefix, matched **case-insensitively** (`PairingClient.kt:19`); 18 characters.
    /// The base64url payload after it is case-sensitive and never normalized.
    public static let prefix = "micdrop://pair/v1/"

    public let endpoint: LANEndpoint
    /// Host SPKI pin, 64 lowercase hex.
    public let hostKey: String
    /// 43-character base64url enrollment secret.
    public let secret: String
    /// Unix seconds, `1…253402300799`.
    public let expiresAt: Int64
    /// Rendezvous route when the invitation was `remote/v1`-wrapped (enrollment runs over the tunnel).
    public let remote: RemoteRoute?

    /// Validating initializer (`PairingInvitation.fromFields`, `PairingClient.kt:36-40`):
    /// `hostKey` is a valid pin, `secret` matches `^[A-Za-z0-9_-]{43}$`, `expiresAt` in range.
    public init(
        endpoint: LANEndpoint, hostKey: String, secret: String, expiresAt: Int64,
        remote: RemoteRoute?
    ) throws {
        guard HexPin.isValid(hostKey) else {
            throw ConnectionLink.FormatError.pin
        }
        guard Base64URL.isUnpaddedToken(secret) else {
            throw ConnectionLink.FormatError.token
        }
        guard UnixTime.expiryRange.contains(expiresAt) else {
            throw ConnectionLink.FormatError.expiry
        }
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.secret = secret
        self.expiresAt = expiresAt
        self.remote = remote
    }

    /// `now >= expiresAt` (`PairingClient.kt:15`); at exactly `expiresAt` it is expired.
    public func isExpired(now: Int64 = UnixTime.now()) -> Bool {
        now >= expiresAt
    }

    /// The paired link this enrollment produces: same host, port and host key, the given client
    /// key, and the same remote route (`PairingClient.kt:14`).
    public func connection(clientKey: String) throws -> ConnectionLink {
        try ConnectionLink.paired(
            host: endpoint.host.description, port: Int(endpoint.port),
            hostKey: hostKey, clientKey: clientKey
        ).withRemote(remote)
    }

    /// Routing rule for pasted/scanned text (`PairingClient.kt:18-20`): the inner link of a valid `remote/v1` wrapper,
    /// else the trimmed text, starts with `prefix` case-insensitively. Any error (e.g. a malformed wrapper) → false.
    public static func isPairingLink(_ value: String) -> Bool {
        do {
            let inner = try RemoteRoute.unwrap(value)?.inner ?? ConnectionLink.trimmed(value)
            return ConnectionLink.hasASCIIPrefix(inner, prefix, caseInsensitive: true)
        } catch {
            return false
        }
    }

    /// Parses an invitation (`PairingInvitation.parse`, `PairingClient.kt:21-40`): Kotlin `trim()`; a `remote/v1`
    /// wrapper → parse the inner text and attach the route (a wrapped paired record is rejected because its inner text
    /// is not a pairing link); length ≤ 4096 and `isPairingLink`; payload after the 18-byte prefix ≤ 2048 bytes; strict
    /// JSON with exactly `host, port, host_key, secret, expires_at` (`port` and `expires_at` integer literals); then
    /// the field rules.
    public static func parse(_ value: String) throws -> PairingInvitation {
        let text = ConnectionLink.trimmed(value)
        if let unwrapped = try RemoteRoute.unwrap(text) {
            return try parse(unwrapped.inner).withRemote(unwrapped.route)
        }
        guard text.utf16.count <= ConnectionLink.maxLinkLength else {
            throw ConnectionLink.FormatError.tooLong
        }
        guard isPairingLink(text) else {
            throw ConnectionLink.FormatError.unsupportedLink
        }
        let json = try ConnectionLink.payloadObject(
            text, droppingPrefixBytes: prefix.utf8.count,
            maxBytes: ConnectionLink.maxPayloadBytes)
        try ConnectionLink.requireKeys(json, ["host", "port", "host_key", "secret", "expires_at"])
        let port = try json.integer("port")
        let expiresAt = try json.integer("expires_at")
        let endpoint = try LANEndpoint(host: json.string("host"), port: Int(exactly: port) ?? -1)
        return try PairingInvitation(
            endpoint: endpoint, hostKey: json.string("host_key"),
            secret: json.string("secret"), expiresAt: expiresAt, remote: nil)
    }

    /// Kotlin `copy(remote = …)`.
    private func withRemote(_ remote: RemoteRoute?) -> PairingInvitation {
        PairingInvitation(
            unchecked: endpoint, hostKey: hostKey, secret: secret,
            expiresAt: expiresAt, remote: remote)
    }

    private init(
        unchecked endpoint: LANEndpoint, hostKey: String, secret: String,
        expiresAt: Int64, remote: RemoteRoute?
    ) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.secret = secret
        self.expiresAt = expiresAt
        self.remote = remote
    }

    public var description: String { "Pairing invitation" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: [Any]()) }
}
