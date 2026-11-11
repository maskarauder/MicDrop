import CallKit
import Foundation
import MicDropCore

/// Per-session microphone route owner (`A/MicrophoneRouting.kt`), created by the session worker at stage INPUT_ROUTE
/// while it holds `AudioSessionOwner`, closed in the teardown step `microphone_route_close`. Physical input removal is
/// watched even while muted.
///
/// iOS mapping: the port identity is `AVAudioSessionPortDescription.uid` (no addresses, no Nearby permission, no
/// recreated ports); Android's communication device is the Bluetooth HFP route of a `.playAndRecord` +
/// `.allowBluetooth` session. Every category/activation/preferred-input write goes through `AudioSessionArbiter` via
/// `SessionControl`; reads use the live route. The single `AudioSessionEventMonitor` forwards events through this
/// object's synchronous subscription. `routeDidChange()` queries current state (never trusting callback payload order)
/// and fans out to registered watchers (`MicrophoneInputProbe`, `HeadsetOutputWatch`).
///
/// Thread-safe (`NSLock`); `prepare`/`activate`/`restoreInput`/`close` run on the session worker,
/// `routeDidChange()` and the health queries on any thread. Never logs `uid` or `portName`.
final class MicrophoneRouting: @unchecked Sendable {
    /// Android constants (`A/MicrophoneRouting.kt:121,157`).
    enum Timing {
        /// Bluetooth activation budget at stage INPUT_ROUTE.
        static let prepareActivationMs: Int64 = 30_000
        /// Bluetooth activation poll.
        static let pollMs = 20
    }

    /// `lastRecoveryCheck` initial value (`A/MicrophoneRouting.kt:27`).
    static let notChecked = "not checked"

    /// The session's explicit selection (identity retained in memory only).
    let selection: MicrophoneSelection

    private let session: SessionControl
    private let calls: CallActivity
    private let clock: any MonotonicClock
    private let lost: @Sendable () -> Void
    private let lock = NSLock()

    // State (`A/MicrophoneRouting.kt:21-33`); guarded by `lock`.
    private var armed = false
    private var monitorCommunication = false
    private var input: AudioPortDescriptor?
    private var headsetEndpoint: HeadsetEndpoint?
    private var lastRecoveryCheck = MicrophoneRouting.notChecked
    /// iOS: this Bluetooth session pinned the HFP route / re-activated the shared session.
    private var ownsCommunication = false
    /// This session set a preferred input (any kind); `close()` clears it (app-local AVAudioSession state).
    private var preferredInputSet = false
    private var watchers: [Int: @Sendable () -> Void] = [:]
    private var nextWatcherID = 0
    private var subscription: AudioSessionEventMonitor.Subscription?

    /// - Parameters:
    ///   - selection: the verified-at-preflight selection of this session.
    ///   - session: route reads plus arbiter-mediated writes (`LiveSession` in production).
    ///   - calls: active phone-call detection for IN_USE (`CXCallObserver`).
    ///   - clock: monotonic milliseconds for activation deadlines.
    ///   - lost: the worker's `inputRouteLost()`; called from any thread, never does HTTP.
    ///   - monitor: the sole audio-event source; route loss is checked synchronously before another
    ///     worker heartbeat can run. The subscription is removed before route cleanup.
    init(
        selection: MicrophoneSelection, session: SessionControl, calls: CallActivity = SystemCallActivity(),
        clock: any MonotonicClock, lost: @escaping @Sendable () -> Void,
        monitor: AudioSessionEventMonitor? = .shared
    ) {
        self.selection = selection
        self.session = session
        self.calls = calls
        self.clock = clock
        self.lost = lost
        self.headsetEndpoint = selection.headsetEndpoint
        subscription = monitor?.addSynchronousSink { [weak self] event in
            switch event {
            case .routeChanged, .interruptionBegan(.routeDisconnected): self?.routeDidChange()
            default: break
            }
        }
    }

    // MARK: - Setup (worker)

