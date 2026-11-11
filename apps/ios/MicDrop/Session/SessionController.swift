import Foundation
import MicDropCore
import MicDropTransport

/// One service-controlled MicDrop session: the iOS port of `StreamReceiver.kt`.
///
/// Execution model: one dedicated `Thread` ("MicDrop-session", QoS `.userInitiated`) runs `run()` synchronously,
/// exactly like `StreamReceiver.worker` (`StreamReceiver.kt:157`). It owns all worker state, issues every HTTP control
/// request sequentially, and is the only thread that calls WebRTC. Asynchronous boundaries (NIO transport, URLSession,
/// WebRTC completion handlers) are bridged with `SessionWorkerWait`. Callbacks (WebRTC delegate, route changes, network
/// monitor, UI) never perform HTTP or native teardown: they set flags under the locks, gate audio and wake the worker
/// (`controlSignal`).
///
/// Collaborators: `MediaEngine` (04, created at stage AUDIO), `OutputRouteController` (09, created
/// here), `MicrophoneControl`/`MicrophoneRouting` (08, created on the worker at INPUT_ROUTE), ICE
/// helpers (05), diagnostics value types (03). Bridges nested in this type adapt this controller to
/// their host protocols.
///
/// Locks: `cancelLock` then `audioLock` (lock order of `StreamReceiver.kt:1155-1161`). Both are
/// recursive because Kotlin `synchronized` is re-entrant (`fail` → `close`, `withCurrentOutput` →
/// `close(.output)`).
final class SessionController: StreamReceiving, @unchecked Sendable {

    // MARK: - Inputs

    let configuration: SessionConfiguration
    let callbacks: SessionCallbacks
    let dependencies: SessionDependencies

    // MARK: - Locks and cancellation

    /// Kotlin `cancelLock`; guards `stopReasonStorage`, `failureMessage`, `failureEvidence`,
    /// `activeRequest`, `remoteStatusRequest`.
    let cancelLock = NSRecursiveLock()
    /// Kotlin `audioLock`; guards `engine` publication, gate decisions and microphone desired/applied transitions
    /// (final gate).
    let audioLock = NSRecursiveLock()

    /// Kotlin `closed` (`AtomicBoolean`).
    let closedFlag: Guarded<Bool>
    /// Kotlin `stopReason` (first reason wins). `cancelLock`.
    var stopReasonStorage: StopReason? = nil
    /// Kotlin `failure` (first message wins; cleanup may set `TEARDOWN_FAILED`). `cancelLock`.
    var failureMessage: String? = nil
    /// Kotlin `failureEvidence`. `cancelLock`.
    var failureEvidence: FailureEvidence? = nil
    /// Registered-wait bridge.
    let workerWait: SessionWorkerWait
    /// Kotlin `controlSignal` (`Object.wait/notifyAll`), sticky notification.
    let controlSignal: ControlSignal
    /// `start()` idempotence.
    let startedFlag = Guarded(false)
    /// In-flight ordinary (non-stopping) request: LAN `activeRequest` and remote `remoteRequest` in Kotlin.
    /// `cancelLock`.
    var activeRequest: SessionRequestRegistration? = nil
    /// In-flight remote `/status`, the only request a network handoff may cancel
    /// (`StreamReceiver.kt:112,136`). `cancelLock`.
    var remoteStatusRequest: SessionRequestRegistration? = nil

    // MARK: - Shared session state (Kotlin @Volatile / atomics)

