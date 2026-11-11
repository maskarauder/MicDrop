import Foundation

/// Why desktop playback is temporarily held (`DefaultOutputPolicy.kt:3-10`).
///
/// `rawValue` is the wire label (`output_control.pause`; Go allows
/// `none|route|bluetooth|unavailable|selected_bluetooth|focus|focus_manual`, nil = `none`). `detail` is user-visible
/// (status card, Now Playing artist line) in the iOS wording of /; the UI shows it through
/// `SessionView.outputPauseDetail`, which adds the session's selected-Bluetooth window
/// (`detail(bluetoothRecoveryMs:)`).
public enum OutputPause: String, CaseIterable, Sendable {
    case route = "route"
    case bluetooth = "bluetooth"
    case unavailable = "unavailable"
    case selectedBluetooth = "selected_bluetooth"
    /// Kept as pure code; never driven on iOS.
    case focus = "focus"
    /// Kept as pure code; never driven on iOS.
    case focusManual = "focus_manual"

    public var detail: String {
        switch self {
        case .route:
            return "Playback paused while iOS changes the media output."
        case .bluetooth:
            return "Playback paused to avoid the iPhone speaker. "
                + "Connect a Bluetooth output, or choose iPhone speaker explicitly."
        case .unavailable:
            return "Playback paused because iOS audio output is unavailable. Reconnect an output or choose it again."
        case .selectedBluetooth:
            // The window is configurable (Advanced); `detail(bluetoothRecoveryMs:)` names the session's value.
            return "Playback paused while waiting for the selected Bluetooth output to return."
        case .focus:
            return "Playback paused for another app. The microphone keeps its current setting."
        case .focusManual:
            return "Playback paused after another app interrupted audio. "
                + "Toggle Play desktop audio off and on to resume."
        }
    }

    /// `detail` with the session's effective selected-Bluetooth window (status and copy report), e.g.
    /// `Playback paused while waiting for the selected Bluetooth output to return (up to 20 seconds).`; the other
    /// pauses are unchanged.
    public func detail(bluetoothRecoveryMs: Int64) -> String {
        guard self == .selectedBluetooth else { return detail }
        return "Playback paused while waiting for the selected Bluetooth output to return "
            + "(up to \(AdvancedAudioPreferences.seconds(bluetoothRecoveryMs)) seconds)."
    }

    /// Wire label; same as `rawValue`.
    public var wireLabel: String { rawValue }

    /// `pause?.name?.lowercase() ?? "none"` (`StreamReceiver.kt:1172`).
    public static func wire(_ pause: OutputPause?) -> String { pause?.rawValue ?? "none" }

    /// Current pause (`outputPauseLocked`, `StreamReceiver.kt:172-175`), evaluated under the audio lock: nil unless the
    /// session uses media output; else the focus pause, else (recovering: Bluetooth pin -> `.selectedBluetooth`, other
    /// -> `.route`), else the default policy's pause explained by the Bluetooth inventory.
    public static func current(
        usesMediaOutput: Bool, focus: OutputPause?, route: OutputRouteChange,
        policy: DefaultOutputPolicy, bluetoothAvailable: Bool
    ) -> OutputPause? {
        guard usesMediaOutput else { return nil }
        if let focus { return focus }
        if route.recovering { return route.selection.kind.isBluetooth ? .selectedBluetooth : .route }
        return policy.pauseForInventory(bluetoothAvailable: bluetoothAvailable)
    }
}
