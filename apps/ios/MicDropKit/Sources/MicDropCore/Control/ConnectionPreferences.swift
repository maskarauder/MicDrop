import Foundation

/// Transport policy shared by session requests and recovery. Matches Android's `ConnectionPreferences`;
/// hardware/heartbeat cadence stays independent.
public struct ConnectionPreferences: Sendable, Equatable {
    public enum Order: String, Sendable, CaseIterable {
        case lanFirst = "LAN_FIRST"
        case rendezvousFirst = "RENDEZVOUS_FIRST"

        public var label: String { self == .lanFirst ? "LAN → rendezvous" : "Rendezvous → LAN" }
    }

    public enum Timeout: String, Sendable, CaseIterable {
        case recovery, setup, busyHost, restartDelay, restartInterval, lanProbe, lanStatus, lanRequest
        case remoteRequest, iceService, lanStop, remoteStop, initialOffer, cancelOffer, initialICE, initialSDP
        case recoveryICE, recoveryOffer, recoveryAnswer

        public var limits: (defaultMs: Int, minimumMs: Int, maximumMs: Int) {
            switch self {
            case .recovery: return (30_000, 5_000, 300_000)
            case .setup: return (45_000, 10_000, 120_000)
            case .busyHost: return (5_000, 0, 30_000)
            case .restartDelay: return (1_000, 0, 10_000)
            case .restartInterval: return (8_000, 5_000, 60_000)
            case .lanProbe: return (1_500, 250, 5_000)
            case .lanStatus: return (2_000, 250, 15_000)
            case .lanRequest, .remoteRequest, .iceService: return (8_000, 1_000, 30_000)
            case .lanStop: return (2_000, 500, 10_000)
            case .remoteStop, .cancelOffer: return (5_000, 500, 15_000)
            case .initialOffer: return (40_000, 1_000, 60_000)
            case .initialICE, .initialSDP: return (15_000, 1_000, 30_000)
            case .recoveryICE: return (8_000, 1_000, 30_000)
            case .recoveryOffer: return (18_000, 1_000, 30_000)
            case .recoveryAnswer: return (5_000, 1_000, 30_000)
            }
        }
    }

    public static let recoveryHeader = "X-MicDrop-Recovery-Window-Ms"
    public static let setupHeader = "X-MicDrop-Setup-Window-Ms"
    /// ICE restarts per interruption (`A/ConnectionPreferences.kt:54`, `require(maxRestarts in 1..10)`).
    public static let maxRestartsRange = 1...10
    public let initialOrder: Order
    public let recoveryOrder: Order
    public let maxRestarts: Int
    private let timeouts: [Timeout: Int]

    public init() {
        initialOrder = .lanFirst
        recoveryOrder = .rendezvousFirst
        maxRestarts = 2
        timeouts = [:]
    }

    public init(
        initialOrder: Order = .lanFirst, recoveryOrder: Order = .rendezvousFirst,
        timeouts: [Timeout: Int], maxRestarts: Int = 2
    ) throws {
        guard Self.maxRestartsRange.contains(maxRestarts),
            timeouts.allSatisfy({ key, value in
                (key.limits.minimumMs...key.limits.maximumMs).contains(value)
            })
        else { throw ControlResponseError(.invalidReply) }
        self.initialOrder = initialOrder
        self.recoveryOrder = recoveryOrder
        self.timeouts = timeouts.filter { $0.value != $0.key.limits.defaultMs }
        self.maxRestarts = maxRestarts
    }

    public subscript(_ timeout: Timeout) -> Int { timeouts[timeout] ?? timeout.limits.defaultMs }

    /// Old hosts keep their watchdogs. Custom windows become effective only after an exact v1 echo.
    public func negotiated(
        restartSupported: Bool, version: Int, recoveryMs: Int, setupMs: Int, heartbeatMs: Int
    ) throws -> ConnectionDeadlines {
        let requestedRecovery = min(self[.recovery], restartSupported ? 300_000 : 10_000)
        if version == 1 {
            guard recoveryMs == requestedRecovery, setupMs == self[.setup], heartbeatMs == recoveryMs + 5_000 else {
                throw ControlResponseError(.invalidReply)
            }
            return ConnectionDeadlines(
                recoveryMs: recoveryMs, setupMs: setupMs, heartbeatMs: heartbeatMs, state: .confirmed)
        }
        return legacy(restartSupported: restartSupported)
    }

    public func legacy(restartSupported: Bool) -> ConnectionDeadlines {
        let window = restartSupported ? 30_000 : 10_000
        return ConnectionDeadlines(
            recoveryMs: min(self[.recovery], window), setupMs: min(self[.setup], 45_000),
            heartbeatMs: window + 5_000, state: .legacy)
    }

