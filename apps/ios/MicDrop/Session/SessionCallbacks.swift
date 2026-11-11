import Foundation
import MicDropCore

/// Worker → coordinator notifications (Kotlin `StreamReceiver` callback parameters, `StreamReceiver.kt:27-46`).
///
/// Delivery contract: `SessionController` posts **every** callback with `DispatchQueue.main.async` (FIFO), never
/// synchronously and never from inside one of its locks. Consumers run on the main thread and must not block. `onEnded`
/// is delivered exactly once per started session, after native disposal and after the `AudioSessionOwner` permit was
/// released.
struct SessionCallbacks {
    /// Status line (stage labels `"<label>…"`, recovery texts, and — parity with — the periodic diagnostics snapshot,
    /// which the UI hides because it contains `" snapshot:"`).
    var onStatus: (String) -> Void
    /// Periodic copy-report text.
    var onDiagnostics: (String) -> Void
    /// Session phase published by the worker (step 11, `StreamReceiver.kt:687-689`).
    var onPhase: (SessionPhase) -> Void
    /// Final result: `(failure ?? mode.endedMessage(reason)) + confirmation`, journal text
    /// (`StreamReceiver.kt:873`).
    var onEnded: (StreamEnd) -> Void
    /// Remote-only `"Network: <label>[ · Restoring connection]"` line (`StreamReceiver.kt:1554-1566`).
    var onNetworkStatus: (String) -> Void
    /// Verified or automatically returned output selection.
    var onOutputSelection: (OutputSelection) -> Void
    /// Current output pause and speaker protection (`publishOutputState`).
    var onOutputState: (_ pause: OutputPause?, _ protectedSpeaker: Bool) -> Void
    /// Desired microphone mute and whether it is still being applied.
    var onMicrophoneState: (_ muted: Bool, _ pending: Bool) -> Void
    /// Microphone selection after verification (last step).
    var onMicrophoneSelection: (MicrophoneSelection) -> Void
    /// Whether a muted capture is actually running with every gate closed
    /// (`MicrophoneControl.captureRetainedWhileMuted`; Android `microphoneCaptureRetained`). Sent on change only.
    var onMicrophoneCaptureRetained: (Bool) -> Void
    /// A verified, unmuted capture actually opened its sample gate after the host acknowledged Unmute. Desired-state
    /// reports and a gated background capture do not establish this session's capture authorization.
    var onMicrophoneCaptureEnabled: () -> Void

    init(
        onStatus: @escaping (String) -> Void,
        onDiagnostics: @escaping (String) -> Void,
        onPhase: @escaping (SessionPhase) -> Void,
        onEnded: @escaping (StreamEnd) -> Void,
        onNetworkStatus: @escaping (String) -> Void = { _ in },
        onOutputSelection: @escaping (OutputSelection) -> Void = { _ in },
        onOutputState: @escaping (_ pause: OutputPause?, _ protectedSpeaker: Bool) -> Void = { _, _ in },
        onMicrophoneState: @escaping (_ muted: Bool, _ pending: Bool) -> Void = { _, _ in },
        onMicrophoneSelection: @escaping (MicrophoneSelection) -> Void = { _ in },
        onMicrophoneCaptureRetained: @escaping (Bool) -> Void = { _ in },
        onMicrophoneCaptureEnabled: @escaping () -> Void = {}
    ) {
        self.onStatus = onStatus
        self.onDiagnostics = onDiagnostics
        self.onPhase = onPhase
        self.onEnded = onEnded
        self.onNetworkStatus = onNetworkStatus
        self.onOutputSelection = onOutputSelection
        self.onOutputState = onOutputState
        self.onMicrophoneState = onMicrophoneState
        self.onMicrophoneSelection = onMicrophoneSelection
        self.onMicrophoneCaptureRetained = onMicrophoneCaptureRetained
        self.onMicrophoneCaptureEnabled = onMicrophoneCaptureEnabled
    }

    /// Callbacks that ignore everything (tests, previews).
    static var none: SessionCallbacks {
        SessionCallbacks(onStatus: { _ in }, onDiagnostics: { _ in }, onPhase: { _ in }, onEnded: { _ in })
    }
}
