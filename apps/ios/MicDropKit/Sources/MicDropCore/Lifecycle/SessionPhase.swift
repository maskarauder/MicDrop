// Session lifecycle phase. Port of `SessionLifecycle.kt:3-7`. Not a wire value: raw values are the Swift case names and
// are never sent to the host.

/// Phase of a playback, microphone or duplex session as shown by the app and lock screen.
///
/// `label` is the status-card title (`MainActivity.kt:1311-1325`). The `interrupted` label is the iOS adaptation from
/// ("audio focus" is an Android term). The `routeRecovering` label is route-neutral on iOS: besides headset-microphone
/// recovery (Android's only use, "Restoring selected headset"), it covers the selected Bluetooth output (car audio,
/// hearing aids), the iPhone-speaker repair and default-route probing (`SessionPhase.heartbeat`).
public enum SessionPhase: String, CaseIterable, Sendable {
    case idle
    case connecting
    case playing
    case recovering
    case routeRecovering
    case pausing
    case paused
    case interrupted
    case switching
    case stopping
    case ended

    /// Status title (`SessionLifecycle.kt:3-7`; `interrupted` per, `routeRecovering` route-neutral).
    public var label: String {
        switch self {
        case .idle: return "Ready"
        case .connecting: return "Connecting"
        case .playing: return "Playing"
        case .recovering: return "Recovering connection"
        case .routeRecovering: return "Restoring selected audio device"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .interrupted: return "Waiting for interruption to end"
        case .switching: return "Changing audio device"
        case .stopping: return "Stopping"
        case .ended: return "Stopped"
        }
    }
}
