import Foundation

/// One native ICE server, one per URL from `GET /v1/ice` (step 12, Kotlin `RemoteIce.kt:322`). STUN entries carry `""`
/// username/credential (parity).
///
/// Private data (TURN REST credentials, server addresses): `description`, `debugDescription` and reflection print a
/// fixed label only. The app maps it to `RTCIceServer(urlStrings: [url], username:, credential:)` (extension
/// `rtcIceServers()`).
public struct RemoteICEServer: Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let url: String
    public let username: String
    public let credential: String

    public init(url: String, username: String, credential: String) {
        self.url = url
        self.username = username
        self.credential = credential
    }

    /// Scheme `turn` or `turns`.
    public var isTURN: Bool { url.hasPrefix("turn:") || url.hasPrefix("turns:") }

    public var description: String { "RemoteICEServer(private)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A validated `/v1/ice` result. Memory-only; never persisted, logged or reported.
public struct RemoteICEConfiguration: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// One per URL, server order preserved, at most 8.
    public let servers: [RemoteICEServer]
    /// Rendezvous `expires_at`, wall-clock Unix seconds.
    public let expiresAt: Int64
    /// At least one TURN URL was accepted.
    public let hasTURN: Bool

    public init(servers: [RemoteICEServer], expiresAt: Int64, hasTURN: Bool) {
        self.servers = servers
        self.expiresAt = expiresAt
        self.hasTURN = hasTURN
    }

    /// LAN sessions use no ICE servers (`StreamReceiver.kt:1648-1650`).
    public static let empty = RemoteICEConfiguration(servers: [], expiresAt: 0, hasTURN: false)

    /// Ordered URL list for `InitialRelayGathering.eligible(relayOnly:urls:)`.
    public var urls: [String] { servers.map { $0.url } }

    public var description: String { "RemoteICEConfiguration(private)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Pure validation of a `/v1/ice` 200 body (rules 3-10, steps 9-13; Kotlin `RemoteIce.kt:296-326`; host-name rule Go
/// `internal/rendezvous/config.go:105-136`).
public enum RemoteICEParser {
    public static let maxBodyBytes = 16_384
    public static let maxServers = 8
    public static let maxURLsPerServer = 8
    public static let maxURLs = 8
    public static let maxFieldBytes = 512
    /// `now + 61 <= expires_at <= now + 660` (wall seconds).
    public static let minimumLifetimeSeconds: Int64 = 61
    public static let maximumLifetimeSeconds: Int64 = 660

    /// Validates `body` against the rules of steps 9-13 using `now` (wall seconds taken at the start of the fetch).
    /// Rule violations throw `ICEProtocolError.invalidConfiguration` (non-retryable); `forceRelay` without an accepted
    /// TURN URL throws `ControlIOError(.iceUnavailable(.forcedRelayRequiresTURN))` (retryable I/O).
    public static func parse(_ body: Data, now: Int64, forceRelay: Bool) throws -> RemoteICEConfiguration {
        guard body.count <= maxBodyBytes,
            let object = try? StrictJSONObject(data: body),
            object.keys == ["version", "expires_at", "ice_servers"],
            case .integer(1)? = object.value("version"),
            case .integer(let expiry)? = object.value("expires_at"),
            case .array(let list)? = object.value("ice_servers"), list.count <= maxServers
        else { throw ICEProtocolError.invalidConfiguration }
        let lifetime = expiry.subtractingReportingOverflow(now)
        guard !lifetime.overflow,
            (minimumLifetimeSeconds...maximumLifetimeSeconds).contains(lifetime.partialValue)
        else { throw ICEProtocolError.invalidConfiguration }
        var result: [RemoteICEServer] = []
        for value in list {
            guard case .object(let server) = value,
                server.keys.isSubset(of: ["urls", "username", "credential"]),
                case .array(let urls)? = server.value("urls"),
                (1...maxURLsPerServer).contains(urls.count)
            else { throw ICEProtocolError.invalidConfiguration }
            let username = try credential(server.value("username"))
            let password = try credential(server.value("credential"))
            for value in urls {
                guard case .string(let url) = value, result.count < maxURLs else {
                    throw ICEProtocolError.invalidConfiguration
                }
                let turn = try validateURL(url)
                guard turn ? (!username.isEmpty && !password.isEmpty) : (username.isEmpty && password.isEmpty) else {
                    throw ICEProtocolError.invalidConfiguration
                }
                result.append(RemoteICEServer(url: url, username: username, credential: password))
            }
        }
        let hasTURN = result.contains { $0.isTURN }
        if forceRelay && !hasTURN { throw ControlIOError(.iceUnavailable(.forcedRelayRequiresTURN)) }
        return RemoteICEConfiguration(servers: result, expiresAt: expiry, hasTURN: hasTURN)
    }

    private static func credential(_ value: StrictJSONObject.Value?) throws -> String {
        guard let value else { return "" }
        guard case .string(let text) = value, text.utf8.count <= maxFieldBytes,
            !text.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
        else { throw ICEProtocolError.invalidConfiguration }
        return text
    }

    private static func validateURL(_ url: String) throws -> Bool {
        guard url.utf8.count <= maxFieldBytes,
            url.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![47, 35, 37, 64].contains($0) }),
            let colon = url.firstIndex(of: ":")
        else { throw ICEProtocolError.invalidConfiguration }
        let scheme = String(url[..<colon])
        let turn = scheme == "turn" || scheme == "turns"
        guard turn || scheme == "stun" else { throw ICEProtocolError.invalidConfiguration }
        let parts = url[url.index(after: colon)...].split(separator: "?", omittingEmptySubsequences: false)
        guard let endpoint = parts.first, RemoteRoute.isValidICEEndpoint(String(endpoint)) else {
            throw ICEProtocolError.invalidConfiguration
        }
        if turn {
            guard parts.count == 2, parts[1] == "transport=tcp" || parts[1] == "transport=udp",
                scheme != "turns" || parts[1] == "transport=tcp"
            else { throw ICEProtocolError.invalidConfiguration }
        } else if parts.count != 1 {
            throw ICEProtocolError.invalidConfiguration
        }
        return turn
    }
}