    /// `prepare(cancelled)` (`A/MicrophoneRouting.kt:112-129`): Bluetooth → IN_USE if a phone call is active; `chosen =
    /// activate(timeoutMs: 30000, cancelled)`; `armed = true`; `!healthy()` → `MicrophoneRouteError(.unavailable)`.
    /// Returns the preferred input port. Cancellation throws `SessionStopped`.
    func prepare(cancelled: () -> Bool) throws -> AudioPortDescriptor {
        if selection.isBluetooth && calls.hasActiveCall { throw MicrophoneRouteError(.inUse) }
        let chosen = try activate(timeoutMs: Timing.prepareActivationMs, cancelled: cancelled)
        lock.lock()
        armed = true
        lock.unlock()
        guard healthy() else { throw MicrophoneRouteError(.unavailable) }
        return chosen
    }

    /// `activate(timeout, cancelled)` (`A/MicrophoneRouting.kt:131-160`). cancelled → `SessionStopped`; not available →
    /// `.unavailable`. Bluetooth: resolve the pinned port (else `.unavailable`), pin the endpoint if absent; if
    /// `!communicationMatches()` → `ownsCommunication = true`, `session.reactivate()` when inactive (`LiveSession` maps
    /// a busy activation — insufficientPriority/cannotInterruptOthers/siri — to `MicrophoneRouteError(.inUse)`; other
    /// errors → `.unverified`), `setPreferredInput(_:)` (error → `.unverified`). Then poll until the deadline:
    /// cancelled → throw; not available → `.unavailable`; resolve among `availableInputs` (Bluetooth also requires
    /// `communicationMatches()`) → store `input`, return it. Non-Bluetooth: one pass only, with `setPreferredInput(_:)`
    /// for the resolved port so the ADM starts on it (built-in pins the built-in port; the plan's category is already
    /// applied by the arbiter). Bluetooth: `Timing.pollMs` sleeps (`Thread.sleep`, cancellation re-checked). Timeout →
    /// `.unverified`.
    func activate(timeoutMs: Int64, cancelled: () -> Bool) throws -> AudioPortDescriptor {
        if cancelled() { throw SessionStopped() }
        guard let ports = session.availableInputs(), let chosen = selection.resolveInput(ports) else {
            throw MicrophoneRouteError(.unavailable)
        }
        if selection.isBluetooth {
            lock.lock()
            if headsetEndpoint == nil { headsetEndpoint = HeadsetEndpoint(port: chosen) }
            ownsCommunication = true
            lock.unlock()
            if !communicationMatches() {
                do {
                    if !session.isActive { try session.reactivate() }
                    try setPreferredInput(chosen)
                } catch let error as MicrophoneRouteError where error.problem == .inUse {
                    throw error
                } catch {
                    throw MicrophoneRouteError(.unverified)
                }
            }
        }
        let started = clock.nowMs()
        repeat {
            if cancelled() { throw SessionStopped() }
            guard let available = session.availableInputs(), let port = selection.resolveInput(available) else {
                throw MicrophoneRouteError(.unavailable)
            }
            if !selection.isBluetooth || communicationMatches() {
                if !selection.isBluetooth {
                    do { try setPreferredInput(port) } catch { throw MicrophoneRouteError(.unverified) }
                }
                lock.lock()
                input = port
                lock.unlock()
                return port
            }
            if clock.nowMs() &- started >= timeoutMs { break }
            Thread.sleep(forTimeInterval: Double(Timing.pollMs) / 1000)
        } while selection.isBluetooth
        throw MicrophoneRouteError(.unverified)
    }

    /// `validateDuplexOutput()` (`A/MicrophoneRouting.kt:102-110`): LE-stereo only, never on iOS → no-op.
    func validateDuplexOutput() throws {}

    /// `module.setPreferredInputDevice(dev)` / `capture.setPreferred(port)`: pins capture to `port` through the arbiter
    /// (`setPreferredInput(uid:)`); built-in selections pin the built-in port.
    func setPreferredInput(_ port: AudioPortDescriptor) throws {
        try session.setPreferredInput(uid: port.uid)
        lock.lock()
        preferredInputSet = true
        lock.unlock()
    }

    // MARK: - Health (any thread)

