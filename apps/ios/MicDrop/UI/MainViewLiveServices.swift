// Live wiring of the main screen to the other app-target types. Every external signature the UI
// assumes is used only here and in `App/MicDropApp.swift`.

import AVFoundation
import Foundation
import MicDropCore
import UIKit
import UniformTypeIdentifiers

// MARK: - Conformances

/// `PlaybackSessionController`: `view`, `observe(_:) -> ObservationToken`, `connect(text:fastRecovery:
/// baseline:reconnect:outputEnabled:outputSelection:)` (non-throwing witness), `pause()`, `stop()`,
/// `setOutputEnabled(_:)`, `setOutputSelection(_:) -> Bool`.
extension PlaybackSessionController: PlaybackSessionControlling {}

/// `SavedConnectionStore`: `view`, `observe(_:)` (its own token type), `connection()`,
/// `pair(_:label:) throws -> Int64?`, `cancelPairing()`, `forget()`, `updateAddress(host:port:) throws`.
extension SavedConnectionStore: SavedConnectionStoring {}

/// `AudioPreferencesStore`: `load()`, `@discardableResult update(_:)`.
extension AudioPreferencesStore: AudioSettingsStore {}

/// `PhoneControlPreferenceStore`: `allowWindows()`, `setAllowWindows(_:) throws`.
extension PhoneControlPreferenceStore: PhoneControlOptInStoring {}

/// `MicrophoneInventory`: `choices() throws`, `refresh(_:)`, `available(_:)`, `processingCapabilities`.
extension MicrophoneInventory: MicrophoneRouteProviding {}

/// 04 `LocalOutputProbe`: `playClick()` and `close()` (any thread; callbacks on the main queue).
extension LocalOutputProbe: LocalOutputProbing {}

// `MicrophoneSessionController: MicrophoneSessionControlling` is declared by app-mic
// (`Microphone/MicrophoneSessionController.swift`); `OutputChoices: OutputRouteProviding` by app-output.

// MARK: - Dependency bundle

