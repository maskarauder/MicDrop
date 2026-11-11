import Foundation

/// Worker-owned control route. Matches `SignalingRoute.kt`. A failed transport never authorizes replay of an ambiguous
/// answer or a new offer allocation.
public final class SignalingRoute {
    public private(set) var direct: Bool
    public private(set) var probe: String
    public private(set) var fallback = "none"
    public private(set) var history: [String] = []
    private let remote: Bool
    private let initialOrder: ConnectionPreferences.Order
    private let recoveryOrder: ConnectionPreferences.Order
    private var checkWhenHealthy: Bool
    private var localIsFallback = false
    private var starting = true
    private var startupFallback = false

    public init(
        remote: Bool, initialOrder: ConnectionPreferences.Order = .lanFirst,
        recoveryOrder: ConnectionPreferences.Order = .rendezvousFirst
    ) {
        self.remote = remote
        self.initialOrder = initialOrder
        self.recoveryOrder = recoveryOrder
        direct = !remote
        probe = remote ? "not tried" : "not needed"
        checkWhenHealthy = remote && initialOrder == .lanFirst
    }

    public func initial(probeLocal: () throws -> Bool) throws {
        guard remote else { return }
        guard probe == "not tried" else { throw ControlResponseError(.invalidReply) }
        if initialOrder == .rendezvousFirst {
            record("Connect: rendezvous first")
            return
        }
        direct = try checkLocal(probeLocal)
        startupFallback = !direct
        fallback = direct ? "none" : "LAN unavailable"
        record(direct ? "Connect: LAN verified" : "Connect: LAN unavailable")
    }

    public func recover(probeLocal: () throws -> Bool = { false }) throws {
        starting = false
        guard remote else { return }
        localIsFallback = false
        checkWhenHealthy = initialOrder == .lanFirst
        direct = try recoveryOrder == .lanFirst && checkLocal(probeLocal)
        fallback =
            recoveryOrder == .lanFirst
            ? (direct ? "recovery: LAN first" : "recovery: LAN unavailable") : "recovery: rendezvous first"
        record(
            direct
                ? "Recovery: LAN verified"
                : recoveryOrder == .lanFirst ? "Recovery: LAN unavailable" : "Recovery: rendezvous first")
    }

    public func upgrade(probeLocal: () throws -> Bool) throws {
        starting = false
        localIsFallback = false
        guard remote, !direct, checkWhenHealthy else { return }
        checkWhenHealthy = false
        if try checkLocal(probeLocal) {
            direct = true
            fallback = "none"
            record("Healthy: LAN verified")
        }
    }

    public func localFallback(probeLocal: () throws -> Bool) throws -> Bool {
        guard remote, !(starting && startupFallback), try checkLocal(probeLocal) else { return false }
        direct = true
        localIsFallback = true
        checkWhenHealthy = false
        fallback = "rendezvous unavailable"
        record("Fallback: LAN verified")
        return true
    }

    public func needsRemoteICE(forceRelay: Bool) -> Bool { remote && (!direct || forceRelay) }
    public func reportRoute(_ lanRoute: String) -> String { direct ? lanRoute : "default" }
    public var label: String { direct ? "direct LAN" : "HTTPS rendezvous" }

    public func text(forceRelay: Bool) -> String {
        "Signaling: \(label) · Local probe: \(probe) · Fallback: \(fallback)"
            + "\nCellular media candidates: \(remote ? "allowed" : "excluded") · Force TURN relay: \(forceRelay)"
            + "\nSignaling history: \(history.joined(separator: " → "))"
    }

    public func exchange<T>(
        path: String, local: () throws -> T, rendezvous: () throws -> T,
        probeLocal: () throws -> Bool, cancelled: () -> Bool,
        networkPending: () -> Bool = { false }
    ) throws -> T {
        guard remote else { return try local() }
        let repeatable = ["/status", "/recover-offer", "/recover-answer", "/stop", "/cancel-offer", "/microphone"]
            .contains(path)
        func handoffCheckpoint() throws {
            if repeatable && path != "/stop" && path != "/cancel-offer" && networkPending() {
                throw SignalingNetworkChanged()
            }
        }
        try handoffCheckpoint()
        if direct {
            record("Request: LAN")
            do { return try local() } catch {
                guard !cancelled(), Self.transportFailure(error) else { throw error }
                try handoffCheckpoint()
                if path == "/offer" && starting && !localIsFallback {
                    direct = false
                    startupFallback = true
                    fallback = "LAN interrupted"
                    throw OfferFallbackRequired()
                }
                guard repeatable else { throw error }
                guard !localIsFallback else { throw SignalingRoutesUnavailable() }
                direct = false
                if starting { startupFallback = true }
            }
        }
        do {
            try handoffCheckpoint()
            record("Request: rendezvous")
            return try rendezvous()
        } catch {
            guard !cancelled(), Self.transportFailure(error) else { throw error }
            try handoffCheckpoint()
            let unsent = error is SignalingRequestNotSent
            guard repeatable || unsent || path == "/offer" else { throw error }
            let reachable = try localFallback {
                try handoffCheckpoint()
                let available = try probeLocal()
                try handoffCheckpoint()
                return available
            }
            try handoffCheckpoint()
            guard reachable else { throw SignalingRoutesUnavailable() }
            if path == "/offer" && !unsent { throw OfferFallbackRequired() }
            do {
                record("Request: LAN")
                return try local()
            } catch {
                guard !cancelled(), Self.transportFailure(error) else { throw error }
                try handoffCheckpoint()
                throw SignalingRoutesUnavailable()
            }
        }
    }

    private static func transportFailure(_ error: Error) -> Bool {
        ConnectionFailure.httpStatus(in: error) == nil && !(error is SignalingNetworkChanged)
            && ConnectionFailure.retryableStatus(error)
    }

    private func checkLocal(_ probeLocal: () throws -> Bool) throws -> Bool {
        let available = try probeLocal()
        probe = available ? "verified" : "unavailable"
        return available
    }

    private func record(_ event: String) {
        guard history.last != event else { return }
        if history.count == 8 { history.removeFirst() }
        history.append(event)
    }
}

public struct SignalingRoutesUnavailable: Error, Sendable, Equatable {
    public init() {}
}

/// Internal worker transition: the previous allocation must be cancelled before another offer.
public struct OfferFallbackRequired: Error, Sendable, Equatable {
    public init() {}
}

public struct SignalingNetworkChanged: Error, Sendable, Equatable {
    public init() {}
}

/// Only produced when the transport proves no inner HTTP request bytes were handed to TLS.
public struct SignalingRequestNotSent: UnderlyingErrorProviding, @unchecked Sendable {
    public let underlying: Error?
    public init(_ error: Error) { underlying = error }
}