/// The process-wide `/v1/ice` credential cache and attempt throttle as a pure, synchronous type (= steps 1-5 and 14;
/// Kotlin `RemoteIce.fetch`, `RemoteIce.kt:275-332`).
///
/// One instance lives for the app process (owned by the app's `RemoteICEService`) and survives
/// Stop/reconnect. The cache is refreshed only when fewer than 60 s of credential lifetime remain at
/// the moment servers are needed (initial setup, each new restart generation); a started attempt
/// blocks another attempt for the same route for 30 s, success or failure (rendezvous issuance
/// bucket: burst 2, one per 30 s). A different route resets the throttle. A failed or cancelled
/// fetch never commits.
///
/// Serialization (Android `@Synchronized`): either call `fetch(...)`, which holds an internal gate across `perform`
/// (worker-thread callers), or call `lookup` / `complete` from inside one external FIFO gate (an actor must not hold an
/// `NSLock` across `await`). Do not coalesce callers onto one in-flight result: a second caller after a failure must
/// see the throttle error.
public final class RemoteICECache: @unchecked Sendable, CustomReflectable {
    /// Cached credentials are reused while `expires_at > now + 60`.
    public static let refreshMarginSeconds: Int64 = 60
    /// Minimum monotonic spacing between attempts for the same route.
    public static let attemptSpacingMs: Int64 = 30_000

    fileprivate struct RouteKey: Equatable {
        let url: String
        let token: String

        static func == (lhs: RouteKey, rhs: RouteKey) -> Bool {
            ICEDescription.bytesEqual(lhs.url, rhs.url) && ICEDescription.bytesEqual(lhs.token, rhs.token)
        }
    }

    /// One network attempt authorized by `lookup`. Private data (holds the bearer token).
    public struct Attempt: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// `remote.url` with all trailing `/` removed + `/v1/ice`.
        public let iceURL: String
        /// Exact `Authorization` header value: `Bearer <43-char token>` (50 bytes).
        public let authorization: String
        public let forceRelay: Bool
        /// Wall-clock seconds at the start of the fetch; the expiry rule is evaluated against it.
        public let nowSeconds: Int64
        fileprivate let key: RouteKey

        public var description: String { "RemoteICECache.Attempt(private)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    public enum Lookup: Sendable {
        /// Valid cached credentials (no network).
        case cached(RemoteICEConfiguration)
        /// Perform `GET attempt.iceURL` (connect/read 8000 ms, no redirects, no caches, no `Origin`),
        /// throw `HTTPFailure` for a non-200 status, then pass the body to `complete`.
        case fetch(Attempt)
    }

