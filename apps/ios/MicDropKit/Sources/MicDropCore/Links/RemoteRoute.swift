import Foundation

/// Rendezvous route of a remote pairing: Android `RemoteConnection` (`RemoteConnection.kt`), and the transport view.
///
/// Privacy (MUST): `description`, `debugDescription` and reflection print only `Remote connection`. Never log `url`,
/// `token` or a wrapped link; only `displayHost` is user-visible (`remote via <host>`, `SavedConnections.kt:58`).
public struct RemoteRoute: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{

    /// Wrapper prefix, matched case-sensitively (`RemoteConnection.kt:27`); 20 characters.
    public static let prefix = "micdrop://remote/v1/"
    /// Maximum `url` length (`RemoteConnection.kt:12`).
    public static let maxURLLength = 512
    /// Maximum decoded wrapper payload (`RemoteConnection.kt:30`).
    public static let maxPayloadBytes = 3072

    /// `https://<host>[:port][/]` — no userinfo, query, fragment or path beyond `/`.
    public let url: String
    /// Rendezvous client role token: canonical unpadded base64url of 32 bytes.
    public let token: String
    /// `force_relay` (JSON boolean): restrict WebRTC to relay candidates.
    public let forceRelay: Bool

    /// URI host exactly as Java `URI.getHost()` reports it (IPv6 literals keep brackets).
    private let authorityHost: String
    /// Explicit URI port; nil when absent or empty (`https://relay.test:` → 443).
    private let explicitPort: Int?

    /// Validates per (`RemoteConnection.kt:10-17`): first the URL, then the token. Throws
    /// `ConnectionLink.FormatError.remoteURL` / `.token`.
    public init(url: String, token: String, forceRelay: Bool) throws {
        let parts = try RemoteRoute.parseURL(url)
        guard Base64URL.isCanonical32ByteToken(token) else {
            throw ConnectionLink.FormatError.token
        }
        self.url = url
        self.token = token
        self.forceRelay = forceRelay
        self.authorityHost = parts.host
        self.explicitPort = parts.port
    }

    public var description: String { "Remote connection" }
    public var debugDescription: String { "Remote connection" }
    public var customMirror: Mirror { Mirror(self, unlabeledChildren: [Any]()) }

    /// URL host for `remote via <host>` (Android `URI(url).host`, `SavedConnections.kt:58`).
    public var displayHost: String { authorityHost }

    /// `micdrop://remote/v1/<b64url JSON>` with members in Go order `url, token, connection, force_relay`, compact, `/`
    /// not escaped (Go form; both the Go and Android `\/` forms parse) (`RemoteConnection.kt:19-22`).
    public func wrap(_ inner: String) -> String {
        let json = StrictJSONObject.encode([
            "url": .string(url),
            "token": .string(token),
            "connection": .string(inner),
            "force_relay": .bool(forceRelay),
        ])
        return RemoteRoute.prefix + Base64URL.encodeUnpadded(Array(json.utf8))
    }

    /// Unwraps a remote route (`RemoteConnection.unwrap`, `RemoteConnection.kt:24-36`): Kotlin `trim()`; not starting
    /// with `prefix` (case-sensitive) → `nil` (not a remote link); else length ≤ 4096, payload ≤ 3072 bytes, strict
    /// JSON with exactly `url, token, connection, force_relay` (`force_relay` a JSON boolean, others strings);
    /// `connection` must start with `micdrop://paired/v1/` (case-sensitive) or `micdrop://pair/v1/` (case-insensitive),
    /// so nested wrappers are rejected; then `RemoteRoute(url:token:forceRelay:)`. Returns the route and the inner link
    /// text (not trimmed again).
    public static func unwrap(_ value: String) throws -> (route: RemoteRoute, inner: String)? {
        let text = ConnectionLink.trimmed(value)
        guard ConnectionLink.hasASCIIPrefix(text, prefix) else {
            return nil
        }
        guard text.utf16.count <= ConnectionLink.maxLinkLength else {
            throw ConnectionLink.FormatError.tooLong
        }
        let json = try ConnectionLink.payloadObject(
            text, droppingPrefixBytes: prefix.utf8.count,
            maxBytes: maxPayloadBytes)
        try ConnectionLink.requireKeys(json, ["url", "token", "connection", "force_relay"])
        let forceRelay = try json.bool("force_relay")
        let inner = try json.string("connection")
        guard
            ConnectionLink.hasASCIIPrefix(inner, ConnectionLink.pairedPrefix)
                || ConnectionLink.hasASCIIPrefix(inner, PairingInvitation.prefix, caseInsensitive: true)
        else {
            throw ConnectionLink.FormatError.remoteInner
        }
        let route = try RemoteRoute(
            url: json.string("url"), token: json.string("token"),
            forceRelay: forceRelay)
        return (route: route, inner: inner)
    }