    /// `healthy()` = (Bluetooth ? `recoveryEndpointAvailable()` : `available(selection)`) and
    /// (`!monitorCommunication || communicationMatches()`).
    func healthy() -> Bool {
        lock.lock()
        let monitoring = monitorCommunication
        lock.unlock()
        let available: Bool
        if selection.isBluetooth {
            available = recoveryEndpointAvailable()
        } else {
            available = session.availableInputs().map { selection.resolveInput($0) != nil } ?? false
        }
        return available && (!monitoring || communicationMatches())
    }

    /// iOS `communicationMatches()`: session active, category `.playAndRecord` with `.allowBluetooth`,
    /// `currentRoute.inputs` = exactly one `.bluetoothHFP` port with the pinned uid, and `currentRoute.outputs` =
    /// exactly one `.bluetoothHFP` port of the same headset (uid match; fallback: the route's single HFP output, never
    /// by `portName`).
    func communicationMatches() -> Bool {
        guard session.isActive,
            session.categoryRawValue == AudioSessionPlan.Category.playAndRecord.rawValue,
            AudioSessionPlan.CategoryOptions(rawValue: session.categoryOptionsRawValue).contains(.allowBluetooth)
        else { return false }
        let inputs = session.currentInputs()
        let outputs = session.currentOutputs()
        guard inputs.count == 1, outputs.count == 1,
            inputs[0].type == MicrophoneKind.sco.portTypeRaw,
            outputs[0].type == MicrophoneKind.sco.portTypeRaw,
            selection.matchesInput(inputs[0])
        else { return false }
        // do not infer headset identity from a display name.
        lock.lock()
        let endpoint = headsetEndpoint
        lock.unlock()
        return endpoint?.matches(outputs[0]) ?? selection.matchesOutput(outputs[0])
    }

    /// `matchesInput(device)` = `selection.matchesInput(device)` && (!Bluetooth || `communicationMatches()`).
    func matchesInput(_ port: AudioPortDescriptor?) -> Bool {
        selection.matchesInput(port) && (!selection.isBluetooth || communicationMatches())
    }

    /// `matchesOutput(device)` = output is the pinned headset (`HeadsetEndpoint`/`selection.matchesOutput`)
    /// && `communicationMatches()`.
    func matchesOutput(_ port: AudioPortDescriptor?) -> Bool {
        guard let port, !port.isInput else { return false }
        lock.lock()
        let endpoint = headsetEndpoint
        lock.unlock()
        return (endpoint?.matches(port) ?? selection.matchesOutput(port)) && communicationMatches()
    }

    /// `acceptsOutputChannels(channels)` (1 for HFP, 2 otherwise).
    func acceptsOutputChannels(_ channels: Int) -> Bool {
        selection.acceptsOutputChannels(channels)
    }

    /// `monitor(active)` → `monitorCommunication = selection.isBluetooth && active`.
    func monitor(_ active: Bool) {
        lock.lock()
        monitorCommunication = selection.isBluetooth && active
        lock.unlock()
    }

    // MARK: - Recovery (worker)

    /// `recoveryEndpointAvailable()`: the pinned HFP uid is in `availableInputs`
    /// (`HeadsetEndpoint.inspect`, recording the state text in `lastRecoveryCheck`), or
    /// `selected port unavailable` / `selected port available` without a pinned endpoint. False on
    /// query failure.
    func recoveryEndpointAvailable() -> Bool {
        guard let inputs = session.availableInputs() else { return false }
        lock.lock()
        let endpoint = headsetEndpoint
        lock.unlock()
        let available: Bool
        let check: String
        if let endpoint {
            let match = endpoint.inspect(inputs)
            available = match.port != nil
            check = match.state.text
        } else {
            available = selection.resolveInput(inputs) != nil
            check = available ? HeadsetRecovery.Check.portAvailable : HeadsetRecovery.Check.portUnavailable
        }
        lock.lock()
        lastRecoveryCheck = check
        lock.unlock()
        return available
    }

