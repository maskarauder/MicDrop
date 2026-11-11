import Foundation
import MicDropCore

/// Output selection, gates and verification delegated to `OutputRouteController`; this extension forwards the
/// `StreamReceiving` output API and provides the controller's host and playout bridges (`OutputSessionHost`,
/// `OutputPlayoutEngine`).
extension SessionController {

    // MARK: - StreamReceiving output API (`StreamReceiver.kt:163-299`)

    func setOutputEnabled(_ enabled: Bool) { outputController.setOutputEnabled(enabled) }

    func setOutputSelection(_ s: OutputSelection) { outputController.setOutputSelection(s) }

    func setOutputFocus(_ p: OutputPause?) { outputController.setOutputFocus(p) }

    func matchesOutputSelection(_ s: OutputSelection) -> Bool { outputController.matchesOutputSelection(s) }

    func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool {
        outputController.matchesOutputState(pause: pause, protectedSpeaker: protectedSpeaker)
    }

    @discardableResult
    func mediaOutputBecomingNoisy() -> Bool { outputController.mediaOutputBecomingNoisy() }

    func outputSwitchPending() -> Bool { outputController.outputSwitchPending() }

    /// `outputEnabled()` (`StreamReceiver.kt:163`): the user gate, independent of holds.
    func outputEnabled() -> Bool { outputController.outputEnabled() }

    // MARK: - Teardown parts

    /// `output_observers_close` (`StreamReceiver.kt:820`): route-observer registrations of this session.
    func closeOutputObservers() throws {
        outputController.stopObservers()
    }

    /// `local_audio_gates` (`StreamReceiver.kt:816-819`, step 3): the five output stops + mute and the microphone
    /// sample gate under the audio lock, then the final speaker mute applied synchronously from the worker before
    /// `/stop`.
    func closeLocalAudioGates() {
        withAudioLock {
            outputController.close()
            if microphoneReturn { closeMicrophoneSampleGateLocked() }
        }
        engine?.setSpeakerMutedSynchronously(true)
    }

    // MARK: - Bridges

    /// `OutputSessionHost` for `OutputRouteController`. Calls arrive from the worker and from route-change threads;
    /// none blocks.
    final class OutputHostBridge: OutputSessionHost {
        weak var owner: SessionController?

        init() {}

        var isClosed: Bool { owner?.isClosed ?? true }
        var networkHeld: Bool { owner?.networkHeld ?? true }
        var headsetRecoveryPending: Bool { owner?.headsetRecovery.pending() ?? false }

        func fail(_ message: String, code: SessionFailure) { owner?.fail(message, code: code) }
        /// `.output` → wire `output_lost`.
        func close(reason: StopReason) { owner?.close(reason) }
        func publishPhase(_ phase: SessionPhase) { owner?.emitPhase(phase) }
        func publishStatus(_ text: String) { owner?.emitStatus(text) }
        func outputSelectionChanged(_ s: OutputSelection) { owner?.emitOutputSelection(s) }
        func outputStateChanged(pause: OutputPause?, protectedSpeaker: Bool) {
            owner?.emitOutputState(pause: pause, protectedSpeaker: protectedSpeaker)
        }
        func wakeWorker() { owner?.controlSignal.notify() }

        /// `synchronized(audioLock)`: the session's recursive audio lock (`OutputSessionHost` requirement).
        func withAudioLock<R>(_ body: () throws -> R) rethrows -> R {
            guard let owner else { return try body() }
            return try owner.withAudioLock(body)
        }

        /// `withCurrentOutput` lock order (`StreamReceiver.kt:1155-1161`): session cancel lock, then the
        /// session audio lock, then the caller's work. iOS addition for the controller.
        func withSessionLocks<R>(_ body: () throws -> R) rethrows -> R {
            guard let owner else { return try body() }
            owner.cancelLock.lock()
            owner.audioLock.lock()
            defer {
                owner.audioLock.unlock()
                owner.cancelLock.unlock()
            }
            return try body()
        }
    }

    /// `OutputPlayoutEngine` for `OutputRouteController`: remote-track mute, playout restart and playout state,
    /// available before the engine exists (the engine is created at stage AUDIO).
    final class PlayoutEngineBridge: OutputPlayoutEngine {
        weak var owner: SessionController?

        init() {}

        func setRemotePlayoutMuted(_ muted: Bool) { owner?.applyEngineSpeakerMute(muted) }

        func restartPlayout() throws { try owner?.restartEnginePlayout() }

        var playoutActive: Bool { owner?.playoutActiveFlag.value ?? false }

        var playoutGlitches: Int64 { owner?.playoutGlitchTotal.value ?? 0 }

        var interrupted: Bool { owner?.audioInterruptedFlag.value ?? false }
    }
}
