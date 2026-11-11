import Foundation
import MicDropCore

/// Microphone/duplex status strings (rows owned).
///
/// `title`/`detail`/`actions` port the Android ongoing-notification content of `A/MicrophoneService.kt:474-502` (first
/// match wins). iOS shows them in the in-app status and, for non-mixable rows, in Now Playing; Mute/Unmute has no
/// lock-screen control (no Live Activity in v1). `Messages` holds the remaining user texts so the controller and the
/// session worker use one spelling. Pure; no device identity is ever included.
enum MicrophoneStatusText {
    /// Out-of-app action labels (`A/MicrophoneService.kt:490-501`).
    enum Action: String, CaseIterable, Sendable {
        case unmute = "Unmute"
        case mute = "Mute"
        case resumeDuplex = "Resume duplex"
        /// Never produced on iOS (no FOCUS_MANUAL output pause); kept for parity.
        case resumeAudio = "Resume audio"
        case stop = "Stop"
    }

    /// Title for duplex (`mode.playback`) sessions.
    static let duplexTitle = "MicDrop desktop audio + microphone"
    /// Title for microphone-only sessions.
    static let microphoneTitle = "MicDrop microphone"

    /// `setContentTitle(if (mode.playback) … else …)`. Kotlin `mode.playback` is spelled
    /// `mode != .microphone` in this directory so only the `StreamMode` case names are relied on.
    static func title(mode: StreamMode) -> String {
        mode != .microphone ? duplexTitle : microphoneTitle
    }

    /// `setContentText(when { … })` (`A/MicrophoneService.kt:479-489`), evaluated on the published view
    /// (`view.session.outputEnabled` / `.outputPause` are the controller's values, copied in by `publish()` exactly as
    /// Android's `lastView`). `keptOpenForBackground`: a microphone-only session that is muted while the scene is not
    /// `.active` actually keeps capture running with every gate closed (the worker's `captureRetainedWhileMuted`, which
    /// needs the Advanced "Keep microphone active while muted in background" setting and a start iOS accepted); the
    /// honest text then replaces the "capture stopped" wording.
    static func detail(_ view: MicrophoneView, keptOpenForBackground: Bool = false) -> String {
        let session = view.session
        let playback = view.mode != .microphone  // Kotlin `mode.playback`
        switch session.phase {
        case .stopping:
            return playback ? "Stopping playback and microphone" : "Stopping microphone return"
        case .switching:
            return "Changing audio device · audio gated"
        case .routeRecovering:
            // iOS: route-neutral like `SessionPhase.label` (duplex also restores a selected media output here).
            return "Restoring selected audio device · \(playback ? "audio" : "microphone") paused"
        case .pausing:
            return "Pausing duplex for phone audio"
        case .paused, .interrupted:
            return "Duplex paused · microphone capture stopped"
        default:
            break
        }
        if view.changing {
            return playback ? "Configuring playback and microphone" : "Configuring microphone return"
        }
        let label = view.input.kind.label
        if playback && session.outputEnabled && session.outputPause != nil {
            return "Playback paused · " + (view.muted ? "microphone muted" : "sending \(label)")
        }
        if view.muted {
            if playback && session.outputEnabled { return "Listening · microphone muted" }
            return keptOpenForBackground && !playback ? Messages.mutedKeptOpen : "Silenced · microphone capture stopped"
        }
        return playback && session.outputEnabled ? "Listening · sending \(label)" : "Sending \(label) to Windows"
    }

    /// Available actions (`A/MicrophoneService.kt:490-501`): Mute/Unmute iff `canSetMuted(!muted)`,
    /// Resume duplex iff `canResume`, Resume audio iff active with a FOCUS_MANUAL output pause, Stop always.
    static func actions(_ view: MicrophoneView) -> [Action] {
        var actions: [Action] = []
        if view.canSetMuted(!view.muted) { actions.append(view.muted ? .unmute : .mute) }
        if view.canResume { actions.append(.resumeDuplex) }
        if view.session.active && view.session.outputPause == .focusManual { actions.append(.resumeAudio) }
        actions.append(.stop)
        return actions
    }

