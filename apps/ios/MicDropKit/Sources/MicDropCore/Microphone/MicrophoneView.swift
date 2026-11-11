import Foundation

/// Published state of the microphone/duplex controller (`A/MicrophoneService.kt:25-38`), ported verbatim.
///
/// `MicrophoneSessionController` (app) publishes it; the UI (`ControlsDeriver`, 10), Now Playing (07) and out-of-app
/// actions read the derived rules. Test vectors: `T/MicrophoneViewTest.kt`.
public struct MicrophoneView: Equatable, Sendable {
    public var session: SessionView
    /// Muted microphone (view only; default true until a session reports otherwise).
    public var muted: Bool
    /// A mute/route/setup change is in flight.
    public var changing: Bool
    public var mode: StreamMode
    public var input: MicrophoneSelection

    public init(
        session: SessionView, muted: Bool = true, changing: Bool = false,
        mode: StreamMode = .microphone, input: MicrophoneSelection = MicrophoneSelection()
    ) {
        self.session = session
        self.muted = muted
        self.changing = changing
        self.mode = mode
        self.input = input
    }

    /// `MicrophoneView()`: idle `SessionView()` and every default above.
    public init() {
        self.init(session: SessionView())
    }

    /// `ownsSession` = `session.retained`: while true the playback controller refuses to
    /// begin and media Play is ignored.
    public var ownsSession: Bool { session.retained }

    /// `canChooseInput` = microphone mode && phase ∈ {playing, recovering, routeRecovering,
    /// paused, interrupted}.
    public var canChooseInput: Bool {
        isMicrophoneMode
            && [SessionPhase.playing, .recovering, .routeRecovering, .paused, .interrupted]
                .contains(session.phase)
    }

    /// `canResume` = duplex && phase ∈ {pausing, paused, interrupted}.
    public var canResume: Bool {
        mode == .duplex && [SessionPhase.pausing, .paused, .interrupted].contains(session.phase)
    }

    /// `canSetMuted(value)` = microphone mode && value != muted && (
    /// (!changing && phase ∈ {playing, recovering, routeRecovering}) ||
    /// (value && phase ∈ {connecting, routeRecovering, switching}) ||
    /// (canResume && (!changing || value))).
    public func canSetMuted(_ value: Bool) -> Bool {
        guard isMicrophoneMode, value != muted else { return false }
        let phase = session.phase
        if !changing && [SessionPhase.playing, .recovering, .routeRecovering].contains(phase) { return true }
        if value && [SessionPhase.connecting, .routeRecovering, .switching].contains(phase) { return true }
        return canResume && (!changing || value)
    }

    /// Whether phone settings exchange v1 offers Windows the `live.microphone_muted` field of this live session
    /// (`MicrophoneService.kt:206`: `!changing && canSetMuted(!muted)`) under (2026-10-27): Windows may unmute only an
    /// already authorized session and never grants permission or starts the first capture. While muted the field is
    /// therefore offered only when all three hold:
    /// - `permissionGranted`: record permission is granted now (the caller reads it at every snapshot and apply);
    /// - `captureEnabledThisSession`: the phone itself opened capture in this session (its worker confirmed an unmuted
    ///   microphone since the explicit Connect), so a Mute tapped while connecting leaves Windows nothing to unmute;
    /// - the iPhone condition: the scene is active or a muted capture is already running. In the background an unmute
    ///   would need `capture.resume()`, which iOS may refuse (failing the session); duplex pauses capture while muted;
    ///   and MicDrop has no out-of-app Unmute.
    ///
    /// Mute is offered whenever unmuted and no mute, unmute or route change is in flight, whatever the other terms.
    /// The caller also requires a live session (active, neither PAUSING nor STOPPING, not superseded).
    public func offersPhoneControlMute(
        applicationActive: Bool, captureRetainedWhileMuted: Bool, permissionGranted: Bool,
        captureEnabledThisSession: Bool
    ) -> Bool {
        guard !changing, canSetMuted(!muted) else { return false }
        if !muted { return true }
        return permissionGranted && captureEnabledThisSession && (applicationActive || captureRetainedWhileMuted)
    }

    /// Kotlin `mode.microphone` (microphone or duplex), expressed through the case names only.
    private var isMicrophoneMode: Bool { mode != .playback }
}
