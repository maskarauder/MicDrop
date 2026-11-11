import Foundation
import MicDropCore

/// Steady-state status loop: heartbeat, report upload, ICE envelopes, recovery, waits (`StreamReceiver.kt:551-772`).
extension SessionController {

    /// Result of one successful status exchange (inputs of "Client processing of a 200").
    struct StatusExchange {
        /// Parsed host response.
        let response: ControlJSON
        /// Typed view of the response (`HostStatus`).
        let host: HostStatus
        /// The report that rode on this heartbeat, if any (`uploading`).
        let uploaded: PlaybackReport?
        /// A report was attempted: the first body carried `android` (Kotlin `body != nil`). After a
        /// report-rejection fallback the retried body omitted it and `delivery` is disabled, so the
        /// acknowledgement is skipped.
        let sentReport: Bool
        /// An `ice` delta was attached (`iceUpdate != nil`).
        let sentTrickle: Bool
        /// A `continuous_ice` snapshot was attached (`continuousUpdate != nil`).
        let sentContinuous: Bool
    }

    /// What the loop does after processing a 200 (`StreamReceiver.kt:657-689`).
    enum StatusOutcome {
        /// Collect stats, build the next report, publish, wait.
        case proceed
        /// `lanRecovery.restartDue(now)` after an unhealthy poll: loop immediately (`:684`).
        case restartNow
        /// A terminal condition already called `fail` (`:668-675`).
        case stop
    }

    /// The `while (!closed)` loop (`StreamReceiver.kt:554-772`).
    func statusLoop() throws {
        pendingReport = nil
        reportSequence = 0
        nextRouteReportAt = 0
        loop: while !isClosed {
            armNetworkHandoffIfEstablished()
            if networkHandoff.waiting() {
                lanRecovery.networkChanged(nowMs())
                holdNetworkAudio()
                suspendNetworkAudio()
                emitPhase(.recovering)
                emitStatus(Messages.networkChanged)
                publishNetworkStatus()
                if lanRecovery.expired(nowMs()) {
                    fail(
                        Messages.mediaRecoveryTimeout(seconds: recoveryWindowSeconds, action: mode.reconnectAction),
                        code: .mediaRecoveryTimeout)
                    break loop
                }
                guard networkHandoff.take(now: nowMs()) else {
                    try waitForSignal(ms: Timing.handoffWaitMs)
                    continue loop
                }
                try signalingRoute.recover { try self.probeLocal() }
                networkHandoffs += 1
            }
            publishNetworkStatus()
            if networkHeld { suspendNetworkAudio() }
            if microphoneReturn && !networkHeld {
                guard try microphoneLoopStep() else { break loop }
            } else if microphoneReturn {
                // Held: the Advanced keep-alive policy may stop a muted background capture, never start one.
                applyBackgroundKeepAlive()
            }
            outputController.step()
            if isClosed { break loop }
            if !networkHeld && routeProbingActive() && nowMs() < nextRouteReportAt {
                // Route probing in short worker steps without extra heartbeats (`:596-600`).
                try waitForSignal(ms: Timing.probingWaitMs)
                continue loop
            }
            let attemptedAt = nowMs()
            let exchange: StatusExchange
            do {
                exchange = try exchangeStatus()
            } catch {
                guard try handleStatusFailure(error, attemptedAt: attemptedAt) else { break loop }
                continue loop
            }
            if isClosed { break loop }
            switch try processHostStatus(exchange, attemptedAt: attemptedAt) {
            case .stop: break loop
            case .restartNow: continue loop
            case .proceed: break
            }
            try collectReport(exchange)
            nextRouteReportAt = nowMs() + Timing.routeReportIntervalMs
            try waitAfterReport()
        }
    }

    /// `if lanRecovery.established && remote && lanRecovery.supported { networkHandoff.arm() }`
    /// (`StreamReceiver.kt:555,678`).
    func armNetworkHandoffIfEstablished() {
        if lanRecovery.established && isRemote && lanRecovery.supported { networkHandoff.arm() }
    }

