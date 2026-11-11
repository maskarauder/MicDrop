// App entry and composition root.
//
// Launch order (before the first run-loop turn): process audio hygiene (`AppLifecycle.prepareProcess`),
// crash capture (`CrashDiagnostics.install`), the controllers, the coordinator and its remote-command
// targets (`AppLifecycle.start`), then the main screen model. No connection, discovery, camera,
// microphone or Local Network access is started at launch.

import MicDropCore
import MicDropIdentity
import MicDropTransport
import SwiftUI

@main
struct MicDropApp: App {
    private let environment: AppEnvironment

    init() {
        environment = AppEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(environment: environment)
        }
    }
}

/// Forwards the scene phase to the lifecycle owner (deadline checks); `MainView` forwards it to the view model (UI flow
/// rules). The dark slate/gold palette applies in both system appearances (`Theme`), so the window keeps the dark
/// appearance and its alerts, dialogs, sheets and keyboard match (Android `windowLightStatusBar` false; Info.plist
/// `UIUserInterfaceStyle` covers launch).
private struct AppRootView: View {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MainView(model: environment.mainViewModel)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase, initial: true) { _, phase in
                environment.lifecycle.scenePhaseChanged(phase)
            }
    }
}

/// Process-lifetime object graph (`AppEnvironment`).
@MainActor
final class AppEnvironment {
    let arbiter: AudioSessionArbiter
    let controlLog: ControlEventLog
    let outputs: OutputChoices
    let inventory: MicrophoneInventory
    let playback: PlaybackSessionController
    let microphone: MicrophoneSessionController
    let coordinator: SessionCoordinator
    let lifecycle: AppLifecycle
    let mainViewModel: MainViewModel

    init() {
        AppLifecycle.prepareProcess()
        CrashDiagnostics.install()

        let arbiter = AudioSessionArbiter.shared
        let clock = SystemMonotonicClock()
        let controlLog = ControlEventLog(clock: clock)
        let preferences = AudioPreferencesStore.shared
        let pins = OutputPinContextSource(arbiter: arbiter, preferences: preferences)
        let inspector = AudioRouteInspector(arbiter: arbiter)
        let outputs = OutputChoices(inspector: inspector, pinContext: { pins.context(input: nil) })
        let inventory = MicrophoneInventory.live(arbiter: arbiter)
        let phoneControl = AppEnvironment.phoneControlEnvironment(
            preferences: preferences, outputs: outputs, inventory: inventory)

        let playback = PlaybackSessionController(
            dependencies: PlaybackSessionController.Dependencies(
                arbiter: arbiter,
                preferences: preferences,
                pausedPlayback: PausedPlaybackStore.shared,
                controlLog: controlLog,
                clock: clock,
                makeReceiver: { configuration, callbacks in
                    SessionController(
                        configuration, callbacks: callbacks,
                        dependencies: try AppEnvironment.sessionDependencies(
                            for: configuration, phoneControl: phoneControl))
                },
                outputAvailable: { outputs.available($0) },
                outputRefresh: { outputs.refresh($0) },
                loadSavedLink: { try await SavedConnectionStore.shared.awaitLoaded(timeout: .seconds(10)) },
                rememberLink: { SavedConnectionStore.shared.remember($0) }))

        let microphone = MicrophoneSessionController(
            dependencies: .live(
                arbiter: arbiter,
                preferences: preferences,
                savedConnections: SavedConnectionStore.shared,
                inventory: inventory,
                outputAvailable: { selection, input in
                    OutputChoices(inspector: inspector, pinContext: { pins.context(input: input) }).available(selection)
                },
                refreshOutput: { selection, input in
                    OutputChoices(inspector: inspector, pinContext: { pins.context(input: input) }).refresh(selection)
                },
                sessionDependencies: { configuration in
                    try AppEnvironment.sessionDependencies(for: configuration, phoneControl: phoneControl)
                },
                clock: clock))
        pins.microphone = microphone
        inventory.sessionState = { [weak playback, weak microphone] in
            let microphoneOwns = microphone?.view.ownsSession ?? false
            return MicrophoneInventory.SessionState(
                retained: microphoneOwns || (playback?.view.retained ?? false),
                microphoneInput: microphoneOwns ? microphone?.view.input : nil)
        }

        let coordinator = SessionCoordinator(
            playback: playback, microphone: microphone,
            nowPlaying: NowPlayingPublisher(), commands: RemoteCommandRouter(),
            controlLog: controlLog)
        let lifecycle = AppLifecycle(arbiter: arbiter, coordinator: coordinator)
        lifecycle.start()

        self.arbiter = arbiter
        self.controlLog = controlLog
        self.outputs = outputs
        self.inventory = inventory
        self.playback = playback
        self.microphone = microphone
        self.coordinator = coordinator
        self.lifecycle = lifecycle
        self.mainViewModel = MainViewModel(
            dependencies: .live(
                playback: playback, microphone: microphone,
                outputs: outputs, inputs: inventory,
                arbiter: arbiter))
    }

