import AVFoundation
import Foundation
import MicDropCore

/// Per-session route-change sink of the output subsystem.
///
/// `AudioSessionEventMonitor` is the only subscriber to `AVAudioSession.routeChangeNotification` /
/// `mediaServicesWereReset/LostNotification` and to `RTCAudioSessionDelegate`. This type is therefore **not** a
/// delegate: the monitor forwards every event through the process-wide entry points
/// `OutputRouteObserver.dispatchRouteChange(_:)`, `dispatchMediaServicesReset()` and `dispatchMediaServicesLost()`,
/// which deliver to the started observer of the live session (normally zero or one). Playout start/stop are not
/// delivered here: per they are `PlayoutTap` edges that the session forwards to
/// `OutputRouteController.playoutDidStart()/playoutDidStop()`.
///
/// It replaces three Android callback sources: `ACTION_AUDIO_BECOMING_NOISY`, `OutputDeviceWatch`
/// (`AudioDeviceCallback` added/removed) and the bound track's routing listener. Delivery may happen on any thread;
/// handling only locks, mutates the controller's state machines, mutes and wakes the worker (no blocking calls into
/// WebRTC).
final class OutputRouteObserver: @unchecked Sendable {

    /// One `routeChangeNotification` (reason + previous route), parsed by the monitor or by
    /// `init?(notification:)`. The current route is read by the observer when it handles the event.
    struct RouteChange: Sendable {
        let reason: AVAudioSession.RouteChangeReason
        /// `AVAudioSessionRouteChangePreviousRouteKey` outputs (empty when absent).
        let previous: [RouteOutput]

        init(reason: AVAudioSession.RouteChangeReason, previous: [RouteOutput]) {
            self.reason = reason
            self.previous = previous
        }

        /// Parses `AVAudioSessionRouteChangeReasonKey` (NSNumber `UInt`) and
        /// `AVAudioSessionRouteChangePreviousRouteKey` (`AVAudioSessionRouteDescription`).
        /// Returns nil when the reason is missing or unknown to the SDK.
        init?(notification: Notification) {
            guard let info = notification.userInfo,
                let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return nil }
            let previousRoute = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            self.init(reason: reason, previous: previousRoute.map { AudioRouteInspector.routeOutputs(of: $0) } ?? [])
        }

