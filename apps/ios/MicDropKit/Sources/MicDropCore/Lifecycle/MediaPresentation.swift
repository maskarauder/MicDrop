// Lock-screen / Now Playing presentation. Port of `SessionLifecycle.kt:138-151` and the output-pause buffering rule of
// `LiveMediaPlayer.kt:25-26` (07 owns Now Playing).

/// What the media controls show. Presentation changes at local mute, independently of slow network or
/// native cleanup: a manual pause shows Play immediately, a queued Play shows Pause + buffering, and an
/// automatic interruption shows Pause (so pressing it cancels the automatic resume) and `suppressed`.
public struct MediaPresentation: Equatable, Sendable {
    /// Now Playing is published (nil info otherwise).
    public var visible: Bool
    /// Playback rate 1 when true, else 0.
    public var playWhenReady: Bool
    public var buffering: Bool
    /// Automatic interruption pending (Android TRANSIENT_AUDIO_FOCUS_LOSS suppression).
    public var suppressed: Bool

    public init(visible: Bool, playWhenReady: Bool, buffering: Bool, suppressed: Bool) {
        self.visible = visible
        self.playWhenReady = playWhenReady
        self.buffering = buffering
        self.suppressed = suppressed
    }

    /// `MediaPresentation.of` (`SessionLifecycle.kt:142-149`). Call with `automatic = lifecycle.resumeOnFocus`
    /// and `queued = lifecycle.playAfterPause` (`PlaybackService.kt:463`).
    public static func of(_ phase: SessionPhase, automatic: Bool, queued: Bool) -> MediaPresentation {
        let visible: Bool
        switch phase {
        case .idle, .ended, .stopping: visible = false
        default: visible = true
        }
        let interrupted = automatic && (phase == .pausing || phase == .interrupted)
        let livePhase: Bool
        switch phase {
        case .connecting, .playing, .recovering, .routeRecovering, .switching: livePhase = true
        default: livePhase = false
        }
        let bufferingPhase: Bool
        switch phase {
        case .connecting, .recovering, .routeRecovering, .switching: bufferingPhase = true
        default: bufferingPhase = false
        }
        let playing = livePhase || interrupted || queued
        return MediaPresentation(
            visible: visible, playWhenReady: visible && playing,
            buffering: bufferingPhase || queued, suppressed: interrupted)
    }

    /// `of(view.phase, …)` plus `LiveMediaPlayer.kt:25-26`: an active session whose enabled output is
    /// held (`outputPause != nil`) also reports buffering. Buffering is not gated by `visible`.
    public static func of(view: SessionView, automatic: Bool, queued: Bool) -> MediaPresentation {
        var presentation = of(view.phase, automatic: automatic, queued: queued)
        if view.outputEnabled && view.outputPause != nil && view.active { presentation.buffering = true }
        return presentation
    }

    /// Now Playing album-title status line, the iOS replacement for the Media3 buffering spinner and suppression state:
    /// suppressed → `interrupted` label; buffering → the phase label, or `"Audio paused"` when only the output hold
    /// causes buffering; rate 1 → `"Live"`; else `"Paused"`.
    public static func nowPlayingStatus(_ view: SessionView, automatic: Bool, queued: Bool) -> String {
        let base = of(view.phase, automatic: automatic, queued: queued)
        let shown = of(view: view, automatic: automatic, queued: queued)
        if shown.suppressed { return SessionPhase.interrupted.label }
        if shown.buffering { return base.buffering ? view.phase.label : "Audio paused" }
        return shown.playWhenReady ? "Live" : "Paused"
    }
}
