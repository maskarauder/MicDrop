import Foundation
import MicDropCore

// Receiver-side output logic of one session: the `StreamReceiver.kt` output code on top of the pure MicDropCore state
// machines. One instance per `SessionController`.

/// What the output controller needs from the session engine (`OutputSessionHost`). Implemented by
/// `SessionController.OutputHostBridge`.
///
/// Threading contract (Android has one `audioLock` for the whole receiver; this keeps that shape):
/// - Lock order is session cancel lock → session audio lock → the controller's private lock
///   (`StreamReceiver.kt:1155-1161`). Both session locks must be **recursive** (Kotlin `synchronized`
///   is reentrant): `withCurrentOutput` invokes `fail`/`close` while holding them, and those take
///   them again before calling `OutputRouteController.close()`.
/// - Every state mutation of the controller runs inside `withAudioLock` (the session audio lock),
///   so the session may call the controller while holding its audio lock, and the controller's
///   engine mute (`OutputPlayoutEngine.setRemotePlayoutMuted`) may re-enter that lock.
/// - `isClosed`, `networkHeld`, `headsetRecoveryPending` are atomic reads (no cancel lock).
/// - `fail` and `close` are idempotent (first reason wins) and call `OutputRouteController.close()`
/// while marking the session closed.
/// - `publish*`, `output*Changed` and `wakeWorker` are called **outside** the controller's locks;
/// the host posts the first four to the main queue in FIFO order (callbacks).
protocol OutputSessionHost: AnyObject {
    /// `StreamReceiver.closed` (atomic).
    var isClosed: Bool { get }
    /// Network-recovery hold (`StreamReceiver.networkHeld`), part of the composite mute.
    var networkHeld: Bool { get }
    /// Bluetooth-headset microphone recovery pending (`headsetRecovery.pending()`), for `media_output`.
    var headsetRecoveryPending: Bool { get }
    /// Runs `body` while holding the session's (recursive) audio lock (`synchronized(audioLock)`).
    func withAudioLock<R>(_ body: () throws -> R) rethrows -> R
    /// Runs `body` while holding the session's cancel lock, then its audio lock (both recursive);
    /// used by `withCurrentOutput` (`StreamReceiver.kt:1155-1161`).
    func withSessionLocks<R>(_ body: () throws -> R) rethrows -> R
    /// `StreamReceiver.fail(message, code)`: records the failure and closes with `StopReason.failure`.
    func fail(_ message: String, code: SessionFailure)
    /// `StreamReceiver.close(reason)` (spelling). `.output` = wire `output_lost` (lost verified non-Bluetooth pin).
    func close(reason: StopReason)
    /// `onPhase` (e.g. `.switching` after an explicit selection).
    func publishPhase(_ phase: SessionPhase)
    /// `onStatus`.
    func publishStatus(_ text: String)
    /// `onOutputSelection` → service acceptance.
    func outputSelectionChanged(_ selection: OutputSelection)
    /// `onOutputState` → service acceptance.
    func outputStateChanged(pause: OutputPause?, protectedSpeaker: Bool)
    /// Wake the worker loop (`controlSignal.notifyAll()`).
    func wakeWorker()
}

/// What the output controller needs from the WebRTC engine (`OutputPlayoutEngine`). Implemented over `MediaEngine`
/// (which conforms) or by `PlayoutEngineBridge`, which exists before the engine and is passed at init; a direct engine
/// can instead be attached with `OutputRouteController.attach(engine:)` after the ADM exists.
protocol OutputPlayoutEngine: AnyObject {
    /// Remote audio track `isEnabled = !muted` through a dedicated serial queue that coalesces to the latest value.
    /// Called while the session audio lock (and the controller's lock) is held: it must **not block** and may take only
    /// the session audio lock (recursive) or leaf locks — never the cancel lock and never a WebRTC proxy call inline.
    func setRemotePlayoutMuted(_ muted: Bool)
    /// Playout-only restart (`isAudioEnabled` false → true); worker thread only; the controller calls it only in
    /// playback-only sessions while playout is not active.
    func restartPlayout() throws
    /// `PlayoutTap` activity (callback within 200 ms).
    var playoutActive: Bool { get }
    /// Running total of `didDetectPlayoutGlitch` (ADM-detected glitches; approximation of underruns).
    var playoutGlitches: Int64 { get }
    /// True between the monitor's interruption `.began` and `.ended` or session close.
    var interrupted: Bool { get }
}

/// Port of the `StreamReceiver` output logic.
///
/// One per session, owned by `SessionController`. All state machines are mutated only inside `withAudioLock` — the
/// host's session audio lock, then a private recursive lock — from the worker and from OS callbacks. Never calls into
/// WebRTC proxy objects while holding the lock (the engine's mute setter enqueues). `host` is assigned before the
/// controller is shared with another thread (init or right after) and never reassigned.
///
/// Callers: the host forwards `StreamReceiving.setOutputSelection/setOutputEnabled/setOutputFocus/
/// matchesOutputSelection/matchesOutputState/mediaOutputBecomingNoisy/outputSwitchPending` here; its
/// `PlayoutTap` edge and track-failure handlers call `playoutDidStart/playoutDidStop/trackFailed`;
/// its network hold and Bluetooth-headset paths call `applySpeakerMute/holdOutputGate/
/// verifyOutputGate`; its worker calls `startObservers`, `markMediaReady`, `step()` every iteration,
/// the diagnostics accessors, and `close()`/`stopObservers()` during teardown.
final class OutputRouteController: @unchecked Sendable {

    // MARK: - Constants (a)

    /// Fast probing window after any output event (`StreamReceiver.kt:203, 246, 263, 284, 932, 1101, 1184`).
    static let probeWindowMs: Int64 = 20_000
    /// Speaker repair: unverified wait before requesting a playout recreation (`StreamReceiver.kt:990`).
    static let speakerRestartWaitMs: Int64 = 1_000
    /// Bluetooth restore: unverified wait before requesting a recreation (`StreamReceiver.kt:1062`).
    static let bluetoothRestartWaitMs: Int64 = 2_000
    /// Default policy: paused wait before requesting a recreation (`StreamReceiver.kt:1143`).
    static let defaultRestartWaitMs: Int64 = 2_000
    /// Worker wait while a switch is pending or probing (`StreamReceiver.kt:598, 769`); used by the host.
    static let fastProbeStepMs: Int64 = 20

