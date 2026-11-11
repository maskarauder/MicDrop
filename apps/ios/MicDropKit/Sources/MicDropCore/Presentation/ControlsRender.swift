import Foundation

/// Every text, check, enabled and visible value of the main screen, produced by `ControlsDeriver.derive`. Defaults are
/// neutral placeholders; `derive` assigns every field.
public struct ControlsRender: Equatable, Sendable {
    /// The status-card output action (`MainActivity.kt:882-893`).
    public enum OutputAction: Equatable, Sendable {
        /// `applyOutputChoice(.fallbackSpeaker())`.
        case usePhoneSpeaker
        /// `applyOutputChoice(OutputSelection())`.
        case followSystemOutput
    }

    /// One discovered-host button (row 8).
    public struct DiscoveryRow: Equatable, Sendable, Identifiable {
        public let host: DiscoveredHost
        public let label: String
        /// `host.matches(saved)`: tapping shows "Connect to saved Windows?" instead of "Pair with Windows first".
        public let savedCandidate: Bool
        public let enabled: Bool
        public var id: DiscoveredHost { host }

        public init(host: DiscoveredHost, label: String, savedCandidate: Bool, enabled: Bool) {
            self.host = host
            self.label = label
            self.savedCandidate = savedCandidate
            self.enabled = enabled
        }
    }

    // MARK: Core
    public var idle = false
    public var setupPending = false

    // MARK: Status card
    public var statusTitle = Strings.statusReady
    public var statusText = ""
    public var outputActionVisible = false
    public var outputActionEnabled = false
    public var outputActionLabel = Strings.usePhoneSpeaker
    public var outputAction: OutputAction? = nil
    /// iOS-only `Open Settings` link in the status card.
    public var openSettingsVisible = false

    // MARK: Action bar
    public var connectEnabled = false
    public var connectLabel = Strings.connect
    /// Connect resumes a paused duplex session (`microphone.resume()`),.
    public var resumeDuplex = false
    public var stopEnabled = false
    public var pauseVisible = false
    public var pauseEnabled = false
    public var pauseLabel = Strings.pause

    // MARK: Connection setup section
    public var connectionSummary = ""
    /// `saved.message` shown as the section's first text.
    public var savedMessage = ""
    public var invitationEnabled = false
    public var scanEnabled = false
    public var discoveryEnabled = false
    public var discoveryButtonLabel = Strings.findWindows
    public var discoveryStatus = ""
    /// iOS-only `Open Settings` link under the discovery status (`DiscoveryView.localNetworkBlocked`).
    public var discoverySettingsVisible = false
    public var discoveryRows: [DiscoveryRow] = []
    public var cancelPairingVisible = false
    public var cancelPairingEnabled = false
    public var addressVisible = false
    public var addressEnabled = false
    public var forgetEnabled = false

    // MARK: Audio output section
    public var outputSummary = ""
    public var outputChecked = false
    public var outputToggleLabel = Strings.enableAudio
    /// Toggle accessibility value: `Audio on` / `Audio silenced` / `Audio paused`.
    public var outputStateText = Strings.audioOn
    public var outputToggleEnabled = false
    public var outputHelp = ""
    public var outputNeedsSelection = false
    public var outputDeviceEnabled = false
    public var outputDeviceLabel = Strings.chooseOutput
    public var volumeEnabled = false
    public var volumeLabel = Strings.playbackVolume
    /// `AVRoutePickerView` row enabled (D042): while following the system route wherever the output menu is, while no
    /// session is retained with a pinned output, and never during a Bluetooth headset microphone session. The picker
    /// never changes the selection or the remembered device.
    public var systemOutputPickerEnabled = false
    /// With a pinned output: `Strings.routePickerPinnedCaption` while a session (Paused included) or setup
    /// disables the picker, else `Strings.routePickerIdlePinCaption` or, when the pin is not the route,
    /// `Strings.routePickerUnavailablePinCaption`. `Strings.routePickerHeadsetCaption` during a Bluetooth headset
    /// microphone session. Nil while following the system route.
    public var systemOutputPickerCaption: String? = nil
    /// Message of the media output dialog: `Strings.outputDialogMessage`, plus `"\n\n"` and the picker caption
    /// while the picker is disabled with one (the explicit Stop step).
    public var outputDialogMessage = Strings.outputDialogMessage

    // MARK: Microphone section
    public var microphoneSummary = ""
    public var micChecked = false
    public var micToggleEnabled = false
    public var micToggleHelp = ""
    public var inputButtonEnabled = false
    public var inputButtonLabel = Strings.microphoneInput
    public var inputHelp = ""
    /// Message of the microphone input dialog.
    public var inputDialogMessage = Strings.microphoneDialogMessage
    public var leStereoVisible = false
    public var leStereoEnabled = false
    public var leStereoChecked = false
    public var echoChecked = false
    public var echoEnabled = false
    public var noiseChecked = false
    public var noiseEnabled = false
    public var processingHelp = ""

    // MARK: Advanced section (`MainActivity.kt:499-511`)
    /// `Strings.advancedSummary` of the saved recovery window (`MainActivity.kt:1388-1389`).
    public var advancedSummary = ""
    public var fastRecoveryChecked = false
    public var fastRecoveryEnabled = false

    // MARK: Diagnostics section (`MainActivity.kt:512-519`)
    /// `Strings.diagnosticsSummary` of the app version (`MainActivity.kt:1390`).
    public var diagnosticsSummary = ""
    public var buildLabel = ""
    public var copyEnabled = false
    public var copyCrashEnabled = true
    public var localTestEnabled = false
    /// Play click is enabled only while the local output probe runs (`MainActivity.kt:1367`).
    public var clickEnabled = false
    /// Play click is shown only while the local output probe runs; same value as `clickEnabled`
    /// (`clickButton.visibility`, `MainActivity.kt:1368`).
    public var clickVisible = false
    public var diagnosticsText = Strings.noReport

    public init() {}
}
