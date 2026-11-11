import Foundation

/// Media recovery budget and ICE restart policy (Kotlin `LanRecovery`, `LanRecovery.kt`).
///
/// Worker-owned (no locking). Times are monotonic milliseconds (`MonotonicClock.nowMs()`). The window starts at the
/// **first** unhealthy observation and never moves on retries, new failures or further network changes. Signaling
/// retries reuse the same generation and prepared answer.
public final class LanRecovery: CustomStringConvertible, CustomReflectable {
    /// The report's `lan_recovery` object (`LanRecovery.kt:130-131`; host vocabulary of `signaling_route`:
    /// `default|wifi|ethernet|vpn|unavailable`).
    public struct Fields: Equatable, Sendable {
        /// `recovering` or `settled`.
        public let phase: String
        /// ICE restarts begun (`generation`).
        public let restarts: Int64
        public let signalingRoute: String

        public init(phase: String, restarts: Int64, signalingRoute: String) {
            self.phase = phase
            self.restarts = restarts
            self.signalingRoute = signalingRoute
        }

        /// Wire object, Kotlin key order `phase, restarts, signaling_route`.
        public func json() -> DiagnosticJSON {
            let fields: [(key: String, value: DiagnosticJSON)] = [
                ("phase", .string(phase)),
                ("restarts", .int(restarts)),
                ("signaling_route", .string(signalingRoute)),
            ]
            return .object(fields)
        }
    }

    public static let supportedWindowMs: Int64 = 30_000
    public static let legacyWindowMs: Int64 = 10_000
    /// At most two restarts per interruption episode.
    public static let maxAttempts = 2
    /// A restart needs ≥ 1000 ms of failure unless a network change requested it.
    public static let failureDelayMs: Int64 = 1_000
    /// ≥ 8000 ms between restart starts.
    public static let attemptSpacingMs: Int64 = 8_000
    /// ≥ 5000 ms after the previous accepted answer (host restart throttle, kept across episodes).
    public static let acceptedSpacingMs: Int64 = 5_000

    /// Host negotiated `ice_restart_version == 1` on a v3 invitation.
    public let supported: Bool
    /// 30 000 ms when supported, else 10 000 ms.
    public let limitMs: Int64
    private let restartDelayMs: Int64
    private let restartIntervalMs: Int64
    private let restartLimit: Int

    private var failedAt: Int64?
    private var attempts = 0
    private var lastAttemptAt: Int64 = 0
    private var lastAcceptedAt: Int64?

    /// Media was healthy at least once (startup failures never restart ICE).
    public private(set) var established = false
    /// Restart generations begun (`/recover-offer` `generation`).
    public private(set) var generation: Int64 = 0
    /// A restart answer has not been accepted yet.
    public private(set) var pending = false
    /// A network change asked for an immediate restart.
    public private(set) var restartRequested = false
    /// Prepared restart answer SDP, reused verbatim on a lost `/recover-answer` reply. Private data.
    public var answer: String?

    public init(
        supported: Bool, limitMs: Int64? = nil, restartDelayMs: Int64 = LanRecovery.failureDelayMs,
        restartIntervalMs: Int64 = LanRecovery.attemptSpacingMs, maxRestarts: Int = LanRecovery.maxAttempts
    ) {
        self.supported = supported
        self.limitMs = max(1, limitMs ?? (supported ? LanRecovery.supportedWindowMs : LanRecovery.legacyWindowMs))
        self.restartDelayMs = max(0, restartDelayMs)
        self.restartIntervalMs = max(LanRecovery.acceptedSpacingMs, restartIntervalMs)
        self.restartLimit = max(1, min(maxRestarts, 10))
    }

    /// An interruption episode is open.
    public var active: Bool { failedAt != nil }

    /// A failed signaling request (`LanRecovery.kt:25-31`): false when stopped or not retryable for this session;
    /// otherwise the failed request itself is charged to the window from `attemptedAt`, so repeated failures and late
    /// network callbacks cannot start a fresh budget or discard a prepared answer.
    public func signalingFailed(_ error: Error, attemptedAt: Int64, stopped: Bool = false) -> Bool {
        if stopped || !ConnectionFailure.retryableStatus(error, establishedSession: established) { return false }
        observe(healthy: false, now: attemptedAt)
        return true
    }

