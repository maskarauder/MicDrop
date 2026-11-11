// The single subscriber to AVAudioSession / RTCAudioSession events.
//
// No other component registers for `interruptionNotification`, `routeChangeNotification`,
// `mediaServicesWereReset/LostNotification` or as an `RTCAudioSessionDelegate`. Consumers attach sinks instead:
// - synchronous sinks run on the posting thread, before anything else (worker-side components that
// must gate/mute or wake immediately: the live session's `OutputRouteObserver`, `MicrophoneRouting`, the engine's
// playout/glitch tracking, local tools);
// - main sinks run on the main queue in FIFO order (`DispatchQueue.main.async`):
//   `SessionCoordinator` (interruption focus mapping, noisy rule, media-services reset).
//
// Event sources (one per event, never both): interruptions, route changes and media-services
// notifications come from `AVAudioSession` notifications (the reason key, including
// `.appWasSuspended`, is not delivered by `RTCAudioSessionDelegate`); play/record start/stop,
// audio-unit start failure, failed activation, can-play-or-record and playout glitches come from
// `RTCAudioSessionDelegate`.

import AVFoundation
import Foundation
import MicDropCore
import WebRTC

final class AudioSessionEventMonitor: NSObject, RTCAudioSessionDelegate, @unchecked Sendable {
    /// The process-wide monitor (one AVAudioSession / RTCAudioSession per process). Session-scoped
    /// consumers (the session worker's `MicrophoneRouting.routeDidChange()`, the engine's
    /// interruption/route hooks) register synchronous sinks on it for the session lifetime.
    static let shared = AudioSessionEventMonitor()

    // MARK: - Event model

    /// `AVAudioSessionInterruptionReasonKey` (iOS 14.5+).
    enum InterruptionReason: Equatable, Sendable {
        /// `.default` (0), and absent keys.
        case `default`
        /// Raw 1 (`.appWasSuspended`, deprecated since iOS 16): we were suspended, nothing was playing → ignore.
        case appWasSuspended
        /// Raw 2 (`.builtInMicMuted`, iPad only).
        case builtInMicMuted
        /// `.routeDisconnected` (iOS 17 SDK; raw value per `routeDisconnectedRawValue`): route loss, never focus
        /// handling.
        case routeDisconnected
        /// Any other raw value (SDK-dependent): treated as `.default` for focus.
        case other(UInt)

        /// Use the SDK constant so route loss follows route recovery rather than focus handling.
        static let routeDisconnectedRawValue = AVAudioSession.InterruptionReason.routeDisconnected.rawValue

        init(rawValue: UInt?) {
            switch rawValue {
            case nil, .some(0): self = .default
            case .some(1): self = .appWasSuspended
            case .some(2): self = .builtInMicMuted
            case .some(InterruptionReason.routeDisconnectedRawValue): self = .routeDisconnected
            case .some(let other): self = .other(other)
            }
        }

        /// The raw `AVAudioSession.InterruptionReason` value.
        var rawValue: UInt {
            switch self {
            case .default: return 0
            case .appWasSuspended: return 1
            case .builtInMicMuted: return 2
            case .routeDisconnected: return InterruptionReason.routeDisconnectedRawValue
            case .other(let value): return value
            }
        }

        /// The SDK value (for 08's `handleInterruption(began:shouldResume:reason:)`).
        var avReason: AVAudioSession.InterruptionReason? {
            AVAudioSession.InterruptionReason(rawValue: rawValue)
        }

        /// `.appWasSuspended` is ignored; every other reason except `.routeDisconnected` is handled as a focus loss.
        var isFocusLoss: Bool {
            switch self {
            case .appWasSuspended, .routeDisconnected: return false
            default: return true
            }
        }
    }

    /// One `routeChangeNotification`, captured on the posting thread with the current route. Port identities are
    /// process-local and never logged.
    struct RouteChange: Equatable, Sendable {
        /// `AVAudioSessionRouteChangeReasonKey` raw value (reason table).
        let reasonRawValue: UInt
        let previousOutputs: [RouteOutput]
        let currentOutputs: [RouteOutput]
        let previousInputs: [AudioPortDescriptor]
        let currentInputs: [AudioPortDescriptor]

        init(
            reasonRawValue: UInt, previousOutputs: [RouteOutput], currentOutputs: [RouteOutput],
            previousInputs: [AudioPortDescriptor], currentInputs: [AudioPortDescriptor]
        ) {
            self.reasonRawValue = reasonRawValue
            self.previousOutputs = previousOutputs
            self.currentOutputs = currentOutputs
            self.previousInputs = previousInputs
            self.currentInputs = currentInputs
        }

        /// The SDK reason, nil for unknown raw values.
        var reason: AVAudioSession.RouteChangeReason? {
            AVAudioSession.RouteChangeReason(rawValue: reasonRawValue)
        }