    /// `recoveryCheck()` = the last fixed "Last check" label (never identity).
    func recoveryCheck() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastRecoveryCheck
    }

    /// Copy-report identity line: `HeadsetEndpoint.identityText`.
    func identityText() -> String { HeadsetEndpoint.identityText }

    /// `restoreInput(reselect)` (`A/MicrophoneRouting.kt:181-203`) — one nonblocking step: Bluetooth +
    /// `ownsCommunication` (else `MicrophoneRouteError(.inUse)`); pinned port in `availableInputs` else nil; inactive
    /// session (not interrupted) → `reactivate()` (failure → `.inUse`); `reselect` → `setPreferredInput(uid:)` (error →
    /// `lastRecoveryCheck = "iOS rejected headset selection"`, nil); `!communicationMatches()` → `"waiting for original
    /// communication route"`, nil; resolve input (none → `"waiting for original microphone source"`, nil); store and
    /// return it.
    func restoreInput(reselect: Bool) throws -> AudioPortDescriptor? {
        lock.lock()
        let owns = ownsCommunication
        let endpoint = headsetEndpoint
        lock.unlock()
        guard selection.isBluetooth, owns else { throw MicrophoneRouteError(.inUse) }
        guard let ports = session.availableInputs(),
            let chosen = endpoint?.resolve(ports) ?? selection.resolveInput(ports)
        else { return nil }
        if !session.isActive {
            do { try session.reactivate() } catch { throw MicrophoneRouteError(.inUse) }
        }
        if reselect {
            do { try setPreferredInput(chosen) } catch {
                setRecoveryCheck(HeadsetRecovery.Check.selectionRejected)
                return nil
            }
        }
        guard communicationMatches() else {
            setRecoveryCheck(HeadsetRecovery.Check.waitingCommunicationRoute)
            return nil
        }
        guard let available = session.availableInputs(), let resolved = selection.resolveInput(available) else {
            setRecoveryCheck(HeadsetRecovery.Check.waitingMicrophoneSource)
            return nil
        }
        lock.lock()
        input = resolved
        lock.unlock()
        return resolved
    }

    private func setRecoveryCheck(_ check: String) {
        lock.lock()
        lastRecoveryCheck = check
        lock.unlock()
    }

    /// `currentSelection()` = the selection with the bound endpoint (iOS: unchanged uid).
    func currentSelection() -> MicrophoneSelection {
        lock.lock()
        defer { lock.unlock() }
        var current = selection
        if let headsetEndpoint {
            current.headsetEndpoint = headsetEndpoint
            current.portUID = headsetEndpoint.uid
        }
        return current
    }

    // MARK: - Live route (any thread)

    /// `AVAudioSession.currentRoute.inputs.first` (Android `AudioRecord.routedDevice`).
    func currentInput() -> AudioPortDescriptor? { session.currentInputs().first }

    /// `AVAudioSession.currentRoute.outputs`.
    func currentOutputs() -> [AudioPortDescriptor] { session.currentOutputs() }

    /// `Int(AVAudioSession.sampleRate.rounded())`.
    var currentSampleRateHz: Int {
        let rate = session.sampleRate
        return rate.isFinite && rate > 0 ? Int(rate.rounded()) : 0
    }

    /// `AVAudioSession.outputNumberOfChannels` (Android `AudioTrack.channelCount`).
    var outputNumberOfChannels: Int { session.outputNumberOfChannels }

    // MARK: - Route changes (any thread)

    /// Fan-out entry for every route change of this session and for an interruption with reason `.routeDisconnected`:
    /// `checkRoute()` (`if armed && !healthy() { lost() }`) then every registered watcher. Never performs I/O beyond
    /// route queries.
    func routeDidChange() {
        lock.lock()
        let isArmed = armed
        let handlers = watchers.sorted { $0.key < $1.key }.map { $0.value }
        lock.unlock()
        if isArmed && !healthy() { lost() }
        for handler in handlers { handler() }
    }

    /// Registers a route watcher (probe/output watch); returns its id.
    @discardableResult
    func addRouteWatcher(_ handler: @escaping @Sendable () -> Void) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextWatcherID += 1
        watchers[nextWatcherID] = handler
        return nextWatcherID
    }

    /// Removes a watcher registered with `addRouteWatcher(_:)`.
    func removeRouteWatcher(_ id: Int) {
        lock.lock()
        watchers[id] = nil
        lock.unlock()
    }

    // MARK: - Teardown (worker)

    /// `close()` (`A/MicrophoneRouting.kt:205-222`): `armed = false`, event subscription removed, monitor off, input
    /// nil, watchers removed; if this session pinned a preferred input (or owns the HFP route): `setPreferredInput(uid:
    /// nil)`. Deactivation stays with the controller's `releaseTransport()` after the worker ended (deactivating with
    /// running I/O fails `.isBusy`). Attempts every step, then throws `CleanupFailed` if any failed (teardown →
    /// TEARDOWN_FAILED).
    func close() throws {
        lock.lock()
        armed = false
        monitorCommunication = false
        input = nil
        watchers.removeAll()
        let clearPreference = ownsCommunication || preferredInputSet
        ownsCommunication = false
        preferredInputSet = false
        let currentSubscription = subscription
        subscription = nil
        lock.unlock()
        currentSubscription?.cancel()
        var failed = false
        if clearPreference {
            do {
                try session.setPreferredInput(uid: nil)
            } catch {
                failed = true
            }
        }
        if failed { throw CleanupFailed() }
    }

    /// `IllegalStateException("Audio route cleanup failed")` (`A/MicrophoneRouting.kt:221`).
    struct CleanupFailed: Error, Equatable, Sendable, CustomStringConvertible {
        init() {}
        var description: String { "Audio route cleanup failed" }
    }
}

