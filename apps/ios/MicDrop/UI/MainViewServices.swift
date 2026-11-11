// Interfaces the main screen consumes.
//
// The view model depends only on these protocols so its flows are testable with fakes. The live
// conformances (over the other owners' concrete controllers and stores) are in
// `MainViewLiveServices.swift`; that file and `App/MicDropApp.swift` are the only integration points
// with other owners.
//
// Every protocol is main-actor isolated: Android calls these from the activity's main thread, and every observer must
// be invoked synchronously from the publishing call (the UI relies on it, e.g. `pendingConnect` clearing before
// `connect` returns, `MainActivity.kt:181`).

import Foundation
import MicDropCore

// MARK: - Observation

/// Keeps one `observe(_:)` registration alive for playback, microphone, and UI subscriptions.
/// `SavedConnectionStore` retains its own public token type. Calling `cancel()` or releasing this
/// token unregisters its observer exactly once on the main actor; cancellation is safe from any thread.
final class ObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@MainActor () -> Void)?
    private var retained: Any?

    /// A token whose cancellation runs `onCancel` once on the main actor. Accepts trailing-closure
    /// syntax (`ObservationToken { … }`) and `ObservationToken({ … })`.
    init(_ onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    /// Labeled convenience form of `init(_:)`.
    convenience init(onCancel: @escaping @MainActor () -> Void) {
        self.init(onCancel)
    }

    /// A token that keeps another registration object alive (e.g. `AudioSessionEventMonitor.Subscription`
    /// or a foreign token whose deinit unregisters); cancelling releases it.
    init(retaining value: Any) {
        self.retained = value
    }

    func cancel() {
        lock.lock()
        let action = onCancel
        onCancel = nil
        let value = retained
        retained = nil
        lock.unlock()
        withExtendedLifetime(value) {}
        guard let action else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    }

    deinit {
        cancel()
    }
}

// MARK: - Session controllers

/// The playback-only controller (Android `PlaybackService` as seen by `MainActivity`). Live conformance:
/// `PlaybackSessionController`.
///
/// `ObservationHandle` is whatever registration object the controller returns (`ObservationToken`); the
/// view model only keeps it alive, so the protocol does not pin the concrete token type.
@MainActor
protocol PlaybackSessionControlling: AnyObject {
    associatedtype ObservationHandle: AnyObject
    /// The current published view.
    var view: SessionView { get }
    /// Calls `observer` immediately with `view`, then synchronously from every later publish; releasing
    /// or cancelling the returned handle unregisters it.
    func observe(_ observer: @escaping (SessionView) -> Void) -> ObservationHandle
    /// `PlaybackService.connectFromActivity` (`MainActivity.kt:713-722`); publishes CONNECTING (or
    /// ENDED with a failure) synchronously before returning. Throws only if the controller could not
    /// even begin (UI shows `Strings.connectStartFailed`); the live controller never throws.
    func connect(
        text: String, fastRecovery: Bool, baseline: OutputSnapshot?, reconnect: Bool,
        outputEnabled: Bool, outputSelection: OutputSelection) throws
    /// Manual pause; while INTERRUPTED it converts the automatic interruption to a manual pause ("Keep paused").
    func pause()
    /// `stop(.user)`; also used to drop a PAUSED session before pairing, address change, Forget,
    /// local tools and microphone sessions.
    func stop()
    func setOutputEnabled(_ enabled: Bool)
    /// Returns false when the live session rejects the selection (`output_change_unavailable`).
    func setOutputSelection(_ selection: OutputSelection) -> Bool
}

