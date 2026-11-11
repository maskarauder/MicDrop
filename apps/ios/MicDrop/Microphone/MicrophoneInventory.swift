import Foundation
import MicDropCore

/// Microphone selector and availability (`A/MicrophoneRouting.kt:236-268` companion), the UI's
/// `MicrophoneRouteProviding` (`refresh(_:)` has no `revealAddress`).
///
/// iOS port lists come from `AVAudioSession.availableInputs`, which depends on the current category: HFP inputs appear
/// only with `.playAndRecord` + `.allowBluetooth`. Rules:
/// - idle (no session retained): read inputs under the arbiter's temporary inventory category
/// `.playAndRecord` + `[.allowBluetooth, .allowBluetoothA2DP]` without activation, so Bluetooth headsets are listed;
/// - during a Bluetooth microphone session: everything in `availableInputs`;
/// - during any other retained session (a non-Bluetooth microphone session or a playback session,
///   Paused included): built-in/wired/USB only, because changing options would reroute live audio. The
///   dialog then carries the footer `MicrophoneChoice.bluetoothUnavailableFooter`, derived by
///   `ControlsDeriver` from the same rule.
/// A Bluetooth selection that cannot be inspected is `.unknown` (shown without "(unavailable)"); the
/// authoritative check is the session preflight / `MicrophoneRouting.prepare`.
@MainActor
final class MicrophoneInventory {
    /// Result of an availability query.
    enum Availability: Equatable, Sendable {
        case available
        case unavailable
        /// Bluetooth selection while HFP inputs cannot be listed (category lacks `.allowBluetooth`).
        case unknown
    }

    /// `choices()` could not list inputs (`iOS could not list microphone inputs. …`).
    struct ListingFailed: Error, Equatable, Sendable {}

    /// What the selector knows about the retained session (set by the composition root from the
    /// controllers; the default is idle).
    struct SessionState: Equatable, Sendable {
        /// Any playback or microphone session is retained (busy or PAUSED).
        var retained: Bool
        /// The retained microphone/duplex session's input, nil for none or a playback session.
        var microphoneInput: MicrophoneSelection?

        init(retained: Bool = false, microphoneInput: MicrophoneSelection? = nil) {
            self.retained = retained
            self.microphoneInput = microphoneInput
        }

        /// Idle: nothing retained.
        static let idle = SessionState()
    }

    /// Port sources (`MicrophoneInventory.live(arbiter:)` in production; fakes in tests).
    struct Sources {
        /// `availableInputs` under the current category; nil when the query failed.
        var currentInputs: @MainActor () -> [AudioPortDescriptor]?
        /// Whether the current category exposes HFP inputs (`.allowBluetooth` set).
        var currentCategoryListsBluetooth: @MainActor () -> Bool
        /// `availableInputs` under the arbiter's temporary inventory category; nil when the arbiter
        /// refused (session retained / local tool running) or the query failed.
        var idleInputs: @MainActor () -> [AudioPortDescriptor]?

        init(
            currentInputs: @escaping @MainActor () -> [AudioPortDescriptor]?,
            currentCategoryListsBluetooth: @escaping @MainActor () -> Bool,
            idleInputs: @escaping @MainActor () -> [AudioPortDescriptor]?
        ) {
            self.currentInputs = currentInputs
            self.currentCategoryListsBluetooth = currentCategoryListsBluetooth
            self.idleInputs = idleInputs
        }
    }

    private let sources: Sources
    /// Retained-session probe (set after both controllers exist; circular otherwise).
    var sessionState: @MainActor () -> SessionState = { .idle }

    init(sources: Sources) {
        self.sources = sources
    }

    // MARK: - MicrophoneRouteProviding

    /// `choices(context)` (`A/MicrophoneRouting.kt:249-268`): `MicrophoneChoice.list(ports:includeBluetooth:)`
    /// over the inputs of `currentListing()`. Throws `ListingFailed` when no list could be read.
    func choices() throws -> [MicrophoneChoice] {
        guard let listing = currentListing() else { throw ListingFailed() }
        return MicrophoneChoice.list(ports: listing.inputs, includeBluetooth: listing.bluetoothVisible)
    }

    /// `refresh(sel)` = Bluetooth ? `sel.refreshBluetooth(inputs)` : (`available(sel)` ? sel : nil)
    /// (`A/MicrophoneRouting.kt:241-248`); a Bluetooth selection that cannot be inspected is returned
    /// unchanged (`.unknown`, preflight verifies). Errors → nil.
    func refresh(_ selection: MicrophoneSelection) -> MicrophoneSelection? {
        let listing = currentListing()
        return MicrophoneInventory.refresh(
            selection, inputs: listing?.inputs,
            bluetoothVisible: listing?.bluetoothVisible ?? false)
    }

