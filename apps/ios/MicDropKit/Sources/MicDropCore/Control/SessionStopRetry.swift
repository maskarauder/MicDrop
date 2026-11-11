import Foundation

/// Remembers one recently stopped session so a lost `/stop` (e.g. across a network change) is re-sent before the next
/// offer to the same destination (`A/SessionStopRetry.kt`).
///
/// Process-wide, memory-only, never logged. Used only by the worker that holds
/// `AudioSessionOwner`; the lock only keeps the record coherent and is never held while
/// `notify` runs.
public final class SessionStopRetry: @unchecked Sendable {
    /// One remembered Stop. `token` is the old session bearer — never log it.
    public final class Stop: @unchecked Sendable {
        public let destination: String
        public let token: String
        /// Wire reason already mapped with `StopReason.wire(forLifecycleVersion:)`.
        public let reason: String
        public let startedMs: Int64
        private let acknowledgedFlag = Locked(false)

        public init(destination: String, token: String, reason: String, startedMs: Int64) {
            self.destination = destination
            self.token = token
            self.reason = reason
            self.startedMs = startedMs
        }

        public var acknowledged: Bool { acknowledgedFlag.value }

        fileprivate func markAcknowledged() {
            acknowledgedFlag.value = true
        }
    }

    public static let shared = SessionStopRetry()

    /// Record lifetime (`A/SessionStopRetry.kt:25`).
    public static let lifetimeMs: Int64 = 120_000

    /// Status published before re-sending an old Stop (`A/StreamReceiver.kt:1205`).
    public static let finishingPreviousText = "Finishing the previous Windows session…"

    private let previous = Locked<Stop?>(nil)

    public init() {}

    /// The current record, if any (tests and diagnostics).
    public var current: Stop? { previous.value }

    /// Replaces the record (cleanup step 6, whenever a session token exists, before `/stop`).
    @discardableResult
    public func remember(destination: String, token: String, reason: String, nowMs: Int64) -> Stop {
        let stop = Stop(destination: destination, token: token, reason: reason, startedMs: nowMs)
        previous.value = stop
        return stop
    }

    /// Marks `stop` acknowledged only if it is still the current record.
    public func acknowledge(_ stop: Stop) {
        if previous.value === stop { stop.markAcknowledged() }
    }

    /// Called at the start of `obtainOffer`. Returns whether a recent Stop to this destination exists (which enables
    /// the busy retry). An unacknowledged record is first re-sent through `notify` (`POST /stop {"reason":
    /// stop.reason}` with the **old** token, 5000 remote / 2000 LAN, cancellable). `HTTPFailure` 401/410 counts as
    /// done; any other error propagates with the record still unacknowledged (no new offer is attempted).
    public func beforeOffer(destination: String, nowMs: Int64, notify: (Stop) throws -> Void) throws -> Bool {
        guard let stop = previous.value else { return false }
        let age = nowMs - stop.startedMs
        guard age >= 0, age < SessionStopRetry.lifetimeMs else {
            previous.value = nil
            return false
        }
        guard stop.destination == destination else { return false }
        if !stop.acknowledged {
            do {
                try notify(stop)
            } catch let failure as HTTPFailure where failure.status == 401 || failure.status == 410 {
                // The old session expired or a successor owns the host; never cancel by
                // identity or by the new offer's nonce instead.
            }
            acknowledge(stop)
        }
        return true
    }

    /// Clears the record once a fresh offer for `destination` was accepted.
    public func accepted(destination: String) {
        previous.withLock { record in
            if record?.destination == destination { record = nil }
        }
    }
}