    // MARK: - Nested types

    /// Track error callbacks (`StreamReceiver.kt:437-441`) with iOS texts.
    enum TrackFailure: CaseIterable, Sendable {
        /// `audioSession(_:failedToSetActive:error:)` / engine start failure before playout ran.
        case initialization
        /// Playout failed to start.
        case start
        /// Media-server terminated / runtime playout failure.
        case runtime

        var message: String {
            switch self {
            case .initialization: return OutputRouteChange.Text.outputInitFailed
            case .start: return OutputRouteChange.Text.outputStartFailed
            case .runtime: return OutputRouteChange.Text.outputRuntimeFailed
            }
        }

        /// `output_init`, `output_start`, `output_runtime` (Go allow-list `session.go:61`).
        var code: SessionFailure {
            switch self {
            case .initialization: return .outputInit
            case .start: return .outputStart
            case .runtime: return .outputRuntime
            }
        }
    }

    /// The routing binding of one ticket (iOS replacement of the bound `AudioTrack` + its routing listener). Created by
    /// the worker's `bind`; route changes are reported for it (rule 3); cleared by `unbind`, recreation and teardown.
    struct Binding: Equatable, Sendable {
        let ticket: Int64
        let selection: OutputSelection
    }

    /// Last published `(pause, protectedSpeaker)` (`publishedOutput`, `StreamReceiver.kt:71`).
    private struct PublishedState: Equatable {
        let pause: OutputPause?
        let protectedSpeaker: Bool
    }

    // MARK: - Configuration

    let mode: StreamMode
    /// The session's microphone kind (`.builtIn` for playback-only sessions).
    let microphoneKind: MicrophoneKind
    /// `mode.hasPlayback` (Kotlin `mode.playback`).
    let playback: Bool
    /// `mode.hasMicrophone` (Kotlin `mode.microphone`).
    let microphone: Bool
    /// `mode.usesMediaOutput(microphoneKind)` = `playback && (!microphone || !kind.bluetooth)`
    /// (`StreamMode.kt:12`). When false every entry point is a no-op except the user silence gate.
    let usesMediaOutput: Bool
    let inspector: AudioRouteInspecting
    let clock: any MonotonicClock
    /// Set right after the host's own initialization (the host owns this controller).
    weak var host: OutputSessionHost?

    /// Route-change sink of this session; created and started by `startObservers()` on the worker.
    private(set) lazy var observer: OutputRouteObserver = OutputRouteObserver(controller: self, inspector: inspector)

    // MARK: - State (guarded by withAudioLock)

    /// Innermost lock (after the host's session audio lock); also the only lock without a host.
    private let audioLock = NSRecursiveLock()
    private var engine: OutputPlayoutEngine?
    private var gate: AudioOutputGate
    private let route: OutputRouteChange
    private let defaultOutput: DefaultOutputPolicy
    private let restarts = OutputRestartBudget()
    private let inventory = BluetoothRouteInventory()
    /// `OutputDeviceWatch.ports`: current outputs with a known kind.
    private var watchedPorts: Set<RouteOutput> = []
    private var outputFocus: OutputPause?
    private var outputRefresh = false
    private var outputWaitingSince: Int64?
    private var speakerBluetoothGeneration: Int64 = 0
    private var outputProbeUntil: Int64 = 0
    private var publishedOutput: PublishedState?
    /// `restartPlayout()` calls actually made (`output_control.playout_recreations`).
    private var outputRecreations = 0
    private var binding: Binding?
    /// The worker applied `overrideToSpeaker()` and has not cleared it yet (leaving PHONE clears it in the next
    /// DEFAULT/external bind and at teardown; clearing is worker-initiated).
    private var speakerOverrideApplied = false
    private var closed = false
    private var mediaReady = false
    private var trackStarted = false
    private var outputRestarting = false
    /// A media-services reset was observed: no playout recreation for the rest of the session.
    private var mediaServicesResetObserved = false
    private var routeChangeCount = 0

    // MARK: - Init

    /// signature. `host` and `engine` are passed here (passes its bridges) or, for `engine`, attached later with
    /// `attach(engine:)`; `host` must be set before first use.
    /// - Parameters:
    ///   - selection: the session's initial output selection (already refreshed by the service).
    ///   - initiallyEnabled: the user's "Play desktop audio" request.
    ///   - protectedDefaultSpeaker: carried across reconnects by the service.
    ///   - initialFocus: always nil on iOS.
    ///   - bluetoothRecoveryMs: the session's Advanced Bluetooth route recovery window (default 20 s).
    init(
        mode: StreamMode, microphoneKind: MicrophoneKind, selection: OutputSelection,
        initiallyEnabled: Bool, protectedDefaultSpeaker: Bool, initialFocus: OutputPause? = nil,
        host: OutputSessionHost? = nil, engine: OutputPlayoutEngine? = nil,
        inspector: AudioRouteInspecting, clock: any MonotonicClock,
        bluetoothRecoveryMs: Int64 = OutputRouteChange.bluetoothRecoveryMs
    ) {
        self.mode = mode
        self.microphoneKind = microphoneKind
        self.playback = mode.hasPlayback
        self.microphone = mode.hasMicrophone
        self.usesMediaOutput = mode.usesMediaOutput(microphoneKind)
        self.inspector = inspector
        self.clock = clock
        self.host = host
        self.engine = engine
        self.gate = AudioOutputGate.session(
            initiallyEnabled: initiallyEnabled, playback: mode.hasPlayback,
            bluetoothMicrophone: mode.hasMicrophone && microphoneKind.isBluetooth,
            selection: selection)
        self.route = OutputRouteChange(selection, bluetoothRecoveryMs: bluetoothRecoveryMs)
        self.defaultOutput = DefaultOutputPolicy(selection, protectedSpeaker: protectedDefaultSpeaker)
        self.outputFocus = initialFocus
    }

    // MARK: - Engine attachment (worker)

    /// After ADM creation (`StreamReceiver.kt:443-447`): under the lock, if closed → `gate.stop()`; apply the composite
    /// mute so the gate exists before the track.
    func attach(engine: OutputPlayoutEngine) {
        withAudioLock {
            self.engine = engine
            if isClosedLocked { gate.stop() }
            applyMuteLocked()
        }
    }

    /// Teardown after the engine closed (before factory release): drops the engine and the binding; later mute requests
    /// are no-ops.
    func detachEngine() {
        withAudioLock {
            engine = nil
            binding = nil
        }
    }

