import Foundation
import MicDropCore

/// Control request plumbing: the `StreamReceiver.request` equivalent (`StreamReceiver.kt:1652-1699`) over the injected
/// `ControlTransport`, bridged onto the worker by `SessionWorkerWait`.
extension SessionController {

    /// One control request, strictly from the worker.
    ///
    /// - GET when `body == nil`, POST otherwise.
    /// - `Authorization: Bearer <token>` iff `token` is non-empty; offer nonce only on `/offer` and
    ///   `/cancel-offer` (`OfferAttempt.header(for:)`); trickle/continuous headers only on remote v3
    ///   `/offer` (`StreamReceiver.kt:1663-1664`).
    /// - Ordinary requests (`stopping == false`) are registered so `close()` can abort them and wait
    /// through `SessionWorkerWait` (Stop throws `SessionStopped`). `stopping` requests (final `/stop`, `/cancel-offer`)
    /// are never registered and never interrupted.
    /// - Throws the error types unchanged (`HTTPFailure` for any non-200).
    func request(
        _ path: String, token: String, body: Data? = nil,
        timeoutMs: Int? = nil, stopping: Bool = false
    ) throws -> ControlJSON {
        guard stopping || !isClosed else { throw SessionStopped() }
        let preferences = configuration.connectionPreferences
        let localTimeout = timeoutMs ?? preferences[.lanRequest]
        let cleanup = stopping || path == "/stop" || path == "/cancel-offer"
        let total: Int
        if cleanup || path == "/offer" || path.hasPrefix("/recover-") {
            total = localTimeout
        } else if path == "/status" || timeoutMs == nil {
            total = preferences[.remoteRequest]
        } else {
            total = max(localTimeout, preferences[.remoteRequest])
        }
        let started = nowMs()
        func budget(_ requested: Int) throws -> Int {
            if cleanup {
                let remaining = Int64(total) - max(0, nowMs() - started)
                guard remaining > 0 else { throw ControlIOError(.timedOut) }
                return Int(min(Int64(requested), remaining))
            }
            return try operationBudget(requested)
        }
        return try signalingRoute.exchange(
            path: path,
            local: {
                let limit = cleanup ? min(localTimeout, preferences[.lanStop] * 3 / 4) : localTimeout
                return try self.transportRequest(
                    path, token: token, body: body, timeoutMs: budget(limit), stopping: stopping, direct: true)
            },
            rendezvous: {
                let limit = cleanup ? min(total, preferences[.remoteStop] * 3 / 5) : total
                return try self.transportRequest(
                    path, token: token, body: body, timeoutMs: budget(limit), stopping: stopping, direct: false)
            },
            probeLocal: {
                let limit =
                    cleanup
                    ? min(try budget(preferences[.lanProbe]) / 2, preferences[.lanProbe] / 2)
                    : preferences[.lanProbe]
                return try self.probeLocal(stopping: stopping, timeoutMs: max(1, limit))
            },
            cancelled: { !stopping && self.isClosed },
            networkPending: { !stopping && self.networkHandoff.waiting() })
    }

    /// One fresh exchange on an explicitly selected transport; no implicit retry or route change.
    ///
    /// Every v3 `/offer` (LAN and rendezvous, busy retries and the re-offer after `/cancel-offer`) carries
    /// `X-MicDrop-Phone-Control: 1` whatever the local opt-in says (`PhoneControl.kt:84`, `StreamReceiver.kt:1888`),
    /// and `X-MicDrop-Session-Resume: 1` plus `X-MicDrop-Session-Resume-Reason: <wire>` when this worker is a resume
    /// (`SessionResume.offerHeaders`). No other path or link version carries them. A negotiated session's `/status`
    /// gets the 160 KiB body budget.
    func transportRequest(
        _ path: String, token: String, body: Data? = nil, timeoutMs: Int,
        stopping: Bool = false, direct: Bool
    ) throws -> ControlJSON {
        let effective = stopping ? timeoutMs : try operationBudget(timeoutMs)
        let resumeOffer = SessionResume.offerHeader(version: protocolVersion, path: path, resume: configuration.resume)
        let request = ControlRequest(
            path: path,
            bearer: token.isEmpty ? nil : token,
            offerAttempt: offerAttempt.header(for: path),
            trickleHeaders: isRemote && protocolVersion == 3 && path == "/offer",
            body: body,
            connectionPreferences: protocolVersion == 3 && path == "/offer" ? configuration.connectionPreferences : nil,
            phoneControlOffer: PhoneControl.offerHeader(version: protocolVersion, path: path) != nil,
            phoneControlNegotiated: phoneControlEnabled,
            sessionResume: resumeOffer != nil,
            sessionResumeReason: resumeOffer != nil ? configuration.resume : nil)
        let transport = direct ? localTransport : dependencies.transport
        if stopping {
            return try workerWait.sendJSON(
                request, over: transport, timeoutMs: effective, stopping: true, waitTimeoutMs: effective)
        }
        let registration = registerActiveRequest(path: path)
        defer { clearActiveRequest(registration) }
        let remaining: Int
        do { remaining = try operationBudget(Int.max) } catch {
            throw registration.failure(error, sessionClosed: isClosed)
        }
        let started = nowMs()
        let progress = Locked<SignalingRequestProgress?>(nil)
        do {
            return try workerWait.sendJSON(
                request, over: transport, timeoutMs: effective,
                waitTimeoutMs: remaining == Int.max ? nil : remaining
            ) { handle in
                registration.attach(handle)
                progress.value = handle.progress
            }
        } catch {
            let failure = registration.failure(error, sessionClosed: isClosed)
            recordSignalingRequestFailure(
                path, direct: direct, progress: progress.value, startedMs: started, error: error, failure: failure)
            throw failure
        }
    }

