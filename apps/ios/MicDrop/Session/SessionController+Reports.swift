import Foundation
import MicDropCore

/// Periodic report, copy-report text and terminal evidence assembly (`StreamReceiver.kt:690-764, 780-811`). Pure value
/// builders live in MicDropCore; this extension gathers the session inputs in the Kotlin order.
extension SessionController {

    /// After a processed heartbeat (`StreamReceiver.kt:690-764`): stats (≤ 5 s, timeout ends the session as
    /// `stage_timeout`), metrics, route selection, recovery monitor, microphone and connection snapshots, the next
    /// `pendingReport` (`sequence = ++reportSequence`, uptime taken last), the copy-report text, journal snapshot, then
    /// `onDiagnostics` + `onStatus` if not closed.
    func collectReport(_ exchange: StatusExchange) throws {
        guard let engine else { throw ProtocolViolation("media engine unavailable") }
        let samples = try engine.statistics(timeoutMs: Timing.statsTimeoutMs)
        let snapshot = metrics.update(samples)
        let routes = routeSelection.update(
            samples, generation: lanRecovery.generation, localSDP: engine.localDescription,
            remoteSDP: engine.remoteDescription)
        let capturedAt = DiagnosticTime.nowRFC3339()
        let mediaOutput = outputController.mediaOutputLabel()
        let state = peerStateStorage.value
        let output = mode.hasPlayback ? engine.outputSnapshot(capturedUptimeMs: nowMs()) : nil
        let recovery =
            mode.hasPlayback
            ? recoveryMonitor.update(
                nowMs: nowMs(), running: mediaOutput == "running" && state == "Connected", epoch: output?.epoch,
                bufferMs: snapshot.value("buffer_ms"), targetMs: snapshot.value("buffer_target_ms")) : nil
        let processing = includeMicrophoneProcessing ? configuration.processing : nil
        let microphone = microphoneControl?.snapshot(networkHeld: networkHeld, processing: processing)
        let connection = evidence.connection(runtime: runtime?.snapshot(), uptimeMs: nowMs())
        // One snapshot per cycle keeps the report member and the copy-report lines consistent.
        let trust = turnTLSTrust.snapshot()
        reportSequence += 1
        pendingReport = PlaybackReport(
            sequence: Int64(clamping: reportSequence), capturedAt: capturedAt, uptimeMs: nowMs(),
            environment: PlaybackEnvironment.snapshot(),
            state: state, mediaOutput: mediaOutput, snapshot: snapshot, recovery: recovery,
            microphone: microphone, microphoneProcessing: processing, mode: mode, connection: connection,
            lanRecovery: lanRecovery.supported
                ? lanRecovery.fields(route: signalingRoute.reportRoute(lanRoute.label)).json() : nil,
            outputControl: usesMediaOutput && includeOutputControl ? outputController.controlSnapshot() : nil,
            iceGathering: includeIceGathering ? initialGathering : nil,
            mediaTransport: includeMediaTransport ? snapshot.transport : nil,
            routeSelection: includeRouteSelection ? routes : nil, tlsVerification: reportedTLSVerification(trust))
        lastDiagnostics = periodicDiagnosticsText(
            exchange, snapshot: snapshot, routes: routes, connection: connection, tlsTrust: trust,
            capturedAt: capturedAt)
        journal.snapshot(lastDiagnostics)
        if !isClosed {
            emitDiagnostics(lastDiagnostics)
            emitStatus(lastDiagnostics)
        }
    }

    /// The negotiated `tls_certificate_verification` member: the cycle's snapshot only when `/offer` advertised
    /// `tls_certificate_diagnostics_version == 1` (`StreamReceiver.kt:779`). Otherwise `nil`, because the host
    /// answers 400 to an unadvertised member and report delivery would then stop.
    func reportedTLSVerification(_ trust: TurnTLSTrustSnapshot) -> TurnTLSTrustSnapshot? {
        includeTlsVerification ? trust : nil
    }

    /// Microphone modes: Android's `Muted capture option: … · Capture retained while muted: …` line
    /// (`StreamReceiver.kt:783` on main `87b15af`) from the live keep-alive setting and the actual capture state
    /// read on the worker; `nil` for playback. The terminal report keeps the last periodic value.
    func mutedCaptureText() -> String? {
        guard microphoneReturn else { return nil }
        return AdvancedAudioPreferences.mutedCaptureText(
            option: keepMicrophoneActiveWhileMuted, retained: microphoneControl?.captureRetainedWhileMuted ?? false)
    }

