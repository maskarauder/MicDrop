import Foundation
import MicDropCore
import NIOCore

/// `ControlTransport` for LAN links: one fresh TCP connection to the paired record's private IPv4 per request (never
/// cellular on NIOTS), the inner paired TLS (identical `ControlTLSSetup.makeHandler()`), the identical HTTP/1.0 bytes
/// and strict parser.
///
/// Timing keeps Android's LAN socket semantics (`StreamReceiver.kt:1675`): connect timeout
/// `min(timeoutMs, connectTimeoutMs)` (8 s by default) and a per-read inactivity timeout of `timeoutMs`
/// (`IdleStateHandler(readTimeout:)`, reset on every inbound read). An inactivity timeout never ends a
/// reply that keeps trickling in, so every request also has the absolute deadline
/// `requestDeadlineMs(timeoutMs:connectTimeoutMs:)`, counted from the start of the exchange over
/// connect, TLS, request and response (the scheduled-deadline pattern of `RemoteExchange` and
/// `LocalProbe`). This bounds `/pair` polls, which no `SessionWorkerWait` wraps; `PairingClient`
/// also ends a poll when the approval window ends, if that is sooner.
///
/// Pipeline (head → tail): `TransportCloser`, `IdleStateHandler(readTimeout:)`,
/// `NIOSSLClientHandler` (inner), `ControlExchangeHandler`.
///
/// Throws `HTTPFailure`, `SignalingTLSFailure(.windows, …)`, `SignalingStreamEnded` (also for an EOF during the LAN TLS
/// handshake — accepted deviation), `ControlIOError` (`.unreachable`, `.timedOut`, `.localNetworkDenied`,
/// `.lanNetworkUnavailable`, `.protocolViolation`, `.transportClosed`), `SessionStopped`,
/// `ControlRequestEncoder.InvalidRequest`, `ControlTLS.SetupError`.
public final class LanControlTransport: ControlTransport, @unchecked Sendable {
    /// Default LAN connect cap; session preferences may override it within 30 s.
    public static let connectTimeoutCapMs = 8000

    /// Absolute bound on one LAN request: the connect budget `min(timeoutMs, connectTimeoutMs)` plus one
    /// read window of `timeoutMs` (each at least 1 ms; saturating). A connect that uses its whole budget
    /// still leaves the full read window. It stays below `SessionWorkerWait`'s
    /// `2 × timeoutMs + transportGraceMs`, so session workers keep their outer bound and see this
    /// transport's own `ControlIOError(.timedOut)` first; a LAN `/pair` poll
    /// (`timeoutMs = clamp(remaining, 1, 5000)`) ends within 10 s, and `PairingClient` caps it at
    /// the approval time left.
    public static func requestDeadlineMs(
        timeoutMs: Int, connectTimeoutMs: Int = LanControlTransport.connectTimeoutCapMs
    ) -> Int {
        let read = max(1, timeoutMs)
        let connect = min(read, max(1, min(connectTimeoutMs, 30_000)))
        let total = read.addingReportingOverflow(connect)
        return total.overflow ? Int.max : total.partialValue
    }

    public let link: ConnectionLink
    public let connector: ControlConnector
    public let connectTimeoutMs: Int

    private let tls: @Sendable () throws -> ControlTLSSetup

    /// - Parameters:
    ///   - connector: on iOS pass `.transportServices(lanHooks:)` with the session's
    ///     `LanSignalingRoute` hooks.
    ///   - tls: builds a **fresh** `ControlTLSSetup` per request.
    public init(
        link: ConnectionLink, connector: ControlConnector = .platformDefault,
        connectTimeoutMs: Int = LanControlTransport.connectTimeoutCapMs,
        tls: @escaping @Sendable () throws -> ControlTLSSetup
    ) {
        self.link = link
        self.connector = connector
        self.connectTimeoutMs = max(1, min(connectTimeoutMs, 30_000))
        self.tls = tls
    }

    public convenience init(
        link: ConnectionLink, client: ControlTLS.ClientIdentity?,
        connector: ControlConnector = .platformDefault,
        connectTimeoutMs: Int = LanControlTransport.connectTimeoutCapMs
    ) {
        self.init(
            link: link, connector: connector, connectTimeoutMs: connectTimeoutMs,
            tls: { try ControlTLS.setup(for: link, client: client) })
    }