        /// "becoming noisy": reason `.oldDeviceUnavailable` **and** the previous outputs contained a port other than
        /// the built-in speaker/receiver.
        var isNoisy: Bool {
            guard reason == .oldDeviceUnavailable else { return false }
            return previousOutputs.contains {
                $0.portType != RouteOutput.PortType.builtInSpeaker
                    && $0.portType != RouteOutput.PortType.builtInReceiver
            }
        }
    }

    /// Everything the monitor fans out.
    enum Event: Equatable, Sendable {
        /// `interruptionNotification` type `.began` with its reason.
        case interruptionBegan(InterruptionReason)
        /// `interruptionNotification` type `.ended`; `shouldResume` = options contain `.shouldResume`.
        case interruptionEnded(shouldResume: Bool)
        /// `routeChangeNotification`.
        case routeChanged(RouteChange)
        /// `mediaServicesWereResetNotification` (the live session ends; no output recovery).
        case mediaServicesWereReset
        /// `mediaServicesWereLostNotification` (record only).
        case mediaServicesWereLost
        /// `audioSessionDidStartPlayOrRecord:` (unit lifetime only, auxiliary for).
        case playOrRecordStarted
        /// `audioSessionDidStopPlayOrRecord:`.
        case playOrRecordStopped
        /// `audioSession:didChangeCanPlayOrRecord:`.
        case canPlayOrRecordChanged(Bool)
        /// `audioSession:audioUnitStartFailedWithError:` (`output_start`).
        case audioUnitStartFailed(code: Int)
        /// `audioSession:failedToSetActive:error:` (`output_init`).
        case failedToSetActive(active: Bool, code: Int)
        /// `audioSession:didDetectPlayoutGlitch:` total count (`playoutGlitches`).
        case playoutGlitches(total: Int64)
    }

    /// Handle of one sink registration; `cancel()` (or releasing it) removes the sink.
    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var onCancel: (() -> Void)?

        init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        func cancel() {
            lock.lock()
            let action = onCancel
            onCancel = nil
            lock.unlock()
            action?()
        }