    /// ICE endpoints share the IPv6 authority parser; DNS additionally follows the host's
    /// bounded label grammar (`internal/rendezvous/config.go`, `validICEURL`).
    static func isValidICEEndpoint(_ endpoint: String) -> Bool {
        guard let separator = endpoint.lastIndex(of: ":") else { return false }
        let host = endpoint[..<separator]
        let port = endpoint[endpoint.index(after: separator)...]
        guard !port.isEmpty, port.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let number = Int(port), (1...65535).contains(number), !host.isEmpty
        else { return false }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), !host.contains("%"), host.utf8.count <= 255 else { return false }
            var authority = JavaServerAuthority(Array(endpoint.utf8))
            return (try? authority.parse()) != nil
        }
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy {
                    ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
                }
        }
    }

    /// Parsed URL authority needed by the transport accessors.
    private struct URLParts {
        let host: String
        let port: Int?
        let ipLiteral: Bool
    }

    /// Java `java.net.URI` acceptance as used by `RemoteConnection.kt:10-14` plus Go's whitespace rule. Throws
    /// `ConnectionLink.FormatError.remoteURL`.
    ///
    /// Kotlin requires `url.length <= 512`, `scheme == "https"` (Java keeps the case, so
    /// `HTTPS://` is rejected), a non-empty `host`, `rawUserInfo == null`, `rawPath` `""` or
    /// `"/"`, `rawQuery == null`, `rawFragment == null` and port `-1` or `1…65535`. A Java `URI`
    /// has a host only for a server-based authority, so the accepted language is exactly
    /// `https://` + authority + (`""` | `/`), where the authority (everything up to the first
    /// `/`, `?` or `#`) parses as `hostname | IPv4address | "[" IPv6 ["%" scope] "]"` followed by
    /// an optional `:port` (OpenJDK `URI.Parser.parseServer`; `JavaServerAuthority` below). Any
    /// `?` or `#` (even empty), any `@` (userinfo, even empty), any path other than `/`, any
    /// whitespace or non-ASCII character is rejected. An empty port (`https://relay.test:`)
    /// is accepted and means 443.
    private static func parseURL(_ url: String) throws -> URLParts {
        guard url.utf16.count <= maxURLLength else {
            throw ConnectionLink.FormatError.remoteURL
        }
        let bytes = Array(url.utf8)
        let scheme: [UInt8] = Array("https://".utf8)
        guard bytes.count > scheme.count, Array(bytes[0..<scheme.count]) == scheme else {
            throw ConnectionLink.FormatError.remoteURL
        }
        var end = scheme.count
        while end < bytes.count, bytes[end] != 0x2F, bytes[end] != 0x3F, bytes[end] != 0x23 {  // / ? #
            end += 1
        }
        let rest = bytes[end...]
        guard rest.isEmpty || (rest.count == 1 && rest.first == 0x2F) else {
            throw ConnectionLink.FormatError.remoteURL
        }
        var authority = JavaServerAuthority(Array(bytes[scheme.count..<end]))
        guard let parsed = try? authority.parse() else {
            throw ConnectionLink.FormatError.remoteURL
        }
        if let port = parsed.port, !(1...65535).contains(port) {
            throw ConnectionLink.FormatError.remoteURL
        }
        return URLParts(host: parsed.host, port: parsed.port, ipLiteral: parsed.ipLiteral)
    }
}

