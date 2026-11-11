import Foundation

/// Wakes the session worker's loop waits (Kotlin `controlSignal.notifyAll()` / `workerWait.await {
/// controlSignal.wait(ms) }`).
///
/// Unlike `Object.wait`, a `notify()` that arrives while the worker is not waiting is **sticky**: the next `wait`
/// returns immediately (strictly better than Android). `notify()` may be called from any thread (UI mute changes,
/// route/peer callbacks) and never blocks.
public final class ControlSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: SessionWorkerWait.Completion<Bool>?

    public init() {}

    public func notify() {
        lock.lock()
        if let current = waiter {
            waiter = nil
            lock.unlock()
            current.succeed(true)
        } else {
            pending = true
            lock.unlock()
        }
    }

    /// Drops a pending notification without waiting.
    public func clear() {
        lock.lock()
        pending = false
        lock.unlock()
    }

    /// Waits up to `ms` for a notification without a `SessionWorkerWait` (not interruptible by
    /// `cancel()`; `close()` wakes it through `notify()`). Returns true when notified.
    @discardableResult
    public func wait(ms: Int) -> Bool {
        let standalone = SessionWorkerWait(isCancelled: { false })
        return (try? wait(ms: ms, in: standalone)) ?? false
    }

    /// Waits up to `ms` (interruptible through `wait.cancel()` → `SessionStopped`). Returns true
    /// when notified (including a pending notification), false on timeout.
    @discardableResult
    public func wait(ms: Int, in wait: SessionWorkerWait) throws -> Bool {
        var notified = false
        var registered: SessionWorkerWait.Completion<Bool>?
        defer {
            lock.lock()
            if let registered {
                if waiter === registered {
                    waiter = nil
                } else if !notified {
                    // notify() consumed our registration after the wait ended: keep it sticky.
                    pending = true
                }
            }
            lock.unlock()
        }
        notified = try wait.awaitCompletion(timeoutMs: max(0, ms), orElse: false) {
            (completion: SessionWorkerWait.Completion<Bool>) in
            lock.lock()
            if pending {
                pending = false
                lock.unlock()
                completion.succeed(true)
            } else {
                waiter = completion
                registered = completion
                lock.unlock()
            }
        }
        return notified
    }
}