    private let clock: any MonotonicClock
    private let wallSeconds: @Sendable () -> Int64
    private let stateLock = NSLock()
    private let fetchGate = NSLock()
    private var key: RouteKey?
    private var expires: Int64 = 0
    private var configuration = RemoteICEConfiguration.empty
    private var nextAttempt: Int64 = 0

    /// `wallSeconds` defaults to `floor(Date().timeIntervalSince1970)` (Android `System.currentTimeMillis() / 1000`);
    /// `clock` is the app's `SystemMonotonicClock`.
    public init(
        clock: any MonotonicClock,
        wallSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970.rounded(.down)) }
    ) {
        self.clock = clock
        self.wallSeconds = wallSeconds
    }

    /// Steps 2-5: cache hit, throttle, or a new attempt (which sets `nextAttempt = now + 30 s` before
    /// any request). Call the session `checkpoint()` first (step 1).
    /// Throws `ControlIOError(.iceUnavailable(.forcedRelayRequiresTURN))` for a cache hit without TURN
    /// under forced relay and `ControlIOError(.iceUnavailable(.throttled))` inside the 30 s spacing.
    public func lookup(url: String, token: String, forceRelay: Bool) throws -> Lookup {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = wallSeconds()
        let selected = RouteKey(url: url, token: token)
        if key == selected && expires > now + Self.refreshMarginSeconds {
            if forceRelay && !configuration.hasTURN {
                throw ControlIOError(.iceUnavailable(.forcedRelayRequiresTURN))
            }
            return .cached(configuration)
        }
        if key == selected && clock.nowMs() < nextAttempt {
            throw ControlIOError(.iceUnavailable(.throttled))
        }
        key = selected
        expires = 0
        nextAttempt = clock.nowMs() + Self.attemptSpacingMs
        return .fetch(
            Attempt(
                iceURL: Self.iceURL(url), authorization: "Bearer " + token,
                forceRelay: forceRelay, nowSeconds: now, key: selected))
    }

    /// Steps 8-14 for a 200 body: size cap (`ControlIOError(.iceUnavailable(.tooLarge))`),
    /// `RemoteICEParser.parse`, then `checkpoint()` (a cancelled fetch never commits), then commit.
    public func complete(_ attempt: Attempt, body: Data, checkpoint: () throws -> Void) throws -> RemoteICEConfiguration
    {
        guard body.count <= RemoteICEParser.maxBodyBytes else {
            throw ControlIOError(.iceUnavailable(.tooLarge))
        }
        let result = try RemoteICEParser.parse(body, now: attempt.nowSeconds, forceRelay: attempt.forceRelay)
        try checkpoint()
        stateLock.lock()
        defer { stateLock.unlock() }
        if key == attempt.key {
            expires = result.expiresAt
            configuration = result
        }
        return result
    }

    /// Whole algorithm, serialized by an internal gate held across `perform` (Android `@Synchronized`). `perform`
    /// executes the HTTPS GET for the attempt (registering it so Stop can cancel it), throws `HTTPFailure` for a
    /// non-200 status and TLS/transport errors, and returns the 200 body read with a hard 16384-byte cap.
    public func fetch(
        url: String, token: String, forceRelay: Bool, checkpoint: () throws -> Void,
        perform: (Attempt) throws -> Data
    ) throws -> RemoteICEConfiguration {
        fetchGate.lock()
        defer { fetchGate.unlock() }
        try checkpoint()
        switch try lookup(url: url, token: token, forceRelay: forceRelay) {
        case .cached(let cached):
            return cached
        case .fetch(let attempt):
            let body = try perform(attempt)
            return try complete(attempt, body: body, checkpoint: checkpoint)
        }
    }

    /// A fetch on a departed network must not throttle the first attempt on its replacement.
    /// Valid cached credentials are retained; only the attempt-spacing gate is reopened.
    public func retryAfterInterruption() {
        stateLock.lock()
        nextAttempt = 0
        stateLock.unlock()
    }

    /// `url.trimEnd('/') + "/v1/ice"` (`RemoteIce.kt:288`).
    public static func iceURL(_ url: String) -> String {
        var trimmed = Substring(url)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed) + "/v1/ice"
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
