import Foundation

/// Microphone permission rules (`A/MicrophonePermissions.kt`).
///
/// iOS requires only the record permission for every input kind: there is no
/// `BLUETOOTH_CONNECT` analog (`BLUETOOTH_PERMISSION` is never raised) and no notification
/// permission. The app maps `AVAudioApplication.shared.recordPermission` to `Status`
/// (`SystemMicrophonePermission`, app target).
public enum MicrophonePermissions {
    /// `AVAudioApplication.recordPermission` (`.undetermined/.denied/.granted`).
    public enum Status: String, CaseIterable, Sendable {
        case undetermined
        case denied
        case granted
    }

    /// iOS denial text: Android's text plus the Settings pointer, because iOS cannot re-prompt after a denial.
    public static let deniedText =
        "Microphone permission was denied. Desktop playback still works without it. Allow microphone access for MicDrop in Settings, then tap Connect."

    /// `denial(kind, granted)` (`A/MicrophonePermissions.kt:10-16`): `nil` iff the record permission is granted.
    /// `.undetermined` counts as not granted (Android evaluates `denial` after the request result; the iOS flow
    /// requests first, and a background re-check never prompts). `kind` is kept for parity: every iOS kind needs only
    /// the microphone permission.
    public static func denial(kind: MicrophoneKind, status: Status) -> String? {
        status == .granted ? nil : deniedText
    }

    /// `missing(kind, granted)` reduced to iOS: whether the system prompt must be shown
    /// (only from an explicit, foreground-active Connect or input change).
    public static func needsRequest(_ status: Status) -> Bool { status == .undetermined }

    /// Runtime evidence `microphone_permission` = `status == .granted`.
    public static func isGranted(_ status: Status) -> Bool { status == .granted }
}

/// name for `MicrophonePermissions.Status`.
public typealias MicrophonePermissionStatus = MicrophonePermissions.Status