    // MARK: - Queries

    /// The current (ticketed) selection.
    var selection: OutputSelection {
        withAudioLock { route.selection }
    }

    /// `outputGate.enabled` (the user's request).
    func outputEnabled() -> Bool {
        withAudioLock { gate.enabled }
    }

    /// `usesMediaOutput && outputRoute.pending && outputRoute.selection.explicit`.
    func outputSwitchPending() -> Bool {
        guard usesMediaOutput else { return false }
        return withAudioLock { route.pending && route.selection.explicit }
    }

    /// This session's selected-Bluetooth restore window (`route.bluetoothRecoveryLimitMs`: the Advanced value fixed
    /// at Connect, default 20 s).
    var bluetoothRecoveryLimitMs: Int64 {
        withAudioLock { route.bluetoothRecoveryLimitMs }
    }

    /// `outputRoute.recovering`: the existing selection is being restored (selected Bluetooth or speaker
    /// repair), as opposed to a newly requested output being verified (heartbeat phase rule: switch
    /// pending && !recovering → SWITCHING).
    func selectedOutputRecovering() -> Bool {
        withAudioLock { route.recovering }
    }

    /// `usesMediaOutput && !selection.explicit && now < outputProbeUntil` (20 ms worker cadence).
    func outputProbing() -> Bool {
        guard usesMediaOutput else { return false }
        let now = clock.nowMs()
        return withAudioLock { !route.selection.explicit && now < outputProbeUntil }
    }

    /// Phase the worker publishes after a heartbeat (`StreamReceiver.kt:687-689`, `SessionPhase.heartbeat`),
    /// read as one snapshot under the audio lock: SWITCHING only while a newly requested output is verified;
    /// recovery of the existing selection (`selectedOutputRecovering()`), headset recovery and default-route
    /// probing are ROUTE_RECOVERING, in which the output chooser stays usable. Gates are not changed here.
    func heartbeatPhase(headsetRecovering: Bool, healthy: Bool) -> SessionPhase {
        withAudioLock {
            SessionPhase.heartbeat(
                outputSwitchPending: outputSwitchPending(), selectedOutputRecovering: selectedOutputRecovering(),
                routeRecovering: headsetRecovering || outputProbing(), healthy: healthy)
        }
    }

    /// `!closed && outputRoute.selection == s` (`StreamReceiver.kt:166-168`).
    func matchesOutputSelection(_ s: OutputSelection) -> Bool {
        withAudioLock { !isClosedLocked && route.selection == s }
    }

    /// `!closed && outputPauseLocked() == pause && (usesMediaOutput && speakerProtected) == protectedSpeaker`.
    func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool {
        withAudioLock {
            !isClosedLocked && pauseLocked() == pause
                && (usesMediaOutput && defaultOutput.speakerProtected) == protectedSpeaker
        }
    }

    /// `playbackPaused()` / `outputPauseLocked()`.
    func currentPause() -> OutputPause? {
        withAudioLock { pauseLocked() }
    }

    /// Composite playback mute: `gate.muted || networkHeld || (usesMediaOutput && (defaultOutput.held || outputFocus !=
    /// nil))`.
    var speakerMuted: Bool {
        withAudioLock { speakerMutedLocked }
    }

    /// The permanent PHONE pin can force the speaker in this session: the session category allows the override and iOS
    /// would not take a wired/USB microphone away.
    var speakerPinnable: Bool {
        inspector.speakerOverrideSupported && (!microphone || microphoneKind == .builtIn)
    }

    // MARK: - Commands (any thread)

    /// `setOutputSelection` (`StreamReceiver.kt:278-291`).
    func setOutputSelection(_ s: OutputSelection) {
        guard usesMediaOutput else { return }
        let now = clock.nowMs()
        let accepted: Bool = withAudioLock {
            guard !isClosedLocked, route.request(s) else { return false }
            speakerBluetoothGeneration = inventory.generation
            defaultOutput.select(s)
            restarts.newRoute()
            outputWaitingSince = nil
            outputProbeUntil = now + OutputRouteController.probeWindowMs
            gate.hold()
            muteLocked()
            return true
        }
        guard accepted else { return }
        if s.explicit { host?.publishPhase(.switching) }
        publishOutputState()
        host?.publishStatus(OutputRouteChange.Text.switching)
        host?.wakeWorker()
    }

    /// `setOutputEnabled` (`StreamReceiver.kt:293-299`): user silence takes effect immediately;
    /// enabling unmutes only when no hold/pause/network hold is active. No phase/status change.
    func setOutputEnabled(_ enabled: Bool) {
        guard playback else { return }
        withAudioLock {
            guard !isClosedLocked else { return }
            gate.request(enabled)
            applyMuteLocked()
        }
    }

    /// `setOutputFocus` (`StreamReceiver.kt:182-189`). Never driven on iOS; kept for parity.
    func setOutputFocus(_ pause: OutputPause?) {
        guard usesMediaOutput else { return }
        let changed: Bool = withAudioLock {
            guard !isClosedLocked else { return false }
            outputFocus = pause
            applyMuteLocked()
            return true
        }
        guard changed else { return }
        publishOutputState()
        host?.wakeWorker()
    }

    /// `setSpeakerMute(speakerMuted)`: re-applies the composite mute. The host calls it after engine publication
    /// (`StreamReceiver.kt:446`) and whenever `networkHeld` is released (`:1549`). Applies in every mode (the user gate
    /// also covers Bluetooth-headset duplex).
    func applySpeakerMute() {
        withAudioLock { applyMuteLocked() }
    }

    /// `outputGate.hold(); setSpeakerMute(true)` for the playback half of a Bluetooth-headset duplex
    /// session, where `usesMediaOutput == false` and the microphone subsystem owns the coupled route
    /// (`StreamReceiver.kt:1352, 1525`: input route lost, network hold). No-op unless `playback`;
    /// harmless after close (a stopped gate stays muted).
    func holdOutputGate() {
        guard playback else { return }
        withAudioLock {
            gate.hold()
            muteLocked()
        }
    }

    /// `outputGate.verified(); setSpeakerMute(speakerMuted)` after the microphone path verified the
    /// same headset output (`StreamReceiver.kt:1309, 1321, 1490`). Never undoes user silence or Stop.
    /// No-op unless `playback`; the caller checks closed/pending conditions as Android does.
    func verifyOutputGate() {
        guard playback else { return }
        withAudioLock {
            gate.verified()
            applyMuteLocked()
        }
    }

