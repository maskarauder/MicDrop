import Foundation

/// The session worker's cancellable waits (`A/SessionWorkerWait.kt`).
///
/// One `SessionWorkerWait` per session; every blocking call runs on that session's dedicated
/// worker `Thread`. Registration, exit and `cancel()` share one `NSCondition`, so Stop wakes a
/// registered wait and can never leak into native setup or disposal:
/// - `checkpoint()` throws `SessionStopped` once the session is closed;
/// - `cancel()` wakes the worker **only** while it is inside a registered, interruptible wait
///   (and cancels that wait's in-flight control request); a late or repeated `cancel()` is a no-op;
/// - an operation is *started before* the wait registers (`start` closure), so a native call is
///   never interrupted; its completion may arrive from any thread;
/// - after a successful wait `checkpoint()` runs again: a completion cannot authorize work after Stop.
///
/// Callers must set their `closed` flag **before** calling `cancel()`.
public final class SessionWorkerWait: @unchecked Sendable {
    /// One-shot result box for an asynchronous operation (WebRTC completion handler, a
    /// `ControlTransport.send` Task, an audio permit grant, a control signal). The first
    /// completion wins; later ones are ignored.
    public final class Completion<T>: @unchecked Sendable {
        private let condition: NSCondition
        fileprivate var result: Result<T, Error>?

        fileprivate init(condition: NSCondition) {
            self.condition = condition
        }

        public func complete(_ result: Result<T, Error>) {
            condition.lock()
            if self.result == nil {
                self.result = result
                condition.broadcast()
            }
            condition.unlock()
        }

        public func succeed(_ value: T) {
            complete(.success(value))
        }

        public func fail(_ error: Error) {
            complete(.failure(error))
        }

        public var isCompleted: Bool {
            condition.lock()
            defer { condition.unlock() }
            return result != nil
        }
    }

    /// Extra worker-side bound on a transport exchange beyond its own deadline: the worker
    /// gives up after `2 * timeoutMs + transportGraceMs` (LAN idle semantics can exceed
    /// `timeoutMs`), cancels the request and throws `ControlIOError(.timedOut)`.
    public static let transportGraceMs = 5_000

    private let condition = NSCondition()
    private let isCancelled: () -> Bool
    // Guarded by `condition`.
    private var waiting = false
    private var interruptible = false
    private var interrupted = false
    private var activeRequest: RequestBox?

    /// `isCancelled` reads the session's `closed` flag; it must not take this wait's lock.
    public init(isCancelled: @escaping () -> Bool) {
        self.isCancelled = isCancelled
    }

    /// Throws `SessionStopped` if the session is closed.
    public func checkpoint() throws {
        if isCancelled() { throw SessionStopped() }
    }

    /// Wakes the worker iff it is inside a registered interruptible wait; cancels that wait's
    /// registered control request (never a `stopping` one).
    public func cancel() {
        condition.lock()
        var request: RequestBox?
        if waiting && interruptible {
            interrupted = true
            request = activeRequest
            condition.broadcast()
        }
        condition.unlock()
        request?.cancel()
    }