/// The microphone / duplex controller (Android `MicrophoneService`; `MicrophoneSessionController` conforms).
/// Android's output-consent `outputActionToken()` is not part of the iOS contract (no Nearby-devices permission).
///
/// `ObservationHandle`: as for `PlaybackSessionControlling`; the live microphone controller returns
/// the shared `ObservationToken`.
@MainActor
protocol MicrophoneSessionControlling: AnyObject {
    associatedtype ObservationHandle: AnyObject
    var view: MicrophoneView { get }
    /// Calls `observer` immediately with `view`, then synchronously from every later publish.
    func observe(_ observer: @escaping (MicrophoneView) -> Void) -> ObservationHandle
    /// Starts a microphone or duplex session (`MicrophoneService.connect`). Throws `MicrophoneRouteError` for route
    /// preflight failures; any other error means the session did not start.
    func connect(
        text: String, mode: StreamMode, input: MicrophoneSelection, outputEnabled: Bool,
        fastRecovery: Bool, outputSelection: OutputSelection) throws
    /// "Resume duplex".
    func resume()
    func stop()
    /// Live mute; the controller also persists `microphoneEnabled = !muted`.
    func setMuted(_ muted: Bool)
    func setOutputEnabled(_ enabled: Bool)
    func setOutputSelection(_ selection: OutputSelection) -> Bool
    /// Token of the session an input change applies to, nil when no change is allowed.
    func inputActionToken() -> String?
    /// Live input change; false when rejected (`input_change_unavailable`).
    func switchInput(_ selection: MicrophoneSelection, expectedToken: String) -> Bool
}

// MARK: - Saved connection

/// The saved-connection store as the UI uses it. Named `…Storing` because the concrete Keychain store
/// `SavedConnectionStore` owns that name; it conforms directly (`MainViewLiveServices.swift`).
@MainActor
protocol SavedConnectionStoring: AnyObject {
    associatedtype ObservationHandle: AnyObject
    var view: SavedConnectionView { get }
    /// Calls `observer` immediately with `view`, then synchronously from every later publish.
    func observe(_ observer: @escaping (SavedConnectionView) -> Void) -> ObservationHandle
    /// The saved link for Connect/Reconnect, or nil while working / absent / expired (may publish an
    /// expired view for a v2 link first).
    func connection() -> String?
    /// Starts pairing; returns the operation id for `PairingConnectIntent.begin`, or nil when the
    /// store refused (busy, or needs Forget — then it publishes a failure with a new id).
    func pair(_ text: String, label: String) throws -> Int64?
    func cancelPairing()
    func forget()
    /// Re-saves the paired record at a new endpoint (keeps a remote route).
    func updateAddress(host: String, port: Int) throws
}

// MARK: - Preferences, routes

/// Preferences store (`AudioPreferencesStore` conforms).
@MainActor
protocol AudioSettingsStore: AnyObject {
    func load() -> AudioPreferences
    /// Read-modify-write of the whole preference set; returns the stored value.
    @discardableResult
    func update(_ change: (AudioPreferences) -> AudioPreferences) -> AudioPreferences
    /// iOS device memory (`RememberedAudioDevices`): the remembered output pin of a new process while its kind
    /// is still saved, else `OutputSelection.restored(preferredOutputKind)`. Availability is checked separately.
    func restoredOutputSelection() -> OutputSelection
    /// The remembered input of a new process while its kind is still saved, else the built-in microphone.
    func restoredMicrophoneSelection() -> MicrophoneSelection
    /// Saves an output choice: its identity (none for iPhone media output and the speakers) and its kind.
    @discardableResult
    func rememberOutput(_ selection: OutputSelection) -> AudioPreferences
    /// Saves an input choice: its identity (none for the built-in microphone) and its kind.
    @discardableResult
    func rememberInput(_ selection: MicrophoneSelection) -> AudioPreferences
    /// Changes only when Windows saved an input or output for the next connection (phone settings exchange v1);
    /// the idle rows then adopt the saved selections.
    var selectionGeneration: UInt64 { get }
}

/// `PhoneControlPreferenceStore`: "Allow Windows to change phone settings" (phone settings exchange v1), read by
/// the session settings adapter too. Any thread.
protocol PhoneControlOptInStoring: AnyObject {
    func allowWindows() -> Bool
    /// Saves at once. A failed write of `true` keeps control off; `false` always takes effect, and a failed write
    /// still throws so the toggle can show it.
    func setAllowWindows(_ allow: Bool) throws
}

// `OutputRouteProviding` (media output choices) is declared by its provider, (`Output/OutputChoices.swift`): `choices()
// throws -> [OutputChoice]`, `refresh(_:) -> OutputSelection?`, `available(_:) -> Bool`; `OutputChoices` conforms.

