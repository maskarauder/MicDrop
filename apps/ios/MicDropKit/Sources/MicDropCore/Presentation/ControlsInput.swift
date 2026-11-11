import Foundation

/// Everything `ControlsDeriver.derive` reads (`MainActivity.kt:1149-1293`).
///
/// The view model builds one per render, **after** its two pre-derive side effects: refreshing `selectedOutput` when no
/// session is retained and `selectedMicrophone` when no microphone session owns the input, and reloading preferences.
/// Android's `pendingOutputPermission` (Nearby-devices output consent) does not exist on iOS and is omitted; every rule
/// that mentions it evaluates as if it were false. `Equatable` so a caller can skip a derive whose input did not
/// change.
public struct ControlsInput: Equatable {
    /// The subset of `SavedConnectionView` (01, app target) the rules read. The app maps its view into this
    /// value because `SavedConnectionView` lives in the app module. Defaults equal `SavedConnectionView()`.
    public struct SavedState: Equatable, Sendable {
        public var message: String
        public var available: Bool
        public var present: Bool
        public var working: Bool
        public var pairing: Bool
        public var paired: Bool

        public init(
            message: String = "Loading saved connection…", available: Bool = false, present: Bool = false,
            working: Bool = true, pairing: Bool = false, paired: Bool = false
        ) {
            self.message = message
            self.available = available
            self.present = present
            self.working = working
            self.pairing = pairing
            self.paired = paired
        }
    }

    /// Freshly loaded preferences (`MainActivity.kt:1153`).
    public var prefs: AudioPreferences
    /// Playback controller view.
    public var session: SessionView
    /// Microphone/duplex controller view.
    public var mic: MicrophoneView
    /// Local output probe running (`localProbe != null`).
    public var localProbeRunning: Bool
    /// `pendingMicrophoneText != nil`.
    public var pendingMicrophone: Bool
    /// `pendingInputChoice != nil`.
    public var pendingInputChoice: Bool
    public var pendingConnect: Bool
    /// `PairingConnectIntent.pending`.
    public var pairingIntentPending: Bool
    /// Android "playback service bound"; always true on iOS (in-process controllers).
    public var playbackAvailable: Bool
    /// Android "microphone service bound"; always true on iOS.
    public var microphoneAvailable: Bool
    public var saved: SavedState
    /// The saved connection parsed when the discovery view was last rendered (`MainActivity.kt:1010`); used only for
    /// discovered-row labels.
    public var savedLink: ConnectionLink?
    public var showingMicrophone: Bool
    public var selectedOutput: OutputSelection
    public var selectedMicrophone: MicrophoneSelection
    /// Trimmed invitation field text.
    public var entered: String
    public var latestDiagnostics: String?
    public var idleMessage: String?
    /// `OutputRouteProviding.choices()`; nil if listing threw.
    public var outputChoices: [OutputChoice]?
    /// `MicrophoneRouteProviding.choices()`; nil if listing threw.
    public var inputChoices: [MicrophoneChoice]?
    /// `outputs.available(selectedOutput)`.
    public var outputAvailable: Bool
    /// `inputs.available(selection)`.
    public var inputAvailable: Bool
    public var discovery: DiscoveryView
    /// `BuildInfo.current.revision` (11).
    public var revision: String
    /// `BuildInfo.current.versionName` (11): the Diagnostics summary (`BuildConfig.VERSION_NAME`,
    /// `MainActivity.kt:1390`).
    public var versionName: String
    /// The saved connection preferences' `.recovery` value in milliseconds: the Advanced summary
    /// (`AppConnectionSettings.load(this)[ConnectionTimeout.RECOVERY]`, `MainActivity.kt:1388-1389`). The default is
    /// `ConnectionPreferences()[.recovery]`.
    public var recoveryWindowMs: Int
    /// `Int((AVAudioSession.outputVolume * 100).rounded())`; nil when it could not be read
    /// (label falls back to `Playback volume` and the slider is disabled, `MainActivity.kt:1300`).
    public var volumePercent: Int?
    /// `MicrophoneRouteProviding.processingCapabilities.echoCancellation`.
    public var echoCancellationSupported: Bool
    /// `MicrophoneRouteProviding.processingCapabilities.noiseReduction`.
    public var noiseReductionSupported: Bool
    /// iOS-only: the most recent failure was a denied permission (microphone, camera) or a Local Network block, so the
    /// status card shows `Open Settings`.
    public var settingsLinkSuggested: Bool
    /// The crash report is being built off the main thread (button disabled).
    public var crashReportBuilding: Bool

