import Foundation
import MicDropCore

/// Worker cleanup: terminal evidence, `/stop` or `/cancel-offer`, media release, journal, owner release, `onEnded`
/// (`StreamReceiver.kt:777-874, 1507-1516`).
extension SessionController {

    /// Strict cleanup order of `StreamReceiver.kt:777-874`. No wait is registered during cleanup, so a
    /// late Stop cannot interrupt the acknowledgment or native disposal.
    func cleanup() {
        withCancelLock { closedFlag.value = true }
        let reason = withCancelLock { stopReasonStorage } ?? .failure
        endReason = reason
        let stamp = withCancelLock { failureEvidence }
        // Capture before intentional capture/route teardown; later native callbacks cannot alter it.
        terminalEvidence = captureTerminalEvidence(reason: reason, stamp: stamp)
        finalSnapshot = refreshedFinalSnapshot()
        terminalDelivery = ReportText.TerminalDelivery.delivery(
            reply: offerReply, connectionNegotiated: includeConnection)
        // Commit before native teardown: a fatal native exit cannot reach onEnded, but the next launch
        // can still copy this report.
        if ownsAudioSession {
            journalActive = true
            journal.snapshot(terminalReport())
        }
        cleanupStep("runtime_close") { runtime?.close() }
        cleanupStep("local_audio_gates") { closeLocalAudioGates() }
        cleanupStep("output_observers_close") { try closeOutputObservers() }
        cleanupStep("input_observers_close") { try closeInputObservers() }
        if microphoneReturn { cleanupStep("audio_recording_stop") { try stopAudioRecording() } }
        let wireReason = reason.wire(forLifecycleVersion: lifecycleVersion)
        let pendingStop = sessionToken.map {
            SessionStopRetry.shared.remember(
                destination: stopDestination, token: $0, reason: wireReason, nowMs: nowMs())
        }
        let acknowledged = SessionShutdown.complete(
            notifyRemote: {
                do {
                    let result = try self.notifyRemoteStop(reason: reason)
                    self.finishRemoteStop(acknowledged: result)
                    return result
                } catch {
                    self.finishRemoteStop(acknowledged: false)
                    throw error
                }
            },
            releaseMedia: {
                self.releaseMedia()
            })
        finishRemoteStop(acknowledged: acknowledged)
        if acknowledged, let pendingStop { SessionStopRetry.shared.acknowledge(pendingStop) }
        let confirmation = Self.confirmationSuffix(
            hasToken: sessionToken != nil,
            pendingCancellation: offerAttempt.needsCancellation(nil),
            acknowledged: acknowledged,
            retryRecorded: pendingStop != nil)
        if journalActive {
            journal.snapshot(terminalReport())
            journal.completed()
        }
        let finalDiagnostics = journal.text()
        journalActive = false
        if ownsAudioSession {
            dependencies.owner.release()
            ownsAudioSession = false
        }
        let message = (withCancelLock { failureMessage } ?? mode.endedMessage(reason)) + confirmation
        emitEnded(StreamEnd(reason: reason, message: message, diagnostics: finalDiagnostics))
    }

    /// `notifyRemote` of `SessionShutdown.complete` (`StreamReceiver.kt:827-853`): `/stop` with optional terminal
    /// diagnostics (one retry without them on 400/413/422), or `/cancel-offer` with this worker's nonce, or nothing.
    /// Both are `stopping` requests (not cancellable). Returns whether Windows acknowledged.
    func notifyRemoteStop(reason: StopReason) throws -> Bool {
        if journalActive { journal.checkpoint("windows_stop") }
        let wire = reason.wire(forLifecycleVersion: lifecycleVersion)
        if let token = sessionToken {
            let diagnostics = includeConnection ? terminalEvidence : nil
            let response: ControlJSON
            do {
                response = try request(
                    "/stop", token: token, body: stopBody(reason: wire, diagnostics: diagnostics),
                    timeoutMs: stopTimeoutMs, stopping: true)
            } catch let failure as HTTPFailure where diagnostics != nil && [400, 413, 422].contains(failure.status) {
                // Diagnostics are optional: an explicit schema rejection must not prevent a graceful Stop.
                terminalDelivery = Messages.terminalRejected
                response = try request(
                    "/stop", token: token, body: WireBody.stop(reason: wire),
                    timeoutMs: stopTimeoutMs, stopping: true)
            }
            if includeConnection && !terminalDelivery.hasPrefix("rejected") {
                terminalDelivery = response.string("receiver_diagnostics", default: Messages.terminalNotConfirmed)
            }
            return true
        }
        guard offerAttempt.needsCancellation(sessionToken) else { return false }
        // Stop aborted /offer before a token arrived: cancel only this worker's private nonce.
        terminalDelivery = Messages.cancellationUnconfirmed
        let response = try request(
            "/cancel-offer", token: configuration.link.token,
            body: WireBody.version(protocolVersion),
            timeoutMs: configuration.connectionPreferences[.cancelOffer], stopping: true)
        let cancelled = response.bool("offer_cancelled", default: false)
        if cancelled { terminalDelivery = Messages.cancellationAcknowledged }
        return cancelled
    }