    /// Per-session worker collaborators, built at Connect for the session's link.
    ///
    /// The phone identity is loaded lazily inside the TLS closures, i.e. on the session worker at stage PAIRING
    /// (`StreamReceiver.kt:369`), so an unreadable identity fails that stage before `/offer` instead of blocking
    /// Connect on the main actor (`CredentialVault.identity(for:)` is nonisolated and returns nil for v1/v2 links). The
    /// transport is LAN or remote by `link.remote` (`ControlTransportFactory`). The engine observes the single
    /// audio-event monitor. The worker reads the live Advanced keep-alive from its store (local Saves apply at once;
    /// Windows edits from the next microphone Connect). `phoneControl` lets a session whose controller passed a binding
    /// create its settings adapter.
    static func sessionDependencies(
        for configuration: SessionConfiguration, phoneControl: PhoneControlAdapter.Environment? = nil
    ) throws -> SessionDependencies {
        let link = configuration.link
        let vault = CredentialVault.shared
        let monitor = AudioSessionEventMonitor.shared
        return SessionDependencies(
            transport: ControlTransportFactory.make(
                for: link,
                connectTimeoutMs: configuration.connectionPreferences[
                    link.remote == nil ? .lanRequest : .remoteRequest],
                tls: {
                    try ControlTLS.setup(for: link, identity: try vault.identity(for: link))
                }),
            localTransport: { route in
                LanControlTransport(
                    link: link, connector: .transportServices(lanHooks: route.transportHooks),
                    connectTimeoutMs: configuration.connectionPreferences[.lanRequest],
                    tls: { try ControlTLS.setup(for: link, identity: try vault.identity(for: link)) })
            },
            localProbe: { route in
                LocalProbe(
                    link: link, connector: .transportServices(lanHooks: route.transportHooks),
                    tls: { try ControlTLS.setup(for: link, identity: try vault.identity(for: link)) })
            },
            tls: { target in try ControlTLS.setup(for: target, identity: try vault.identity(for: target)) },
            iceService: RemoteICEService.shared,
            engineFactory: { engineConfiguration, events, checkpoint in
                let engine = try MediaEngine(engineConfiguration, events: events, checkpoint: checkpoint)
                engine.observe(monitor)
                return engine
            },
            arbiter: AudioSessionArbiter.shared,
            owner: AudioSessionOwner.shared,
            clock: SystemMonotonicClock(),
            journalSave: { try StoredReports.saveStream($0) },
            runtime: { SessionRuntime() },
            keepMicrophoneActiveWhileMuted: { AppEnvironment.keepMicrophoneActiveWhileMuted() },
            phoneControl: phoneControl)
    }

    /// `SessionDependencies.keepMicrophoneActiveWhileMuted` of every production session: the store's live keep-alive
    /// (`liveKeepMicrophoneActive()`), never `load()`, which already holds a Windows edit saved for the next
    /// connection, so Windows cannot start a muted background capture in the running session. Any thread: the
    /// session worker reads it at each background or foreground step.
    nonisolated static func keepMicrophoneActiveWhileMuted(_ store: AdvancedAudioPreferencesStore = .shared) -> Bool {
        store.liveKeepMicrophoneActive()
    }

    /// Phone settings exchange v1 (D046): the shared preference stores, the phone-local opt-in and the read-only device
    /// lists of the running session (current inputs without the temporary inventory category, current-route outputs).
    /// Windows edits here are saved selections and next-connection preferences; none switches a live route, starts
    /// capture or changes consent. Saved selections bump the store's `selectionGeneration`, so the idle rows adopt them
    /// after the session; Advanced audio edits go through the next-connection latch (`saveForNextConnection`), so
    /// `audio.keep_microphone_active` never changes the running session. The one live route change, a Windows
    /// `audio.output` choice for a playback or duplex session, does not use this environment: it goes through the
    /// session controller's `setOutputSelection` (`PhoneControlBinding`).
    static func phoneControlEnvironment(
        preferences: AudioPreferencesStore, outputs: OutputChoices, inventory: MicrophoneInventory
    ) -> PhoneControlAdapter.Environment {
        let optIn = PhoneControlPreferenceStore.shared
        let connection = ConnectionPreferencesStore.shared
        let advanced = AdvancedAudioPreferencesStore.shared
        return PhoneControlAdapter.Environment(
            allowWindows: { optIn.allowWindows() },
            audio: { preferences.load() },
            updateAudio: { change in _ = preferences.update(change) },
            savedInput: { preferences.restoredMicrophoneSelection() },
            savedOutput: { preferences.restoredOutputSelection() },
            rememberInput: { preferences.saveInputForNextConnection($0) },
            rememberOutput: { preferences.saveOutputForNextConnection($0) },
            connection: { connection.load() },
            saveConnection: { try connection.save($0) },
            advanced: { advanced.load() },
            saveAdvanced: { try advanced.saveForNextConnection($0) },
            keepAliveForNextConnection: true,
            inputs: { inventory.sessionChoices() },
            outputs: { outputs.choices() },
            outputAvailable: { outputs.available($0) })
    }
}

/// Inputs of `OutputChoices.PinContext`: the live session's plan from the arbiter, else the plan the next Connect would
/// use, plus the microphone input it applies to.
@MainActor
private final class OutputPinContextSource {
    weak var microphone: MicrophoneSessionController?
    private let arbiter: AudioSessionArbiter
    private let preferences: AudioPreferencesStore

    init(arbiter: AudioSessionArbiter, preferences: AudioPreferencesStore) {
        self.arbiter = arbiter
        self.preferences = preferences
    }

    /// `input` overrides the microphone input (microphone preflight passes its selection).
    func context(input: MicrophoneSelection?) -> OutputChoices.PinContext {
        if let live = arbiter.currentPlan {
            let liveInput: MicrophoneKind?
            if let input {
                liveInput = input.kind
            } else if let microphone, microphone.view.ownsSession {
                liveInput = microphone.view.input.kind
            } else {
                liveInput = nil
            }
            return OutputChoices.PinContext(plan: live, input: liveInput)
        }
        let prefs = preferences.load()
        let kind = input?.kind ?? prefs.preferredInputKind ?? .builtIn
        let processing = MicrophoneProcessing(
            echoCancellation: prefs.echoCancellation,
            noiseReduction: prefs.noiseReduction)
        let plan = AudioSessionPlan.make(mode: prefs.connectionMode, input: kind, processing: processing)
        return OutputChoices.PinContext(plan: plan, input: kind)
    }
}