    // MARK: - OS callbacks (any thread; only gate and wake, native work stays on the worker)

    /// "Becoming noisy" (`StreamReceiver.kt:193-208`): DEFAULT → `defaultOutput.noisy()`; Bluetooth pin
    /// → `holdSelectedBluetoothOutput`; other pins → `gate.hold()`; mute; refresh; 20 s probing.
    /// "The broadcast describes a global media change. It does not establish loss of this app's pinned
    /// speaker or authorize stopping independent capture." Returns false when not using media output
    /// or closed.
    ///
    /// Two callers per notification, as on Android (noisy broadcast + device callbacks): the observer synchronously on
    /// the notification thread (rule 1, so the hold precedes the worker's next route read) and the coordinator's noisy
    /// rule on main (via `StreamReceiving.mediaOutputBecomingNoisy()`). Every effect is idempotent, so the repeat only
    /// renews the 20 s probing window.
    @discardableResult
    func mediaOutputBecomingNoisy() -> Bool {
        guard usesMediaOutput else { return false }
        let now = clock.nowMs()
        let handled: Bool = withAudioLock {
            guard !isClosedLocked else { return false }
            if !route.selection.explicit {
                defaultOutput.noisy()
            } else if route.selection.kind.isBluetooth {
                holdSelectedBluetoothOutputLocked(now)
            } else {
                gate.hold()
            }
            muteLocked()
            outputRefresh = true
            outputProbeUntil = now + OutputRouteController.probeWindowMs
            return true
        }
        guard handled else { return false }
        publishOutputState()
        host?.wakeWorker()
        return true
    }

    /// `OutputDeviceWatch.refresh` semantics (rule 2): updates the Bluetooth inventory (`bluetoothAdded` may advance
    /// its generation) and calls `outputDevicesChanged(bluetoothRemoved:)` iff the known-kind output set changed, or
    /// `bluetoothRemoved || bluetoothAdded`.
    func outputDevicesObserved(_ current: [RouteOutput], bluetoothRemoved: Bool, bluetoothAdded: Bool) {
        let changed: Bool = withAudioLock {
            let latest = Set(current.filter { $0.kind != nil })
            inventory.update(current, bluetoothAdded: bluetoothAdded)
            let differs = latest != watchedPorts || bluetoothRemoved || bluetoothAdded
            watchedPorts = latest
            return differs
        }
        if changed { outputDevicesChanged(bluetoothRemoved: bluetoothRemoved) }
    }

    /// Device inventory changed (`StreamReceiver.kt:227-249`).
    func outputDevicesChanged(bluetoothRemoved: Bool) {
        guard usesMediaOutput else { return }
        let now = clock.nowMs()
        let woke: Bool = withAudioLock {
            guard !isClosedLocked else { return false }
            if route.selection.kind.isBluetooth {
                if mediaReady { holdSelectedBluetoothOutputLocked(now) } else { outputRefresh = true }
            } else if route.selection.explicit {
                // "A temporary speaker choice keeps listening for Bluetooth return. The worker clears
                // the pin; callbacks do no native work." A pinned non-Bluetooth output ignores inventory.
                guard route.selection.temporarySpeaker else { return false }
                gate.hold()
            } else {
                if bluetoothRemoved { defaultOutput.noisy() } else { defaultOutput.changing() }
                restarts.newRoute()
            }
            muteLocked()
            outputRefresh = true
            outputWaitingSince = nil
            outputProbeUntil = now + OutputRouteController.probeWindowMs
            return true
        }
        if woke { host?.wakeWorker() }
    }

    /// Route changed for the bound "track" (`StreamReceiver.kt:1178-1201`): ignored when closed or for another ticket.
    /// DEFAULT → `changing()`, mute, 20 s probing. Bluetooth pin not verifying → `holdSelectedBluetoothOutput` ("do not
    /// start another recovery simply because our own rebind was acknowledged"). Other pins not verifying → PHONE:
    /// speaker repair; else `lost` → hold. While interrupted (`outputFocus != nil` or `engine.interrupted`) no loss is
    /// evaluated.
    func outputRouteChanged(ticket: Int64, selection selected: OutputSelection) {
        let now = clock.nowMs()
        let handled: Bool = withAudioLock {
            guard !isClosedLocked, route.ticket == ticket else { return false }
            if !selected.explicit {
                defaultOutput.changing()
                muteLocked()
                outputProbeUntil = now + OutputRouteController.probeWindowMs
            }
            if interruptedLocked { return true }
            if selected.kind.isBluetooth {
                if !boundVerifiesLocked(ticket, selected) { holdSelectedBluetoothOutputLocked(now) }
            } else if selected.explicit && !boundVerifiesLocked(ticket, selected) {
                if selected.kind == .phone {
                    holdSelectedSpeakerOutputLocked(now)
                } else if route.lost(ticket) {
                    gate.hold()
                    muteLocked()
                }
            }
            return true
        }
        guard handled else { return }
        publishOutputState()
        host?.wakeWorker()
    }

    /// rule 3: if a binding exists, report the route change for its ticket/selection.
    func boundRouteChanged() {
        let bound = withAudioLock { binding }
        if let bound { outputRouteChanged(ticket: bound.ticket, selection: bound.selection) }
    }

    /// `PlayoutTap` rising edge (`StreamReceiver.kt:409-418`): `trackStarted = true`; then
    /// `outputRoute.trackStarted()`, `defaultOutput.changing()`, `gate.hold()`, mute — a fresh 5 s verification (also
    /// after an interruption ended).
    func playoutDidStart() {
        withAudioLock {
            trackStarted = true
            guard usesMediaOutput, !isClosedLocked else { return }
            route.trackStarted()
            defaultOutput.changing()
            gate.hold()
            muteLocked()
        }
    }

    /// `PlayoutTap` falling edge (`StreamReceiver.kt:419-425`): `trackStarted = false`; `recoverableOutputFailed()`
    /// when media is ready and playout is not being restarted. Ignored while interrupted or closed. The
    /// Bluetooth-microphone branch stays with the host.
    func playoutDidStop() {
        let recover: Bool = withAudioLock {
            trackStarted = false
            return mediaReady && !outputRestarting && !interruptedLocked && !isClosedLocked
        }
        if recover { recoverableOutputFailed() }
    }

