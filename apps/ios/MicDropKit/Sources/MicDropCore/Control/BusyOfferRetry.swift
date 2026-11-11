import Foundation

/// Busy (`423`) offer retry window (`A/BusyOfferRetry.kt`).
///
/// `enabled = reconnect || previousStop` (`A/StreamReceiver.kt:1209`); only an explicit 423
/// proves that no session was allocated, so nothing else is ever retried.
public struct BusyOfferRetry: Sendable, Equatable {
    /// Retry window from creation (`A/BusyOfferRetry.kt:4`).
    public static let windowMs: Int64 = 5_000
    /// Interruptible sleep between attempts (`A/StreamReceiver.kt:1228`).
    public static let spacingMs = 500

    public let enabled: Bool
    public let startedMs: Int64
    public let limitMs: Int64

    public init(enabled: Bool, startedMs: Int64, limitMs: Int64 = BusyOfferRetry.windowMs) {
        self.enabled = enabled
        self.startedMs = startedMs
        self.limitMs = max(0, min(limitMs, 30_000))
    }

    /// `enabled && status == 423 && 0 <= now - startedMs < 5000`.
    public func allow(status: Int, nowMs: Int64) -> Bool {
        let elapsed = nowMs.subtractingReportingOverflow(startedMs)
        return enabled && status == 423 && !elapsed.overflow && elapsed.partialValue >= 0
            && elapsed.partialValue < limitMs
    }
}