    /// Worker-owned failure history at the transport boundary (`StreamReceiver.kt:1883-1893`, `RemoteHttp.kt:36-40`):
    /// fixed labels only. A LAN request cancelled for a handoff is recorded as `network_changed`; stopping requests are
    /// never recorded.
    func recordSignalingRequestFailure(
        _ path: String, direct: Bool, progress: SignalingRequestProgress?, startedMs: Int64, error: Error,
        failure: Error
    ) {
        let handedOff = ConnectionFailure.isCancellation(error) && !ConnectionFailure.isCancellation(failure)
        let observed: Error = direct && handedOff ? SignalingNetworkChanged() : error
        let phase = progress?.phase ?? (direct ? .lanRequest : .rendezvousConnect)
        let detail = signalingRequestFailureText(
            direct: direct, path: path, phase: phase, elapsedMs: nowMs() - startedMs, error: observed)
        signalingRequestFailures.record(uptimeMs: nowMs(), detail)
    }

    /// Pinned TLS-only LAN reachability. A negative verdict permits rendezvous; Stop always wins.
    func probeLocal(stopping: Bool = false, timeoutMs: Int? = nil) throws -> Bool {
        let requested = min(5_000, timeoutMs ?? configuration.connectionPreferences[.lanProbe])
        let effective = stopping ? requested : try operationBudget(requested)
        let registration = stopping ? nil : registerActiveRequest(path: "local-probe")
        defer { if let registration { clearActiveRequest(registration) } }
        do {
            let reachable: Bool = try workerWait.runAsync(timeoutMs: effective, stopping: stopping) { register in
                try await self.localProbe.reachable(timeoutMs: effective) { handle in
                    register(handle)
                    registration?.attach(handle)
                }
            }
            if !stopping { try workerWait.checkpoint() }
            return reachable
        } catch {
            if !stopping { try workerWait.checkpoint() }
            // A bounded probe timing out is an unavailable LAN, not an invitation rejection.
            if ConnectionFailure.isIOClass(error) { return false }
            throw error
        }
    }

    /// One monotonic budget shared by control, SDP, gathering and credential operations.
    func operationBudget(_ requestedMs: Int) throws -> Int {
        try workerWait.checkpoint()
        return try connectionDeadlines.budget(
            requestedMs: requestedMs, nowMs: nowMs(), setupStartedMs: setupStartedMs,
            recoveryRemainingMs: lanRecovery.active ? lanRecovery.remaining(nowMs()) : nil)
    }

    /// Publish the request lifetime before dispatch. Stop and handoff therefore also cover a
    /// transport that registers its handle after the worker has stopped waiting.
    func registerActiveRequest(path: String) -> SessionRequestRegistration {
        let registration = SessionRequestRegistration()
        let cancelNow = withCancelLock { () -> Bool in
            if isClosed { return true }
            activeRequest = registration
            if isRemote && path == "/status" { remoteStatusRequest = registration }
            return false
        }
        if cancelNow { registration.cancel() }
        return registration
    }

    /// Clears the registration after the request finished (`StreamReceiver.kt:1665,1698`).
    func clearActiveRequest(_ registration: SessionRequestRegistration) {
        withCancelLock {
            registration.finish()
            if activeRequest === registration { activeRequest = nil }
            if remoteStatusRequest === registration { remoteStatusRequest = nil }
        }
    }

    /// The session bearer once `/offer` succeeded; a missing token after that point is a programming
    /// error (Kotlin passes the non-null local `token`).
    func requireSessionToken() throws -> String {
        guard let token = sessionToken else { throw ProtocolViolation("session token missing") }
        return token
    }

    /// Remote ICE configuration for this link (`StreamReceiver.kt:1648-1650`): nil on LAN; otherwise
    /// `RemoteICEService.fetch` bridged onto the worker, its handle registered so Stop can cancel the URLSession task.
    /// Failures are fatal at PAIRING (and retryable inside recovery).
    func fetchRemoteICEConfiguration() throws -> RemoteICEConfiguration? {
        guard let route = configuration.link.remote else { return nil }
        guard signalingRoute.needsRemoteICE(forceRelay: route.forceRelay) else { return .empty }
        let service = dependencies.iceService
        let registration = registerActiveRequest(path: "/v1/ice")
        defer { clearActiveRequest(registration) }
        func handoffCheckpoint() throws {
            try workerWait.checkpoint()
            if networkHandoff.waiting() { throw SignalingNetworkChanged() }
        }
        try handoffCheckpoint()
        do {
            return try service.fetchOnWorker(
                route, worker: workerWait,
                timeoutMs: operationBudget(configuration.connectionPreferences[.iceService] * 2),
                requestTimeoutMs: operationBudget(configuration.connectionPreferences[.iceService])
            ) { registration.attach($0) }
        } catch {
            try workerWait.checkpoint()
            guard ConnectionFailure.retryableStatus(error) else { throw error }
            if networkHandoff.waiting() {
                try service.retryAfterInterruptionOnWorker(workerWait)
                throw SignalingNetworkChanged()
            }
            guard !route.forceRelay else { throw error }
            let reachable = try signalingRoute.localFallback {
                let available = try self.probeLocal()
                try handoffCheckpoint()
                return available
            }
            try handoffCheckpoint()
            guard reachable else { throw SignalingRoutesUnavailable() }
            return .empty
        }
    }
}