// MARK: - Audio session access

extension MicrophoneRouting {
    /// Route reads (`AudioRouteReading`): implemented over `RTCAudioSession`/`AVAudioSession` (`LiveSession`), faked in
    /// tests. Ports carry `uid`/`type`/`name` for comparisons only.
    protocol RouteReading: AnyObject {
        /// `AVAudioSession.availableInputs` under the current category; nil when the query failed.
        func availableInputs() -> [AudioPortDescriptor]?
        /// `currentRoute.inputs` (`isInput == true`).
        func currentInputs() -> [AudioPortDescriptor]
        /// `currentRoute.outputs` (`isInput == false`).
        func currentOutputs() -> [AudioPortDescriptor]
        /// `AVAudioSession.sampleRate` (Hz).
        var sampleRate: Double { get }
        /// `AVAudioSession.outputNumberOfChannels`.
        var outputNumberOfChannels: Int { get }
        /// `RTCAudioSession.isActive`.
        var isActive: Bool { get }
        /// `AVAudioSession.category.rawValue` (compare with `AudioSessionPlan.Category.rawValue`).
        var categoryRawValue: String { get }
        /// `AVAudioSession.mode.rawValue` (compare with `AudioSessionPlan.Mode.rawValue`).
        var modeRawValue: String { get }
        /// `AVAudioSession.categoryOptions.rawValue` (same bits as `AudioSessionPlan.CategoryOptions`).
        var categoryOptionsRawValue: UInt { get }
    }

    /// Reads plus the two arbiter-mediated writes the route needs.
    protocol SessionControl: RouteReading {
        /// `AudioSessionArbiter.setPreferredInput`: resolves `uid` among `availableInputs` and calls
        /// `RTCAudioSession.setPreferredInput(_:)` under `lockForConfiguration`; nil clears the preference.
        func setPreferredInput(uid: String?) throws
        /// `AudioSessionArbiter.reactivate()`: `setActive(true)` of the already prepared plan (no-op while
        /// active). A busy activation throws `MicrophoneRouteError(.inUse)`; anything else is a failure the
        /// caller maps to `.unverified` (activate) or `.inUse` (restoreInput step 3).
        func reactivate() throws
    }

    /// Phone-call detection (Android `manager.mode != MODE_NORMAL`, step 2).
    protocol CallActivity: AnyObject {
        /// True while any call (cellular or VoIP) has not ended.
        var hasActiveCall: Bool { get }
    }

    /// `CXCallObserver`-backed call detection (CallKit framework only; no entitlement).
    final class SystemCallActivity: CallActivity {
        private let observer = CXCallObserver()

        init() {}

        var hasActiveCall: Bool { observer.calls.contains { !$0.hasEnded } }
    }
}

/// name for `MicrophoneRouting.RouteReading`.
typealias AudioRouteReading = MicrophoneRouting.RouteReading