    /// user-visible texts. The session worker's `SessionController.Messages` must use the same strings.
    enum Messages {
        // Controller (table).
        /// Activation refused while another session holds audio (`MicrophoneService.kt:169`).
        static let focusDenied =
            "iOS did not let MicDrop use audio. Stop other playback, keep MicDrop open and tap Connect again."
        /// Any exception while starting the session (`MicrophoneService.kt:241`).
        static let startFailed =
            "Microphone return could not start. Keep MicDrop open and allow microphone access in Settings."
        /// 20 s input-change replacement expired (`MicrophoneService.kt:429`).
        static let switchTimedOut = "Microphone change timed out. Capture stayed stopped. Tap Connect when ready."
        /// Replacement preflight failed after the old worker ended (`MicrophoneService.kt:445`).
        static let switchReconnectFailed =
            "The selected input could not reconnect. Check permission and the media output, then tap Connect."
        /// `SessionLifecycle.Messages.duplexResumeFailed` (`MicrophoneService.kt:373`).
        static var duplexResumeFailed: String { SessionLifecycle.Messages.duplexResumeFailed }
        /// `SessionLifecycle.Messages.duplexPauseExpired` (`MicrophoneService.kt:377`).
        static var duplexPauseExpired: String { SessionLifecycle.Messages.duplexPauseExpired }

        // Worker ("Other microphone messages").
        /// Route-loss detail (`StreamReceiver.kt:1342-1361`).
        static let inputRouteChanged = "The selected microphone or Bluetooth audio route changed."
        /// Recovery window expired (`StreamReceiver.kt:1367`, iOS wording). `seconds` is the session's configured
        /// Bluetooth route recovery window (`AdvancedAudioPreferences.seconds`), as Android's messages name its
        /// configured window (`StreamReceiver.kt:57-59,1465,1470` on main `87b15af`).
        static func headsetNotRestored(seconds: String) -> String {
            "iOS did not restore the selected headset within \(seconds) seconds."
        }
        /// Reselection impossible (`StreamReceiver.kt:1438`, iOS wording).
        static let headsetNotReselected = "iOS could not reselect the original headset."
        /// Muted Bluetooth duplex output could not be verified (`StreamReceiver.kt:1290`).
        static let headsetOutputUnverified =
            "The selected headset output could not be verified. Stop and select the input again."
        /// Record init error (`StreamReceiver.kt:432`).
        static let microphoneInitFailed =
            "The selected microphone could not start. Check microphone permission in Settings."
        /// Record start error (`StreamReceiver.kt:433`).
        static let microphoneStartFailed = "The selected microphone failed to start."
        /// Record runtime error (`StreamReceiver.kt:434`).
        static let microphoneRuntimeFailed = "The selected microphone stopped unexpectedly."
        /// Host cable gate failure, HTTP 410/500 on `/microphone` (`StreamReceiver.kt:1336`).
        static let hostMicrophoneGateFailed =
            "Windows ended microphone return or could not apply its cable gate. Check the Windows console and the selected render endpoint with bridge-devices before retrying."
        /// DUPLEX + HTTP 400 on `/offer` (`StreamReceiver.kt:1218`).
        static let duplexUnsupported =
            "Windows does not support duplex. Update both apps, then enable Play desktop audio and Send microphone and tap Connect again."
        /// Microphone mode + HTTP 409 on `/offer` (`StreamReceiver.kt:1220`).
        static let microphoneReturnNotConfigured =
            "Windows microphone return is not configured. Restart Windows with --paired and --microphone-device using the cable render ID from bridge-devices."
        /// Mode confirmation mismatch (`StreamReceiver.kt:387-390`).
        static let modeNotConfirmed =
            "Windows did not confirm the requested audio mode. Update both apps and select a cable endpoint for microphone return."
        /// mic-only Mute while backgrounded keeps capture open with every gate closed (Advanced "Keep microphone active
        /// while muted in background" on, the default).
        static let mutedKeptOpen = "Muted · microphone kept open so iOS keeps MicDrop running"

        /// `stopForInputRouteChange(detail)` (`StreamReceiver.kt:1357-1361`):
        /// `"<detail> <Playback and microphone return stopped.|Microphone return stopped.> Choose an available input and tap Connect again."`.
        static func inputRouteStopped(detail: String, playback: Bool) -> String {
            "\(detail) \(playback ? "Playback and microphone return stopped." : "Microphone return stopped.") Choose an available input and tap Connect again."
        }

        /// First restoration step of an episode (`StreamReceiver.kt:1372`); `seconds` as in `headsetNotRestored`.
        static func restoringHeadset(playback: Bool, seconds: String) -> String {
            "Restoring the selected headset for up to \(seconds) seconds. "
                + "\(playback ? "Playback and microphone" : "Microphone") temporarily silenced."
        }

        /// Restoration success (`StreamReceiver.kt:1497`).
        static func headsetRestored(muted: Bool) -> String {
            "Selected headset restored.\(muted ? " Microphone remains muted." : "")"
        }

        /// `mode.endedMessage(.service)` for a microphone controller torn down by iOS (`MicrophoneService.kt:526-528`):
        /// `Microphone session stopped by iOS. Tap Connect when ready.`
        static var serviceEnded: String {
            StopReason.service.endedMessage(microphone: true, reconnectAction: "Connect")
        }
    }
}