    /// Kotlin `stage` (`@Volatile`).
    let stageStorage = Guarded(ConnectionStage.waiting)
    /// Local peer-connection state, capitalized (`New` … `Closed`); initial `"Connecting"` (`StreamReceiver.kt:154`).
    let peerStateStorage = Guarded("Connecting")
    /// Kotlin `iceConnected`.
    let iceConnectedFlag = Guarded(false)
    /// Kotlin `mediaReady`: true after `/answer` was submitted (`StreamReceiver.kt:550`).
    let mediaReadyFlag = Guarded(false)
    /// `lanRecovery.supported`, readable from delegate threads (`StreamReceiver.kt:1719,1731,1735`).
    let recoverySupportedFlag = Guarded(false)
    /// Kotlin `continuousEnabled` (`@Volatile`).
    let continuousEnabledFlag = Guarded(false)
    /// Kotlin `collectingRecovery` (`@Volatile`).
    let collectingRecoveryFlag = Guarded(false)
    /// Playout active (Kotlin `trackStarted`, `PlayoutTap` edges).
    let playoutActiveFlag = Guarded(false)
    /// Audio interruption in progress.
    let audioInterruptedFlag = Guarded(false)
    /// Total playout glitches reported by the engine (`OutputPlayoutEngine.playoutGlitches`).
    let playoutGlitchTotal = Guarded(Int64(0))
    /// Scene `.active`; sessions start from the foreground.
    let applicationActiveFlag = Guarded(true)
    /// Kotlin `lastSignalingFailure` (written by `fail` on any thread and by the worker).
    let lastSignalingFailureStorage = Guarded<String?>(nil)
    /// Kotlin `networkHeld`.
    let networkHeldFlag = Guarded(false)

    // MARK: - Media engine (published under audioLock)

    /// WebRTC engine created at stage AUDIO. Published under `audioLock` (`StreamReceiver.kt:443-447`); callbacks read
    /// it under the lock, the worker directly.
    var engine: MediaEngine? = nil
    /// TLS setup evaluated at PAIRING (`StreamReceiver.kt:369`).
    var tlsSetup: ControlTLSSetup? = nil

    // MARK: - Signalling state (worker)

    /// Session bearer from `/offer` (`StreamReceiver.kt:385`).
    var sessionToken: String? = nil
    /// `SessionDestination.digest(link)` (`StreamReceiver.kt:78-81`).
    let stopDestination: String
    /// One nonce per worker.
    let offerAttempt: OfferAttempt
    /// `session_lifecycle_version` (default 1, `StreamReceiver.kt:373`).
    var lifecycleVersion = 1
    var connectionDeadlines: ConnectionDeadlines
    /// Whether `/offer` has been answered for terminal report labels (`StreamReceiver.kt:398,425,451,904`).
    var offerReply: ReportText.OfferReply = .none
    var setupStartedMs: Int64?
    /// Replaced after `/offer` with `LanRecovery(supported:)` (`StreamReceiver.kt:374`).
    var lanRecovery: LanRecovery
    /// Remote default-network handoff coalescer.
    let networkHandoff = NetworkHandoff()
    /// Kotlin `networkHandoffs`.
    var networkHandoffs = 0
    /// Last `onNetworkStatus` text (published only on change).
    var publishedNetworkStatus = ""
    /// Periodic report delivery state, created after `/offer`.
    var delivery: ReportDelivery? = nil
    /// Offer capability flags.
    var includeOutput = false
    var includeConnection = false
    var includeOutputControl = false
    var includeIceGathering = false
    var includeMediaTransport = false
    var includeRouteSelection = false
    /// `tls_certificate_diagnostics_version == 1` (`StreamReceiver.kt:408`).
    var includeTlsVerification = false
    var includeMicrophoneProcessing = false
    var gatheringDiagnosticsVersion = 0
    /// `remote && v3 && trickle_ice_version == 1` (`StreamReceiver.kt:392`).
    var useTrickle = false
    /// Phone settings exchange v1 for this session (`StreamReceiver.kt:397`): set in `acceptOffer` from
    /// `OfferCapabilities.phoneControlNegotiated` and the presence of `phoneControl`, kept across ICE restarts and
    /// LAN recovery, never persisted or reused by a later Connect or Play. It gives `/status` the 160 KiB body
    /// budget, the `phone_control` snapshot and `phone_control_command` processing.
    var phoneControlEnabled = false
    /// This session's settings adapter (`StreamReceiver.kt:52`): only with a controller binding and the stores, a
    /// fresh salt and an empty command history, discarded with the session.
    let phoneControl: PhoneControlAdapter?
    /// Validated host SDP offer (≤ 65 536 UTF-16 units, `StreamReceiver.kt:391`).
    var offerDescription = ""

    // MARK: - ICE state (worker unless noted)