/// Port of the OpenJDK `java.net.URI.Parser` server-authority grammar (RFC 2396 + RFC 2732):
/// `parseServer`, `parseHostname`, `parseIPv4Address`/`scanIPv4Address`/`scanByte` and
/// `parseIPv6Reference`/`scanHexSeq`/`scanHexPost`. `parse()` throws wherever Java would fail
/// or fall back to a registry-based authority (whose `getHost()` is null). Operates on ASCII
/// bytes; any other byte fails.
private struct JavaServerAuthority {
    struct Malformed: Error {}

    struct Parsed {
        /// Java `getHost()`: IPv6 literals keep their brackets (and scope id).
        let host: String
        /// nil when absent or empty (Java `getPort() == -1`); otherwise the decimal value.
        let port: Int?
        /// True for the IPv4 and IPv6 forms.
        let ipLiteral: Bool
    }

    private let bytes: [UInt8]
    private var ipv6ByteCount = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() throws -> Parsed {
        let n = bytes.count
        // Any "@" makes Java parse a user-info part (`rawUserInfo != null`, even when empty) or
        // fall back to a registry authority without a host; both are rejected.
        guard n > 0, !bytes.contains(0x40) else {
            throw Malformed()
        }
        var p = 0
        let host: String
        let ipLiteral: Bool
        if at(p, n, 0x5B) {  // [
            p += 1
            var q = p
            while q < n, bytes[q] != 0x5D { q += 1 }  // ]
            guard q > p, at(q, n, 0x5D) else {
                throw Malformed()
            }
            var r = p
            while r < q, bytes[r] != 0x25 { r += 1 }  // %
            if r > p {
                try parseIPv6Reference(p, r)
                if r < q {
                    guard r + 1 < q, bytes[(r + 1)..<q].allSatisfy(Self.isAlphanumeric) else {
                        throw Malformed()  // "scope id expected" / illegal scope id
                    }
                }
            } else {
                try parseIPv6Reference(p, q)
            }
            host = String(decoding: bytes[(p - 1)...q], as: UTF8.self)
            ipLiteral = true
            p = q + 1
        } else {
            var q = parseIPv4Address(p, n)
            if q <= p {
                q = try parseHostname(p, n)
                ipLiteral = false
            } else {
                ipLiteral = true
            }
            host = String(decoding: bytes[p..<q], as: UTF8.self)
            p = q
        }
        var port: Int?
        if at(p, n, 0x3A) {  // :
            p += 1
            if n > p {
                var value = 0
                for byte in bytes[p..<n] {
                    guard Self.isDigit(byte) else {
                        throw Malformed()  // checkChars(L_DIGIT) "port number"
                    }
                    value = value * 10 + Int(byte - 0x30)
                    guard value <= Int(Int32.max) else {
                        throw Malformed()  // Integer.parseInt overflow → "Malformed port number"
                    }
                }
                port = value
                p = n
            }
        }
        guard p == n else {
            throw Malformed()  // "Expected port number"
        }
        return Parsed(host: host, port: port, ipLiteral: ipLiteral)
    }