    /// Records one health observation; returns true when an interruption just recovered
    /// (`LanRecovery.kt:91-98`). A stale "connected" while a restart is requested or pending counts
    /// as unhealthy.
    @discardableResult
    public func observe(healthy: Bool, now: Int64) -> Bool {
        if expired(now) { return false }
        if !healthy || pending || restartRequested {
            if failedAt == nil { failedAt = now }
            return false
        }
        established = true
        let recovered = active
        failedAt = nil
        attempts = 0
        answer = nil
        return recovered
    }

    /// Milliseconds left in the current window (`limitMs` when no episode is open).
    public func remaining(_ now: Int64) -> Int64 {
        guard let failedAt = failedAt else { return limitMs }
        return max(limitMs - (now - failedAt), 0)
    }

    public func expired(_ now: Int64) -> Bool {
        active && remaining(now) == 0
    }

    /// A taken network handoff (step 2): opens/keeps the episode and requests a restart.
    public func networkChanged(_ now: Int64) {
        if !supported || !established || expired(now) { return }
        observe(healthy: false, now: now)
        restartRequested = true
    }

    /// Restart policy of `LanRecovery.kt:105-107`.
    public func restartDue(_ now: Int64) -> Bool {
        guard supported, established, let failedAt = failedAt, !pending, !expired(now),
            attempts < restartLimit
        else { return false }
        guard restartRequested || now - failedAt >= restartDelayMs else { return false }
        guard attempts == 0 || now - lastAttemptAt >= restartIntervalMs else { return false }
        if let lastAcceptedAt = lastAcceptedAt, now - lastAcceptedAt < Self.acceptedSpacingMs { return false }
        return true
    }

    /// Begins restart generation `generation + 1`. Throws `ICEProtocolError.restartNotDue` (fatal
    /// internal error, Kotlin `check`) unless `restartDue(now)`.
    public func begin(_ now: Int64) throws {
        guard restartDue(now) else { throw ICEProtocolError.restartNotDue }
        generation += 1
        attempts += 1
        lastAttemptAt = now
        pending = true
        answer = nil
        restartRequested = false
    }

    /// `/recover-answer` acknowledged. Throws `ICEProtocolError.recoveryNotPending` unless pending.
    public func accepted(_ now: Int64) throws {
        guard pending else { throw ICEProtocolError.recoveryNotPending }
        pending = false
        lastAcceptedAt = now
    }

    /// One status round (`LanRecovery.kt:115-125`, synchronous): deadline check → optional restart (`beforeRestart`
    /// then `begin`) → `restore` while pending → deadline check → `poll`. Throws `RecoveryTimeout.deadlineReached` once
    /// the window expired. No reporting or sleep is inserted between an accepted answer and its confirmation poll.
    public func exchangeStatus<T>(
        now: () -> Int64, beforeRestart: () throws -> Void,
        restore: () throws -> Void, poll: () throws -> T
    ) throws -> T {
        if expired(now()) { throw RecoveryTimeout.deadlineReached }
        if restartDue(now()) {
            try beforeRestart()
            if expired(now()) { throw RecoveryTimeout.deadlineReached }
            try begin(now())
        }
        if pending { try restore() }
        if expired(now()) { throw RecoveryTimeout.deadlineReached }
        return try poll()
    }

    /// Copy-report line (`LanRecovery.kt:70`, fractional seconds retained). The session replaces
    /// "LAN media recovery" by "Media recovery" when appending it (`StreamReceiver.kt:785`).
    public func text() -> String {
        let window = ConnectionPreferences.seconds(Int(clamping: limitMs))
        return "LAN media recovery: \(active ? "recovering" : "settled") · ICE restarts requested: \(generation)"
            + " · Window: \(window) seconds"
    }

    /// The report's `lan_recovery` object; included only when `supported` (step 16).
    public func fields(route: String) -> Fields {
        Fields(phase: active ? "recovering" : "settled", restarts: generation, signalingRoute: route)
    }

    public var description: String { "LanRecovery(\(active ? "recovering" : "settled"))" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Literal private IPv4 recognition for LAN hosts (Kotlin `LanAddress`, `LanNetwork.kt:12-20`).
public enum LanAddress {
    /// Exactly four dot-separated integers 0...255 inside 10/8, 172.16/12, 192.168/16 or
    /// 169.254/16 → the four bytes; anything else → nil.
    public static func bytes(_ host: String) -> [UInt8]? {
        var values: [Int] = []
        for part in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let local =
            values[0] == 10
            || (values[0] == 172 && (16...31).contains(values[1]))
            || (values[0] == 192 && values[1] == 168)
            || (values[0] == 169 && values[1] == 254)
        return local ? values.map { UInt8($0) } : nil
    }
}
