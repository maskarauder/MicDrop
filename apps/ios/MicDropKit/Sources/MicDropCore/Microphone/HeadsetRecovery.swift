import Foundation

/// Bounded restoration of the *same* Bluetooth headset (`A/HeadsetRecovery.kt`), ported verbatim.
///
/// Shared by route callbacks and the session worker; every member is serialized by one `NSLock` (Kotlin
/// `@Synchronized`; `OSAllocatedUnfairLock` is unavailable on Linux). Repeated route callbacks bump `revision`
/// (invalidating an in-flight acknowledgment) but never extend the original window. Native audio gates and completion
/// are serialized separately by the session's audio lock. Callers supply fixed, redacted "Last check" labels only
/// (`Check`), never device identity.
///
/// Time arithmetic and the episode/revision counters use wrapping operators, exactly like
/// Kotlin `Long`, so an injected clock at an extreme value can never trap the session worker.
public final class HeadsetRecovery: @unchecked Sendable {
    /// `HeadsetRecoveryTicket(episode, revision)` (`A/HeadsetRecovery.kt:3`).
    public struct Ticket: Equatable, Hashable, Sendable {
        public let episode: Int64
        public let revision: Int64

        public init(episode: Int64, revision: Int64) {
            self.episode = episode
            self.revision = revision
        }
    }

    /// Fixed "Last check" labels. Routing passes `HeadsetEndpoint.State.text` for endpoint inspections and these labels
    /// for the other steps.
    public enum Check {
        public static let notStarted = "not started"
        public static let checking = "checking selected headset"
        public static let portUnavailable = "selected port unavailable"
        public static let portAvailable = "selected port available"
        public static let selectionRejected = "iOS rejected headset selection"
        public static let waitingCommunicationRoute = "waiting for original communication route"
        public static let waitingMicrophoneSource = "waiting for original microphone source"
        public static let waitingVerifiedMicrophone = "waiting for verified original microphone"
        public static let waitingVerifiedOutput = "waiting for verified original output and channel count"
    }

    /// `WINDOW_MS` (`A/HeadsetRecovery.kt:10`): the default; a session passes its configured Advanced window
    /// (`AdvancedAudioPreferences.bluetoothRecoveryMs`) as `limitMs`.
    public static let windowMs: Int64 = 20_000
    /// `WINDOW_SECONDS`.
    public static let windowSeconds: Int64 = windowMs / 1000
    /// Counter saturation, 2^53 − 1 (`:51`).
    public static let counterLimit: Int64 = 9_007_199_254_740_991
    /// Reselection / profile requests per episode and their minimum spacing (`:47-71`).
    public static let requestsPerEpisode = 3
    public static let requestSpacingMs: Int64 = 500
    /// First words of `text()`; the terminal copy report replaces earlier lines with this prefix
    /// (`A/StreamReceiver.kt:796-800`).
    public static let textPrefix = "Selected headset recovery:"

    private let lock = NSLock()
    /// This session's window; every episode gets exactly this much time from its first `request`.
    public let limitMs: Int64
    private var startedAt: Int64?
    private var episode: Int64 = 0
    private var revision: Int64 = 0
    private var cancelled = false
    private var lastSelectionAt: Int64?
    private var episodeSelections = 0
    private var totalSelections: Int64 = 0
    private var completed: Int64 = 0
    private var routeReleased = false
    private var totalRouteReleases: Int64 = 0
    private var lastProfileRequestAt: Int64?
    private var episodeProfileRequests = 0
    private var totalProfileRequests: Int64 = 0
    private var lastCheck = Check.notStarted

    public init(limitMs: Int64 = HeadsetRecovery.windowMs) {
        self.limitMs = limitMs
    }

    /// `request(nowMs)`: false once cancelled; starts an episode if none is running
    /// (resets per-episode budgets and "Last check"), then bumps `revision`.
    @discardableResult
    public func request(nowMs: Int64) -> Bool {
        locked {
            if cancelled { return false }
            if startedAt == nil {
                startedAt = nowMs
                episode &+= 1
                lastSelectionAt = nil
                episodeSelections = 0
                routeReleased = false
                lastCheck = Check.checking
                lastProfileRequestAt = nil
                episodeProfileRequests = 0
            }
            revision &+= 1
            return true
        }
    }

    /// `current()`: the in-flight ticket, or nil when not started or cancelled.
    public func current() -> Ticket? {
        locked { unlockedCurrent() }
    }

    /// `pending()` = started and not cancelled.
    public func pending() -> Bool {
        locked { unlockedPending() }
    }

    /// `remaining(nowMs)` = `max(0, limit − (now − startedAt))`, or 0 when not started.
    public func remaining(nowMs: Int64) -> Int64 {
        locked { unlockedRemaining(nowMs) }
    }