    public init(
        prefs: AudioPreferences = AudioPreferences(),
        session: SessionView = SessionView(),
        mic: MicrophoneView = MicrophoneView(),
        localProbeRunning: Bool = false,
        pendingMicrophone: Bool = false,
        pendingInputChoice: Bool = false,
        pendingConnect: Bool = false,
        pairingIntentPending: Bool = false,
        playbackAvailable: Bool = true,
        microphoneAvailable: Bool = true,
        saved: SavedState = SavedState(),
        savedLink: ConnectionLink? = nil,
        showingMicrophone: Bool = false,
        selectedOutput: OutputSelection = OutputSelection(),
        selectedMicrophone: MicrophoneSelection = MicrophoneSelection(),
        entered: String = "",
        latestDiagnostics: String? = nil,
        idleMessage: String? = nil,
        outputChoices: [OutputChoice]? = [],
        inputChoices: [MicrophoneChoice]? = [],
        outputAvailable: Bool = true,
        inputAvailable: Bool = true,
        discovery: DiscoveryView = DiscoveryView(),
        revision: String = "local",
        versionName: String = BuildInfo.fallbackVersionName,
        recoveryWindowMs: Int = 30_000,
        volumePercent: Int? = nil,
        echoCancellationSupported: Bool = true,
        noiseReductionSupported: Bool = true,
        settingsLinkSuggested: Bool = false,
        crashReportBuilding: Bool = false
    ) {
        self.prefs = prefs
        self.session = session
        self.mic = mic
        self.localProbeRunning = localProbeRunning
        self.pendingMicrophone = pendingMicrophone
        self.pendingInputChoice = pendingInputChoice
        self.pendingConnect = pendingConnect
        self.pairingIntentPending = pairingIntentPending
        self.playbackAvailable = playbackAvailable
        self.microphoneAvailable = microphoneAvailable
        self.saved = saved
        self.savedLink = savedLink
        self.showingMicrophone = showingMicrophone
        self.selectedOutput = selectedOutput
        self.selectedMicrophone = selectedMicrophone
        self.entered = entered
        self.latestDiagnostics = latestDiagnostics
        self.idleMessage = idleMessage
        self.outputChoices = outputChoices
        self.inputChoices = inputChoices
        self.outputAvailable = outputAvailable
        self.inputAvailable = inputAvailable
        self.discovery = discovery
        self.revision = revision
        self.versionName = versionName
        self.recoveryWindowMs = recoveryWindowMs
        self.volumePercent = volumePercent
        self.echoCancellationSupported = echoCancellationSupported
        self.noiseReductionSupported = noiseReductionSupported
        self.settingsLinkSuggested = settingsLinkSuggested
        self.crashReportBuilding = crashReportBuilding
    }

    // MARK: Core derived values (`MainActivity.kt:1154-1174`)

    /// A local diagnostic tool owns audio; the output probe is the only one since Android removed the test tone
    /// (`localProbe != null`, `MainActivity.kt:1244`).
    public var local: Bool { localProbeRunning }

    /// `MainActivity.kt:1155-1156`.
    public var idle: Bool {
        !session.busy && !mic.ownsSession && !pendingMicrophone && !pendingInputChoice && !pendingConnect
            && !pairingIntentPending && !local && playbackAvailable && !saved.working
    }

    /// `MainActivity.kt:1157`.
    public var setupPending: Bool {
        pendingInputChoice || pendingMicrophone || pendingConnect || pairingIntentPending
    }

    /// The input the rules describe: the live session's input while a microphone session owns it.
    public var selection: MicrophoneSelection { mic.ownsSession ? mic.input : selectedMicrophone }

    /// `MainActivity.kt:1165`.
    public var inputNeedsSelection: Bool { !mic.ownsSession && prefs.needsInputSelection(selection) }

    /// The session view shown in the status card (`MainActivity.kt:1166`).
    public var current: SessionView { (mic.ownsSession || showingMicrophone) ? mic.session : session }

    /// Mode of the session that owns audio, or nil when idle (`MainActivity.kt:1167-1171`).
    public var mode: StreamMode? {
        if mic.ownsSession { return mic.mode }
        return session.retained ? StreamMode.playback : nil
    }

    /// `prefs.needsOutputSelection(selectedOutput)` (`MainActivity.kt:1196`).
    public var outputNeedsSelection: Bool { prefs.needsOutputSelection(selectedOutput) }

    /// Android voice-call volume stream selection (`MainActivity.kt:1172-1174`); on iOS it only picks the
    /// `Headset voice volume` label. Reads `mic.session` even when the microphone view is not shown, like Android.
    public var volumeUsesVoiceStream: Bool {
        mic.session.active && mic.session.phase != .pausing && selection.kind.isBluetooth
    }
}
