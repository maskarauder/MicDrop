import Foundation
import MicDropCore

/// Actual-capture-route probe and watcher (port of `A/MicrophoneInput.kt`).
///
/// Android reads the routed device of WebRTC's own `AudioRecord`; iOS has one process route, so
/// "capture object available" ⇔ `capture.captureActive` (ADM input running) and the routed input is
/// `currentRoute.inputs.first`. `watch(invalid:)` replaces `AudioRecord.addOnRoutingChangedListener`:
/// it registers with `MicrophoneRouting`'s route-change fan-out and is filtered by a generation counter
/// so callbacks queued before a mute or teardown (`clear()`) are ignored.
final class MicrophoneInputProbe: @unchecked Sendable {
    private let routing: MicrophoneRouting
    private let capture: MicrophoneCapture
    private let lock = NSLock()
    private var generation: Int64 = 0
    private var watcherID: Int?

    init(routing: MicrophoneRouting, capture: MicrophoneCapture) {
        self.routing = routing
        self.capture = capture
    }

    /// `matches()` (`A/MicrophoneInput.kt:38-40`): capture is running and
    /// `routing.matchesInput(currentRoute.inputs.first)`.
    func matches() -> Bool {
        capture.captureActive && routing.matchesInput(routing.currentInput())
    }

    /// What the report builder reads: nil while capture is not active ("capture object unavailable"); otherwise the
    /// routed input, `Int(sampleRate.rounded())`, channels **1** (the ADM's mono recording format, never
    /// `inputNumberOfChannels`) and `routing.matchesInput(routed)`.
    func reading() -> MicrophoneSnapshot.CaptureReading? {
        guard capture.captureActive else { return nil }
        let routed = routing.currentInput()
        return MicrophoneSnapshot.CaptureReading(
            routedInput: routed, sampleRateHz: routing.currentSampleRateHz,
            channels: 1, inputMatches: routing.matchesInput(routed))
    }

    /// `snapshot(state, selection, routing)` (`A/MicrophoneInput.kt:42-54`) =
    /// `MicrophoneSnapshot.make(state:selection:capture: reading(), processing:)`.
    func snapshot(
        state: String, selection: MicrophoneSelection,
        processing: MicrophoneProcessing? = nil
    ) -> MicrophoneSnapshot {
        MicrophoneSnapshot.make(state: state, selection: selection, capture: reading(), processing: processing)
    }

    /// `watch(invalid)` (`A/MicrophoneInput.kt:55-67`): `clear()`; false when capture is not active;
    /// otherwise registers a route watcher that calls `invalid()` when (generation unchanged and)
    /// `!matches()`; returns true once registered.
    @discardableResult
    func watch(invalid: @escaping @Sendable () -> Void) -> Bool {
        clear()
        guard capture.captureActive else { return false }
        lock.lock()
        let current = generation
        lock.unlock()
        let id = routing.addRouteWatcher { [weak self] in
            guard let self, self.isCurrent(current), !self.matches() else { return }
            invalid()
        }
        lock.lock()
        let stillCurrent = generation == current
        if stillCurrent { watcherID = id }
        lock.unlock()
        if !stillCurrent { routing.removeRouteWatcher(id) }
        return true
    }

    /// `clear()` (`A/MicrophoneInput.kt:68-73`): `generation += 1` (ignore callbacks queued before
    /// mute/teardown) and removes the route watcher.
    func clear() {
        lock.lock()
        generation += 1
        let id = watcherID
        watcherID = nil
        lock.unlock()
        if let id { routing.removeRouteWatcher(id) }
    }

    private func isCurrent(_ value: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}
