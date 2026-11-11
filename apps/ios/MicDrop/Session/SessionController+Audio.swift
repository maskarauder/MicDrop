import AVFoundation
import Foundation
import MicDropCore

/// Network audio holds and WebRTC engine events (`StreamReceiver.kt:408-442, 1518-1552, 1713-1754`).
extension SessionController {

    // MARK: - Engine publication

    /// Publishes the engine created at stage AUDIO under `audioLock` (`StreamReceiver.kt:443-447`):
    /// a Stop that raced the creation stops the output gates; the composite speaker mute is applied.
    func publishEngine(_ created: MediaEngine) {
        withAudioLock {
            engine = created
            if isClosed { outputController.close() }
            outputController.applySpeakerMute()
        }
    }

    /// `OutputPlayoutEngine.setRemotePlayoutMuted` target: forwards to the engine's coalescing gate queue; never blocks
    /// and never runs WebRTC under the audio lock.
    func applyEngineSpeakerMute(_ muted: Bool) {
        let current = withAudioLock { engine }
        current?.setSpeakerMuted(muted)
    }

    /// `OutputPlayoutEngine.restartPlayout` target: worker only.
    func restartEnginePlayout() throws {
        try engine?.restartPlayout()
    }

    // MARK: - Network audio hold

    /// `holdNetworkAudio()` (`StreamReceiver.kt:1518-1529`): any thread; speaker mute, Bluetooth-duplex
    /// output gate hold, microphone sample gate closed.
    func holdNetworkAudio() {
        withAudioLock {
            guard !isClosed else { return }
            networkHeldFlag.value = true
            // A headset duplex route can change while capture is stopped; keep listening held until
            // the resumed microphone-control path verifies that same headset output.
            if mode.hasPlayback && microphoneIsBluetooth { outputController.holdOutputGate() }
            engine?.setSpeakerMuted(true)
            if microphoneReturn { closeMicrophoneSampleGateLocked() }
        }
    }

    /// `suspendNetworkAudio()` (`StreamReceiver.kt:1531-1542`): worker, once per hold episode. Playout
    /// keeps consuming NetEq into silence (keeps the iOS app alive in playback/duplex).
    func suspendNetworkAudio() {
        guard !networkAudioSuspended, !isClosed else { return }
        networkAudioSuspended = true
        if microphoneReturn { suspendMicrophoneForNetwork() }
    }

    /// `releaseNetworkAudio()` (`StreamReceiver.kt:1544-1552`): only when not closed, no recovery
    /// pending, local peer `Connected` and ICE connected. Microphone control becomes dirty so the next
    /// iteration re-sends `/microphone` (the host re-mutes the cable on every restart).
    func releaseNetworkAudio() {
        withAudioLock {
            guard !isClosed, !lanRecovery.pending, peerStateStorage.value == "Connected", iceConnectedFlag.value else {
                return
            }
            networkHeldFlag.value = false
            if microphoneReturn { microphoneControlDirty = true }
            outputController.applySpeakerMute()
            networkAudioSuspended = false
        }
    }

    // MARK: - Engine events (delegate / signalling threads; never block, never HTTP)

    /// `onConnectionChange` (`StreamReceiver.kt:1727-1738`).
    func handlePeerState(_ label: String) {
        guard !isClosed else { return }
        peerStateStorage.value = label
        let value = label.lowercased()
        evidence.observe(.peer, value, uptimeMs: nowMs())
        let supported = recoverySupportedFlag.value
        if (value == "disconnected" || value == "failed") && supported {
            holdNetworkAudio()
            controlSignal.notify()
        }
        if value == "failed" && !supported {
            fail(Messages.connectionLost(action: mode.reconnectAction), code: .peerFailed)
        }
    }

    /// `onIceConnectionChange` (`StreamReceiver.kt:1715-1722`, legacy ICE state).
    func handleIceConnection(_ label: String, connected: Bool) {
        guard !isClosed else { return }
        iceConnectedFlag.value = connected
        let value = label.lowercased()
        evidence.observe(.ice, value, uptimeMs: nowMs())
        if (value == "disconnected" || value == "failed") && recoverySupportedFlag.value {
            holdNetworkAudio()
            controlSignal.notify()
        }
    }

    /// `onIceCandidate` (`StreamReceiver.kt:1739-1742`).
    func handleLocalCandidate(index: Int32, sdp: String) {
        guard !isClosed else { return }
        if collectingRecoveryFlag.value { recoveryCandidates.add(index: Int(index), sdp: sdp) }
        if continuousEnabledFlag.value { continuousCandidates.add(index: Int(index), sdp: sdp) }
    }

    /// `onIceCandidatesRemoved` (`StreamReceiver.kt:1746-1748`); the SDK reports index −1.
    func handleCandidatesRemoved(_ candidates: [(Int32, String)]) {
        guard !isClosed, continuousEnabledFlag.value else { return }
        for (index, sdp) in candidates { continuousCandidates.remove(index: Int(index), sdp: sdp) }
    }

