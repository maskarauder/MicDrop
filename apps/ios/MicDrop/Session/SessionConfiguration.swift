import Foundation
import MicDropCore

/// Immutable inputs of one session worker.
///
/// Port of the `StreamReceiver` constructor parameters (`StreamReceiver.kt:22-47`). The playback or microphone
/// coordinator (07/08) builds one value per Connect; the worker never mutates it. The Android
/// `wakeLockHeld`/`foregroundTypes` providers are removed: iOS reports `null` / `"unknown"`.
struct SessionConfiguration: Sendable {
    /// Parsed connection link (`ConnectionLink`): v1, v2, paired v3 and remote-wrapped v3.
    let link: ConnectionLink
    /// Trimmed link text as entered or saved. Bookkeeping only (resume ticket digest is computed by the
    /// coordinator); never logged, never sent.
    let linkText: String
    /// Requested audio direction (`StreamMode.kt`).
    let mode: StreamMode
    /// Caller's reconnect flag: enables `BusyOfferRetry` together with `previousStop` (`StreamReceiver.kt:1209`).
    /// Saved-connection reconnects, resumes and every microphone session pass `true`.
    let reconnect: Bool
    /// "Faster recovery after audio interruptions": `RTCConfiguration.audioJitterBufferFastAccelerate`
    /// and `RecoveryMonitor(fastAccelerate:)` (`StreamReceiver.kt:149,471`).
    let fastRecovery: Bool
    /// Local output baseline used only for copy-report text; never on the wire (`local_output_baseline` is always
    /// `null`).
    let baseline: OutputSnapshot?
    /// Initial "Play desktop audio" gate (`AudioOutputGate(enabled:)`, `StreamReceiver.kt:54`).
    let initiallyOutputEnabled: Bool
    /// Initial output choice.
    let outputSelection: OutputSelection
    /// Speaker protection carried across reconnects.
    let protectedDefaultSpeaker: Bool
    /// Always `nil` on iOS (duplex interruptions use Path B); kept for the pure `MediaOutputFocus` parity path.
    let initialOutputFocus: OutputPause?
    /// Selected microphone; `.builtIn` default for playback sessions.
    let microphoneSelection: MicrophoneSelection
    /// Initial desired microphone mute (`StreamReceiver.kt:100`; fresh Connect passes `false`, resume and input switch
    /// pass the retained value).
    let initiallyMicrophoneMuted: Bool
    /// Already `MicrophoneProcessing.effective(mode:input:)` (`StreamReceiver.kt:122`).
    let processing: MicrophoneProcessing
    /// The single audio plan row, already applied by `AudioSessionArbiter.prepare` before `SessionController.start()`.
    let plan: AudioSessionPlan
    let connectionPreferences: ConnectionPreferences
    /// Advanced Bluetooth route recovery window of this session (ms, `AdvancedAudioPreferences` bounds): one
    /// fixed deadline per episode for the selected Bluetooth output (`OutputRouteChange`) and the Bluetooth
    /// headset microphone (`HeadsetRecovery`). Read at Connect, so a saved change applies to the next session.
    /// Separate from the network recovery window in `connectionPreferences`.
    let bluetoothRecoveryMs: Int64
    /// The resume cause of this phone's session (`StreamReceiver.kt:49`): when non-nil, every v3 `/offer` of this
    /// worker carries `X-MicDrop-Session-Resume: 1` and `X-MicDrop-Session-Resume-Reason: <wire>`
    /// (`SessionResume.offerHeaders`). A presentation hint only: it grants no capture consent, no permission and no
    /// session capability. Explicit Connect/Reconnect, including after Stop while paused, passes `nil`.
    let resume: SessionResume.Reason?
    /// Convenience boolean for whether this configuration is a resume (`resume != nil`).
    var resuming: Bool { resume != nil }
    /// The controller's live-settings hooks for phone settings exchange v1 (`StreamReceiver.kt:49`,
    /// `phoneControlBinding`). With a binding (and the stores in `SessionDependencies.phoneControl`) the worker
    /// creates this session's `PhoneControlAdapter`; it is used only if Windows also negotiates the exchange. Nil
    /// keeps the session out of it.
    let phoneControl: PhoneControlBinding?

    init(
        link: ConnectionLink,
        linkText: String,
        mode: StreamMode,
        reconnect: Bool,
        fastRecovery: Bool,
        baseline: OutputSnapshot?,
        initiallyOutputEnabled: Bool,
        outputSelection: OutputSelection,
        protectedDefaultSpeaker: Bool,
        initialOutputFocus: OutputPause? = nil,
        microphoneSelection: MicrophoneSelection,
        initiallyMicrophoneMuted: Bool,
        processing: MicrophoneProcessing,
        plan: AudioSessionPlan, connectionPreferences: ConnectionPreferences = ConnectionPreferences(),
        bluetoothRecoveryMs: Int64 = OutputRouteChange.bluetoothRecoveryMs,
        resume: SessionResume.Reason? = nil,
        phoneControl: PhoneControlBinding? = nil
    ) {
        self.link = link
        self.linkText = linkText
        self.mode = mode
        self.reconnect = reconnect
        self.fastRecovery = fastRecovery
        self.baseline = baseline
        self.initiallyOutputEnabled = initiallyOutputEnabled
        self.outputSelection = outputSelection
        self.protectedDefaultSpeaker = protectedDefaultSpeaker
        self.initialOutputFocus = initialOutputFocus
        self.microphoneSelection = microphoneSelection
        self.initiallyMicrophoneMuted = initiallyMicrophoneMuted
        self.processing = processing
        self.plan = plan
        self.connectionPreferences = connectionPreferences
        self.bluetoothRecoveryMs = AdvancedAudioPreferences.boundedBluetoothRecoveryMs(bluetoothRecoveryMs)
        self.resume = resume
        self.phoneControl = phoneControl
    }
}

extension SessionConfiguration {
    /// Control protocol version of the link: 1, 2 or 3 (`LanInvitation.version`).
    var protocolVersion: Int { link.version.rawValue }

    /// `invitation.remote != null`.
    var isRemote: Bool { link.remote != nil }

    /// Remote forced-relay flag (`invitation.remote?.forceRelay == true`).
    var forceRelay: Bool { link.remote?.forceRelay ?? false }

    /// `mode.usesMediaOutput(microphoneSelection.kind)` (`StreamReceiver.kt:58`).
    var usesMediaOutput: Bool { mode.usesMediaOutput(microphoneSelection.kind) }

}