    var trickle: TrickleExchange? = nil
    var continuous: ContinuousExchange? = nil
    /// Thread-safe; fed by delegate callbacks (`StreamReceiver.kt:1741,1747`).
    let continuousCandidates = ContinuousCandidateEvidence()
    /// Thread-safe; fed while `collectingRecoveryFlag` (`StreamReceiver.kt:1740`).
    let recoveryCandidates = RecoveryCandidateEvidence()
    /// Thread-safe; fed by `didFailToGatherIceCandidate` (`StreamReceiver.kt:1744`).
    let gatheringErrors = IceGatheringErrors()
    /// Frozen initial gathering snapshot.
    var initialGathering: IceGatheringSnapshot? = nil
    var gatheringStartedMs: Int64 = 0
    /// Remote `/v1/ice` configuration fetched at PAIRING (nil on LAN).
    var iceConfiguration: RemoteICEConfiguration? = nil
    /// Kotlin `recoveryLocalGeneration` / `recoveryPreviousLocal` (`StreamReceiver.kt:116-117`).
    var recoveryLocalGeneration: Int64 = 0
    var recoveryPreviousLocal = ""
    /// Route-selection evidence.
    let routeSelection = RouteSelectionTracker()
    /// TURN/TLS platform-trust counters: one set per session, shared by the peer's verifier across ICE
    /// restarts and handoffs (`StreamReceiver.kt:93`). Thread-safe; WebRTC's network thread records.
    let turnTLSTrust = TurnTLSTrustCounters()
    /// LAN signaling route label/text and wake-on-change.
    let lanRoute: LanSignalingRoute
    let signalingRoute: SignalingRoute
    let localTransport: any ControlTransport
    let localProbe: any LocalHostProbing

    // MARK: - Diagnostics (03)

    let evidence = SessionEvidence()
    let metrics: SessionMetrics
    let recoveryMonitor: RecoveryMonitor
    let journal: StopReportJournal
    /// Only the worker holding `AudioSessionOwner` writes the journal (`StreamReceiver.kt:147`).
    var journalActive = false
    /// Kotlin `lastDiagnostics`.
    var lastDiagnostics = ""
    /// Kotlin `signalingRequestFailures`: the last four failed ordinary requests (worker).
    var signalingRequestFailures = SignalingRequestFailures()
    /// One pending snapshot, never a queue.
    var pendingReport: PlaybackReport? = nil
    var reportSequence: UInt64 = 0
    var nextRouteReportAt: Int64 = 0
    /// Created by `dependencies.runtime()` at WAITING (`StreamReceiver.kt:357`).
    var runtime: SessionRuntime? = nil

    // MARK: - Network audio hold

    /// Kotlin `networkAudioSuspended` (worker).
    var networkAudioSuspended = false

    // MARK: - Microphone (08)

    /// Kotlin `microphoneDesiredMuted`.
    let microphoneDesiredMuted: Guarded<Bool>
    /// Kotlin `microphoneAppliedMuted` (`nil` until the first applied control).
    let microphoneAppliedMuted = Guarded<Bool?>(nil)
    /// Kotlin `microphoneControlDirty` (worker).
    var microphoneControlDirty = false
    /// Thread-safe headset recovery window of `configuration.bluetoothRecoveryMs`; cancelled by `close`.
    let headsetRecovery: HeadsetRecovery
    /// Route prepare/activate/verify/close; created at INPUT_ROUTE.
    var microphoneRouting: MicrophoneRouting? = nil
    /// Mute protocol / headset restoration steps; created after AUDIO.
    var microphoneControl: MicrophoneControl? = nil
    /// Created before the ADM so input initialization cannot race the first native unit.
    var microphoneCapture: MicrophoneCapture? = nil

    // MARK: - Output (09)

    /// All output selection/verification state machines.
    let outputController: OutputRouteController

    // MARK: - Bridges to collaborator host protocols

    let outputHost: OutputHostBridge
    let playoutBridge: PlayoutEngineBridge
    let microphoneHooks: MicrophoneHooksBridge
    let engineEvents: EngineEventsBridge

    // MARK: - Teardown (worker)