    /// Before `/offer` answers: the local setup budget still bounds pre-offer steps, while the copy report states
    /// that Windows has not answered `/offer` instead of calling the host a legacy build (`ConnectionPreferences.kt`).
    public func unnegotiated() -> ConnectionDeadlines {
        var deadlines = legacy(restartSupported: false)
        deadlines.state = .notNegotiated
        return deadlines
    }

    public func text(deadlines: ConnectionDeadlines) -> String {
        let detail: String
        switch deadlines.state {
        case .notNegotiated:
            detail = "requested setup: \(self[.setup]) ms · not negotiated (no Windows offer reply)"
        case .rejected:
            detail = "requested setup: \(self[.setup]) ms · not negotiated (Windows offer reply rejected)"
        case .legacy, .confirmed:
            detail =
                "effective: \(deadlines.recoveryMs) ms · setup: \(deadlines.setupMs) ms · Windows heartbeat: \(deadlines.heartbeatMs) ms"
                + (deadlines.state == .confirmed
                    ? " · confirmed by Windows" : " · legacy Windows limits (update Windows for custom deadlines)")
        }
        return "Connection order — initial: \(initialOrder.label) · recovery: \(recoveryOrder.label)"
            + "\nConnection deadlines — requested recovery: \(self[.recovery]) ms · " + detail
            + "\nConnection timing (ms): "
            + Timeout.allCases.map { "\($0.storageKey.lowercased())=\(self[$0])" }.joined(separator: ", ")
            + " · max ICE restarts=\(maxRestarts)"
    }

    /// The Connection settings sheet's Save (iPhone): `self` holds the values the sheet shows, `opened` those it
    /// loaded. Each value that differs from `opened` (order, restart limit or one timeout) replaces the same value
    /// of `latest`, the store's preferences at Save time; every other value keeps `latest`. A Windows edit (phone
    /// settings exchange v1) that landed while the sheet was open is therefore kept unless the user changed that
    /// same value. Android's per-group dialog reloads and rewrites its whole group instead
    /// (`ConnectionSettingsDialog.kt:80-85`). Throws only for a value out of bounds, which three valid inputs
    /// never produce.
    public func merged(
        onto latest: ConnectionPreferences, since opened: ConnectionPreferences
    ) throws -> ConnectionPreferences {
        func pick<Value: Equatable>(_ shown: Value, _ loaded: Value, _ current: Value) -> Value {
            shown != loaded ? shown : current
        }
        var timeouts: [Timeout: Int] = [:]
        for timeout in Timeout.allCases {
            timeouts[timeout] = pick(self[timeout], opened[timeout], latest[timeout])
        }
        return try ConnectionPreferences(
            initialOrder: pick(initialOrder, opened.initialOrder, latest.initialOrder),
            recoveryOrder: pick(recoveryOrder, opened.recoveryOrder, latest.recoveryOrder), timeouts: timeouts,
            maxRestarts: pick(maxRestarts, opened.maxRestarts, latest.maxRestarts))
    }
}

public enum DeadlineState: String, Sendable, Equatable {
    case notNegotiated
    case rejected
    case legacy
    case confirmed
}

public struct ConnectionDeadlines: Sendable, Equatable {
    public let recoveryMs: Int
    public let setupMs: Int
    public let heartbeatMs: Int
    public var state: DeadlineState
    public var confirmed: Bool { state == .confirmed }

    public init(recoveryMs: Int, setupMs: Int, heartbeatMs: Int, state: DeadlineState) {
        self.recoveryMs = recoveryMs
        self.setupMs = setupMs
        self.heartbeatMs = heartbeatMs
        self.state = state
    }

    public init(recoveryMs: Int, setupMs: Int, heartbeatMs: Int, confirmed: Bool) {
        self.init(
            recoveryMs: recoveryMs, setupMs: setupMs, heartbeatMs: heartbeatMs,
            state: confirmed ? .confirmed : .legacy)
    }

    /// Recompute before every operation. A spent window throws instead of issuing a new 1 ms request.
    /// Recovery takes precedence; repeated errors and handoffs never move either start timestamp.
    public func budget(
        requestedMs: Int, nowMs: Int64, setupStartedMs: Int64?, recoveryRemainingMs: Int64?
    ) throws -> Int {
        let remaining =
            recoveryRemainingMs ?? setupStartedMs.map { started in
                let elapsed = nowMs.subtractingReportingOverflow(started)
                let spent = elapsed.overflow ? Int64.max : max(0, elapsed.partialValue)
                return Int64(setupMs) - spent
            }
            ?? Int64(requestedMs)
        guard requestedMs > 0, remaining > 0 else { throw ControlIOError(.timedOut) }
        return Int(min(Int64(requestedMs), remaining))
    }
}