    /// `/stop` body: `{"reason":…}` plus `"diagnostics": TerminalEvidence.json(includeIceGathering:)` when connection
    /// diagnostics were negotiated and evidence exists. An evidence encoding failure (never with the current
    /// composition) sends the plain Stop body: diagnostics are optional and must not prevent a graceful Stop.
    func stopBody(reason: String, diagnostics: TerminalEvidence?) -> Data {
        guard let diagnostics,
            let evidence = try? diagnostics.json(includeIceGathering: includeIceGathering)
        else {
            return WireBody.stop(reason: reason)
        }
        return DiagnosticJSON.object([
            (key: "reason", value: .string(reason)),
            (key: "diagnostics", value: evidence),
        ]).encoded()
    }

    /// `releaseMedia` of `SessionShutdown.complete` (`StreamReceiver.kt:854-863`, step 6): always runs after the remote
    /// notification.
    func releaseMedia() {
        if journalActive { journal.snapshot(terminalReport()) }
        releaseEngine()
        if microphoneReturn { cleanupStep("microphone_route_close") { try closeMicrophoneRoute() } }
        cleanupStep("lan_network_close") { lanRoute.close() }
    }

    /// `peer_dispose`, `microphone_track_dispose`, `microphone_source_dispose`, `factory_dispose`,
    /// `audio_module_release` inside one `autoreleasepool`: each journal checkpoint written, each failure recorded as
    /// `TEARDOWN_FAILED`; `isAudioEnabled = false` after the factory is released; a surviving factory reference is a
    /// teardown failure.
    func releaseEngine() {
        let failed =
            engine?.close { step in
                if self.journalActive { self.journal.checkpoint(step.rawValue) }
            } ?? []
        if !failed.isEmpty {
            withCancelLock { if failureMessage == nil { failureMessage = Messages.cleanupFailed } }
        }
        microphoneCapture?.detach()
        withAudioLock { engine = nil }
    }

    /// `cleanupStep(name)` (`StreamReceiver.kt:1507-1516`): journal checkpoint, run, and on any error keep the first
    /// failure message or set `Audio cleanup failed [TEARDOWN_FAILED]. Restart MicDrop before retrying.` (no
    /// NATIVE_LOAD analogue on iOS).
    func cleanupStep(_ name: String, _ operation: () throws -> Void) {
        if journalActive { journal.checkpoint(name) }
        do {
            try operation()
        } catch {
            withCancelLock {
                if failureMessage == nil { failureMessage = Messages.cleanupFailed }
            }
        }
    }

    /// Confirmation suffix appended to the end message (table, `StreamReceiver.kt:865-868`).
    static func confirmationSuffix(
        hasToken: Bool, pendingCancellation: Bool,
        acknowledged: Bool, retryRecorded: Bool
    ) -> String {
        if !hasToken && !pendingCancellation { return "" }
        if acknowledged { return Messages.stopAcknowledged }
        if retryRecorded { return Messages.stopNotConfirmedRetry }
        return Messages.stopNotConfirmedWatchdog
    }

    // MARK: - Background setup and termination

    /// .
    func expireBackgroundSetup() {
        guard !isClosed, !mediaReadyFlag.value else { return }
        fail(Messages.backgroundSetupExpired, code: .stageTimeout)
    }

    /// Wakes `awaitRemoteStop` once the remote notification finished (idempotent; first result wins).
    func finishRemoteStop(acknowledged: Bool) {
        remoteStopSignal.lock()
        if !remoteStopFinished {
            remoteStopFinished = true
            remoteStopAcknowledged = acknowledged
        }
        remoteStopSignal.broadcast()
        remoteStopSignal.unlock()
    }

    /// the main thread in `applicationWillTerminate` waits at most 2000 ms (LAN) / 3000 ms (remote) for the worker's
    /// Stop; the wire timeouts stay 2000 / 5000 ms.
    func awaitRemoteStop(timeoutMs: Int?) -> Bool {
        let limit = timeoutMs ?? (isRemote ? Timing.terminateWaitRemoteMs : Timing.terminateWaitLanMs)
        let deadline = Date(timeIntervalSinceNow: Double(max(limit, 0)) / 1000)
        remoteStopSignal.lock()
        defer { remoteStopSignal.unlock() }
        while !remoteStopFinished {
            if !remoteStopSignal.wait(until: deadline) { break }
        }
        return remoteStopFinished && remoteStopAcknowledged
    }
}