        /// Reasons counted by the iOS `RecoveryMonitor` epoch `(1, audioRouteChangeCount)`: `.newDeviceAvailable`,
        /// `.oldDeviceUnavailable`, `.override`, `.routeConfigurationChange`.
        var countsForRecoveryEpoch: Bool {
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
                return true
            default:
                return false
            }
        }
    }

    private weak var controller: OutputRouteController?
    private let inspector: AudioRouteInspecting
    private let stateLock = NSLock()
    private var started = false

    /// signature. The controller owns its observer (`OutputRouteController.observer`); the reference back is weak.
    init(controller: OutputRouteController, inspector: AudioRouteInspecting) {
        self.controller = controller
        self.inspector = inspector
    }

    /// True between `start()` and `stop()`.
    var isStarted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return started
    }

    /// Worker, before signaling (`StreamReceiver.kt:360`, only when `usesMediaOutput`): registers for the fan-out and
    /// performs the initial watch refresh — Android's registration delivers an initial "added" callback for existing
    /// devices, which advances the inventory generation ("Initial state"): `refresh(current, removed: false, added:
    /// bluetoothNow)`.
    func start() {
        stateLock.lock()
        let wasStarted = started
        started = true
        stateLock.unlock()
        guard !wasStarted else { return }
        OutputRouteObserver.registry.add(self)
        let current = inspector.currentRouteOutputs()
        let bluetoothNow = current.contains { $0.kind?.isBluetooth == true }
        controller?.outputDevicesObserved(current, bluetoothRemoved: false, bluetoothAdded: bluetoothNow)
    }

    /// Worker cleanup step `output_observers_close`. Idempotent.
    func stop() {
        stateLock.lock()
        let wasStarted = started
        started = false
        stateLock.unlock()
        if wasStarted { OutputRouteObserver.registry.remove(self) }
    }

    /// Handles one route change, any thread:
    /// ```
    /// bluetoothBefore/Now, externalBefore (kind != nil && !=.phone in the previous route) added = reason
    /// ==.newDeviceAvailable && bluetoothNow removed = reason ==.oldDeviceUnavailable && bluetoothBefore && no previous
    /// Bluetooth uid remains
    /// 1..oldDeviceUnavailable && externalBefore → mediaOutputBecomingNoisy
    /// 2. watch refresh → controller.outputDevicesObserved(current, removed, added)
    /// 3. a binding exists → outputRouteChanged(binding.ticket, binding.selection)
    /// +.noSuitableRouteForCategory → recoverableOutputFailed
    /// ```
    /// Reasons beyond rule 1 and `added` are not relied upon (picker changes may arrive as
    /// `.override`, `.categoryChange`, `.newDeviceAvailable` or `.routeConfigurationChange`).
    func routeChanged(_ change: RouteChange) {
        guard isStarted, let controller else { return }
        let current = inspector.currentRouteOutputs()
        let previous = change.previous
        let previousBluetooth = previous.filter { $0.kind?.isBluetooth == true }
        let bluetoothBefore = !previousBluetooth.isEmpty
        let bluetoothNow = current.contains { $0.kind?.isBluetooth == true }
        let externalBefore = previous.contains { output in
            guard let kind = output.kind else { return false }
            return kind != .phone
        }
        let added = change.reason == .newDeviceAvailable && bluetoothNow
        let removed =
            change.reason == .oldDeviceUnavailable && bluetoothBefore
            && !current.contains { output in previousBluetooth.contains { $0.uid == output.uid } }

        if change.countsForRecoveryEpoch { controller.noteRouteChangeForRecoveryEpoch() }
        if change.reason == .oldDeviceUnavailable && externalBefore {
            controller.mediaOutputBecomingNoisy()
        }
        controller.outputDevicesObserved(current, bluetoothRemoved: removed, bluetoothAdded: added)
        controller.boundRouteChanged()
        if change.reason == .noSuitableRouteForCategory {
            controller.recoverableOutputFailed()
        }
    }

    /// `mediaServicesWereReset` (which overrides): no `recoverableOutputFailed()`, only `mediaServicesWereReset()` so
    /// that no playout recreation runs before the engine's sink ends the session; the coordinator separately applies
    /// media-reset stop.
    func mediaServicesReset() {
        guard isStarted, let controller else { return }
        controller.mediaServicesWereReset()
    }

    /// `mediaServicesWereLost` (`audioSessionMediaServerTerminated`): `recoverableOutputFailed()`.
    func mediaServicesLost() {
        guard isStarted, let controller else { return }
        controller.recoverableOutputFailed()
    }

    // MARK: - Process-wide fan-out entry points (called by AudioSessionEventMonitor)

    /// Delivers `change` to every started observer. Any thread; never blocks on the main actor.
    static func dispatchRouteChange(_ change: RouteChange) {
        for observer in registry.snapshot() { observer.routeChanged(change) }
    }

    /// Delivers a media-services reset to every started observer. Any thread.
    static func dispatchMediaServicesReset() {
        for observer in registry.snapshot() { observer.mediaServicesReset() }
    }

    /// Delivers a media-services loss to every started observer. Any thread.
    static func dispatchMediaServicesLost() {
        for observer in registry.snapshot() { observer.mediaServicesLost() }
    }

    // MARK: - Registry

    private static let registry = Registry()

    /// Weakly held set of started observers (normally zero or one live session).
    private final class Registry: @unchecked Sendable {
        private struct Entry {
            weak var observer: OutputRouteObserver?
        }

        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]

        func add(_ observer: OutputRouteObserver) {
            lock.lock()
            entries[ObjectIdentifier(observer)] = Entry(observer: observer)
            lock.unlock()
        }

        func remove(_ observer: OutputRouteObserver) {
            lock.lock()
            entries[ObjectIdentifier(observer)] = nil
            lock.unlock()
        }

        /// Live observers; drops entries whose observer was deallocated.
        func snapshot() -> [OutputRouteObserver] {
            lock.lock()
            defer { lock.unlock() }
            entries = entries.filter { $0.value.observer != nil }
            return entries.values.compactMap { $0.observer }
        }
    }
}