    public func send(
        _ request: ControlRequest, timeoutMs: Int,
        onStart: (ControlRequestHandle) -> Void
    ) async throws -> ControlResponse {
        let bytes = try ControlRequestEncoder.encode(request, host: link.endpoint)
        let setup = try tls()
        let progress = SignalingRequestProgress(.lanRequest)
        let exchange = Exchange(
            endpoint: link.endpoint, setup: setup, requestBytes: bytes,
            maxResponseBytes: request.maxResponseBytes, timeoutMs: max(1, timeoutMs),
            connector: connector, connectTimeoutMs: connectTimeoutMs, progress: progress)
        onStart(ControlRequestHandle(progress: progress) { exchange.cancel() })
        return try await withTaskCancellationHandler {
            try await exchange.run().get()
        } onCancel: {
            exchange.cancel()
        }
    }

    /// One LAN request. All mutable state is confined to `loop`; `cancel()` is non-blocking and callable from any
    /// thread.
    ///
    /// `run()`: already cancelled → `SessionStopped()`; schedules the absolute deadline
    /// (`deadlineMs`, cancelled on completion); `connector.connectLAN(endpoint:connectTimeout:
    /// min(timeoutMs, connectTimeoutMs) ms)` with an initializer that captures the channel and adds
    /// `[closer, IdleStateHandler(readTimeout: .milliseconds(timeoutMs)), setup.makeHandler(),
    /// ControlExchangeHandler(requestBytes:parser: StrictHTTPResponse.Parser(maxBody:)latch:
    /// TerminalErrorLatch(tunnelled: false)…)]`; connect failure → the connector's classified error
    /// (unless `latch.local` is set → `latch.resolve()`); the exchange handler completes the promise.
    ///
    /// Deadline expiry with no recorded error → `latch.recordLocal(.timedOut)`. A paired-TLS trust,
    /// transport or framing failure (or a cancel) recorded first keeps its classification. Either way
    /// the connection or connect attempt is closed and the promise fails at once; a late response,
    /// close or connect result is ignored.
    public final class Exchange: @unchecked Sendable {
        /// Opens the LAN connection: `ControlConnector.connectLAN(endpoint:connectTimeout:on:initializer:)`
        /// in production; tests substitute a scripted channel.
        typealias Connect =
            (LANEndpoint, TimeAmount, EventLoop, @escaping @Sendable (Channel) -> EventLoopFuture<Void>)
            -> EventLoopFuture<Channel>

        public let endpoint: LANEndpoint
        public let setup: ControlTLSSetup
        public let requestBytes: [UInt8]
        public let maxResponseBytes: Int
        public let timeoutMs: Int
        public let connector: ControlConnector
        public let connectTimeoutMs: Int
        /// The absolute deadline from `run()`: `LanControlTransport.requestDeadlineMs(timeoutMs:connectTimeoutMs:)`.
        public let deadlineMs: Int
        /// Stage evidence for the session's failure history (`localRequest` `phase`).
        public let progress: SignalingRequestProgress
        public let loop: EventLoop

        private let connect: Connect
        private let cancelled = Locked(false)
        private let latch = TerminalErrorLatch(tunnelled: false)
        private let closer = TransportCloser()
        private var channel: Channel?
        private var completion: EventLoopPromise<ControlResponse>?
        private var deadline: Scheduled<Void>?
        private var finished = false

        public convenience init(
            endpoint: LANEndpoint, setup: ControlTLSSetup, requestBytes: [UInt8], maxResponseBytes: Int,
            timeoutMs: Int, connector: ControlConnector,
            connectTimeoutMs: Int = LanControlTransport.connectTimeoutCapMs,
            progress: SignalingRequestProgress = SignalingRequestProgress(.lanRequest)
        ) {
            self.init(
                endpoint: endpoint, setup: setup, requestBytes: requestBytes, maxResponseBytes: maxResponseBytes,
                timeoutMs: timeoutMs, connector: connector, connectTimeoutMs: connectTimeoutMs, progress: progress,
                connect: { endpoint, timeout, loop, initializer in
                    connector.connectLAN(
                        endpoint: endpoint, connectTimeout: timeout, on: loop, initializer: initializer)
                })
        }

