import Foundation

/// Bounded playout recreation per route episode (`DefaultOutputPolicy.kt:53-70`).
///
/// "Recreate playout only, on the existing peer/worker, with a finite budget per device change. A broken output cannot
/// trap the heartbeat in an endless retry loop." Sessions use the default (2 recreations, >= 1000 ms apart). On iOS
/// `take` results are ignored in duplex. Not internally synchronized (session audio lock).
public final class OutputRestartBudget: @unchecked Sendable {
    public let maximum: Int
    public let intervalMs: Int64
    private var attempts = 0
    private var nextAt: Int64 = 0
    private var requested = false
    private var stopped = false

    public init(maximum: Int = 2, intervalMs: Int64 = 1000) {
        self.maximum = maximum
        self.intervalMs = intervalMs
    }

    /// New route episode: renews the budget.
    public func newRoute() {
        if !stopped {
            attempts = 0
            nextAt = 0
            requested = false
        }
    }

    /// Request a recreation if budget remains.
    public func request() {
        if !stopped && attempts < maximum { requested = true }
    }

    /// Route settled: clears the request (does not renew attempts).
    public func settled() { requested = false }

    /// Consume one requested recreation when allowed at `nowMs`.
    public func take(nowMs: Int64) -> Bool {
        if stopped || !requested || attempts >= maximum || nowMs < nextAt { return false }
        requested = false
        attempts += 1
        nextAt = nowMs + intervalMs
        return true
    }

    public func stop() {
        stopped = true
        requested = false
    }
}