    /// True while the worker is blocked in a registered wait (tests).
    public var isWaiting: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waiting
    }

    /// Kotlin `await { operation }` for an asynchronous operation: `checkpoint()`, `start` the operation (it must
    /// eventually complete the box from any thread), block until completion, `timeoutMs` (nil = unbounded; expiry →
    /// `StageTimeoutError`) or `cancel()` (→ `SessionStopped`), then `checkpoint()` again after a success. A failure
    /// completion rethrows its error. (calls this `await(timeoutMs:_:)`.)
    public func awaitCompletion<T>(timeoutMs: Int?, _ start: (Completion<T>) throws -> Void) throws -> T {
        try checkpoint()
        let completion = Completion<T>(condition: condition)
        try start(completion)
        switch block(completion, timeoutMs: timeoutMs, interruptible: true, request: nil) {
        case .finished(.success(let value)):
            try checkpoint()
            return value
        case .finished(.failure(let error)):
            throw error
        case .stopped:
            throw SessionStopped()
        case .timedOut:
            throw StageTimeoutError()
        }
    }

    /// Like `awaitCompletion(timeoutMs:_:)`, but an expired wait returns `fallback`
    /// (Kotlin `Object.wait(ms)` / latch `await(ms)` returning false).
    public func awaitCompletion<T>(timeoutMs: Int, orElse fallback: T, _ start: (Completion<T>) throws -> Void) throws
        -> T
    {
        try checkpoint()
        let completion = Completion<T>(condition: condition)
        try start(completion)
        switch block(completion, timeoutMs: timeoutMs, interruptible: true, request: nil) {
        case .finished(.success(let value)):
            try checkpoint()
            return value
        case .finished(.failure(let error)):
            throw error
        case .stopped:
            throw SessionStopped()
        case .timedOut:
            try checkpoint()
            return fallback
        }
    }

    /// Callback spelling of `awaitCompletion(timeoutMs:_:)` (`await`), used as `try wait.await(timeoutMs: 15000) {
    /// complete in peer.answer(…) { … complete(.success(sdp)) } }`. `complete` may be called from any thread; only the
    /// first call counts. Same semantics: timeout → `StageTimeoutError`, `cancel()` → `SessionStopped`, `checkpoint()`
    /// after success.
    public func `await`<T>(timeoutMs: Int, _ start: (@escaping (Result<T, Error>) -> Void) throws -> Void) throws -> T {
        try awaitCompletion(timeoutMs: timeoutMs) { (completion: Completion<T>) in
            try start { result in completion.complete(result) }
        }
    }

    /// Interruptible sleep (Kotlin `workerWait.await { Thread.sleep(ms) }`); Stop → `SessionStopped`.
    public func sleep(ms: Int) throws {
        try awaitCompletion(timeoutMs: max(0, ms), orElse: ()) { (_: Completion<Void>) in }
    }

    /// Runs an async operation in a detached `Task` and blocks the worker until it finishes (bridge for
    /// `ControlTransport.send`, the `/v1/ice` fetch, …).
    ///
    /// `operation` receives `register`, which it must call with the operation's cancel handle as soon as one exists.
    /// Unless `stopping`, `cancel()` wakes the worker, cancels the registered handle and the call throws
    /// `SessionStopped`. A `stopping` call (final `/stop`, `/cancel-offer`) skips both checkpoints and ignores
    /// `cancel()`. `timeoutMs` expiry (nil = unbounded) cancels the handle and task and throws
    /// `ControlIOError(.timedOut)`. A failure while the session is closed is reported as `SessionStopped`.
    public func runAsync<T: Sendable>(
        timeoutMs: Int?, stopping: Bool = false,
        _ operation:
            @escaping @Sendable (_ register: @escaping @Sendable (ControlRequestHandle) -> Void) async throws -> T
    ) throws -> T {
        if !stopping { try checkpoint() }
        let completion = Completion<T>(condition: condition)
        let box = RequestBox()
        let task = Task.detached {
            do {
                try Task.checkCancellation()
                let value = try await operation({ handle in box.attach(handle) })
                completion.succeed(value)
            } catch {
                completion.fail(error)
            }
        }
        switch block(completion, timeoutMs: timeoutMs, interruptible: !stopping, request: box) {
        case .finished(.success(let value)):
            if !stopping { try checkpoint() }
            return value
        case .finished(.failure(let error)):
            if !stopping && isCancelled() { throw SessionStopped() }
            throw error
        case .stopped:
            box.cancel()
            task.cancel()
            throw SessionStopped()
        case .timedOut:
            box.cancel()
            task.cancel()
            throw ControlIOError(.timedOut)
        }
    }

    /// One control request from the worker (Kotlin `request(...)`'s transport part).
    /// `timeoutMs` must already be `ControlRequest.effectiveTimeoutMs(...)`. `onStart` receives
    /// the handle too (e.g. the remote `/status` handle that a network handoff may cancel).
    public func send(
        _ request: ControlRequest, over transport: any ControlTransport, timeoutMs: Int,
        stopping: Bool = false, waitTimeoutMs: Int? = nil,
        onStart: @escaping @Sendable (ControlRequestHandle) -> Void = { _ in }
    ) throws -> ControlResponse {
        let bound = 2 * max(0, timeoutMs) + SessionWorkerWait.transportGraceMs
        return try runAsync(timeoutMs: min(bound, waitTimeoutMs ?? bound), stopping: stopping) { register in
            try await transport.send(request, timeoutMs: timeoutMs) { handle in
                register(handle)
                onStart(handle)
            }
        }
    }

    /// `send` + `ControlJSON` parsing (`ControlResponseError(.invalidJSON)` on a non-object body).
    public func sendJSON(
        _ request: ControlRequest, over transport: any ControlTransport, timeoutMs: Int,
        stopping: Bool = false, waitTimeoutMs: Int? = nil,
        onStart: @escaping @Sendable (ControlRequestHandle) -> Void = { _ in }
    ) throws -> ControlJSON {
        try send(
            request, over: transport, timeoutMs: timeoutMs, stopping: stopping,
            waitTimeoutMs: waitTimeoutMs, onStart: onStart
        ).json()
    }

    // MARK: Private

    private enum Outcome<T> {
        case finished(Result<T, Error>)
        case stopped
        case timedOut
    }

    /// Cancel handle of the request a `runAsync` wait is blocked on.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: ControlRequestHandle?
        private var cancelled = false

        func attach(_ newHandle: ControlRequestHandle) {
            lock.lock()
            handle = newHandle
            let cancelNow = cancelled
            lock.unlock()
            if cancelNow { newHandle.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = handle
            lock.unlock()
            current?.cancel()
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Registers, blocks on the condition, unregisters. A registration after Stop
    /// (`isCancelled()`) returns `.stopped` immediately for interruptible waits.
    private func block<T>(
        _ completion: Completion<T>, timeoutMs: Int?, interruptible: Bool,
        request: RequestBox?
    ) -> Outcome<T> {
        let clock = ContinuousClock()
        let deadline = timeoutMs.map { clock.now + .milliseconds(max(0, $0)) }
        condition.lock()
        defer { condition.unlock() }
        if interruptible && isCancelled() { return .stopped }
        waiting = true
        self.interruptible = interruptible
        interrupted = false
        activeRequest = request
        defer {
            waiting = false
            self.interruptible = false
            interrupted = false
            activeRequest = nil
        }
        while true {
            if let result = completion.result { return .finished(result) }
            if interruptible && interrupted { return .stopped }
            if let deadline {
                let remaining = deadline - clock.now
                if remaining <= .zero { return .timedOut }
                _ = condition.wait(until: Date(timeIntervalSinceNow: SessionWorkerWait.seconds(remaining)))
            } else {
                condition.wait()
            }
        }
    }
}
