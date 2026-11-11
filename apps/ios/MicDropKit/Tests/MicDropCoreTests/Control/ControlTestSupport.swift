import Foundation
import XCTest

@testable import MicDropCore

/// Shared helpers of the core-control tests. Everything is nested so no top-level name can collide
/// with another owner's tests in the `MicDropCoreTests` module.
enum ControlTestSupport {
    /// A cause-carrying wrapper (Kotlin `ExecutionException(cause)` / `initCause` in the Android tests).
    struct Wrapped: Error, UnderlyingErrorProviding {
        let underlying: Error?

        init(_ underlying: Error?) {
            self.underlying = underlying
        }
    }

    /// An error type the classifier does not know (Kotlin `IllegalStateException("secret-…")`). Its
    /// description carries a secret so tests can prove that no message reaches user text.
    struct Unclassified: Error, CustomStringConvertible {
        let secret: String

        init(_ secret: String = "secret-sdp-token-address") {
            self.secret = secret
        }

        var description: String { secret }
    }

    /// `error` inside `levels` wrappers (the chain then has `levels + 1` entries).
    static func nested(_ error: Error, levels: Int) -> Error {
        var current: Error = error
        for _ in 0..<levels { current = Wrapped(current) }
        return current
    }

    /// Every `ControlIOError` kind.
    static let allIOKinds: [ControlIOError.Kind] = [
        .rendezvousFailed, .rendezvousClosed, .invalidRendezvousStream, .transportClosed, .timedOut,
        .unreachable, .localNetworkDenied, .lanNetworkUnavailable, .protocolViolation("Invalid HTTP line"),
        .iceServiceUnavailable, .iceUnavailable(.throttled), .iceUnavailable(.tooLarge),
        .iceUnavailable(.forcedRelayRequiresTURN),
    ]

    /// Polls `condition` every millisecond until it holds or `timeout` elapses.
    static func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    /// `attemptNonce(n)` of `internal/session/offer_cancel_test.go:15-17`: base64url of 32 bytes `n`.
    static func attemptNonce(_ value: UInt8) -> String {
        base64URL([UInt8](repeating: value, count: 32))
    }

    /// Unpadded base64url.
    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url; nil when malformed.
    static func decodeBase64URL(_ text: String) -> [UInt8]? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.utf8.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64).map { [UInt8]($0) }
    }

    static func json(_ text: String) throws -> ControlJSON {
        try ControlJSON(bytes: Array(text.utf8))
    }

    static func text(_ data: Data?) -> String? {
        data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// A synthetic session worker (`SessionWorkerWaitTest.Owner`): one dedicated `Thread` running
    /// `operation`, a `closed` flag read by its `SessionWorkerWait`, and `stop()` = Stop.
    final class Worker: @unchecked Sendable {
        let closed: Locked<Bool>
        let waits: SessionWorkerWait
        let failure = Locked<Error?>(nil)
        private let finished = DispatchSemaphore(value: 0)
        private let operation: @Sendable (Worker) throws -> Void

        init(_ operation: @escaping @Sendable (Worker) throws -> Void) {
            let flag = Locked(false)
            closed = flag
            waits = SessionWorkerWait(isCancelled: { flag.value })
            self.operation = operation
        }

        func start() {
            let thread = Thread { [self] in
                do {
                    try operation(self)
                } catch {
                    failure.value = error
                }
                finished.signal()
            }
            thread.name = "synthetic-session-owner"
            thread.start()
        }

        /// Kotlin `stop()`: `closed = true` **before** `cancel()`.
        func stop() {
            closed.value = true
            waits.cancel()
        }

        /// True once the worker finished within `timeout` seconds.
        func finish(timeout: TimeInterval = 5) -> Bool {
            finished.wait(timeout: .now() + timeout) == .success
        }

        var stopped: Bool { failure.value is SessionStopped }
    }

    /// One in-flight exchange of `ScriptedTransport`, completed by the test or by its cancel handle.
    final class PendingReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ControlResponse, Error>?
        private var outcome: Result<ControlResponse, Error>?

        func wait() async throws -> ControlResponse {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ControlResponse, Error>) in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(with: outcome)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        /// First call wins.
        func finish(_ result: Result<ControlResponse, Error>) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return outcome != nil
        }
    }

    /// A `ControlTransport` whose replies are scripted by the test. `onStart` receives a handle whose
    /// `cancel()` ends the exchange with `SessionStopped` (as the real transports do).
    final class ScriptedTransport: ControlTransport, @unchecked Sendable {
        enum Behaviour {
            case reply(ControlResponse)
            case fail(Error)
            /// Blocks until the test calls `finish` on the pending reply or the handle is cancelled.
            case block
        }

        let requests = Locked<[ControlRequest]>([])
        let timeouts = Locked<[Int]>([])
        let handles = Locked<[ControlRequestHandle]>([])
        let pending = Locked<[PendingReply]>([])
        private let behaviour: Behaviour

        init(_ behaviour: Behaviour) {
            self.behaviour = behaviour
        }

        convenience init(body: String) {
            self.init(.reply(ControlResponse(body: Array(body.utf8))))
        }

        func send(
            _ request: ControlRequest, timeoutMs: Int,
            onStart: (ControlRequestHandle) -> Void
        ) async throws -> ControlResponse {
            requests.withLock { $0.append(request) }
            timeouts.withLock { $0.append(timeoutMs) }
            let reply = PendingReply()
            let handle = ControlRequestHandle { reply.finish(.failure(SessionStopped())) }
            handles.withLock { $0.append(handle) }
            pending.withLock { $0.append(reply) }
            onStart(handle)
            switch behaviour {
            case .reply(let response):
                reply.finish(.success(response))
            case .fail(let error):
                reply.finish(.failure(error))
            case .block:
                break
            }
            return try await reply.wait()
        }
    }
}