/// Microphone inputs for the input dialog (owner 08 `MicrophoneInventory` conforms).
@MainActor
protocol MicrophoneRouteProviding: AnyObject {
    /// The selectable inputs. Throws when inputs cannot be listed.
    func choices() throws -> [MicrophoneChoice]
    func refresh(_ selection: MicrophoneSelection) -> MicrophoneSelection?
    func available(_ selection: MicrophoneSelection) -> Bool
    /// iOS availability of the two processing toggles (risk 12).
    var processingCapabilities: (echoCancellation: Bool, noiseReduction: Bool) { get }
}

// MARK: - Local diagnostic tools

/// The local output probe, the only local diagnostic tool since Android retired Android's AAudio test tone. Callbacks
/// are delivered on the main actor.
@MainActor
protocol LocalAudioTools: AnyObject {
    var isReleasing: Bool { get }
    var onReleased: (() -> Void)? { get set }
    /// Exclusive local audio: `AudioSessionOwner.shared.tryAcquire()` then the arbiter's local-tool plan
    /// (`.playback`/`.default`, 48 kHz, 0.01 s), only while `RTCAudioSession.isAudioEnabled == false`.
    /// False → the UI shows `Strings.focusDenied`.
    func acquire() -> Bool
    /// Releases what `acquire()` took (deactivate, then release the permit). Idempotent.
    func release()
    /// Starts the local output probe: snapshots every 500 ms; `onEnded` with
    /// `Local output test stopped.` / `Local output test failed. Stop and choose the output again.`.
    func startProbe(
        onSnapshot: @escaping (OutputSnapshot) -> Void,
        onEnded: @escaping (String) -> Void
    ) -> any LocalOutputProbing
}

extension LocalAudioTools {
    var isReleasing: Bool { false }
    var onReleased: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// A running local output probe (app-media `LocalOutputProbe` conforms).
@MainActor
protocol LocalOutputProbing: AnyObject {
    /// Arms one 10 ms chirp (a single pending flag, never a queue).
    func playClick()
    /// Stops the probe; `onEnded` follows with the stopped text.
    func close()
}

// MARK: - Permissions and platform

/// Camera authorization as the scanner flow needs it.
enum CameraAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    /// `.denied` or `.restricted`.
    case denied
}

/// Record/camera permission queries and requests, and the Settings deep link (`PermissionGateway`). Completions run on
/// the main actor.
@MainActor
protocol PermissionGateway: AnyObject {
    /// `AVAudioApplication.shared.recordPermission` mapped to 08's status.
    var recordPermission: MicrophonePermissions.Status { get }
    func requestRecordPermission(_ completion: @escaping (Bool) -> Void)
    /// A back wide-angle camera exists (false in the Simulator).
    var cameraAvailable: Bool { get }
    var cameraAuthorization: CameraAuthorization { get }
    func requestCameraAccess(_ completion: @escaping (Bool) -> Void)
    /// Opens MicDrop's page in Settings (`UIApplication.openSettingsURLString`).
    func openSettings()
}

/// The system output volume for the volume label.
@MainActor
protocol VolumeReading: AnyObject {
    /// `Int((AVAudioSession.outputVolume * 100).rounded())`, nil when unreadable.
    var percent: Int? { get }
    /// Called on the main actor after `percent` changed.
    var onChange: (() -> Void)? { get set }
}

/// Audio-session events the main screen reacts to, delivered by the single `AudioSessionEventMonitor` fan-out (no other
/// component observes the notifications).
enum MainViewAudioEvent: Equatable, Sendable {
    /// `interruptionNotification` `.began` (reason not `.appWasSuspended`): stop local tools.
    case interruptionBegan
    /// `routeChangeNotification`; `oldDeviceUnavailable` stops local tools (Android becoming-noisy), every route change
    /// re-derives the output/input rows while visible (onStart).
    case routeChanged(oldDeviceUnavailable: Bool)
}

// MARK: - Dependency bundle

