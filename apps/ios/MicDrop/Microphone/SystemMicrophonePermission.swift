import AVFoundation
import Foundation
import MicDropCore

/// Record-permission source. The protocol lets controllers and the UI flow be tested with a fake; delegated its
/// declaration to this app-target owner (MicDropCore has no `async` members). iOS needs no Bluetooth or notification
/// permission.
protocol MicrophonePermissionProviding: Sendable {
    /// `AVAudioApplication.shared.recordPermission` mapped to the portable status.
    var status: MicrophonePermissions.Status { get }
    /// Shows the system prompt when undetermined; resolves `true` iff granted. Call only from an explicit,
    /// foreground-active Connect or input-change action; background resumes never prompt.
    func request() async -> Bool
}

/// `AVAudioApplication`-backed record permission (iOS 17; replaces Android `RECORD_AUDIO`,
/// `A/MicrophonePermissions.kt`). Stateless; safe from any thread.
///
/// Rules kept from `A/MicrophoneService.kt:109-136`: the controller re-checks `isGranted` at session start, at
/// automatic resume and at input switch; denial text is `MicrophonePermissions.denial(kind:status:)` (points to
/// Settings because iOS cannot re-prompt). Runtime evidence `microphone_permission` = `isGranted`.
struct SystemMicrophonePermission: MicrophonePermissionProviding {
    init() {}

    /// `.undetermined` / `.denied` / `.granted`; unknown future values map to `.denied` (fail closed).
    var status: MicrophonePermissions.Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .undetermined: return .undetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// `status == .granted`.
    var isGranted: Bool { status == .granted }

    /// `AVAudioApplication.requestRecordPermission()` (async, iOS 17).
    func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Completion form for the UI flow (step 5): the completion runs on the main actor.
    func request(completion: @escaping @MainActor (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
        }
    }

    /// Denial text for `kind` under the current status (`MicrophonePermissions.denial`), nil when granted.
    func denial(kind: MicrophoneKind) -> String? {
        MicrophonePermissions.denial(kind: kind, status: status)
    }
}
