import AVFoundation
import Foundation
import MicDropCore

/// Microphone return parts of the worker (`StreamReceiver.kt:301-313, 565-593, 1234-1505`). The per-step algorithms run
/// in `MicrophoneControl` (08) with `MicrophoneHooksBridge` as its host; this extension keeps the receiver-side request
/// state the `StreamReceiving` API needs before those collaborators exist.
extension SessionController {

    // MARK: - StreamReceiving

    var microphoneMuteRequested: Bool { microphoneDesiredMuted.value }

    /// (`StreamReceiver.kt:301-313`): the local sample gate closes immediately for Mute **and** Unmute; only the worker
    /// reopens it after route verification and the host acknowledgment.
    func setMicrophoneMuted(_ muted: Bool) {
        let accepted = withAudioLock { () -> Bool in
            guard microphoneReturn, !isClosed else { return false }
            if microphoneAppliedMuted.value == muted && microphoneDesiredMuted.value == muted { return false }
            microphoneDesiredMuted.value = muted
            closeMicrophoneSampleGateLocked()
            return true
        }
        guard accepted else { return }
        emitMicrophoneState(muted: muted, pending: true)
        controlSignal.notify()
    }

    /// Scene `.active` changes for the microphone-only background keep-alive. The worker applies the policy on its next
    /// microphone step.
    func setApplicationActive(_ active: Bool) {
        let changed = applicationActiveFlag.withLock { current -> Bool in
            if current == active { return false }
            current = active
            return true
        }
        if changed && microphoneReturn && !isClosed { controlSignal.notify() }
    }

    // MARK: - Local sample gate

    /// Sample gate close: microphone track disabled through the engine's gate queue and
    /// `AVAudioApplication.setInputMuted(true)`. Call with `audioLock` held (or from `close`). Synchronous and
    /// non-blocking from any thread.
    func closeMicrophoneSampleGateLocked() {
        engine?.setMicrophoneSampleGate(open: false)
        try? AVAudioApplication.shared.setInputMuted(true)
    }

    // MARK: - Worker steps

    /// Status-loop microphone block (`StreamReceiver.kt:600-625`). Returns `false` when the session closed (the loop
    /// breaks). Retryable failures hold network audio instead of failing.
    func microphoneLoopStep() throws -> Bool {
        guard let microphoneControl else { throw ProtocolViolation("microphone control unavailable") }
        try runMicrophoneControl { try microphoneControl.loopStep(token: self.requireSessionToken()) }
        return !isClosed
    }

    /// The microphone block's catch: `retrySignaling(error, controlStartedAt)`, so a failure is charged to
    /// the recovery window from the control step's start, then network audio is held and suspended.
    func runMicrophoneControl(_ step: () throws -> Void) throws {
        let controlStartedAt = nowMs()
        do {
            try step()
        } catch {
            guard try retrySignaling(error, attemptedAt: controlStartedAt) else { throw error }
            holdNetworkAudio()
            suspendNetworkAudio()
        }
    }

    /// `applyMicrophoneControl` (`StreamReceiver.kt:1234-1329`) including the iOS order of (wait for the
    /// `initializeInput` completion inside the verification deadline, one `resumeRecording`, `< 0` →
    /// `microphone_start`).
    func applyMicrophoneControl() throws {
        guard let microphoneControl else { throw ProtocolViolation("microphone control unavailable") }
        try microphoneControl.apply(token: requireSessionToken())
    }

    /// `restoreHeadset` (`StreamReceiver.kt:1363-1505`) — one non-blocking recovery step at the 20 ms cadence; the
    /// configured window (`configuration.bluetoothRecoveryMs`, default 20 s) never moves.
    func restoreHeadset() throws {
        guard let microphoneControl else { throw ProtocolViolation("microphone control unavailable") }
        try microphoneControl.restoreHeadset(token: requireSessionToken())
    }

    /// `suspendNetworkAudio` microphone part (`StreamReceiver.kt:1534-1539`): gate closed, track disabled, probe watch
    /// cleared, capture paused — except mic-only while the scene is not `.active`, where `pauseRecording` would stop
    /// the unit, unless the user muted with the Advanced keep-alive preference off — `applied = true`,
    /// `onMicrophoneState(desired, false)`.
    func suspendMicrophoneForNetwork() {
        withAudioLock { closeMicrophoneSampleGateLocked() }
        microphoneControl?.suspendForNetwork()
    }