    /// `onIceCandidateError` (`StreamReceiver.kt:1743-1745`).
    func handleCandidateError(code: Int32) {
        guard !isClosed else { return }
        gatheringErrors.record(code: Int(code))
    }

    /// Playout rising edge = Android `onWebRtcAudioTrackStart` (`StreamReceiver.kt:409-418`).
    func handlePlayoutStarted() {
        playoutActiveFlag.value = true
        outputController.playoutDidStart()
    }

    /// Playout falling edge = `onWebRtcAudioTrackStop` (`StreamReceiver.kt:419-425`): ignored while interrupted;
    /// Bluetooth-duplex with an applied control treats it as headset route loss.
    func handlePlayoutStopped() {
        playoutActiveFlag.value = false
        guard !audioInterruptedFlag.value, !isClosed else { return }
        outputController.playoutDidStop()
        if mode.hasPlayback && microphoneIsBluetooth && microphoneAppliedMuted.value != nil { inputRouteLost() }
    }

    /// Track init/start/runtime errors (`StreamReceiver.kt:436-441`): first
    /// `outputController.recoverableOutputFailed()`, else fail with the iOS texts (`output_init` / `output_start` /
    /// `output_runtime`).
    func handleOutputFailure(_ kind: OutputFailureKind) {
        guard !outputController.recoverableOutputFailed() else { return }
        switch kind {
        case .initialization: fail(kind.failureText, code: .outputInit)
        case .start: fail(kind.failureText, code: .outputStart)
        case .runtime: fail(kind.failureText, code: .outputRuntime)
        }
    }

    /// Record init/start/runtime errors (`StreamReceiver.kt:431-435`): `microphone_init` / `microphone_start` /
    /// `microphone_runtime` with the texts.
    func handleCaptureFailure(_ kind: CaptureFailureKind) {
        switch kind {
        case .initialization: fail(kind.failureText, code: .microphoneInit)
        case .start: fail(kind.failureText, code: .microphoneStart)
        case .runtime: fail(kind.failureText, code: .microphoneRuntime)
        }
    }

    /// `mediaServicesWereResetNotification` (which overrides): every audio object is invalid, so no output recovery is
    /// tried and playout recreation is blocked first. Microphone modes whose capture was active (Android
    /// `recordStarted`) fail with `microphone_runtime`; every other case (playback, muted or suspended capture) closes
    /// with `.failure`. The arbiter re-applies nothing until the next explicit Connect. Posting thread; never blocks.
    func handleMediaServicesReset() {
        guard !isClosed else { return }
        outputController.mediaServicesWereReset()
        if microphoneReturn && microphoneCapture?.captureActive == true {
            fail(CaptureFailureKind.runtime.failureText, code: .microphoneRuntime)
        } else {
            close(.failure)
        }
    }

    /// Interruption edges: output loss is not evaluated while interrupted.
    func handleAudioInterruption(began: Bool, shouldResume: Bool) {
        guard !isClosed else { return }
        audioInterruptedFlag.value = began
        controlSignal.notify()
    }

    /// `didDetectPlayoutGlitch` running total (`playoutGlitches`).
    func handlePlayoutGlitches(total: Int) {
        playoutGlitchTotal.value = Int64(total)
    }

    // MARK: - Bridge

    /// `MediaEngineEvents` adapter handed to `dependencies.engineFactory`. Called on WebRTC / main threads; every
    /// method returns immediately.
    final class EngineEventsBridge: MediaEngineEvents {
        weak var owner: SessionController?

        init() {}

        func peerStateChanged(_ label: String) { owner?.handlePeerState(label) }
        func iceConnectionChanged(_ label: String, connected: Bool) {
            owner?.handleIceConnection(label, connected: connected)
        }
        /// The engine owns the gathering latch (`resetGatheredLatch` / `waitGathered`).
        func iceGatheringCompleted() {}
        func localCandidate(index: Int32, sdp: String) { owner?.handleLocalCandidate(index: index, sdp: sdp) }
        func localCandidatesRemoved(_ c: [(Int32, String)]) { owner?.handleCandidatesRemoved(c) }
        func candidateError(code: Int32) { owner?.handleCandidateError(code: code) }
        func playoutStarted() { owner?.handlePlayoutStarted() }
        func playoutStopped() { owner?.handlePlayoutStopped() }
        func outputFailure(_ kind: OutputFailureKind) { owner?.handleOutputFailure(kind) }
        func captureFailure(_ kind: CaptureFailureKind) { owner?.handleCaptureFailure(kind) }
        func mediaServicesReset() { owner?.handleMediaServicesReset() }
        func audioInterruption(began: Bool, shouldResume: Bool) {
            owner?.handleAudioInterruption(began: began, shouldResume: shouldResume)
        }
        /// Route changes reach the session through `AudioSessionEventMonitor` → `OutputRouteController` /
        /// `MicrophoneRouting`; nothing to do here.
        func audioRouteChanged(reason: AVAudioSession.RouteChangeReason) {}
        func playoutGlitches(total: Int) { owner?.handlePlayoutGlitches(total: total) }
    }
}
