import Foundation
import MicDropCore

/// Bluetooth duplex output verification and watcher (row "AudioTrack.getRoutedDevice + channelCount", Android
/// `outputMatches()` / `outputWatch` in `StreamReceiver.kt`).
///
/// A Bluetooth (HFP) duplex session must play desktop audio only through the selected headset: the
/// current route has exactly one output, it is the pinned headset (`MicrophoneRouting.matchesOutput`,
/// which includes the communication-route check) and `outputNumberOfChannels` is acceptable (1 for
/// HFP). The watch registers with `MicrophoneRouting`'s route-change fan-out, generation-filtered like
/// `MicrophoneInputProbe`. Unused for non-Bluetooth inputs.
final class HeadsetOutputWatch: @unchecked Sendable {
    private let routing: MicrophoneRouting
    private let lock = NSLock()
    private var generation: Int64 = 0
    private var watcherID: Int?

    init(routing: MicrophoneRouting) {
        self.routing = routing
    }

    /// `outputMatches()`: exactly one routed output, `routing.matchesOutput(output)` and
    /// `routing.acceptsOutputChannels(outputNumberOfChannels)`.
    func matches() -> Bool {
        let outputs = routing.currentOutputs()
        guard outputs.count == 1 else { return false }
        return routing.matchesOutput(outputs[0]) && routing.acceptsOutputChannels(routing.outputNumberOfChannels)
    }

    /// `outputWatch.watch(invalid)`: `clear()`; registers a generation-checked route watcher that calls
    /// `invalid()` when `!matches()`; returns whether the output matched at registration.
    @discardableResult
    func watch(invalid: @escaping @Sendable () -> Void) -> Bool {
        clear()
        guard matches() else { return false }
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

    /// Stops watching (`generation += 1`, watcher removed).
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