    /// while mic-only, muted and the scene left `.active`, resume recording with every local gate closed so the audio
    /// unit keeps the app alive (status `Messages.mutedKeepAlive`, applied stays muted, no `/microphone` traffic);
    /// pause again on return to `.active`. Only while the Advanced "Keep microphone active while muted in background"
    /// preference is on; off, muted background capture stops. The status loop also calls this while network audio is
    /// held, when it can only stop capture.
    func applyBackgroundKeepAlive() {
        microphoneControl?.applyBackgroundPolicy()
    }

    /// `inputRouteLost` (`StreamReceiver.kt:1342-1356`): built-in/wired/USB changes, or Bluetooth before the first
    /// applied control, stop the session; an established Bluetooth session starts the headset recovery (configured
    /// window, default 20 s; repeated losses never extend it) with all local gates shut. Callbacks only gate and wake.
    func inputRouteLost() {
        guard microphoneReturn, microphoneIsBluetooth, microphoneAppliedMuted.value != nil else {
            stopForInputRouteChange(Messages.inputRouteChanged)
            return
        }
        let requested = withAudioLock { () -> Bool in
            guard !isClosed else { return false }
            closeMicrophoneSampleGateLocked()
            if mode.hasPlayback {
                outputController.holdOutputGate()
                engine?.setSpeakerMuted(true)
            }
            _ = headsetRecovery.request(nowMs: nowMs())
            return true
        }
        if requested { controlSignal.notify() }
    }

    /// `stopForInputRouteChange` (`StreamReceiver.kt:1358-1361`): `input_route_changed`.
    func stopForInputRouteChange(_ detail: String) {
        fail(
            Messages.stopForInputRouteChange(detail: detail, playback: mode.hasPlayback, action: mode.reconnectAction),
            code: .inputRouteChanged)
    }

    /// `setHostMicrophoneGate` (`StreamReceiver.kt:1331-1340`): 410/500 fail with `host_microphone_gate` then rethrow;
    /// the acknowledgment must be `ok == true` with a JSON boolean `muted` equal to the request, else a non-retryable
    /// violation. `timeoutMs == nil` (ordinary mute/unmute) lets `request` apply the configured `lanRequest` /
    /// `remoteRequest` budgets; headset restoration passes its clamp (`StreamReceiver.kt:1402,1784-1789`).
    func setHostMicrophoneGate(token: String, muted: Bool, timeoutMs: Int? = nil) throws {
        let acknowledgment: ControlJSON
        do {
            acknowledgment = try request(
                "/microphone", token: token,
                body: WireBody.object([("version", .int(3)), ("muted", .bool(muted))]),
                timeoutMs: timeoutMs)
        } catch let failure as HTTPFailure {
            if failure.status == 410 || failure.status == 500 {
                fail(Messages.hostMicrophoneGateFailed, code: .hostMicrophoneGate)
            }
            throw failure
        }
        guard acknowledgment.bool("ok", default: false), acknowledgment.isBool("muted"),
            acknowledgment.bool("muted", default: !muted) == muted
        else {
            throw ProtocolViolation("microphone acknowledgment mismatch")
        }
    }

    /// `OutputSessionHost`/`MicrophoneEngineHooks.holdOutputForHeadset`: `outputGate.hold()` + speaker
    /// mute for Bluetooth duplex (`StreamReceiver.kt:1352`).
    func holdOutputForHeadset() {
        withAudioLock {
            guard !isClosed else { return }
            outputController.holdOutputGate()
            engine?.setSpeakerMuted(true)
        }
    }

    /// `outputGate.verified(); setSpeakerMute(speakerMuted)` for Bluetooth duplex
    /// (`StreamReceiver.kt:1309,1321,1490`).
    func verifyOutputForHeadset() {
        withAudioLock {
            guard !isClosed else { return }
            outputController.verifyOutputGate()
        }
    }

    // MARK: - Teardown parts

    /// `input_observers_close` (`StreamReceiver.kt:821`): input probe / headset output watches cleared.
    func closeInputObservers() throws {
        microphoneControl?.closeInputObservers()
    }