    /// `recoverableOutputFailed()` (`StreamReceiver.kt:251-267`): Bluetooth pin → hold selected
    /// Bluetooth; PHONE → false for an initial verification failure (`pending && !recovering`), else
    /// speaker repair; other explicit → false; DEFAULT → `unavailable()`, mute. Tail: request a playout
    /// recreation, reset the wait, 20 s probing, wake. Returns whether the failure is recoverable.
    @discardableResult
    func recoverableOutputFailed() -> Bool {
        guard usesMediaOutput else { return false }
        let now = clock.nowMs()
        let recoverable: Bool = withAudioLock {
            guard !isClosedLocked else { return false }
            let selected = route.selection
            if selected.kind.isBluetooth {
                holdSelectedBluetoothOutputLocked(now)
            } else if selected.kind == .phone {
                if route.pending && !route.recovering { return false }
                holdSelectedSpeakerOutputLocked(now)
            } else {
                if selected.explicit { return false }
                defaultOutput.unavailable()
                muteLocked()
            }
            restarts.request()
            outputWaitingSince = nil
            outputProbeUntil = now + OutputRouteController.probeWindowMs
            return true
        }
        if recoverable { host?.wakeWorker() }
        return recoverable
    }

    /// Track error callbacks (`StreamReceiver.kt:437-441`): `if !recoverableOutputFailed() { fail(...) }`
    /// with `output_init` / `output_start` / `output_runtime` and the iOS texts.
    func trackFailed(_ failure: TrackFailure) {
        if !recoverableOutputFailed() { host?.fail(failure.message, code: failure.code) }
    }

    /// `mediaServicesWereReset` (which overrides `recoverableOutputFailed()`): every audio object is invalid and the
    /// session ends with `.failure`, so this requests no recovery and blocks every later playout recreation
    /// (`restartPlayout()` would re-run the WebRTC session configuration); nothing is re-applied until the next
    /// explicit Connect. Any thread; called by the observer before the engine's sink ends the session, and by that
    /// session handler.
    func mediaServicesWereReset() {
        withAudioLock { mediaServicesResetObserved = true }
    }

    /// Counts one route change for the iOS recovery epoch; called by the observer.
    func noteRouteChangeForRecoveryEpoch() {
        withAudioLock { routeChangeCount += 1 }
    }

    // MARK: - Worker integration

    /// Starts the route-change sink (`StreamReceiver.kt:360`), only when `usesMediaOutput`.
    func startObservers() {
        guard usesMediaOutput else { return }
        observer.start()
    }

    /// Cleanup steps `output_observers_close` / `input_observers_close`, worker only: stops the sink, drops the routing
    /// binding and clears a speaker override this session applied (best effort; errors ignored). Idempotent.
    func stopObservers() {
        if usesMediaOutput { observer.stop() }
        let clearOverride: Bool = withAudioLock {
            let applied = speakerOverrideApplied
            speakerOverrideApplied = false
            binding = nil
            return applied
        }
        if clearOverride { try? inspector.clearSpeakerOverride() }
    }

    /// `mediaReady = true` after `/answer` was submitted (`StreamReceiver.kt:550`).
    func markMediaReady() {
        withAudioLock { mediaReady = true }
    }

    /// `updateOutputRoute()` (`StreamReceiver.kt:885-919`); call every worker iteration. Dispatcher:
    /// `returnToDefaultOutput()`; DEFAULT → `updateDefaultOutput()`; Bluetooth pin → `updateBluetoothOutput()`; other
    /// pins: invalid → `close(reason: .output)`; verified steady state → release the temporary hold if the route still
    /// verifies, else `outputRouteChanged` + invalid check; pending → `updatePinnedOutput()`. While interrupted the
    /// pinned verification branches are skipped.
    func step() {
        guard usesMediaOutput, !isClosed else { return }
        returnToDefaultOutput()
        let kind: (explicit: Bool, bluetooth: Bool) = withAudioLock {
            (route.selection.explicit, route.selection.kind.isBluetooth)
        }
        if !kind.explicit {
            updateDefaultOutput()
            return
        }
        if kind.bluetooth {
            updateBluetoothOutput()
            return
        }
        let request: (id: Int64, selected: OutputSelection, pending: Bool, invalid: Bool, interrupted: Bool) =
            withAudioLock { (route.ticket, route.selection, route.pending, route.invalid, interruptedLocked) }
        if request.invalid {
            withCurrentOutput(request.id) { if route.invalid { host?.close(reason: .output) } }
            return
        }
        if request.interrupted { return }
        if !request.pending {
            if boundVerifies(request.id, request.selected) {
                // "A global noisy broadcast may concern another Bluetooth device. The actual pinned track
                // is sufficient to clear its temporary hold, without changing focus or user silence."
                withCurrentOutput(request.id) {
                    outputRefresh = false
                    gate.verified()
                    applyMuteLocked()
                }
                publishOutputState()
            } else {
                outputRouteChanged(ticket: request.id, selection: request.selected)
                withCurrentOutput(request.id) { if route.invalid { host?.close(reason: .output) } }
            }
            return
        }
        updatePinnedOutput()
    }

    /// `close(reason)` output part (`StreamReceiver.kt:315-336`) and cleanup `local_audio_gates`:
    /// `gate.stop()`, `route.stop()`, `defaultOutput.stop()`, `restarts.stop()`, mute — "Silence
    /// immediately, even if signaling is blocked." Idempotent; called by the host while it marks the
    /// session closed (under its cancel lock) and again in the worker's teardown.
    func close() {
        withAudioLock {
            closed = true
            gate.stop()
            route.stop()
            defaultOutput.stop()
            restarts.stop()
            muteLocked()
        }
    }

    /// `publishOutputState()` (`StreamReceiver.kt:269-276`): publishes `(pause, protectedSpeaker)` to
    /// the host when it changed and the session is not closed (callback outside the lock).
    func publishOutputState() {
        let next: PublishedState? = withAudioLock {
            let value = PublishedState(
                pause: pauseLocked(),
                protectedSpeaker: usesMediaOutput && defaultOutput.speakerProtected)
            if isClosedLocked || value == publishedOutput { return nil }
            publishedOutput = value
            return value
        }
        if let next { host?.outputStateChanged(pause: next.pause, protectedSpeaker: next.protectedSpeaker) }
    }