    // MARK: Character classes (ASCII)

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || isAlpha(byte) }
    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    // MARK: Scanning primitives (Java `at` / `scan`)

    private func at(_ start: Int, _ end: Int, _ byte: UInt8) -> Bool {
        start >= 0 && start < end && bytes[start] == byte
    }

    /// Java `at(start, end, "::")`.
    private func atDoubleColon(_ start: Int, _ end: Int) -> Bool {
        start >= 0 && end - start >= 2 && bytes[start] == 0x3A && bytes[start + 1] == 0x3A
    }

    /// Index of the first byte in `start..<end` that does not match (Java mask scan).
    private func scan(_ start: Int, _ end: Int, _ matches: (UInt8) -> Bool) -> Int {
        var p = start
        while p < end, matches(bytes[p]) { p += 1 }
        return p
    }

    // MARK: Hostname

    /// `hostname = domainlabel ["."] | 1*(domainlabel ".") toplabel ["."]`; labels are
    /// alphanumeric with inner `-`; the last label of a multi-label name starts with a letter.
    private func parseHostname(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        var lastLabel = -1
        repeat {
            var q = scan(p, n, Self.isAlphanumeric)
            if q <= p {
                break
            }
            lastLabel = p
            p = q
            q = scan(p, n) { Self.isAlphanumeric($0) || $0 == 0x2D }
            if q > p {
                if bytes[q - 1] == 0x2D {
                    throw Malformed()
                }
                p = q
            }
            q = at(p, n, 0x2E) ? p + 1 : p
            if q <= p {
                break
            }
            p = q
        } while p < n
        if p < n && !at(p, n, 0x3A) {
            throw Malformed()
        }
        if lastLabel < 0 {
            throw Malformed()
        }
        if lastLabel > start && !Self.isAlpha(bytes[lastLabel]) {
            throw Malformed()
        }
        return p
    }

    // MARK: IPv4

    /// Non-strict IPv4 (Java `parseIPv4Address`): -1 unless a well-formed address is followed
    /// by the end or `:`.
    private func parseIPv4Address(_ start: Int, _ n: Int) -> Int {
        var p: Int
        do {
            p = try scanIPv4Address(start, n, strict: false)
        } catch {
            return -1
        }
        if p > start && p < n && bytes[p] != 0x3A {
            p = -1
        }
        return p
    }

    /// Four decimal runs whose values are ≤ 255 (any number of digits, as Java), separated by
    /// dots, ending exactly where the digit/dot run ends. -1 when no digit/dot run starts here
    /// (or, `strict`, when it does not reach `n`).
    private func scanIPv4Address(_ start: Int, _ n: Int, strict: Bool) throws -> Int {
        var p = start
        let m = scan(p, n) { Self.isDigit($0) || $0 == 0x2E }
        if m <= p || (strict && m != n) {
            return -1
        }
        for part in 0..<4 {
            if part > 0 {
                guard at(p, m, 0x2E) else {
                    throw Malformed()
                }
                p += 1
            }
            let q = try scanByte(p, m)
            guard q > p else {
                throw Malformed()
            }
            p = q
        }
        guard p == m else {
            throw Malformed()  // "Malformed IPv4 address"
        }
        return p
    }

    /// Java `scanByte`: a digit run whose value is ≤ 255; `Integer.parseInt` overflow throws.
    private func scanByte(_ start: Int, _ n: Int) throws -> Int {
        let q = scan(start, n, Self.isDigit)
        if q <= start {
            return q
        }
        var value = 0
        for byte in bytes[start..<q] {
            value = value * 10 + Int(byte - 0x30)
            guard value <= Int(Int32.max) else {
                throw Malformed()  // NumberFormatException
            }
        }
        return value > 255 ? start : q
    }

    private func takeIPv4Address(_ start: Int, _ n: Int) throws -> Int {
        let p = try scanIPv4Address(start, n, strict: true)
        guard p > start else {
            throw Malformed()
        }
        return p
    }

    // MARK: IPv6 (RFC 2373 text forms, as Java)

    private mutating func parseIPv6Reference(_ start: Int, _ n: Int) throws {
        ipv6ByteCount = 0
        var p = start
        var compressedZeros = false
        let q = try scanHexSeq(p, n)
        if q > p {
            p = q
            if atDoubleColon(p, n) {
                compressedZeros = true
                p = try scanHexPost(p + 2, n)
            } else if at(p, n, 0x3A) {
                p = try takeIPv4Address(p + 1, n)
                ipv6ByteCount += 4
            }
        } else if atDoubleColon(p, n) {
            compressedZeros = true
            p = try scanHexPost(p + 2, n)
        }
        guard p >= n else {
            throw Malformed()  // "Malformed IPv6 address"
        }
        guard ipv6ByteCount <= 16 else {
            throw Malformed()  // "IPv6 address too long"
        }
        if !compressedZeros && ipv6ByteCount < 16 {
            throw Malformed()  // "IPv6 address too short"
        }
        if compressedZeros && ipv6ByteCount == 16 {
            throw Malformed()
        }
    }

    private mutating func scanHexPost(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        if p == n {
            return p
        }
        let q = try scanHexSeq(p, n)
        if q > p {
            p = q
            if at(p, n, 0x3A) {
                p += 1
                p = try takeIPv4Address(p, n)
                ipv6ByteCount += 4
            }
        } else {
            p = try takeIPv4Address(p, n)
            ipv6ByteCount += 4
        }
        return p
    }

    /// `hex4 *( ":" hex4 )`, stopping before `::` or before an embedded IPv4 address; -1 if
    /// no group starts here.
    private mutating func scanHexSeq(_ start: Int, _ n: Int) throws -> Int {
        var p = start
        var q = scan(p, n, Self.isHex)
        if q <= p {
            return -1
        }
        if at(q, n, 0x2E) {
            return -1
        }
        if q > p + 4 {
            throw Malformed()  // "IPv6 hexadecimal digit sequence too long"
        }
        ipv6ByteCount += 2
        p = q
        while p < n {
            if !at(p, n, 0x3A) {
                break
            }
            if at(p + 1, n, 0x3A) {
                break  // "::"
            }
            p += 1
            q = scan(p, n, Self.isHex)
            if q <= p {
                throw Malformed()  // "Expected digits for an IPv6 address"
            }
            if at(q, n, 0x2E) {
                p -= 1  // beginning of an IPv4 address
                break
            }
            if q > p + 4 {
                throw Malformed()
            }
            ipv6ByteCount += 2
            p = q
        }
        return p
    }
}