    /// `headsetRecovery.pending() || outputSwitchPending() || outputProbing()` (`StreamReceiver.kt:596,769`).
    func routeProbingActive() -> Bool {
        headsetRecovery.pending() || outputController.outputSwitchPending() || outputController.outputProbing()
    }

    /// One heartbeat inside `lanRecovery.exchangeStatus` (`StreamReceiver.kt:657-690`, step 5): recovery restart first
    /// (`beforeRestart` = `retireICEBeforeRestart`, `restore` = `restoreLanConnection`), then the body is built *after*
    /// recovery so a pre-restart ICE delta never accompanies the confirmation poll; GET when nothing is pending. A
    /// rejected report (400/404/405/ 409/413/422, not stopped) disables reporting and is retried once without the
    /// report, keeping the exact `phone_control`, `ice` and `continuous_ice` values (`sendStatus`, `:682-697`); a
    /// second rejection, other statuses, Stop and transport errors reach `handleStatusFailure`.
    func exchangeStatus() throws -> StatusExchange {
        try lanRecovery.exchangeStatus(
            now: nowMs,
            beforeRestart: {
                try self.signalingRoute.recover { try self.probeLocal() }
                self.retireICEBeforeRestart()
            }, restore: restoreLanConnection,
            poll: {
                guard let engine = self.engine else { throw ProtocolViolation("media engine unavailable") }
                let uploading = self.delivery?.enabled == true ? self.pendingReport : nil
                var report: DiagnosticJSON?
                if let uploading {
                    do {
                        report = try uploading.json(
                            includeOutput: self.includeOutput, includeConnection: self.includeConnection,
                            platformEnvironment: false)
                    } catch { self.delivery?.unavailable() }
                }
                var ice: DiagnosticJSON?
                if let trickle = self.trickle, !trickle.finished, self.lanRecovery.generation == 0 {
                    let complete = engine.iceGatheringComplete
                    guard let local = engine.localDescription else { throw ICEProtocolError.missingUpdate }
                    try trickle.observe(localDescription: local, complete: complete)
                    ice = trickle.delta().json()
                }
                var continuousICE: DiagnosticJSON?
                if let continuous = self.continuous {
                    guard continuous.generation == self.lanRecovery.generation, let local = engine.localDescription
                    else {
                        throw ICEProtocolError.invalidGeneration
                    }
                    try continuous.observe(localDescription: self.continuousCandidates.description(for: local))
                    continuousICE = continuous.snapshot().json()
                }
                let response = try self.sendStatus(report: report, ice: ice, continuousICE: continuousICE)
                return StatusExchange(
                    response: response, host: HostStatus(response), uploaded: uploading,
                    sentReport: report != nil, sentTrickle: ice != nil, sentContinuous: continuousICE != nil)
            })
    }

    /// The `/status` request of one heartbeat, after the report and ICE members exist (`StreamReceiver.kt:687-697`).
    /// The phone settings snapshot is taken last, so after any recovery restart, and only in a session that
    /// negotiated phone control: other hosts answer the member with 400. A rejected report is retried once without
    /// it, keeping the snapshot and the ICE values (`ReportDelivery.exchangeStatus`); without `delivery` there is no
    /// report and nothing to retry. Stop during the settings hop throws `SessionStopped`.
    func sendStatus(report: DiagnosticJSON?, ice: DiagnosticJSON?, continuousICE: DiagnosticJSON?) throws
        -> ControlJSON
    {
        var phoneSnapshot: DiagnosticJSON?
        if phoneControlEnabled { phoneSnapshot = try phoneControl?.snapshot() }
        func send(_ body: DiagnosticJSON?) throws -> ControlJSON {
            try request(
                "/status", token: requireSessionToken(), body: body?.encoded(),
                timeoutMs: configuration.connectionPreferences[.lanStatus])
        }
        if let delivery {
            return try delivery.exchangeStatus(
                version: protocolVersion, phoneControl: phoneSnapshot, report: report, ice: ice,
                continuousIce: continuousICE, stopped: { self.isClosed }, exchange: send)
        }
        return try send(
            StatusBody.make(
                version: protocolVersion, phoneControl: phoneSnapshot, report: nil, ice: ice,
                continuousIce: continuousICE))
    }