    // MARK: - Diagnostics

    /// `output_control` (`StreamReceiver.kt:1169-1176`) with the iOS constants; the terminal copy is taken after close,
    /// so its phase is `stopped`. Include it only when `usesMediaOutput && output_control_diagnostics_version == 1`.
    func controlSnapshot() -> OutputControlSnapshot {
        withAudioLock {
            OutputControlSnapshot(
                selection: route.selection.kind,
                requestedEnabled: gate.enabled,
                phase: OutputControlSnapshot.Phase.of(
                    closed: isClosedLocked, recovering: route.recovering,
                    pending: route.pending, defaultHeld: defaultOutput.held),
                pause: pauseLocked(),
                playoutRecreations: outputRecreations)
        }
    }

    /// Always nil on iOS v1: the report carries `"output": null` until the host accepts an iOS backend label. Kept as
    /// the single call site.
    func outputSnapshot() -> OutputSnapshot? {
        nil
    }

    /// Route changes counted for the recovery epoch while the sink is started.
    var audioRouteChangeCount: Int {
        withAudioLock { routeChangeCount }
    }

    /// iOS `RecoveryMonitor` epoch `(1, audioRouteChangeCount)`.
    func recoveryEpoch() -> (Int, Int) {
        (1, audioRouteChangeCount)
    }

    /// `media_output` report label (`StreamReceiver.kt:704`): `running` iff playout started, not
    /// muted, no headset recovery pending and no output switch pending; else `waiting`.
    func mediaOutputLabel() -> String {
        let headsetPending = host?.headsetRecoveryPending ?? false
        let playing: Bool = withAudioLock { trackStarted && !speakerMutedLocked }
        let running = playing && !headsetPending && !outputSwitchPending()
        return running ? "running" : "waiting"
    }

    /// `App audio output: enabled|silenced` plus the current pause detail line, if any
    /// (`StreamReceiver.kt:741-742`); a selected-Bluetooth pause names this session's configured window.
    func audioOutputLines() -> [String] {
        withAudioLock {
            var lines = ["App audio output: " + (gate.enabled ? "enabled" : "silenced")]
            if let pause = pauseLocked() {
                lines.append(pause.detail(bluetoothRecoveryMs: route.bluetoothRecoveryLimitMs))
            }
            return lines
        }
    }

    /// Selection lines (`StreamReceiver.kt:743-748`): `App output selection: …` (playback modes),
    /// `Selected output identity: current route device` (Bluetooth pin), and `recoveryText()`
    /// (media output; may contain a newline). The host interleaves them like Android.
    func selectionLines() -> [String] {
        withAudioLock {
            var lines: [String] = []
            if playback {
                lines.append(
                    OutputRouteChange.Text.appOutputSelection(
                        usesMediaOutput: usesMediaOutput, selection: route.selection,
                        recovering: route.recovering, pending: route.pending))
            }
            if usesMediaOutput && route.selection.kind.isBluetooth {
                lines.append(OutputRouteChange.Text.selectedIdentity)
            }
            if usesMediaOutput { lines.append(recoveryTextLocked()) }
            return lines
        }
    }

    /// `audioOutputLines() + selectionLines()` for callers that do not interleave.
    func diagnosticsLines() -> [String] {
        audioOutputLines() + selectionLines()
    }

    /// `outputRecoveryText()` (`StreamReceiver.kt:1163-1167`, iOS wording). The final copy-report text replaces earlier
    /// `Output recovery:` / `System Bluetooth route:` lines with this.
    func recoveryText() -> String {
        withAudioLock { recoveryTextLocked() }
    }

    // MARK: - Private: locking and composite state

    /// Android `synchronized(audioLock)`: the host's session audio lock, then the private lock (lock
    /// order of `OutputSessionHost`). Without a host (unit tests) only the private lock is taken.
    private func withAudioLock<T>(_ body: () -> T) -> T {
        guard let host else { return withPrivateLock(body) }
        return host.withAudioLock { withPrivateLock(body) }
    }

    private func withPrivateLock<T>(_ body: () -> T) -> T {
        audioLock.lock()
        defer { audioLock.unlock() }
        return body()
    }

    /// Own `closed` flag or the host's (atomic) one.
    private var isClosed: Bool {
        withAudioLock { isClosedLocked }
    }

    private var isClosedLocked: Bool {
        closed || (host?.isClosed ?? false)
    }

    /// `outputFocus != nil || engine.interrupted`.
    private var interruptedLocked: Bool {
        outputFocus != nil || (engine?.interrupted ?? false)
    }

    private var speakerMutedLocked: Bool {
        gate.muted || (host?.networkHeld ?? false)
            || (usesMediaOutput && (defaultOutput.held || outputFocus != nil))
    }

    private func pauseLocked() -> OutputPause? {
        OutputPause.current(
            usesMediaOutput: usesMediaOutput, focus: outputFocus, route: route,
            policy: defaultOutput, bluetoothAvailable: inventory.available)
    }

    /// `setSpeakerMute(true)`.
    private func muteLocked() {
        engine?.setRemotePlayoutMuted(true)
    }

    /// `setSpeakerMute(speakerMuted)`.
    private func applyMuteLocked() {
        engine?.setRemotePlayoutMuted(speakerMutedLocked)
    }

    private func recoveryTextLocked() -> String {
        OutputRouteChange.Text.outputRecovery(recreations: outputRecreations, selection: route.selection)
    }

    /// `holdSelectedBluetoothOutput(now)` (`StreamReceiver.kt:212-218`): the first call of an episode
    /// starts the fixed window (`route.bluetoothRecoveryLimitMs`, Advanced, default 20 s) and renews the
    /// restart budget; every call holds and mutes, and repeated calls never extend the window.
    private func holdSelectedBluetoothOutputLocked(_ now: Int64) {
        if route.recoverBluetooth(route.ticket, nowMs: now) {
            restarts.newRoute()
            outputWaitingSince = nil
        }
        gate.hold()
        muteLocked()
        outputRefresh = true
    }

    /// `holdSelectedSpeakerOutput(now)` (`StreamReceiver.kt:220-225`): speaker repair (5 s) from a
    /// verified PHONE pin only.
    private func holdSelectedSpeakerOutputLocked(_ now: Int64) {
        if route.recoverSpeaker(route.ticket, nowMs: now) {
            restarts.newRoute()
            outputWaitingSince = nil
        }
        gate.hold()
        muteLocked()
        outputRefresh = true
    }

