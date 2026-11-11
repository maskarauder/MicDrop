// Published session view. Port of `SessionLifecycle.kt:28-46`.

/// Immutable-by-convention snapshot the controllers publish to the UI and Now Playing.
///
/// Field defaults follow Kotlin `SessionView`; `message` uses the iOS default of (the UI never shows it in the idle
/// state). `outputEnabled`, `outputSelection` and `outputPause` are overlaid by the owning controller in its
/// `shownView()` (`PlaybackService.kt:455-457`), and on iOS `bluetoothRecoveryMs`.
public struct SessionView: Equatable, Sendable {
    /// Default `message` (`SessionLifecycle.kt:29`, adapted for iOS).
    public static let readyMessage = "Ready. Choose your output in Control Center or with AirPlay."

    public var phase: SessionPhase
    public var message: String
    public var diagnostics: String?
    /// `"Windows: <host>:<port>"` once the link was parsed, else `""`.
    public var destination: String
    /// Session token of a session that ended with failure; the UI shows a one-shot notice when it changes.
    public var failureId: String?
    public var outputEnabled: Bool
    public var outputSelection: OutputSelection
    public var outputPause: OutputPause?
    /// Remote-mode network line (`"Network: Wi-Fi"`, …), else `""`.
    public var networkStatus: String
    /// iOS: the session's Bluetooth route recovery window (Advanced, `SessionConfiguration.bluetoothRecoveryMs`),
    /// set by the owning controller once it configured a session; nil before, and the pause text then names no time.
    public var bluetoothRecoveryMs: Int64?

    public init(
        phase: SessionPhase = .idle,
        message: String = SessionView.readyMessage,
        diagnostics: String? = nil,
        destination: String = "",
        failureId: String? = nil,
        outputEnabled: Bool = true,
        outputSelection: OutputSelection = OutputSelection(),
        outputPause: OutputPause? = nil,
        networkStatus: String = "",
        bluetoothRecoveryMs: Int64? = nil
    ) {
        self.phase = phase
        self.message = message
        self.diagnostics = diagnostics
        self.destination = destination
        self.failureId = failureId
        self.outputEnabled = outputEnabled
        self.outputSelection = outputSelection
        self.outputPause = outputPause
        self.networkStatus = networkStatus
        self.bluetoothRecoveryMs = bluetoothRecoveryMs
    }

    /// A worker owns or is finishing the session: CONNECTING, PLAYING, RECOVERING, ROUTE_RECOVERING,
    /// SWITCHING, PAUSING or STOPPING (`SessionLifecycle.kt:33-34`).
    public var active: Bool {
        switch phase {
        case .connecting, .playing, .recovering, .routeRecovering, .switching, .pausing, .stopping:
            return true
        case .idle, .paused, .interrupted, .ended:
            return false
        }
    }

    /// `active || phase == .interrupted` (`SessionLifecycle.kt:35`).
    public var busy: Bool { active || phase == .interrupted }

    /// `busy || phase == .paused` (`SessionLifecycle.kt:36`). A retained session keeps its token.
    public var retained: Bool { busy || phase == .paused }

    /// `retained && phase != .stopping` (`SessionLifecycle.kt:37`).
    public var canSetOutput: Bool { retained && phase != .stopping }

    /// `outputEnabled && outputPause != nil` (`SessionLifecycle.kt:38`).
    public var outputPaused: Bool { outputEnabled && outputPause != nil }

    /// The user-visible `outputPause` text (status card, output help, Now Playing): `OutputPause.detail`, with this
    /// session's selected-Bluetooth window when known (`detail(bluetoothRecoveryMs:)`, e.g. "(up to 7.5 seconds)").
    public var outputPauseDetail: String? {
        guard let outputPause else { return nil }
        guard let bluetoothRecoveryMs else { return outputPause.detail }
        return outputPause.detail(bluetoothRecoveryMs: bluetoothRecoveryMs)
    }

    /// Temporary speaker fallback is offered only on a live default-output session held for Bluetooth
    /// (`SessionLifecycle.kt:42-43`).
    public var canUsePhoneSpeaker: Bool {
        outputEnabled && !outputSelection.explicit && outputPause == .bluetooth
            && (phase == .playing || phase == .recovering)
    }

    /// Android `canFollowAndroidOutput` (`SessionLifecycle.kt:44-45`), iOS name.
    public var canFollowSystemOutput: Bool {
        outputEnabled && outputSelection.kind == .phone && (phase == .playing || phase == .recovering)
    }

    /// The worker publishes periodic diagnostics through `onStatus` with a `" snapshot:"` marker; the UI hides such
    /// messages from the status card (`MainActivity.kt:1330`).
    public var messageIsDiagnosticSnapshot: Bool { message.contains(" snapshot:") }
}
