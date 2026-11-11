import Foundation
import MicDropCore

/// Output-route provider consumed by the UI and the session controllers (no `revealAddress`; the provider computes
/// `speakerPinnable` itself).
@MainActor
protocol OutputRouteProviding {
    /// The output menu (the UI renders whatever this returns).
    func choices() throws -> [OutputChoice]
    /// `OutputDevices.refresh`: the selection if it is still available now, else nil (→ `output_reselect` /
    /// `output_change_unavailable`).
    func refresh(_ s: OutputSelection) -> OutputSelection?
    /// `OutputDevices.available` (`OutputDevices.kt:37-38`): `!explicit || refresh(s) != nil`.
    func available(_ s: OutputSelection) -> Bool
}

/// iOS output choices over the current audio route.
///
/// iOS cannot enumerate inactive devices: choices are `iPhone media output`, `iPhone speaker 1` (when the speaker can
/// be pinned or already is the route) and the external outputs currently in the route with a non-empty uid (guarded
/// pins). The system route picker is a separate UI element (`SystemRoutePickerView`), never a choice.
///
/// `speakerPinnable` comes from the audio-session plan that applies — the live session's plan from
/// `AudioSessionArbiter`, or the plan the next Connect would use when idle — and the selected input, supplied by the
/// composition root through `pinContext`.
@MainActor
final class OutputChoices: OutputRouteProviding {

    /// Inputs of the `speakerPinnable` rule.
    struct PinContext: Equatable, Sendable {
        /// The plan of the live session (arbiter) or of the next Connect (`AudioSessionPlan.make`);
        /// nil when unknown (then the speaker is pinnable only while it already is the route).
        var plan: AudioSessionPlan?
        /// The session's / next session's microphone kind; ignored for playback-only plans.
        var input: MicrophoneKind?
    }

    private let inspector: AudioRouteInspecting
    private let pinContext: @MainActor () -> PinContext

    init(inspector: AudioRouteInspecting, pinContext: @escaping @MainActor () -> PinContext) {
        self.inspector = inspector
        self.pinContext = pinContext
    }

    /// The permanent iPhone-speaker pin can force the speaker now.
    var speakerPinnable: Bool {
        OutputChoices.speakerPinnable(context: pinContext())
    }

    func choices() -> [OutputChoice] {
        OutputChoices.current(inspector: inspector, speakerPinnable: speakerPinnable)
    }

    func refresh(_ s: OutputSelection) -> OutputSelection? {
        s.refresh(inspector.currentRouteOutputs(), speakerPinnable: speakerPinnable)
    }

    func available(_ s: OutputSelection) -> Bool {
        s.available(in: inspector.currentRouteOutputs(), speakerPinnable: speakerPinnable)
    }

    // MARK: - Pure rules (testable without a session)

    /// `speakerPinnable`: the plan's category allows `overrideOutputAudioPort(.speaker)` (`.playAndRecord`) and, for
    /// plans that capture, the input is the built-in microphone (iOS forces the built-in microphone with the speaker
    /// override, so a wired/USB headset microphone forbids the permanent pin; a Bluetooth HFP input does not use the
    /// media output at all). With the `.playback` row this is always false.
    nonisolated static func speakerPinnable(context: PinContext) -> Bool {
        guard let plan = context.plan, plan.supportsSpeakerOverride else { return false }
        if case .some(.playback) = plan.streamMode { return true }
        return context.input == .builtIn
    }

    /// Choice list for the current route (`OutputChoices.current`), via `OutputChoice.list(route:speakerPinnable:)`.
    nonisolated static func current(inspector: AudioRouteInspecting, speakerPinnable: Bool) -> [OutputChoice] {
        OutputChoice.list(
            route: inspector.currentOutputs().map { (output: $0.output, name: $0.name) },
            speakerPinnable: speakerPinnable)
    }
}