    /// `withCurrentOutput(id, op)` (`StreamReceiver.kt:1155-1161`): session cancel lock, then audio lock
    /// (`host.withSessionLocks`), then the private lock; runs `operation` only if not closed and
    /// `ticket == id`. "An old failed request cannot stop a newer choice between checking its ticket
    /// and marking the stream closed." `operation` may call `host.fail`/`host.close` (recursive locks).
    /// No host → nothing to fail or close → no-op.
    private func withCurrentOutput(_ id: Int64, _ operation: () -> Void) {
        guard let host else { return }
        host.withSessionLocks {
            withAudioLock {
                if !isClosedLocked && route.ticket == id { operation() }
            }
        }
    }

    // MARK: - Private: binding (iOS replacement of WebRtcOutputRouting)

    /// Routed outputs of the bound ticket: nil unless a binding for `id` exists and playout started (Android
    /// `devices()` returns the bound track's routed devices only while PLAYING); else the session-wide current route
    /// (MicDrop has one audio graph).
    private func boundOutputsLocked(_ id: Int64) -> [RouteOutput]? {
        guard let binding, binding.ticket == id, trackStarted else { return nil }
        return inspector.currentRouteOutputs()
    }

    private func boundVerifiesLocked(_ id: Int64, _ selected: OutputSelection) -> Bool {
        selected.verifies(boundOutputsLocked(id) ?? [])
    }

    private func boundVerifies(_ id: Int64, _ selected: OutputSelection) -> Bool {
        withAudioLock { boundVerifiesLocked(id, selected) }
    }

    /// `outputRouting.clear()`: forget the binding so the next `bind` re-applies (e.g. the speaker override after every
    /// route change). An applied override stays until the next bind decides to keep, re-apply or clear it.
    private func unbind() {
        withAudioLock { binding = nil }
    }

    /// `bind(id, selected)` tri-state, worker only, never under the audio lock while calling the inspector's override:
    /// nil = no engine yet (track not accessible); idempotent `true` for the same ticket + selection.
    /// - DEFAULT: clear an applied speaker override (`speakerOverrideApplied`) → true.
    /// - PHONE permanent: if `speakerPinnable` apply `overrideToSpeaker()` once per ticket (throw → false);
    /// else true iff the route already is the built-in speaker (`.playback` row), else false.
    /// - PHONE temporary: no override when the route already is the speaker (keeps Bluetooth return
    ///   visible) → true; else override if `speakerPinnable` (throw → false), otherwise false.
    /// - External pins: clear an applied override; true iff the route contains the pinned output; else
    ///   nil for Bluetooth (wait) / false for non-Bluetooth.
    /// Records `Binding(ticket: id, selection: selected)` whenever it returns true.
    private func bind(_ id: Int64, _ selected: OutputSelection) -> Bool? {
        let state = withAudioLock { (engine != nil, binding, speakerOverrideApplied, isClosedLocked, route.ticket) }
        guard state.0, !state.3, state.4 == id else { return nil }
        if state.1 == Binding(ticket: id, selection: selected) { return true }
        var accepted: Bool?
        do {
            if selected.kind == .phone {
                if selected.temporarySpeaker && inspector.routeIsBuiltInSpeaker {
                    accepted = true
                } else if speakerPinnable {
                    try inspector.overrideToSpeaker()
                    withAudioLock { speakerOverrideApplied = true }
                    accepted = true
                } else {
                    accepted = inspector.routeIsBuiltInSpeaker
                }
            } else {
                if state.2 {
                    try inspector.clearSpeakerOverride()
                    withAudioLock { speakerOverrideApplied = false }
                }
                if !selected.explicit {
                    accepted = true
                } else if selected.resolve(inspector.currentRouteOutputs()) != nil {
                    accepted = true
                } else {
                    accepted = selected.kind.isBluetooth ? nil : false
                }
            }
        } catch { return false }
        if accepted == true {
            let current = withAudioLock { () -> Bool in
                guard !isClosedLocked, route.ticket == id, route.selection == selected else { return false }
                binding = Binding(ticket: id, selection: selected)
                return true
            }
            if !current { return nil }
        }
        return accepted
    }

    // MARK: - Private: worker steps

    /// `returnToDefaultOutput()` (`StreamReceiver.kt:921-940`).
    private func returnToDefaultOutput() {
        let returned: OutputSelection? = withAudioLock {
            let bluetoothReturned = inventory.available && inventory.generation > speakerBluetoothGeneration
            guard !isClosedLocked, route.returnToDefault(route.ticket, bluetoothReturned: bluetoothReturned) else {
                return nil
            }
            let selected = route.selection
            defaultOutput.select(selected, protectSpeakerOnReturn: true)
            restarts.newRoute()
            outputWaitingSince = nil
            outputProbeUntil = clock.nowMs() + Self.probeWindowMs
            outputRefresh = true
            gate.hold()
            muteLocked()
            return selected
        }
        guard let returned else { return }
        host?.outputSelectionChanged(returned)
        publishOutputState()
        host?.publishStatus(OutputRouteChange.Text.bluetoothReturned)
    }

    /// `updateDefaultOutput()` (`StreamReceiver.kt:1093-1153`).
    private func updateDefaultOutput() {
        let now = clock.nowMs()
        let work: (Bool, Bool)? = withAudioLock {
            guard !isClosedLocked, !route.selection.explicit, !interruptedLocked else { return nil }
            let work = (restarts.take(nowMs: now), outputRefresh)
            outputRefresh = false
            return work
        }
        guard let work else { return }
        if work.0 { recreateOutput() } else if work.1 { unbind() }
        let current = withAudioLock { (route.ticket, route.selection) }
        let (id, selected) = current
        guard !selected.explicit, !isClosed else { return }
        let accepted = bind(id, selected)
        let changed = withAudioLock { () -> Bool in
            guard !isClosedLocked, !interruptedLocked, route.ticket == id, !route.selection.explicit else {
                return false
            }
            let outputs = accepted == true ? boundOutputsLocked(id) : nil
            let kinds: [OutputKind]? = outputs.flatMap { ports in
                let kinds = ports.compactMap { $0.kind }
                return !ports.isEmpty && kinds.count == ports.count ? kinds : nil
            }
            if accepted == false || !trackStarted {
                defaultOutput.unavailable()
                restarts.request()
            } else {
                defaultOutput.observe(kinds)
            }
            if defaultOutput.pause == nil { restarts.settled() }
            let changed = accepted == true && route.verified(id)
            if changed { gate.verified() }
            if defaultOutput.pause != nil && (kinds == nil || inventory.available) {
                if outputWaitingSince == nil { outputWaitingSince = now }
                if let since = outputWaitingSince, now - since >= Self.defaultRestartWaitMs { restarts.request() }
            } else {
                outputWaitingSince = nil
            }
            let pause = defaultOutput.pauseForInventory(bluetoothAvailable: inventory.available)
            if pause == nil || (pause == .bluetooth && !inventory.available) { outputProbeUntil = 0 }
            applyMuteLocked()
            return changed
        }
        if changed { host?.outputSelectionChanged(selected) }
        publishOutputState()
    }