    /// `reselectionDue(nowMs, endpointAvailable)`: at most 3 per episode, ≥ 500 ms apart,
    /// only while pending with time remaining and the endpoint available.
    public func reselectionDue(nowMs: Int64, endpointAvailable: Bool = true) -> Bool {
        locked {
            if !endpointAvailable || !unlockedPending() || unlockedRemaining(nowMs) == 0
                || episodeSelections >= HeadsetRecovery.requestsPerEpisode
            {
                return false
            }
            if let lastSelectionAt, nowMs &- lastSelectionAt < HeadsetRecovery.requestSpacingMs { return false }
            lastSelectionAt = nowMs
            episodeSelections += 1
            totalSelections = min(totalSelections + 1, HeadsetRecovery.counterLimit)
            return true
        }
    }

    /// `routeReleaseDue(nowMs, endpointAvailable)`: once per episode while the endpoint is unavailable. Never called on
    /// iOS (no communication-route release); kept for the ported tests and the report counter.
    public func routeReleaseDue(nowMs: Int64, endpointAvailable: Bool) -> Bool {
        locked {
            if endpointAvailable || !unlockedPending() || unlockedRemaining(nowMs) == 0 || routeReleased {
                return false
            }
            routeReleased = true
            totalRouteReleases = min(totalRouteReleases + 1, HeadsetRecovery.counterLimit)
            return true
        }
    }

    /// `profileRequestDue(nowMs)`: same 3 / 500 ms budget shape as reselection. Never called on iOS (no HFP profile
    /// request API); kept for parity and tests.
    public func profileRequestDue(nowMs: Int64) -> Bool {
        locked {
            if !unlockedPending() || unlockedRemaining(nowMs) == 0
                || episodeProfileRequests >= HeadsetRecovery.requestsPerEpisode
            {
                return false
            }
            if let lastProfileRequestAt, nowMs &- lastProfileRequestAt < HeadsetRecovery.requestSpacingMs {
                return false
            }
            lastProfileRequestAt = nowMs
            episodeProfileRequests += 1
            totalProfileRequests = min(totalProfileRequests + 1, HeadsetRecovery.counterLimit)
            return true
        }
    }

    /// `observe(check)`: records a fixed label while pending.
    public func observe(_ check: String) {
        locked { if unlockedPending() { lastCheck = check } }
    }

    /// `complete(ticket, nowMs)`: succeeds only for the current ticket with time remaining;
    /// ends the episode and counts it.
    public func complete(_ ticket: Ticket, nowMs: Int64) -> Bool {
        locked {
            if unlockedCurrent() != ticket || unlockedRemaining(nowMs) == 0 { return false }
            startedAt = nil
            completed = min(completed + 1, HeadsetRecovery.counterLimit)
            return true
        }
    }

    /// `cancel()`: permanent for this session (Stop wins an in-flight completion).
    public func cancel() {
        locked {
            cancelled = true
            startedAt = nil
        }
    }

    /// `text()` (`A/HeadsetRecovery.kt:84-86`): `Selected headset recovery: <stopped|restoring|settled> · Window:
    /// <limitMs> ms · Completed: <n> · Reselection requests: <n> · Route releases: <n> · SCO profile requests: <n> ·
    /// Last check: <label>`. `Window` is this session's configured window in milliseconds. With `platformNotes` (the
    /// iOS copy report) a zero "Route releases" / "SCO profile requests" value is followed by ` (not available on
    /// iOS)`; pass `false` for the verbatim Android text (ported tests).
    public func text(platformNotes: Bool = true) -> String {
        locked {
            let state = cancelled ? "stopped" : (unlockedPending() ? "restoring" : "settled")
            func iosOnly(_ value: Int64) -> String {
                platformNotes && value == 0 ? "0 (not available on iOS)" : "\(value)"
            }
            return "\(HeadsetRecovery.textPrefix) \(state) · Window: \(limitMs) ms · Completed: \(completed) · "
                + "Reselection requests: \(totalSelections) · Route releases: \(iosOnly(totalRouteReleases)) · "
                + "SCO profile requests: \(iosOnly(totalProfileRequests)) · Last check: \(lastCheck)"
        }
    }

    // MARK: - Unlocked helpers (callers hold `lock`; NSLock is not reentrant)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func unlockedPending() -> Bool { startedAt != nil && !cancelled }

    private func unlockedCurrent() -> Ticket? {
        guard startedAt != nil, !cancelled else { return nil }
        return Ticket(episode: episode, revision: revision)
    }

    private func unlockedRemaining(_ nowMs: Int64) -> Int64 {
        guard let startedAt else { return 0 }
        return max(0, limitMs &- (nowMs &- startedAt))
    }
}

/// name for `HeadsetRecovery.Ticket`.
public typealias HeadsetRecoveryTicket = HeadsetRecovery.Ticket