    /// `audio_recording_stop` (`StreamReceiver.kt:822`): pause capture (skip if input was never
    /// initialized). Through `MicrophoneControl.stopRecording()` once it exists, which also clears the keep-alive
    /// flag and reports the retained capture ended; the capture alone before that.
    func stopAudioRecording() throws {
        if let microphoneControl {
            microphoneControl.stopRecording()
        } else {
            microphoneCapture?.pause()
            microphoneCapture?.input.discard()
        }
    }

    /// `microphone_route_close` (`StreamReceiver.kt:861`, `close()`), plus hygiene:
    /// `AVAudioApplication.setInputMuted(false)` after every teardown.
    func closeMicrophoneRoute() throws {
        var failure: Error?
        do { try microphoneRouting?.close() } catch { failure = error }
        do { try AVAudioApplication.shared.setInputMuted(false) } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    // MARK: - Bridge

    /// Host for `MicrophoneControl` (`MicrophoneEngineHooks`synchronous) and its `/microphone` gate
    /// (`MicrophoneHostGate`).
    final class MicrophoneHooksBridge: MicrophoneEngineHooks, MicrophoneHostGate {
        weak var owner: SessionController?

        init() {}

        var closed: Bool { owner?.isClosed ?? true }
        var networkHeld: Bool { owner?.networkHeld ?? true }

        func withAudioLock<T>(_ body: () -> T) -> T {
            guard let owner else { return body() }
            return owner.withAudioLock(body)
        }

        func fail(_ message: String, _ code: SessionFailure) { owner?.fail(message, code: code) }
        func onPhase(_ p: SessionPhase) { owner?.emitPhase(p) }
        func onStatus(_ s: String) { owner?.emitStatus(s) }
        func onMicrophoneState(_ muted: Bool, pending: Bool) {
            owner?.emitMicrophoneState(muted: muted, pending: pending)
        }
        func onMicrophoneSelection(_ s: MicrophoneSelection) { owner?.emitMicrophoneSelection(s) }
        func holdOutputForHeadset() { owner?.holdOutputForHeadset() }
        func verifyOutputForHeadset() { owner?.verifyOutputForHeadset() }

        func checkpoint() throws {
            guard let owner else { throw SessionStopped() }
            try owner.workerWait.checkpoint()
        }

        func sleep(ms: Int) throws {
            guard let owner else { throw SessionStopped() }
            try owner.workerWait.sleep(ms: ms)
        }

        func nowMs() -> Int64 { owner?.nowMs() ?? 0 }

        func setHostMicrophoneGate(token: String, muted: Bool, timeoutMs: Int?) throws {
            guard let owner else { throw SessionStopped() }
            try owner.setHostMicrophoneGate(token: token, muted: muted, timeoutMs: timeoutMs)
        }

        // Worker state that lives in `SessionController` (app-mic `MicrophoneControl.Hooks` members 14-18).

        /// `microphoneDesiredMuted`; a detached bridge reads muted.
        var desiredMuted: Bool {
            get { owner?.microphoneDesiredMuted.value ?? true }
            set { owner?.microphoneDesiredMuted.value = newValue }
        }

        /// `microphoneAppliedMuted` (`nil` until the first applied control).
        var appliedMuted: Bool? {
            get { owner?.microphoneAppliedMuted.value ?? nil }
            set { owner?.microphoneAppliedMuted.value = newValue }
        }

        /// `microphoneControlDirty` (worker).
        var controlDirty: Bool {
            get { owner?.microphoneControlDirty ?? false }
            set { owner?.microphoneControlDirty = newValue }
        }

        /// scene state (`applicationActiveFlag`).
        var applicationActive: Bool { owner?.applicationActiveFlag.value ?? true }

        /// `controlSignal.notify()`.
        func notifyControl() { owner?.controlSignal.notify() }

        /// The live Advanced keep-alive preference; a detached bridge never keeps a muted capture running.
        var keepMicrophoneActiveWhileMuted: Bool { owner?.keepMicrophoneActiveWhileMuted ?? false }

        /// Actual retained muted capture for Now Playing (`SessionCallbacks.onMicrophoneCaptureRetained`).
        func onCaptureRetainedWhileMuted(_ retained: Bool) { owner?.emitMicrophoneCaptureRetained(retained) }

        func onCaptureEnabled() { owner?.emitMicrophoneCaptureEnabled() }
    }
}