    /// The periodic copy-report text (+ iOS substitutions, `StreamReceiver.kt:723-762`): mode block (with the
    /// muted-capture line after the microphone lines), `App audio output`, pause detail, connection text, LAN/remote
    /// signalling line, media recovery, output selection/recovery lines, headset lines, initial gathering, TURN/TLS
    /// trust lines (always, `StreamReceiver.kt:810`), trickle/continuous ICE, route selection, TURN lines, remote
    /// handoffs, last secure-signaling failure.
    func periodicDiagnosticsText(
        _ exchange: StatusExchange, snapshot: PlaybackSnapshot,
        routes: RouteSelectionSnapshot, connection: ConnectionSnapshot, tlsTrust: TurnTLSTrustSnapshot,
        capturedAt: String
    ) -> String {
        let host = exchange.host
        let outputLines = outputController.selectionLines()
        let selectionPrefix = "App output selection: "
        let selection = outputLines.first { $0.hasPrefix(selectionPrefix) }.map {
            String($0.dropFirst(selectionPrefix.count))
        }
        let hostTransport = MediaTransportSnapshot.reported(statusBody: Array(exchange.response.encoded()))
        return ReportText.periodic(
            ReportText.Periodic(
                mode: mode, capturedAt: capturedAt, environment: pendingReport?.environment,
                state: peerStateStorage.value,
                mediaOutput: outputController.mediaOutputLabel(),
                deliveryText: delivery?.text ?? ReportDelivery.notNegotiatedText,
                host: ReportText.HostFigures(
                    sourceRateHz: host.number("source_rate_hz"), sourceChannels: host.number("source_channels"),
                    encoderChannels: host.number("encoder_channels"),
                    encoderPacketMsAtCreation: host.number("encoder_packet_ms_at_creation"),
                    bridgeMixRateHz: host.number("bridge_mix_rate_hz"),
                    bridgeMixChannels: host.number("bridge_mix_channels"),
                    bridgeBufferFrames: host.number("bridge_buffer_frames"),
                    bridgeFramesSubmitted: host.bridgeFramesSubmitted,
                    microphoneMuted: host.microphoneMuted),
                snapshot: snapshot, connection: connection, signalingText: signalingText(),
                lanRecoveryText: lanRecovery.text(), routeSelectionText: routes.text(),
                phoneTurnText: snapshot.transport.turnText(), hostTurnText: hostTransport.turnText(),
                outputEnabled: outputEnabled(),
                audioSessionText: engine?.outputSnapshot(capturedUptimeMs: nowMs()).text(),
                recoveryText: pendingReport?.recovery?.text(),
                localBaselineUptimeMs: configuration.baseline?.capturedUptimeMs,
                localBaselineText: configuration.baseline?.text(),
                microphoneText: pendingReport?.microphone?.text(),
                mutedCaptureText: mutedCaptureText(),
                processingText: microphoneReturn
                    ? configuration.processing.text(voiceProcessingActive: configuration.plan.voiceProcessing) : nil,
                outputPauseDetail: outputController.audioOutputLines().dropFirst().first,
                outputSelectionText: selection,
                outputIdentityText: outputLines.first { $0.hasPrefix("Selected output identity:") },
                outputRecoveryText: usesMediaOutput ? outputController.recoveryText() : nil,
                headsetLines: microphoneControl?.copyReportLines() ?? [], iceGatheringText: initialGathering?.text(),
                tlsTrustText: tlsTrust.text(), trickleText: trickle?.text(), continuousText: continuous?.text(),
                remoteNetworkHandoffs: isRemote ? networkHandoffs : nil,
                signalingFailureText: lastSignalingFailureStorage.value))
    }

    /// Terminal evidence captured right after `closed = true` and before any teardown (`StreamReceiver.kt:785-794`):
    /// code = failure ? (stamp?.code ?? sessionException): none; stage = stamp?.stage ?? stage; failure uptime =
    /// failure ? (stamp?.uptimeMs ?? uptime): nil; output control only for media-output sessions with the capability
    /// (phase is then "stopped"). `nil` if any input cannot be captured.
    func captureTerminalEvidence(reason: StopReason, stamp: FailureEvidence?) -> TerminalEvidence? {
        TerminalEvidence.capture(
            failed: reason == .failure, stamp: stamp, currentStage: stage, evidence: evidence,
            runtime: runtime?.snapshot(), clock: dependencies.clock, now: Date(),
            outputControl: usesMediaOutput && includeOutputControl ? outputController.controlSnapshot() : nil,
            iceGathering: initialGathering)
    }

    /// `signalingText()` (`StreamReceiver.kt:1731-1732`): the LAN route line or the remote route/probe/fallback/history
    /// text, then the connection order and deadlines, then the iOS Advanced audio line (this session's Bluetooth route
    /// recovery window and, for microphone sessions, the current keep-alive preference; no device identity).
    func signalingText() -> String {
        let route = isRemote ? signalingRoute.text(forceRelay: configuration.forceRelay) : lanRoute.text
        let audio = AdvancedAudioPreferences.text(
            bluetoothRecoveryMs: configuration.bluetoothRecoveryMs,
            keepMicrophoneActiveWhileMuted: microphoneReturn ? keepMicrophoneActiveWhileMuted : nil)
        return route + "\n" + configuration.connectionPreferences.text(deadlines: connectionDeadlines) + "\n" + audio
    }

    /// `finalSnapshot` (`StreamReceiver.kt:838-863`): `lastDiagnostics` with refreshed headset lines (Bluetooth
    /// microphone), output recovery lines (media output), the last secure-signaling failure line, the recent request
    /// failures and the worker's current recovery state, even when setup or a failed heartbeat left no newer periodic
    /// snapshot.
    func refreshedFinalSnapshot() -> String {
        ReportText.refreshedFinalSnapshot(
            lastDiagnostics, headsetLines: microphoneIsBluetooth ? microphoneControl?.copyReportLines() : nil,
            outputRecoveryText: usesMediaOutput ? outputController.recoveryText() : nil,
            signalingFailureText: lastSignalingFailureStorage.value,
            requestFailuresText: signalingRequestFailures.text, recoveryText: lanRecovery.text(),
            recoveryRemainingMs: lanRecovery.remaining(nowMs()), offerReply: offerReply)
    }

    /// Terminal copy report (`StreamReceiver.kt:864-866`): the final snapshot, then the current signaling text and
    /// deadlines.
    func terminalReport() -> String {
        let result = withCancelLock { failureMessage } ?? mode.endedMessage(endReason)
        let terminalText = terminalEvidence?.text() ?? Messages.terminalDiagnosticsUnavailable
        return "\(finalSnapshot)\n\(signalingText())\n\nSession result: \(result)\n\(terminalText)"
            + "\nWindows terminal diagnostics: \(terminalDelivery)"
    }
}
