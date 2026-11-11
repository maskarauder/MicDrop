import Foundation

/// Lifetime of one worker request, registered before its asynchronous operation starts.
/// A retired registration cancels late handles without publishing them into the next request.
/// Only a remote `/status` registration may be cancelled for a network handoff.
public final class SessionRequestRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: ControlRequestHandle?
    private var cancelled = false
    private var finished = false
    private var handedOff = false

    public init() {}

    public func attach(_ handle: ControlRequestHandle) {
        lock.lock()
        let cancelNow = cancelled || finished
        if !cancelNow { self.handle = handle }
        lock.unlock()
        if cancelNow { handle.cancel() }
    }

    /// Stop cancels this request even when its transport has not registered a handle yet.
    public func cancel() {
        cancel(forHandoff: false)
    }

    /// Interrupt the old network's heartbeat while keeping the session eligible for recovery.
    public func cancelForHandoff() {
        cancel(forHandoff: true)
    }

    /// Called on every worker exit, including timeout. Later callbacks cannot revive the request.
    public func finish() {
        lock.lock()
        finished = true
        handle = nil
        lock.unlock()
    }

    /// Transports report handle cancellation as `SessionStopped`. At the session boundary only
    /// a known handoff becomes retryable I/O; Stop wins, and TLS/protocol failures stay unchanged.
    public func failure(_ error: Error, sessionClosed: Bool) -> Error {
        if sessionClosed { return SessionStopped() }
        lock.lock()
        let retryHandoff = handedOff
        lock.unlock()
        if retryHandoff && ConnectionFailure.isCancellation(error) && !ConnectionFailure.isTLSFailure(error) {
            return ControlIOError(.transportClosed)
        }
        return error
    }

    private func cancel(forHandoff: Bool) {
        lock.lock()
        guard !finished, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        handedOff = forHandoff
        let current = handle
        lock.unlock()
        current?.cancel()
    }
}