    /// `updateBluetoothOutput()` (`StreamReceiver.kt:1005-1076`).
    private func updateBluetoothOutput() {
        let now = clock.nowMs()
        let initial = withAudioLock { (route.ticket, route.selection, route.pending, interruptedLocked) }
        guard initial.1.kind.isBluetooth, !isClosed, !initial.3 else { return }
        let available = initial.1.refresh(inspector.currentRouteOutputs(), speakerPinnable: speakerPinnable)
        if !initial.2 && available == initial.1 && boundVerifies(initial.0, initial.1) { return }
        let work: (Bool, Bool)? = withAudioLock {
            guard !isClosedLocked, !interruptedLocked, route.ticket == initial.0 else { return nil }
            if !route.pending || available == nil || !trackStarted { holdSelectedBluetoothOutputLocked(now) }
            if let available { route.rebind(route.ticket, available) }
            route.beginCheck(route.ticket, nowMs: now)
            let work = (restarts.take(nowMs: now), outputRefresh)
            outputRefresh = false
            return work
        }
        guard let work else { return }
        if work.0 { recreateOutput() } else if work.1 { unbind() }
        let (id, selected) = withAudioLock { (route.ticket, route.selection) }
        guard !isClosed, selected.kind.isBluetooth else { return }
        let current = selected.refresh(inspector.currentRouteOutputs(), speakerPinnable: speakerPinnable)
        let accepted = current == selected ? bind(id, selected) : nil
        let released = withAudioLock { () -> Bool in
            guard !isClosedLocked, !interruptedLocked, route.ticket == id else { return false }
            if accepted == true && boundVerifiesLocked(id, selected) && !route.expired(clock.nowMs())
                && route.verified(id)
            {
                gate.verified()
                restarts.settled()
                outputWaitingSince = nil
                applyMuteLocked()
                return true
            }
            gate.hold()
            muteLocked()
            if outputWaitingSince == nil { outputWaitingSince = now }
            if let since = outputWaitingSince, now - since >= Self.bluetoothRestartWaitMs { restarts.request() }
            return false
        }
        if released { host?.outputSelectionChanged(selected) }
        publishOutputState()
        withCurrentOutput(id) {
            if !interruptedLocked && route.expired(clock.nowMs()) {
                host?.fail(
                    route.recovering
                        ? route.bluetoothRestoreTimeoutText
                        : OutputRouteChange.Text.bluetoothVerifyTimeout, code: .outputRuntime)
            }
        }
    }

    /// `updatePinnedOutput()` (`StreamReceiver.kt:942-1003`).
    private func updatePinnedOutput() {
        let now = clock.nowMs()
        let work: (Bool, Bool)? = withAudioLock {
            guard !isClosedLocked, !interruptedLocked, route.selection.explicit, !route.selection.kind.isBluetooth
            else { return nil }
            route.beginCheck(route.ticket, nowMs: now)
            let work = (restarts.take(nowMs: now), outputRefresh)
            outputRefresh = false
            return work
        }
        guard let work else { return }
        if work.0 { recreateOutput() } else if work.1 { unbind() }
        let current: (Int64, OutputSelection)? = withAudioLock {
            guard !isClosedLocked, !interruptedLocked, route.selection.explicit, !route.selection.kind.isBluetooth
            else { return nil }
            route.beginCheck(route.ticket, nowMs: now)
            return (route.ticket, route.selection)
        }
        guard let (id, selected) = current else { return }
        let accepted = bind(id, selected)
        let repairingSpeaker = withAudioLock { route.ticket == id && selected.kind == .phone && route.recovering }
        if accepted == false && !repairingSpeaker {
            withCurrentOutput(id) { host?.fail(OutputRouteChange.Text.selectFailed, code: .outputRuntime) }
            return
        }
        let released = withAudioLock { () -> Bool in
            guard !isClosedLocked, !interruptedLocked, route.ticket == id else { return false }
            if accepted == true && boundVerifiesLocked(id, selected) && !route.expired(clock.nowMs())
                && route.verified(id)
            {
                restarts.settled()
                outputWaitingSince = nil
                gate.verified()
                applyMuteLocked()
                return true
            }
            gate.hold()
            muteLocked()
            if repairingSpeaker {
                if outputWaitingSince == nil { outputWaitingSince = now }
                if let since = outputWaitingSince, now - since >= Self.speakerRestartWaitMs { restarts.request() }
            }
            return false
        }
        if released { host?.outputSelectionChanged(selected) }
        publishOutputState()
        withCurrentOutput(id) {
            if !interruptedLocked && route.expired(clock.nowMs()) {
                host?.fail(
                    repairingSpeaker
                        ? OutputRouteChange.Text.speakerRestoreTimeout
                        : OutputRouteChange.Text.verifyTimeout, code: .outputRuntime)
            }
        }
    }

    /// `recreateOutput()` (`StreamReceiver.kt:1078-1091`); never after a media-services reset.
    private func recreateOutput() {
        let target: OutputPlayoutEngine? = withAudioLock {
            guard mode == .playback, !isClosedLocked, !interruptedLocked, !mediaServicesResetObserved,
                let engine, !engine.playoutActive
            else { return nil }
            outputRestarting = true
            muteLocked()
            outputRecreations += 1
            binding = nil
            return engine
        }
        guard let target else { return }
        defer {
            withAudioLock {
                outputRestarting = false
                applyMuteLocked()
            }
        }
        do {
            if !isClosed { try target.restartPlayout() }
        } catch {
            withAudioLock {
                defaultOutput.unavailable()
                restarts.request()
            }
        }
    }
}