    /// `available(sel)` (`A/MicrophoneRouting.kt:236-240`): `availability(sel) != .unavailable`.
    func available(_ selection: MicrophoneSelection) -> Bool {
        availability(selection) != .unavailable
    }

    /// Tri-state availability (see type comment).
    func availability(_ selection: MicrophoneSelection) -> Availability {
        let listing = currentListing()
        return MicrophoneInventory.availability(
            selection, inputs: listing?.inputs,
            bluetoothVisible: listing?.bluetoothVisible ?? false)
    }

    /// iOS processing support for the UI toggles: echo cancellation exists through VoiceProcessingIO, noise reduction
    /// through WebRTC software NS.
    var processingCapabilities: (echoCancellation: Bool, noiseReduction: Bool) { (true, true) }

    /// Inputs of a running session for the phone settings snapshot (`audio.input`, D046): the selector rows
    /// and the tri-state availability over the same list.
    struct SessionChoices: Equatable, Sendable {
        let choices: [MicrophoneChoice]
        /// The listed ports; nil when the query failed.
        let inputs: [AudioPortDescriptor]?
        let bluetoothVisible: Bool

        /// `MicrophoneInventory.availability` over this listing.
        func availability(_ selection: MicrophoneSelection) -> Availability {
            MicrophoneInventory.availability(selection, inputs: inputs, bluetoothVisible: bluetoothVisible)
        }
    }

    /// Read-only listing for phone settings snapshots (`A/AppPhoneControl.kt:105`): the retained-session branch
    /// of `currentListing()`, i.e. `currentInputs()` with HFP inputs only in a Bluetooth microphone session whose
    /// category lists them. It never reads `idleInputs()`, which switches the audio session to the temporary
    /// inventory category, so a snapshot every few seconds cannot reroute or glitch live audio. A failed query
    /// (also a category that lists no inputs) keeps only the always-present built-in row, and every other input is
    /// then unavailable.
    func sessionChoices() -> SessionChoices {
        guard let inputs = sources.currentInputs() else {
            let builtIn = MicrophoneChoice.list(ports: [], includeBluetooth: false)
            return SessionChoices(choices: builtIn, inputs: nil, bluetoothVisible: false)
        }
        let bluetoothVisible =
            sessionState().microphoneInput?.isBluetooth == true && sources.currentCategoryListsBluetooth()
        return SessionChoices(
            choices: MicrophoneChoice.list(ports: inputs, includeBluetooth: bluetoothVisible), inputs: inputs,
            bluetoothVisible: bluetoothVisible)
    }

    /// The input list for the current situation and whether HFP inputs are part of it:
    /// idle → `idleInputs()` (Bluetooth visible) falling back to `currentInputs()`; retained Bluetooth
    /// microphone session → current inputs, Bluetooth visible; any other retained session → current
    /// inputs, Bluetooth hidden. Nil when no list could be read.
    func currentListing() -> (inputs: [AudioPortDescriptor], bluetoothVisible: Bool)? {
        let state = sessionState()
        if !state.retained, let inputs = sources.idleInputs() {
            return (inputs, true)
        }
        guard let inputs = sources.currentInputs() else { return nil }
        if !state.retained || state.microphoneInput?.isBluetooth == true {
            return (inputs, sources.currentCategoryListsBluetooth())
        }
        return (inputs, false)
    }

    // MARK: - Pure rules (testable without AVFoundation)

    /// `available(sel)` over a port list: Bluetooth → `refreshBluetooth(inputs) != nil` when visible,
    /// `.unknown` when hidden; others → `resolveInput(inputs) != nil`. A nil list (query failure) is
    /// `.unavailable` (Android "errors → false").
    nonisolated static func availability(
        _ selection: MicrophoneSelection, inputs: [AudioPortDescriptor]?,
        bluetoothVisible: Bool
    ) -> Availability {
        guard let inputs else { return .unavailable }
        if selection.isBluetooth {
            guard bluetoothVisible else { return .unknown }
            return selection.refreshBluetooth(inputs) != nil ? .available : .unavailable
        }
        return selection.resolveInput(inputs) != nil ? .available : .unavailable
    }

    /// `refresh(sel)` over a port list (see `refresh(_:)`).
    nonisolated static func refresh(
        _ selection: MicrophoneSelection, inputs: [AudioPortDescriptor]?,
        bluetoothVisible: Bool
    ) -> MicrophoneSelection? {
        guard let inputs else { return nil }
        if selection.isBluetooth {
            guard bluetoothVisible else { return selection }
            return selection.refreshBluetooth(inputs)
        }
        return selection.resolveInput(inputs) != nil ? selection : nil
    }
}
