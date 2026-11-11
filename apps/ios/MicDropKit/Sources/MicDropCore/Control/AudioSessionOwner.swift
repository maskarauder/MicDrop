import Foundation

/// Process-wide single audio permit, FIFO (Android `AudioSessionOwner.lock = Semaphore(1)`,
/// `A/LocalOutputProbe.kt:13`).
///
/// A session worker acquires it at stage WAITING inside its `SessionWorkerWait` and releases it as the very last
/// cleanup step, after factory deallocation is confirmed and immediately before `onEnded` (step 10). Local diagnostic
/// tools take it with `tryAcquire()` from the main actor.
///
/// Cancellation semantics (`SessionWorkerWaitTest.kt:100-137`): a waiter stopped while queued
/// is removed from the queue and never consumes or releases another session's permit; a
/// waiter stopped after the permit was granted to it releases it before throwing.
public final class AudioSessionOwner: @unchecked Sendable {
    public static let shared = AudioSessionOwner()

    private final class Ticket {
        var granted = false
        var completion: SessionWorkerWait.Completion<Void>?
    }

    private let lock = NSLock()
    private var held = false
    private var queue: [Ticket] = []

    public init() {}

    /// True while some owner holds the permit.
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Blocks the worker until the permit is granted (FIFO). Stop (`wait.cancel()`) →
    /// `SessionStopped`, with the permit returned if it had already been granted.
    public func acquire(_ wait: SessionWorkerWait) throws {
        try wait.checkpoint()
        let ticket = Ticket()
        lock.lock()
        if !held && queue.isEmpty {
            held = true
            ticket.granted = true
        } else {
            queue.append(ticket)
        }
        lock.unlock()
        do {
            try wait.awaitCompletion(timeoutMs: nil) { (completion: SessionWorkerWait.Completion<Void>) in
                lock.lock()
                if ticket.granted {
                    lock.unlock()
                    completion.succeed(())
                } else {
                    ticket.completion = completion
                    lock.unlock()
                }
            }
        } catch {
            if withdraw(ticket) { release() }
            throw error
        }
    }

    /// Non-blocking acquisition for main-actor local tools. Fails while a session holds the permit or one is queued.
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !held && queue.isEmpty else { return false }
        held = true
        return true
    }

    /// Releases the permit, handing it directly to the oldest queued waiter if any.
    public func release() {
        lock.lock()
        guard held else {
            lock.unlock()
            return
        }
        guard !queue.isEmpty else {
            held = false
            lock.unlock()
            return
        }
        let next = queue.removeFirst()
        next.granted = true
        let completion = next.completion
        lock.unlock()
        completion?.succeed(())
    }

    /// Returns true when the ticket already owns the permit (the caller must release it);
    /// otherwise removes it from the queue.
    private func withdraw(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ticket.granted { return true }
        queue.removeAll { $0 === ticket }
        return false
    }
}
