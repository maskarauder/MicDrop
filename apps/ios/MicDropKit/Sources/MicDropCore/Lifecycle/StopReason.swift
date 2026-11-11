// Stop reasons and the worker's terminal result. Port of `SessionLifecycle.kt:9-26` with iOS wording. Raw
// values are the `/stop` wire labels (`internal/session/server.go:389-393`) and must never be localized or changed.

/// Why a session stopped. The raw value is the precise `/stop` `reason` wire label.
public enum StopReason: String, CaseIterable, Sendable {
    case user = "user_stop"
    case pause = "user_pause"
    case focus = "focus_loss"
    case focusTransient = "focus_loss_transient"
    case focusPermanent = "focus_loss_permanent"
    case output = "output_lost"
    case service = "service_stopped"
    case failure = "connection_failed"

    /// Precise wire label for hosts with `session_lifecycle_version >= 2`.
    public var wire: String { rawValue }

    /// Playback-mode end message (`SessionLifecycle.kt:10-17`; FOCUS, FOCUS_TRANSIENT, FOCUS_PERMANENT and SERVICE
    /// adapted for iOS).
    public var message: String {
        switch self {
        case .user: return "Stopped."
        case .pause: return "Paused."
        case .focus: return "Stopped after another app took audio. Use Reconnect when ready."
        case .focusTransient: return "Temporarily interrupted by another audio source."
        case .focusPermanent: return "Another app took over audio. Tap Play to resume."
        case .output: return "Stopped because the audio output was disconnected. Choose an output and reconnect."
        case .service: return "Playback stopped by iOS. Use Reconnect when ready."
        case .failure: return "Connection ended. Use Reconnect when ready."
        }
    }

    /// Wire label negotiated by `/offer` `session_lifecycle_version` (default 1 when absent or when no
    /// offer was received). `StopReason.wireFor`, `SessionLifecycle.kt:19-23`: version >= 2 sends
    /// `wire`; older hosts receive PAUSE as `user_stop` and both precise focus reasons as `focus_loss`.
    public func wire(forLifecycleVersion version: Int) -> String {
        if version >= 2 { return wire }
        switch self {
        case .pause: return StopReason.user.wire
        case .focusTransient, .focusPermanent: return StopReason.focus.wire
        default: return wire
        }
    }

    /// Mode-specific end message. Port of `StreamMode.endedMessage` (`StreamMode.kt:19-29`) with the iOS strings of
    /// (owner 07). `StreamMode.endedMessage(_:)` delegates here as `reason.endedMessage(microphone: microphone,
    /// reconnectAction: reconnectAction)`.
    ///
    /// Playback modes return `message`. Microphone/duplex modes map FOCUS, OUTPUT, SERVICE and FAILURE to
    /// a detail followed by `" Tap <reconnectAction> when ready."`; other reasons return `message`.
    public func endedMessage(microphone: Bool, reconnectAction: String) -> String {
        if !microphone { return message }
        let detail: String
        switch self {
        case .focus: detail = "Stopped after another app took audio."
        case .output: detail = "Stopped because the audio output was disconnected. Choose an output."
        case .service: detail = "Microphone session stopped by iOS."
        case .failure: detail = "Connection ended."
        default: return message
        }
        return "\(detail) Tap \(reconnectAction) when ready."
    }
}

/// Terminal result delivered exactly once by the session worker through `onEnded` (`SessionLifecycle.kt:26`). `message`
/// is `(failure ?? mode.endedMessage(reason)) + confirmation`; `diagnostics` is the final diagnostics text, if any.
public struct StreamEnd: Equatable, Sendable {
    public let reason: StopReason
    public let message: String
    public let diagnostics: String?

    public init(reason: StopReason, message: String, diagnostics: String? = nil) {
        self.reason = reason
        self.message = message
        self.diagnostics = diagnostics
    }
}