/// Everything `MainViewModel` uses. `MainViewDependencies.live(...)` (MainViewLiveServices.swift) wires
/// the app; tests pass fakes.
@MainActor
struct MainViewDependencies {
    var playback: any PlaybackSessionControlling
    var microphone: any MicrophoneSessionControlling
    var saved: any SavedConnectionStoring
    var settings: any AudioSettingsStore
    var outputs: any OutputRouteProviding
    var inputs: any MicrophoneRouteProviding
    var tools: any LocalAudioTools
    var permissions: any PermissionGateway
    var volume: any VolumeReading
    var discovery: LanDiscovery
    /// `PausedPlaybackStore.clear()` (07): media Play must never recreate a replaced session.
    var clearPausedPlayback: () -> Void
    /// `StoredReports.stream()` (03): the last saved stream report.
    var storedStreamReport: () -> String?
    /// `CrashDiagnostics.latest()` (03): the "Copy crash report" text; never throws; runs off the main
    /// actor (non-isolated async).
    var latestCrashReport: () async -> String
    /// Local-only pasteboard copy (`UIPasteboard` `.localOnly`).
    var copyToPasteboard: (String) -> Void
    /// `UIApplication.shared.isIdleTimerDisabled` (local output test only).
    var setIdleTimerDisabled: (Bool) -> Void
    /// `DeviceLabel.current()` (01).
    var deviceLabel: () -> String
    /// `BuildInfo.current.revision` (11).
    var revision: String
    /// `BuildInfo.current.versionName` (11): the Diagnostics summary (`BuildConfig.VERSION_NAME`).
    var versionName: String
    /// The saved recovery window in milliseconds, `ConnectionPreferencesStore.shared.load()[.recovery]`: the Advanced
    /// summary (`AppConnectionSettings.load(this)[ConnectionTimeout.RECOVERY]`). Read on every derive.
    var recoveryWindowMs: () -> Int
    /// Registers the main screen's audio-event handler with the event monitor; the returned token keeps the
    /// registration alive.
    var subscribeAudioEvents: (@escaping @MainActor (MainViewAudioEvent) -> Void) -> ObservationToken
    /// "Allow Windows to change phone settings" (phone settings exchange v1, `PhoneControlOptIn`); production
    /// `PhoneControlPreferenceStore.shared`, which the session settings adapter reads too.
    var phoneControlOptIn: any PhoneControlOptInStoring

    init(
        playback: any PlaybackSessionControlling,
        microphone: any MicrophoneSessionControlling,
        saved: any SavedConnectionStoring,
        settings: any AudioSettingsStore,
        outputs: any OutputRouteProviding,
        inputs: any MicrophoneRouteProviding,
        tools: any LocalAudioTools,
        permissions: any PermissionGateway,
        volume: any VolumeReading,
        discovery: LanDiscovery,
        clearPausedPlayback: @escaping () -> Void,
        storedStreamReport: @escaping () -> String?,
        latestCrashReport: @escaping () async -> String,
        copyToPasteboard: @escaping (String) -> Void,
        setIdleTimerDisabled: @escaping (Bool) -> Void,
        deviceLabel: @escaping () -> String,
        revision: String,
        versionName: String,
        recoveryWindowMs: @escaping () -> Int,
        subscribeAudioEvents: @escaping (@escaping @MainActor (MainViewAudioEvent) -> Void) -> ObservationToken,
        phoneControlOptIn: any PhoneControlOptInStoring
    ) {
        self.playback = playback
        self.microphone = microphone
        self.saved = saved
        self.settings = settings
        self.outputs = outputs
        self.inputs = inputs
        self.tools = tools
        self.permissions = permissions
        self.volume = volume
        self.discovery = discovery
        self.clearPausedPlayback = clearPausedPlayback
        self.storedStreamReport = storedStreamReport
        self.latestCrashReport = latestCrashReport
        self.copyToPasteboard = copyToPasteboard
        self.setIdleTimerDisabled = setIdleTimerDisabled
        self.deviceLabel = deviceLabel
        self.revision = revision
        self.versionName = versionName
        self.recoveryWindowMs = recoveryWindowMs
        self.subscribeAudioEvents = subscribeAudioEvents
        self.phoneControlOptIn = phoneControlOptIn
    }
}