    /// Failure handling of a status exchange (`StreamReceiver.kt:678-691`). Returns `true` to continue the loop,
    /// `false` after a terminal `fail`; rethrows non-retryable errors. A handoff-cancelled heartbeat is charged to the
    /// window like any other failed request, then coalesced at the top of the loop without the ordinary retry delay.
    func handleStatusFailure(_ error: Error, attemptedAt: Int64) throws -> Bool {
        if let text = signalingFailureText(error) { lastSignalingFailureStorage.value = text }
        if error is SignalingNetworkChanged {
            try workerWait.checkpoint()
            guard try retrySignaling(error, attemptedAt: attemptedAt) else { throw error }
            return true
        }
        guard try retrySignaling(error, attemptedAt: attemptedAt) else { throw error }
        holdNetworkAudio()
        suspendNetworkAudio()
        publishNetworkStatus()
        if lanRecovery.expired(nowMs()) {
            fail(
                Messages.controlRecoveryTimeout(seconds: recoveryWindowSeconds, action: mode.reconnectAction),
                code: .statusRecoveryTimeout, error: error)
            return false
        }
        emitPhase(.recovering)
        emitStatus(Messages.connectionInterrupted(seconds: recoveryWindowSeconds))
        try waitForSignal(ms: Timing.statusRetryWaitMs)
        return true
    }

    /// `retrySignaling` (`StreamReceiver.kt:1589-1599`) for status and microphone-control failures. False when closed
    /// or not retryable; otherwise the failed request is charged from `attemptedAt` (`LanRecovery.signalingFailed`). An
    /// established session inside its window then holds audio, restores the configured recovery priority (no sticky LAN
    /// fallback) and reopens the `/v1/ice` failed-fetch cooldown, keeping usable cached credentials
    /// (`RemoteIce.kt:16-18`).
    func retrySignaling(_ error: Error, attemptedAt: Int64) throws -> Bool {
        guard lanRecovery.signalingFailed(error, attemptedAt: attemptedAt, stopped: isClosed) else { return false }
        if lanRecovery.established && !lanRecovery.expired(nowMs()) {
            holdNetworkAudio()  // LAN-first verification must not delay the local mute.
            try signalingRoute.recover { try self.probeLocal() }
            try dependencies.iceService.retryAfterInterruptionOnWorker(workerWait)
        }
        return true
    }

    /// `ConnectionTimeout.seconds(lanRecovery.limitMs)`: exact decimal seconds, e.g. `7.5`.
    var recoveryWindowSeconds: String {
        ConnectionPreferences.seconds(Int(clamping: lanRecovery.limitMs))
    }

