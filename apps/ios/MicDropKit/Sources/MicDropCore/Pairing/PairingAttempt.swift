import Foundation

/// Cancellation handle for one enrollment (Android `PairingAttempt`, `PairingClient.kt:44-56`).
///
/// `cancel()` sets the flag, closes the in-flight request (the closer registered from `ControlTransport.send`'s
/// `onStart`) and cancels the bound `Task`, so a `Task.sleep` between polls throws `CancellationError`. `checkpoint()`
/// throws `CancellationError` once cancelled. Every catch path in the enrollment loop calls `checkpoint()` first, so an
/// I/O error caused by the cancel is reported as cancelled. Thread-safe; callbacks run outside the lock.
public final class PairingAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var closer: (@Sendable () -> Void)?
    private var cancelTask: (@Sendable () -> Void)?

    public init() {}

    /// True once `cancel()` was called.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Idempotent. Closes the registered request and cancels the bound task.
    public func cancel() {
        lock.lock()
        cancelled = true
        let close = closer
        closer = nil
        let stopTask = cancelTask
        lock.unlock()
        close?()
        stopTask?()
    }

    /// Throws `CancellationError` when this attempt (or the current `Task`) is cancelled
    /// (Android `check()` throws `InterruptedException`).
    public func checkpoint() throws {
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Registers the closer of the in-flight request (`handle.cancel()`). If the attempt is
    /// already cancelled the closer runs immediately.
    public func register(closer: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            closer()
            return
        }
        self.closer = closer
        lock.unlock()
    }

    /// Clears the request closer after the request finished (Android `finally { … request = null }`).
    public func clearCloser() {
        lock.lock()
        closer = nil
        lock.unlock()
    }

    /// Binds the task running the enrollment so `cancel()` also cancels it. If already
    /// cancelled the task is cancelled immediately.
    public func bind<T, E>(_ task: Task<T, E>) where T: Sendable, E: Error {
        let stop: @Sendable () -> Void = { task.cancel() }
        lock.lock()
        if cancelled {
            lock.unlock()
            stop()
            return
        }
        cancelTask = stop
        lock.unlock()
    }
}
