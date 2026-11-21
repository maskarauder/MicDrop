// Deterministic App Store screenshot fixture (Debug builds only).
//
// Compiled out completely in Release / App Store / TestFlight builds (`#if DEBUG`). When launched on
// an iOS Simulator with `--micdrop-screenshot-scene <scene>` (or `MICDROP_SCREENSHOT_SCENE`), the app
// renders the real `MainView` + `MainViewModel` + `ControlsDeriver` over in-memory protocol fakes so
// captures never touch Keychain, AVAudioSession, Bonjour, camera, or microphone hardware.

#if DEBUG
    import Foundation
    import MicDropCore
    import Network
    import SwiftUI

    /// The four deterministic App Store screenshot scenes (matching Android Play Store scenes).
    enum ScreenshotScene: String, CaseIterable, Sendable {
        case connection = "connection"
        case connectedOutput = "connected_output"
        case microphone = "microphone"
        case diagnostics = "diagnostics"

        var expandedSection: SettingsSectionID {
            switch self {
            case .connection: return .connection
            case .connectedOutput: return .output
            case .microphone: return .microphone
            case .diagnostics: return .diagnostics
            }
        }
    }

    /// Parsed screenshot launch request from CLI arguments or `SIMCTL_CHILD_*` environment variables.
    struct ScreenshotLaunch: Equatable, Sendable {
        static let sceneArgument = "--micdrop-screenshot-scene"
        static let readyArgument = "--micdrop-screenshot-ready"
        static let sceneEnvironmentKey = "MICDROP_SCREENSHOT_SCENE"
        static let readyEnvironmentKey = "MICDROP_SCREENSHOT_READY"

        let scene: ScreenshotScene
        /// File name written inside `FileManager.default.temporaryDirectory` once layout and scrolling settle.
        let readyFileName: String?

        static var current: ScreenshotLaunch? {
            parse(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
        }

        static func parse(arguments: [String], environment: [String: String]) -> ScreenshotLaunch? {
            let rawScene = argumentValue(sceneArgument, in: arguments) ?? environment[sceneEnvironmentKey]
            guard let rawScene, let scene = ScreenshotScene(rawValue: rawScene) else {
                return nil
            }
            let rawReady = argumentValue(readyArgument, in: arguments) ?? environment[readyEnvironmentKey]
            let sanitizedReady: String?
            if let rawReady, !rawReady.isEmpty {
                let name = URL(fileURLWithPath: rawReady).lastPathComponent
                sanitizedReady = (name.isEmpty || name == "." || name == "..") ? nil : name
            } else {
                sanitizedReady = nil
            }
            return ScreenshotLaunch(scene: scene, readyFileName: sanitizedReady)
        }

        /// Writes the ready marker inside the app's sandbox `tmp/` directory for `capture_ios_screenshots.sh`.
        func writeReadyMarker() {
            guard let readyFileName else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(readyFileName)
            try? Data("ok\n".utf8).write(to: url, options: .atomic)
        }

        private static func argumentValue(_ flag: String, in arguments: [String]) -> String? {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                return arguments[index + 1]
            }
            let prefix = flag + "="
            if let combined = arguments.first(where: { $0.hasPrefix(prefix) }) {
                return String(combined.dropFirst(prefix.count))
            }
            return nil
        }
    }

    /// Isolated object graph for deterministic simulator screenshot capture.
    @MainActor
    final class ScreenshotEnvironment {
        static let hostAddress = "192.168.1.42"
        static let hostPort = 8443
        static let hostKey = "8a4f2c91e03bd715a6c40289f1b374e28a4f2c91e03bd715a6c40289f1b374e2"
        static let clientKey = "3b7d91e4c028a56f9e1d4b82c7a3501e3b7d91e4c028a56f9e1d4b82c7a3501e"

        let launch: ScreenshotLaunch
        let mainViewModel: MainViewModel
        private var activated = false

        init(
            launch: ScreenshotLaunch,
            revision: String = BuildInfo.current.revision,
            versionName: String = BuildInfo.current.versionName
        ) {
            self.launch = launch

            let pairedLink = try! ConnectionLink.paired(
                host: Self.hostAddress,
                port: Self.hostPort,
                hostKey: Self.hostKey,
                clientKey: Self.clientKey)
            let pairedRecord = try! pairedLink.pairedRecord()

            let playback = FakePlaybackController(view: SessionView())
            let microphoneView: MicrophoneView
            if launch.scene == .connectedOutput {
                microphoneView = MicrophoneView(
                    session: SessionView(
                        phase: .playing,
                        message: "Streaming desktop audio and microphone.",
                        destination: "Windows: \(Self.hostAddress):\(Self.hostPort)",
                        outputEnabled: true,
                        outputSelection: OutputSelection(),
                        networkStatus: "Network: Wi-Fi"),
                    muted: false,
                    changing: false,
                    mode: .duplex,
                    input: MicrophoneSelection())
            } else {
                microphoneView = MicrophoneView()
            }
            let microphone = FakeMicrophoneController(view: microphoneView)
            let saved = FakeSavedConnectionStore(
                view: SavedConnectionView.saved(pairedLink, now: 0),
                record: pairedRecord)
            let settings = FakeAudioSettingsStore(
                preferences: AudioPreferences(
                    outputEnabled: true,
                    microphoneEnabled: true,
                    fastRecovery: true,
                    leStereo: false,
                    preferredInputKind: .builtIn,
                    preferredOutputKind: .default,
                    echoCancellation: true,
                    noiseReduction: true))
            let outputs = FakeOutputRoutes()
            let inputs = FakeMicrophoneRoutes()
            let baseline = IOSOutputSnapshot(
                capturedUptimeMs: 18_420,
                route: "phone speaker",
                sampleRateHz: 48_000,
                outputChannels: 2,
                ioBufferDuration: 0.01,
                outputLatency: 0.012,
                decodedChannels: nil,
                playoutGlitches: 0,
                trackGeneration: 1,
                routeChanges: 0
            ).outputSnapshot(backend: OutputSnapshot.localBackend)
            let tools = FakeLocalAudioTools(snapshot: baseline)
            let permissions = FakePermissionGateway()
            let volume = FakeVolumeReader(percent: 75)
            let discovery = LanDiscovery(
                makeBrowser: { FakeBonjourBrowser() },
                resolver: FakeBonjourResolver(),
                scheduler: FakeBonjourScheduler())
            let optIn = FakePhoneControlOptInStore()

            let dependencies = MainViewDependencies(
                playback: playback,
                microphone: microphone,
                saved: saved,
                settings: settings,
                outputs: outputs,
                inputs: inputs,
                tools: tools,
                permissions: permissions,
                volume: volume,
                discovery: discovery,
                clearPausedPlayback: {},
                storedStreamReport: { nil },
                latestCrashReport: { Strings.crashRecordUnavailable },
                copyToPasteboard: { _ in },
                setIdleTimerDisabled: { _ in },
                deviceLabel: { "iPhone" },
                revision: revision,
                versionName: versionName,
                recoveryWindowMs: { ConnectionPreferences()[.recovery] },
                subscribeAudioEvents: { _ in ObservationToken {} },
                phoneControlOptIn: optIn)

            let model = MainViewModel(dependencies: dependencies)
            if launch.scene == .connection {
                model.applyScreenshotDiscovery(
                    DiscoveryView(
                        searching: false,
                        message: Strings.Discovery.select,
                        hosts: [
                            DiscoveredHost(
                                host: Self.hostAddress,
                                port: Self.hostPort,
                                keyHint: Self.hostKey)
                        ]))
            }
            self.mainViewModel = model
        }

        /// Runs scene actions that require an active foreground scene (such as the local output probe).
        func activateIfNeeded() {
            guard !activated else { return }
            activated = true
            mainViewModel.scenePhaseChanged(.active)
            if launch.scene == .diagnostics {
                mainViewModel.localOutputTestTapped()
            }
        }
    }

    /// Root view used exclusively during simulator screenshot launches.
    struct ScreenshotRootView: View {
        let environment: ScreenshotEnvironment

        var body: some View {
            MainView(model: environment.mainViewModel, screenshotEnvironment: environment)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: - In-memory protocol fakes (no Keychain, audio, or network access)

    @MainActor
    private final class FakePlaybackController: PlaybackSessionControlling {
        var view: SessionView

        init(view: SessionView) {
            self.view = view
        }

        func observe(_ observer: @escaping (SessionView) -> Void) -> ObservationToken {
            observer(view)
            return ObservationToken {}
        }

        func connect(
            text: String, fastRecovery: Bool, baseline: OutputSnapshot?, reconnect: Bool,
            outputEnabled: Bool, outputSelection: OutputSelection
        ) throws {}

        func pause() {}
        func stop() {}
        func setOutputEnabled(_ enabled: Bool) {}
        func setOutputSelection(_ selection: OutputSelection) -> Bool { true }
    }

    @MainActor
    private final class FakeMicrophoneController: MicrophoneSessionControlling {
        var view: MicrophoneView

        init(view: MicrophoneView) {
            self.view = view
        }

        func observe(_ observer: @escaping (MicrophoneView) -> Void) -> ObservationToken {
            observer(view)
            return ObservationToken {}
        }

        func connect(
            text: String, mode: StreamMode, input: MicrophoneSelection, outputEnabled: Bool,
            fastRecovery: Bool, outputSelection: OutputSelection
        ) throws {}

        func resume() {}
        func stop() {}
        func setMuted(_ muted: Bool) {}
        func setOutputEnabled(_ enabled: Bool) {}
        func setOutputSelection(_ selection: OutputSelection) -> Bool { true }
        func inputActionToken() -> String? { nil }
        func switchInput(_ selection: MicrophoneSelection, expectedToken: String) -> Bool { true }
    }

    @MainActor
    private final class FakeSavedConnectionStore: SavedConnectionStoring {
        var view: SavedConnectionView
        private let record: String

        init(view: SavedConnectionView, record: String) {
            self.view = view
            self.record = record
        }

        func observe(_ observer: @escaping (SavedConnectionView) -> Void) -> ObservationToken {
            observer(view)
            return ObservationToken {}
        }

        func connection() -> String? { record }
        func pair(_ text: String, label: String) throws -> Int64? { nil }
        func cancelPairing() {}
        func forget() {}
        func updateAddress(host: String, port: Int) throws {}
    }

    @MainActor
    private final class FakeAudioSettingsStore: AudioSettingsStore {
        private var preferences: AudioPreferences
        let selectionGeneration: UInt64 = 0

        init(preferences: AudioPreferences) {
            self.preferences = preferences
        }

        func load() -> AudioPreferences { preferences }

        @discardableResult
        func update(_ change: (AudioPreferences) -> AudioPreferences) -> AudioPreferences {
            preferences = change(preferences)
            return preferences
        }

        func restoredOutputSelection() -> OutputSelection { OutputSelection() }
        func restoredMicrophoneSelection() -> MicrophoneSelection { MicrophoneSelection() }

        @discardableResult
        func rememberOutput(_ selection: OutputSelection) -> AudioPreferences { preferences }

        @discardableResult
        func rememberInput(_ selection: MicrophoneSelection) -> AudioPreferences { preferences }
    }

    @MainActor
    private final class FakeOutputRoutes: OutputRouteProviding {
        func choices() throws -> [OutputChoice] {
            [
                OutputChoice(selection: OutputSelection(), title: OutputKind.default.label),
                OutputChoice(selection: OutputSelection.restored(.phone), title: "\(OutputKind.phone.label) 1"),
            ]
        }

        func refresh(_ s: OutputSelection) -> OutputSelection? { s }
        func available(_ s: OutputSelection) -> Bool { true }
    }

    @MainActor
    private final class FakeMicrophoneRoutes: MicrophoneRouteProviding {
        func choices() throws -> [MicrophoneChoice] {
            [MicrophoneChoice(selection: MicrophoneSelection(), title: MicrophoneChoice.builtInTitle)]
        }

        func refresh(_ selection: MicrophoneSelection) -> MicrophoneSelection? { selection }
        func available(_ selection: MicrophoneSelection) -> Bool { true }
        var processingCapabilities: (echoCancellation: Bool, noiseReduction: Bool) { (true, true) }
    }

    @MainActor
    private final class FakeLocalOutputProbe: LocalOutputProbing {
        func playClick() {}
        func close() {}
    }

    @MainActor
    private final class FakeLocalAudioTools: LocalAudioTools {
        private let snapshot: OutputSnapshot
        var isReleasing: Bool = false
        var onReleased: (() -> Void)?

        init(snapshot: OutputSnapshot) {
            self.snapshot = snapshot
        }

        func acquire() -> Bool { true }
        func release() {}

        func startProbe(
            onSnapshot: @escaping (OutputSnapshot) -> Void,
            onEnded: @escaping (String) -> Void
        ) -> any LocalOutputProbing {
            onSnapshot(snapshot)
            return FakeLocalOutputProbe()
        }
    }

    @MainActor
    private final class FakePermissionGateway: PermissionGateway {
        var recordPermission: MicrophonePermissions.Status { .granted }
        func requestRecordPermission(_ completion: @escaping (Bool) -> Void) { completion(true) }
        var cameraAvailable: Bool { true }
        var cameraAuthorization: CameraAuthorization { .authorized }
        func requestCameraAccess(_ completion: @escaping (Bool) -> Void) { completion(true) }
        func openSettings() {}
    }

    @MainActor
    private final class FakeVolumeReader: VolumeReading {
        let percent: Int?
        var onChange: (() -> Void)?

        init(percent: Int?) {
            self.percent = percent
        }
    }

    private final class FakePhoneControlOptInStore: PhoneControlOptInStoring {
        private var allowed = false
        func allowWindows() -> Bool { allowed }
        func setAllowWindows(_ allow: Bool) throws { allowed = allow }
    }

    @MainActor
    private final class FakeBonjourCancellable: BonjourCancellable {
        func cancel() {}
    }

    @MainActor
    private final class FakeBonjourBrowser: BonjourBrowsing {
        var onState: (@MainActor (BonjourBrowseState) -> Void)?
        var onChanges: (@MainActor ([BonjourBrowseChange]) -> Void)?
        func start() {}
        func cancel() {}
    }

    @MainActor
    private final class FakeBonjourResolver: BonjourResolving {
        func resolve(
            _ endpoint: NWEndpoint,
            completion: @escaping @MainActor (Result<BonjourResolvedAddress, Error>) -> Void
        ) -> BonjourCancellable {
            FakeBonjourCancellable()
        }
    }

    @MainActor
    private final class FakeBonjourScheduler: BonjourScheduling {
        func schedule(afterMs: Int64, _ action: @escaping @MainActor () -> Void) -> BonjourCancellable {
            FakeBonjourCancellable()
        }
    }
#endif