extension MainViewDependencies {
    /// Production dependencies over the composition root's controllers (`AppEnvironment`).
    static func live(
        playback: PlaybackSessionController,
        microphone: MicrophoneSessionController,
        outputs: OutputChoices,
        inputs: MicrophoneInventory,
        arbiter: AudioSessionArbiter,
        monitor: AudioSessionEventMonitor = .shared
    ) -> MainViewDependencies {
        MainViewDependencies(
            playback: playback,
            microphone: microphone,
            saved: SavedConnectionStore.shared,
            settings: AudioPreferencesStore.shared,
            outputs: outputs,
            inputs: inputs,
            tools: LiveLocalAudioTools(arbiter: arbiter),
            permissions: SystemPermissionGateway(),
            volume: SystemVolumeMonitor(),
            discovery: LanDiscovery.shared,
            clearPausedPlayback: { PausedPlaybackStore.shared.clear() },
            storedStreamReport: { StoredReports.stream() },
            latestCrashReport: { await CrashDiagnostics.latest() },
            copyToPasteboard: { text in
                // `.localOnly`: private diagnostics never sync through Universal Clipboard.
                UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
            },
            setIdleTimerDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 },
            deviceLabel: { DeviceLabel.current() },
            revision: BuildInfo.current.revision,
            versionName: BuildInfo.current.versionName,
            recoveryWindowMs: { ConnectionPreferencesStore.shared.load()[.recovery] },
            subscribeAudioEvents: { handler in
                let subscription = monitor.addMainSink { event in
                    switch event {
                    case .interruptionBegan(let reason) where reason != .appWasSuspended:
                        handler(.interruptionBegan)
                    case .routeChanged(let change):
                        handler(.routeChanged(oldDeviceUnavailable: change.reason == .oldDeviceUnavailable))
                    default:
                        break
                    }
                }
                return ObservationToken(retaining: subscription)
            },
            phoneControlOptIn: PhoneControlPreferenceStore.shared)
    }

    // MARK: Local diagnostic tools

    /// Exclusive local audio for the output probe. `acquire()` takes the process-wide `AudioSessionOwner` permit and
    /// the arbiter's `.localTool` activation (only while WebRTC audio is disabled); `release()` deactivates, then
    /// releases the permit. The probe itself (`LocalOutputProbe`) never touches the session. Local tools never publish
    /// Now Playing or register remote commands.
    @MainActor
    final class LiveLocalAudioTools: LocalAudioTools {
        private let arbiter: AudioSessionArbiter
        private let owner: AudioSessionOwner
        private let clock: any MonotonicClock
        private var activation: AudioSessionArbiter.Activation?
        private var permitHeld = false
        private var activeProbe: LocalOutputProbe?
        private var releaseRequested = false
        var isReleasing: Bool { releaseRequested }
        var onReleased: (() -> Void)?

        init(
            arbiter: AudioSessionArbiter, owner: AudioSessionOwner = .shared,
            clock: any MonotonicClock = SystemMonotonicClock()
        ) {
            self.arbiter = arbiter
            self.owner = owner
            self.clock = clock
        }

        func acquire() -> Bool {
            guard !releaseRequested else { return false }
            if permitHeld { return true }
            guard !arbiter.isAudioEnabled, owner.tryAcquire() else { return false }
            switch arbiter.prepareNow(.localTool) {
            case .success(let granted):
                activation = granted
                permitHeld = true
                return true
            case .failure:
                owner.release()
                return false
            }
        }

        func release() {
            if let activeProbe {
                releaseRequested = true
                activeProbe.close()
                return
            }
            finishRelease()
        }

        private func finishRelease() {
            let wasReleasing = releaseRequested
            releaseRequested = false
            if let activation {
                arbiter.deactivate(activation, notifyOthers: true)
            }
            activation = nil
            if permitHeld {
                permitHeld = false
                owner.release()
            }
            if wasReleasing {
                onReleased?()
            }
        }

        /// `LocalOutputProbe(clock:onSnapshot:onEnded:)` + `start()`; both callbacks arrive on the main queue. The
        /// probe's "phone uptime" uses the monotonic clock.
        func startProbe(
            onSnapshot: @escaping (OutputSnapshot) -> Void,
            onEnded: @escaping (String) -> Void
        ) -> any LocalOutputProbing {
            let probe = LocalOutputProbe(
                clock: clock, onSnapshot: onSnapshot,
                onEnded: { [self] message in
                    MainActor.assumeIsolated {
                        activeProbe = nil
                        finishRelease()
                        onEnded(message)
                    }
                })
            activeProbe = probe
            probe.start()
            return probe
        }
    }

    // MARK: Permissions

    /// `AVAudioApplication` record permission, `AVCaptureDevice` camera authorization and the app's Settings page. No
    /// Bluetooth or notification permission exists on iOS.
    @MainActor
    final class SystemPermissionGateway: PermissionGateway {
        init() {}

        var recordPermission: MicrophonePermissions.Status {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }

        func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(granted) }
                }
            }
        }

        var cameraAvailable: Bool {
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        }

        var cameraAuthorization: CameraAuthorization {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .authorized
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }

        func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(granted) }
                }
            }
        }

        func openSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    // MARK: Volume

    /// `AVAudioSession.outputVolume` (0…1) as a percentage, updated by KVO. The slider itself is `MPVolumeView`
    /// (`SystemVolumeView`); iOS apps cannot set the system volume otherwise.
    @MainActor
    final class SystemVolumeMonitor: VolumeReading {
        private(set) var percent: Int?
        var onChange: (() -> Void)?
        private var observation: NSKeyValueObservation?

        init(session: AVAudioSession = AVAudioSession.sharedInstance()) {
            percent = SystemVolumeMonitor.percent(session.outputVolume)
            observation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
                let value = session.outputVolume
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.update(value) }
                }
            }
        }

        /// `Int((outputVolume * 100).rounded())`.
        nonisolated static func percent(_ volume: Float) -> Int {
            Int((volume * 100).rounded())
        }

        private func update(_ volume: Float) {
            let next = SystemVolumeMonitor.percent(volume)
            guard next != percent else { return }
            percent = next
            onChange?()
        }
    }
}
