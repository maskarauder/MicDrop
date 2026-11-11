import Foundation

/// The 5-minute consent window of an automatically or manually paused duplex session (`A/MicrophoneService.kt:40-47`),
/// ported verbatim.
///
/// `nowMs` must come from a sleep-inclusive monotonic clock (`MonotonicClock.nowMs()`, — Android `elapsedRealtime`),
/// never `ProcessInfo.systemUptime`/`DispatchTime`, so deep sleep cannot extend microphone consent. A repeated loss
/// never renews the original deadline. Every control entry of the controller first checks `expired(nowMs:)`.
public struct DuplexPauseWindow: Equatable, Sendable {
    /// 5 × 60 × 1000 ms (`A/MicrophoneService.kt:42`).
    public static let defaultLimitMs: Int64 = 300_000

    public let limitMs: Int64
    /// Absolute deadline on the caller's monotonic clock, or nil when no pause is retained.
    public private(set) var deadlineMs: Int64?

    public init(limitMs: Int64 = DuplexPauseWindow.defaultLimitMs) {
        self.limitMs = limitMs
        self.deadlineMs = nil
    }

    /// `retain(now)`: sets the deadline only if unset. (Wrapping addition like Kotlin `Long`: an
    /// extreme injected time yields an already-expired window instead of a trap.)
    public mutating func retain(nowMs: Int64) {
        if deadlineMs == nil { deadlineMs = nowMs &+ limitMs }
    }

    /// `expired(now)` = deadline set && now >= deadline.
    public func expired(nowMs: Int64) -> Bool {
        guard let deadlineMs else { return false }
        return nowMs >= deadlineMs
    }

    /// Time until expiry (0 when expired), or nil when no pause is retained; used to
    /// schedule the expiry timer on the first pause of an episode.
    public func remainingMs(nowMs: Int64) -> Int64? {
        guard let deadlineMs else { return nil }
        return max(0, deadlineMs &- nowMs)
    }

    /// `clear()`.
    public mutating func clear() {
        deadlineMs = nil
    }
}