// MARK: - Transport accessors

extension RemoteRoute {
    /// `url.trimEnd('/')` with the first `https://` replaced by `wss://`, plus `/v1/tunnel`
    /// (`RemoteTunnel.kt:42`).
    public var tunnelURL: String {
        let base = RemoteRoute.trimmingTrailingSlashes(url)
        let rest = base.hasPrefix("https://") ? String(base.dropFirst("https://".count)) : base
        return "wss://" + rest + "/v1/tunnel"
    }

    /// `url.trimEnd('/') + "/v1/ice"` (`RemoteIce.kt:29`).
    public var iceURL: String {
        RemoteRoute.trimmingTrailingSlashes(url) + "/v1/ice"
    }

    /// TCP connect host: the URI host without IPv6 brackets.
    public var connectHost: String {
        if authorityHost.hasPrefix("["), authorityHost.hasSuffix("]"), authorityHost.count >= 2 {
            return String(authorityHost.dropFirst().dropLast())
        }
        return authorityHost
    }

    /// TCP connect port: the explicit port, else 443.
    public var connectPort: Int { explicitPort ?? 443 }

    /// WebSocket upgrade `Host` header: host (bracketed if IPv6) plus `:port` only when an
    /// explicit port other than 443 is present (Java-WebSocket 1.6.0 `sendHandshake`).
    public var hostHeader: String {
        if let port = explicitPort, port != 443 {
            return authorityHost + ":" + String(port)
        }
        return authorityHost
    }

    /// True for an IPv4 or bracketed IPv6 literal host: no SNI is sent and trust is evaluated against IP SANs.
    public var hostIsIPLiteral: Bool {
        if authorityHost.hasPrefix("[") {
            return true
        }
        let parts = authorityHost.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber }
                && (Int(part) ?? 256) <= 255
        }
    }

    /// Kotlin `trimEnd('/')`.
    private static func trimmingTrailingSlashes(_ text: String) -> String {
        var result = Substring(text)
        while result.hasSuffix("/") {
            result = result.dropLast()
        }
        return String(result)
    }
}