        /// `connect` replaces `connector.connectLAN`; the exchange still runs on `connector.nextLoop()`.
        init(
            endpoint: LANEndpoint, setup: ControlTLSSetup, requestBytes: [UInt8], maxResponseBytes: Int,
            timeoutMs: Int, connector: ControlConnector, connectTimeoutMs: Int,
            progress: SignalingRequestProgress, connect: @escaping Connect
        ) {
            self.endpoint = endpoint
            self.setup = setup
            self.requestBytes = requestBytes
            self.maxResponseBytes = maxResponseBytes
            self.timeoutMs = timeoutMs
            self.connector = connector
            self.connectTimeoutMs = max(1, min(connectTimeoutMs, 30_000))
            self.deadlineMs = LanControlTransport.requestDeadlineMs(
                timeoutMs: timeoutMs, connectTimeoutMs: self.connectTimeoutMs)
            self.progress = progress
            self.loop = connector.nextLoop()
            self.connect = connect
        }

        public var isCancelled: Bool {
            cancelled.value
        }

        /// Runs the request once (see type documentation). Call at most once.
        public func run() -> EventLoopFuture<ControlResponse> {
            let promise = loop.makePromise(of: ControlResponse.self)
            loop.execute { [self] in
                guard completion == nil else {
                    promise.fail(ControlIOError(.transportClosed))
                    return
                }
                completion = promise
                promise.futureResult.whenComplete { [self] _ in
                    finished = true
                    deadline?.cancel()
                    deadline = nil
                }
                if isCancelled {
                    latch.recordLocal(.cancelled)
                    failIfPending(latch.resolve())
                    return
                }
                deadline = loop.scheduleTask(in: .milliseconds(Int64(deadlineMs))) { [self] in expire() }
                connect(
                    endpoint, .milliseconds(Int64(min(max(1, timeoutMs), connectTimeoutMs))), loop,
                    { [self] channel in
                        self.channel = channel
                        guard !isCancelled, !finished else {
                            latch.recordLocal(.cancelled)
                            channel.close(promise: nil)
                            return loop.makeFailedFuture(latch.resolve())
                        }
                        return loop.makeCompletedFuture {
                            let tls = try setup.makeHandler()
                            try channel.pipeline.syncOperations.addHandlers([
                                closer, IdleStateHandler(readTimeout: .milliseconds(Int64(max(1, timeoutMs)))), tls,
                                ControlExchangeHandler(
                                    requestBytes: requestBytes,
                                    parser: StrictHTTPResponse.Parser(maxBody: maxResponseBytes),
                                    latch: latch, setup: setup, completion: promise, closer: closer, innerTLS: tls,
                                    onProgress: { [progress] phase in
                                        // Android keeps LAN_REQUEST until the request was written.
                                        if phase != .requestWrite { progress.advance(to: phase) }
                                    }),
                            ])
                        }
                    }
                ).whenComplete { [self] result in
                    if case .failure(let error) = result {
                        failIfPending(latch.local != nil ? latch.resolve() : error)
                    }
                }
            }
            return promise.futureResult
        }

        /// Marks cancelled; on `loop`: `latch.recordLocal(.cancelled)`, `closer.abort()` (or close the
        /// captured channel if the closer is not yet in a pipeline).
        public func cancel() {
            let first: Bool = cancelled.withLock { value in
                let wasCancelled = value
                value = true
                return !wasCancelled
            }
            guard first else {
                return
            }
            loop.execute { [self] in
                self.abortForCancel()
            }
        }

        private func abortForCancel() {
            guard !finished else { return }
            latch.recordLocal(.cancelled)
            closer.abort()
            if !closer.aborted { channel?.close(promise: nil) }
            if channel == nil { failIfPending(latch.resolve()) }
        }

        /// The absolute deadline. An error recorded before it (trust, transport, framing, cancel) is
        /// already closing the channel and keeps its classification. Completes now rather than after
        /// the close, which a Network.framework connection reports asynchronously.
        private func expire() {
            guard !finished else { return }
            if !latch.hasRecordedError { latch.recordLocal(.timedOut) }
            closer.abort()
            if !closer.aborted { channel?.close(promise: nil) }
            failIfPending(latch.resolve())
        }

        private func failIfPending(_ error: Error) {
            guard !finished, let completion else { return }
            finished = true
            completion.fail(error)
        }
    }
}