    /// Kotlin `ownsSession`.
    var ownsAudioSession = false
    var endReason: StopReason = .failure
    var terminalEvidence: TerminalEvidence? = nil
    var finalSnapshot = ""
    /// Windows terminal diagnostics delivery text.
    var terminalDelivery = ""

    /// `awaitRemoteStop` signalling.
    let remoteStopSignal = NSCondition()
    var remoteStopFinished = false
    var remoteStopAcknowledged = false

    // MARK: - Init

    init(_ configuration: SessionConfiguration, callbacks: SessionCallbacks, dependencies: SessionDependencies) {
        self.configuration = configuration
        self.callbacks = callbacks
        self.dependencies = dependencies
        connectionDeadlines = configuration.connectionPreferences.unnegotiated()
        let closed = Guarded(false)
        closedFlag = closed
        let wait = SessionWorkerWait(isCancelled: { closed.value })
        workerWait = wait
        if let binding = configuration.phoneControl, let environment = dependencies.phoneControl {
            phoneControl = PhoneControlAdapter(
                binding: binding, environment: environment, wait: wait, clock: dependencies.clock,
                closed: { closed.value })
        } else {
            phoneControl = nil
        }
        let signal = ControlSignal()
        controlSignal = signal
        stopDestination = SessionDestination.digest(configuration.link)
        offerAttempt = OfferAttempt(supported: configuration.protocolVersion >= 2)
        lanRecovery = LanRecovery(supported: false)
        metrics = SessionMetrics(mode: configuration.mode)
        recoveryMonitor = RecoveryMonitor(fastAccelerate: configuration.fastRecovery)
        microphoneDesiredMuted = Guarded(configuration.initiallyMicrophoneMuted)
        headsetRecovery = HeadsetRecovery(limitMs: configuration.bluetoothRecoveryMs)
        journal = StopReportJournal(
            header: SessionController.journalHeader(mode: configuration.mode),
            save: dependencies.journalSave)
        let route = LanSignalingRoute(host: configuration.link.endpoint.host.description, onChange: { signal.notify() })
        lanRoute = route
        signalingRoute = SignalingRoute(
            remote: configuration.isRemote, initialOrder: configuration.connectionPreferences.initialOrder,
            recoveryOrder: configuration.connectionPreferences.recoveryOrder)
        localTransport = dependencies.localTransport(route)
        localProbe = dependencies.localProbe(route)
        let host = OutputHostBridge()
        let playout = PlayoutEngineBridge()
        outputHost = host
        playoutBridge = playout
        microphoneHooks = MicrophoneHooksBridge()
        engineEvents = EngineEventsBridge()
        outputController = OutputRouteController(
            mode: configuration.mode,
            microphoneKind: configuration.microphoneSelection.kind,
            selection: configuration.outputSelection,
            initiallyEnabled: configuration.initiallyOutputEnabled,
            protectedDefaultSpeaker: configuration.protectedDefaultSpeaker,
            initialFocus: configuration.initialOutputFocus,
            host: host,
            engine: playout,
            inspector: AudioRouteInspector(arbiter: dependencies.arbiter),
            clock: dependencies.clock,
            bluetoothRecoveryMs: configuration.bluetoothRecoveryMs)
        host.owner = self
        playout.owner = self
        microphoneHooks.owner = self
        engineEvents.owner = self
    }

    /// Journal header (`StreamReceiver.kt:143-144`): `"MicDrop <version> · build <revision>\nSession mode:
    /// <direction>\nSession started at: <instant>"`.
    static func journalHeader(mode: StreamMode) -> String {
        let build = BuildInfo.current
        return "MicDrop \(build.versionName) · build \(build.revision)\nSession mode: \(mode.direction)\n"
            + "Session started at: \(DiagnosticTime.nowRFC3339())"
    }

    // MARK: - Derived values