        deinit { cancel() }
    }

    // MARK: - State

    private let center: NotificationCenter
    private let rtcSession: RTCAudioSession
    private let avSession: AVAudioSession
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var interrupted = false
    private var nextID: UInt64 = 0
    private var synchronousSinks: [(id: UInt64, sink: @Sendable (Event) -> Void)] = []
    private var mainSinks: [(id: UInt64, sink: @MainActor (Event) -> Void)] = []

    init(
        center: NotificationCenter = .default,
        rtcSession: RTCAudioSession = RTCAudioSession.sharedInstance(),
        avSession: AVAudioSession = AVAudioSession.sharedInstance()
    ) {
        self.center = center
        self.rtcSession = rtcSession
        self.avSession = avSession
        super.init()
    }

    // MARK: - Lifecycle

    /// Registers the four notification observers (queue nil → synchronous on the posting thread; object nil like
    /// `RTCAudioSession`'s own registration, since an app has exactly one AVAudioSession) and the RTCAudioSession
    /// delegate. Idempotent. Call at launch (before the first run-loop turn) via `SessionCoordinator.start()`.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let event = AudioSessionEventMonitor.interruptionEvent(note.userInfo) else { return }
            self?.deliver(event)
        }
        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            guard
                let change = AudioSessionEventMonitor.routeChange(
                    note.userInfo,
                    current: self.avSession.currentRoute)
            else { return }
            self.deliver(.routeChanged(change))
        }
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.deliver(.mediaServicesWereReset)
        }
        let lost = center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.deliver(.mediaServicesWereLost)
        }
        lock.lock()
        observers = [interruption, route, reset, lost]
        lock.unlock()
        rtcSession.add(self)
    }

    /// Removes every registration (tests; the app keeps the monitor for the process lifetime).
    func stop() {
        lock.lock()
        let registered = observers
        observers = []
        let wasStarted = started
        started = false
        lock.unlock()
        for observer in registered {
            center.removeObserver(observer)
        }
        if wasStarted { rtcSession.remove(self) }
    }

    // MARK: - Sinks

    /// Adds a sink invoked synchronously on the posting thread (any thread, possibly the WebRTC worker or a
    /// notification thread). It must not block or call back into WebRTC under a lock ("lock, mutate state machines,
    /// mute, wake the worker, no blocking calls").
    func addSynchronousSink(_ sink: @escaping @Sendable (Event) -> Void) -> Subscription {
        lock.lock()
        nextID += 1
        let id = nextID
        synchronousSinks.append((id: id, sink: sink))
        lock.unlock()
        return Subscription { [weak self] in self?.removeSink(id) }
    }

    /// Adds a sink invoked on the main queue, FIFO with every other event.
    func addMainSink(_ sink: @escaping @MainActor (Event) -> Void) -> Subscription {
        lock.lock()
        nextID += 1
        let id = nextID
        mainSinks.append((id: id, sink: sink))
        lock.unlock()
        return Subscription { [weak self] in self?.removeSink(id) }
    }

    /// true between an interruption `.began` that is a focus loss or route disconnect (not `.appWasSuspended`) and the
    /// next `.ended` or media-services reset. Read by the engine's `OutputPlayoutEngine.interrupted` and by local
    /// tools.
    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    // MARK: - Fan-out

    /// Updates the interruption flag, forwards to the live session's output observer (on the posting thread so the
    /// noisy hold precedes the worker's next route observation), calls every synchronous sink in registration order,
    /// then hops once to the main queue for the main sinks (sinks cancelled before the hop are skipped). Internal so
    /// tests can inject events.
    func deliver(_ event: Event) {
        lock.lock()
        switch event {
        case .interruptionBegan(let reason) where reason != .appWasSuspended:
            interrupted = true
        case .interruptionEnded, .mediaServicesWereReset:
            interrupted = false
        default:
            break
        }
        let synchronous = synchronousSinks
        lock.unlock()
        AudioSessionEventMonitor.forwardToOutputObservers(event)
        for entry in synchronous { entry.sink(event) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let main = self.mainSinks
            self.lock.unlock()
            MainActor.assumeIsolated {
                for entry in main { entry.sink(event) }
            }
        }
    }

    /// process-wide entry points (`OutputRouteObserver.dispatchRouteChange(_:)`, `dispatchMediaServicesReset()`,
    /// `dispatchMediaServicesLost()`; API "Requirements on other owners" item 1). Route changes whose reason the SDK
    /// does not know are not forwarded (the observer's own parser drops them too).
    private static func forwardToOutputObservers(_ event: Event) {
        switch event {
        case .routeChanged(let change):
            guard let reason = change.reason else { return }
            OutputRouteObserver.dispatchRouteChange(
                OutputRouteObserver.RouteChange(reason: reason, previous: change.previousOutputs))
        case .mediaServicesWereReset:
            OutputRouteObserver.dispatchMediaServicesReset()
        case .mediaServicesWereLost:
            OutputRouteObserver.dispatchMediaServicesLost()
        default:
            break
        }
    }

    private func removeSink(_ id: UInt64) {
        lock.lock()
        synchronousSinks.removeAll { $0.id == id }
        mainSinks.removeAll { $0.id == id }
        lock.unlock()
    }

    // MARK: - Parsing (pure, testable)

    /// `interruptionNotification` user info → event: `AVAudioSessionInterruptionTypeKey` (`.began`/
    /// `.ended`); `.began` carries `AVAudioSessionInterruptionReasonKey`; `.ended` carries
    /// `AVAudioSessionInterruptionOptionKey` with `.shouldResume`. Unknown type → nil.
    static func interruptionEvent(_ userInfo: [AnyHashable: Any]?) -> Event? {
        guard let rawType = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return nil }
        switch type {
        case .began:
            let rawReason = userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            return .interruptionBegan(InterruptionReason(rawValue: rawReason))
        case .ended:
            let rawOptions = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// `routeChangeNotification` user info + the current route → `RouteChange` (reason key and
    /// `AVAudioSessionRouteChangePreviousRouteKey`; a missing previous route is an empty route).
    static func routeChange(
        _ userInfo: [AnyHashable: Any]?,
        current: AVAudioSessionRouteDescription
    ) -> RouteChange? {
        guard let rawReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return nil }
        let previous = userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        return RouteChange(
            reasonRawValue: rawReason,
            previousOutputs: previous.map { outputs($0) } ?? [],
            currentOutputs: outputs(current),
            previousInputs: previous.map { inputs($0) } ?? [],
            currentInputs: inputs(current))
    }

    /// `route.outputs` as `RouteOutput(portType:uid:)`.
    static func outputs(_ route: AVAudioSessionRouteDescription) -> [RouteOutput] {
        route.outputs.map { RouteOutput(portType: $0.portType.rawValue, uid: $0.uid) }
    }

    /// `route.inputs` as `AudioPortDescriptor`.
    static func inputs(_ route: AVAudioSessionRouteDescription) -> [AudioPortDescriptor] {
        route.inputs.map {
            AudioPortDescriptor(uid: $0.uid, type: $0.portType.rawValue, isInput: true, name: $0.portName)
        }
    }

    // MARK: - RTCAudioSessionDelegate (only the events not taken from notifications)

    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        deliver(.playOrRecordStarted)
    }

    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        deliver(.playOrRecordStopped)
    }

    func audioSession(_ session: RTCAudioSession, didChangeCanPlayOrRecord canPlayOrRecord: Bool) {
        deliver(.canPlayOrRecordChanged(canPlayOrRecord))
    }

    func audioSession(_ audioSession: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        deliver(.audioUnitStartFailed(code: (error as NSError).code))
    }

    func audioSession(_ audioSession: RTCAudioSession, failedToSetActive active: Bool, error: Error) {
        deliver(.failedToSetActive(active: active, code: (error as NSError).code))
    }

    func audioSession(_ audioSession: RTCAudioSession, didDetectPlayoutGlitch totalNumberOfGlitches: Int64) {
        deliver(.playoutGlitches(total: totalNumberOfGlitches))
    }
}