    /// Client processing of a 200 (steps 1-11, steps 7-14; `StreamReceiver.kt:657-689`).
    func processHostStatus(_ exchange: StatusExchange, attemptedAt: Int64) throws -> StatusOutcome {
        let host = exchange.host
        // Before ICE acceptance and the report acknowledgment (`StreamReceiver.kt:713-716`). The host attaches a
        // pending command to every 200, GET or POST and the report-less retry alike, until a snapshot acknowledges
        // it or it expires (`server.go:425`); a repeat is answered from the adapter's history. Not an object: ignored.
        if phoneControlEnabled, !isClosed, let command = exchange.response.object("phone_control_command") {
            try phoneControl?.receive(command)
        }
        if exchange.sentTrickle { try acceptTrickle(host.requireICE()) }
        if exchange.sentContinuous { try acceptContinuous(host.requireContinuousICE()) }
        if exchange.sentReport, let uploaded = exchange.uploaded, delivery?.enabled == true {
            delivery?.acknowledge(status: host.reportLog, sequence: host.reportSequence, expected: uploaded.sequence)
        }
        evidence.observe(.host, host.evidenceState, uptimeMs: nowMs())
        if host.isTerminal(restartSupported: lanRecovery.supported) {
            fail(Messages.hostAudioStopped(action: mode.reconnectAction), code: .hostAudioStopped)
            return .stop
        }
        let healthy = host.isHealthy(
            localPeerState: peerStateStorage.value, iceConnected: iceConnectedFlag.value,
            continuous: continuousEnabledFlag.value, generation: lanRecovery.generation)
        if lanRecovery.expired(nowMs()) {
            fail(
                Messages.mediaRecoveryTimeout(seconds: recoveryWindowSeconds, action: mode.reconnectAction),
                code: .mediaRecoveryTimeout)
            return .stop
        }
        _ = lanRecovery.observe(healthy: healthy, now: attemptedAt)
        armNetworkHandoffIfEstablished()
        if !healthy || lanRecovery.pending || lanRecovery.restartRequested {
            holdNetworkAudio()
            suspendNetworkAudio()
            if lanRecovery.restartDue(nowMs()) { return .restartNow }
        } else if networkHeld && !networkHandoff.waiting() {
            releaseNetworkAudio()
        }
        if healthy && upgradeGatesReady() {
            try signalingRoute.upgrade {
                let available = try self.probeLocal()
                return available && !self.networkHandoff.waiting()
            }
        }
        publishNetworkStatus()
        // Recovery of the existing output selection is ROUTE_RECOVERING, not SWITCHING (`StreamReceiver.kt:687`),
        // so a replacement stays selectable while the gates remain closed.
        emitPhase(outputController.heartbeatPhase(headsetRecovering: headsetRecovery.pending(), healthy: healthy))
        return .proceed
    }

    /// The healthy-session LAN check runs only once audio is already running (`StreamReceiver.kt:722-727`): no network
    /// hold or pending handoff, the first microphone control applied, and playout started or deliberately muted. It
    /// never holds gates or delays initial rendezvous setup or a recovery episode.
    func upgradeGatesReady() -> Bool {
        guard !networkHeld, !networkHandoff.waiting() else { return false }
        if microphoneReturn && microphoneAppliedMuted.value == nil { return false }
        return !mode.hasPlayback || playoutActiveFlag.value || outputController.speakerMuted
    }

    /// Loop wait after a report (`StreamReceiver.kt:766-771`): only when not closed and (held, or not a
    /// microphone session, or the applied mute already equals the desired one); a pending microphone
    /// change loops immediately.
    func waitAfterReport() throws {
        let microphonePending = microphoneReturn && microphoneAppliedMuted.value != microphoneDesiredMuted.value
        guard !isClosed, networkHeld || !microphonePending else { return }
        try waitForSignal(ms: loopWaitMs())
    }

    /// 100 ms handoff waiting / 500 ms held / 20 ms probing / 2000 ms healthy (`StreamReceiver.kt:769`).
    func loopWaitMs() -> Int {
        if networkHandoff.waiting() { return Timing.handoffWaitMs }
        if networkHeld { return Timing.heldWaitMs }
        if routeProbingActive() { return Timing.probingWaitMs }
        return Timing.healthyWaitMs
    }

    /// Remote-only network status line, published on change (`StreamReceiver.kt:1554-1566`).
    func publishNetworkStatus() {
        guard isRemote, !isClosed else { return }
        let label = runtime?.networkLabel() ?? "unknown"
        let message = Messages.networkStatus(label: label, restoring: lanRecovery.active || networkHandoff.waiting())
        guard message != publishedNetworkStatus else { return }
        publishedNetworkStatus = message
        emitNetworkStatus(message)
    }

    /// Default-network change from `SessionRuntime` (any thread, `StreamReceiver.kt:132-139`): remote and armed only;
    /// cancels **only** the in-flight `/status` and wakes the worker. Never cancels `/offer`, `/answer`, `/recover-*`
    /// or `/stop`.
    func defaultNetworkChanged() {
        guard isRemote, !isClosed, networkHandoff.changed(now: nowMs()) else { return }
        let handle = withCancelLock { remoteStatusRequest }
        handle?.cancelForHandoff()
        controlSignal.notify()
    }
}