    var mode: StreamMode { configuration.mode }
    var protocolVersion: Int { configuration.protocolVersion }
    var isRemote: Bool { configuration.isRemote }
    var usesMediaOutput: Bool { configuration.usesMediaOutput }
    /// Kotlin `microphoneReturn` (`mode.microphone`).
    var microphoneReturn: Bool { configuration.mode.hasMicrophone }
    var microphoneIsBluetooth: Bool { configuration.microphoneSelection.kind.isBluetooth }
    var isClosed: Bool { closedFlag.value }
    var stage: ConnectionStage { stageStorage.value }
    var networkHeld: Bool { networkHeldFlag.value }
    /// `/stop` timeout: 5000 ms remote / 2000 ms LAN (`StreamReceiver.kt:829`).
    var stopTimeoutMs: Int { configuration.connectionPreferences[isRemote ? .remoteStop : .lanStop] }
    /// Advanced "Keep microphone active while muted in background", read live (`SessionDependencies`).
    var keepMicrophoneActiveWhileMuted: Bool { dependencies.keepMicrophoneActiveWhileMuted() }

    /// Monotonic milliseconds including sleep.
    func nowMs() -> Int64 { dependencies.clock.nowMs() }

    // MARK: - Locks

    @discardableResult
    static func locked<R>(_ lock: NSRecursiveLock, _ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    @discardableResult
    func withCancelLock<R>(_ body: () throws -> R) rethrows -> R { try Self.locked(cancelLock, body) }

    @discardableResult
    func withAudioLock<R>(_ body: () throws -> R) rethrows -> R { try Self.locked(audioLock, body) }

    // MARK: - StreamReceiving: lifecycle

    func start() {
        let first = startedFlag.withLock { started -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        let thread = Thread { [self] in self.run() }
        thread.name = Timing.workerThreadName
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// (`StreamReceiver.kt:315-336`).
    func close(_ reason: StopReason) {
        let pending: [SessionRequestRegistration] = withCancelLock {
            if stopReasonStorage == nil { stopReasonStorage = reason }
            let transitioned = closedFlag.withLock { closed -> Bool in
                if closed { return false }
                closed = true
                return true
            }
            guard transitioned else { return [] }
            networkHandoff.stop()
            headsetRecovery.cancel()
            // Silence immediately, even if signalling is blocked. Destruction stays on the worker.
            withAudioLock {
                outputController.close()
                engine?.setSpeakerMuted(true)
                if microphoneReturn { closeMicrophoneSampleGateLocked() }
            }
            audioInterruptedFlag.value = false
            workerWait.cancel()
            let handles = [activeRequest, remoteStatusRequest].compactMap { $0 }
            activeRequest = nil
            remoteStatusRequest = nil
            return handles
        }
        // ControlRequestHandle.cancel only schedules the channel close; never blocks.
        for handle in pending { handle.cancel() }
        controlSignal.notify()
    }

    /// `StreamReceiver.fail` (`StreamReceiver.kt:338-347`): ignored once closed or once a stop reason exists; records
    /// `FailureEvidence` (stage at this moment, first `HTTPFailure` status in the cause chain), remembers the
    /// secure-signaling text, keeps the first message, closes with `.failure`.
    func fail(_ message: String, code: SessionFailure = .sessionException, error: Error? = nil) {
        withCancelLock {
            guard !isClosed, stopReasonStorage == nil else { return }
            stopReasonStorage = .failure
            let http = error.flatMap { SessionController.firstHTTPStatus($0) }
            failureEvidence = FailureEvidence(code: code, stage: stage, uptimeMs: nowMs(), httpStatus: http)
            if let error, let text = signalingFailureText(error) { lastSignalingFailureStorage.value = text }
            if failureMessage == nil { failureMessage = message }
            close(.failure)
        }
    }

    /// First `HTTPFailure` status within 8 cause levels (`StreamReceiver.kt:341`).
    static func firstHTTPStatus(_ error: Error) -> Int? {
        var current: Error? = error
        var depth = 0
        while let value = current, depth < 8 {
            if let http = value as? HTTPFailure { return http.status }
            current = (value as? UnderlyingErrorProviding)?.underlying
            depth += 1
        }
        return nil
    }

    // MARK: - Worker entry

    /// Thread body: setup + status loop, failure mapping, then strict cleanup
    /// (`StreamReceiver.kt:349-875`). Never call from any other thread.
    func run() {
        do {
            try runSession()
        } catch {
            // A Stop-caused SessionStopped is ignored here because the session is already closed.
            fail(
                ConnectionFailure.describe(stage: stage, error: error, action: mode.reconnectAction),
                code: SessionFailure.from(error), error: error)
        }
        cleanup()
    }

    /// `step(stage)` (`StreamReceiver.kt:877-883`): checkpoint, set stage, journal checkpoint
    /// `"setup_<stage>"`, status `"<label>…"`.
    func step(_ value: ConnectionStage) throws {
        try workerWait.checkpoint()
        stageStorage.value = value
        if journalActive { journal.checkpoint(Self.setupCheckpoint(value)) }
        emitStatus("\(value.label)…")
    }

    /// `"setup_" + stage.name.lowercase()` (`StreamReceiver.kt:356,880`), e.g. `setup_input_route`.
    static func setupCheckpoint(_ value: ConnectionStage) -> String { "setup_\(value.rawValue)" }

    /// Interruptible control-signal wait (`workerWait.await { controlSignal.wait(ms) }`,
    /// `StreamReceiver.kt:598,654,766-771`): throws `SessionStopped` if closed before or after.
    func waitForSignal(ms: Int) throws {
        try workerWait.checkpoint()
        if !isClosed { controlSignal.wait(ms: ms) }
        try workerWait.checkpoint()
    }

    // MARK: - Callback delivery (DispatchQueue.main.async)

    func emitStatus(_ text: String) {
        let callback = callbacks.onStatus
        DispatchQueue.main.async { callback(text) }
    }

    func emitDiagnostics(_ text: String) {
        let callback = callbacks.onDiagnostics
        DispatchQueue.main.async { callback(text) }
    }

    func emitPhase(_ phase: SessionPhase) {
        let callback = callbacks.onPhase
        DispatchQueue.main.async { callback(phase) }
    }

    func emitEnded(_ end: StreamEnd) {
        let callback = callbacks.onEnded
        DispatchQueue.main.async { callback(end) }
    }

    func emitNetworkStatus(_ text: String) {
        let callback = callbacks.onNetworkStatus
        DispatchQueue.main.async { callback(text) }
    }

    func emitOutputSelection(_ selection: OutputSelection) {
        let callback = callbacks.onOutputSelection
        DispatchQueue.main.async { callback(selection) }
    }

    func emitOutputState(pause: OutputPause?, protectedSpeaker: Bool) {
        let callback = callbacks.onOutputState
        DispatchQueue.main.async { callback(pause, protectedSpeaker) }
    }

    func emitMicrophoneState(muted: Bool, pending: Bool) {
        let callback = callbacks.onMicrophoneState
        DispatchQueue.main.async { callback(muted, pending) }
    }

    func emitMicrophoneSelection(_ selection: MicrophoneSelection) {
        let callback = callbacks.onMicrophoneSelection
        DispatchQueue.main.async { callback(selection) }
    }

    /// `MicrophoneControl.captureRetainedWhileMuted` changed; FIFO with `onMicrophoneState`.
    func emitMicrophoneCaptureRetained(_ retained: Bool) {
        let callback = callbacks.onMicrophoneCaptureRetained
        DispatchQueue.main.async { callback(retained) }
    }

    /// Successful verified Unmute, delivered outside the audio lock and FIFO with the state callbacks.
    func emitMicrophoneCaptureEnabled() {
        let callback = callbacks.onMicrophoneCaptureEnabled
        DispatchQueue.main.async { callback() }
    }
}

// MARK: - Small nested helpers (private to this owner; port-rules "Naming and access control")

extension SessionController {
    /// Lock-protected value shared between the worker and callback threads (Kotlin
    /// `AtomicBoolean` / `AtomicReference` / `@Volatile`).
    final class Guarded<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) { stored = value }

        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }

        @discardableResult
        func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body(&stored)
        }
    }

    /// Non-retryable protocol/setup violation (Kotlin `require`/`check` failures →
    /// `IllegalArgumentException`/`IllegalStateException`): classified `SETUP_FAILED` / `session_exception` by
    /// `ConnectionFailure.describe` / `SessionFailure.from` (last rows). The reason is a fixed label, never private
    /// data.
    struct ProtocolViolation: Error, CustomStringConvertible {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var description: String { reason }
    }
}
