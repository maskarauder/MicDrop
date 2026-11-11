import Foundation
import MicDropCore
import NIOCore

/// One remote control request: a brand-new rendezvous tunnel, the inner paired TLS, one HTTP/1.0
/// exchange, teardown (`RemoteHttp.kt:14-63`, `RemoteTunnel.kt`).
///
/// Never pooled, pipelined or retried (`docs/REMOTE_ACCESS.md`). All mutable state is confined
/// to `loop`; `cancel()` may be called from any thread and never blocks.
///
/// `run()`:
/// 1. If already cancelled → fail with `SessionStopped()` (no connection is opened).
/// 2. Schedule the absolute deadline `loop.scheduleTask(in: .milliseconds(timeoutMs))` →
///    `latch.recordLocal(.timedOut)`, `closer.abort()`; cancelled on completion.
/// 3. `connector.connectRendezvous(route:outerTrust:verdict:connectTimeout: min(8000, timeoutMs) ms)`
///    whose initializer captures the channel (so cancel/deadline can close it while connecting,
///    `RemoteTunnel.kt:81-90`) and installs `RendezvousUpgrade.install(…)` with a
///    `RendezvousFrameAdapter` whose `onReady` returns `[setup.makeHandler(), ControlExchangeHandler(…)]`.
/// 4. Connect failure → `latch.recordOuter(connector.classifyRendezvousConnectFailure(error, verdict:))`,
///    fail with `latch.resolve()` (local precedence first).
/// 5. `channel.closeFuture` → if the promise is still pending, fail with `latch.resolve()`.
public final class RemoteExchange: @unchecked Sendable {
    /// Default rendezvous connect budget; session preferences may override it within 30 s.
    public static let connectTimeoutCapMs = 8000

    public let route: RemoteRoute
    public let setup: ControlTLSSetup
    public let requestBytes: [UInt8]
    public let maxResponseBytes: Int
    public let timeoutMs: Int
    public let connector: ControlConnector
    public let outerTrust: OuterTrustPolicy
    public let connectTimeoutMs: Int
    /// Stage evidence for the session's failure history (`RemoteHttp.kt` `phase`).
    public let progress: SignalingRequestProgress
    /// The loop every handler and the latch of this exchange are confined to.
    public let loop: EventLoop

    private let cancelled = Locked(false)
    private let sent = Locked(false)
    public var requestWasSent: Bool { sent.value }
    private let latch = TerminalErrorLatch(tunnelled: true)
    private let closer = TransportCloser()
    private let verdict = OuterTrustVerdictBox()
    private var channel: Channel?
    private var completion: EventLoopPromise<ControlResponse>?
    private var deadline: Scheduled<Void>?
    private var finished = false
    private var connected = false

    /// - Parameters:
    ///   - requestBytes: `ControlRequestEncoder.encode(_:host:)` with the paired record's LAN endpoint.
    ///   - maxResponseBytes: `ControlRequest.maxResponseBytes` (1024 for `/pair`).
    ///   - timeoutMs: the absolute deadline for the whole exchange (the session already applied
    ///     remote formula).
    public init(
        route: RemoteRoute, setup: ControlTLSSetup, requestBytes: [UInt8], maxResponseBytes: Int,
        timeoutMs: Int, connector: ControlConnector, outerTrust: OuterTrustPolicy,
        connectTimeoutMs: Int = RemoteExchange.connectTimeoutCapMs,
        progress: SignalingRequestProgress = SignalingRequestProgress(.rendezvousConnect)
    ) {
        self.route = route
        self.setup = setup
        self.requestBytes = requestBytes
        self.maxResponseBytes = maxResponseBytes
        self.timeoutMs = timeoutMs
        self.connector = connector
        self.outerTrust = outerTrust
        self.connectTimeoutMs = max(1, min(connectTimeoutMs, 30_000))
        self.progress = progress
        self.loop = connector.nextLoop()
    }

    /// `true` once `cancel()` was called.
    public var isCancelled: Bool {
        cancelled.value
    }

    /// Runs the exchange once (see type documentation). Call at most once.
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
            deadline = loop.scheduleTask(in: .milliseconds(Int64(max(1, timeoutMs)))) { [self] in
                expire()
            }
            connector.connectRendezvous(
                route: route, outerTrust: outerTrust, verdict: verdict,
                connectTimeout: .milliseconds(Int64(min(max(1, timeoutMs), connectTimeoutMs))), on: loop,
                initializer: { [self] channel, outerTLS in
                    self.channel = channel
                    guard !finished, !isCancelled, latch.local == nil else {
                        if isCancelled { latch.recordLocal(.cancelled) }
                        channel.close(promise: nil)
                        return loop.makeFailedFuture(latch.resolve())
                    }
                    // A failed connect can close before its typed error is delivered. Let that
                    // future publish the outer verdict before choosing the terminal error.
                    channel.closeFuture.whenComplete { [self] _ in
                        if connected { failIfPending(latch.resolve()) }
                    }
                    return loop.makeCompletedFuture {
                        let adapter = RendezvousFrameAdapter(
                            latch: latch, closer: closer,
                            classifyTransportError: { [self] error in
                                connector.classifyOuterError(error, verdict: verdict, duringHandshake: false)
                            },
                            onReady: { [self] _ in
                                progress.advance(to: .windowsTLS)
                                let tls = try setup.makeHandler()
                                return [
                                    tls,
                                    ControlExchangeHandler(
                                        requestBytes: requestBytes,
                                        parser: StrictHTTPResponse.Parser(maxBody: maxResponseBytes),
                                        latch: latch, setup: setup, completion: promise, closer: closer, innerTLS: tls,
                                        onRequestSent: { [self] in sent.value = true },
                                        onProgress: { [progress] in progress.advance(to: $0) }),
                                ]
                            })
                        try RendezvousUpgrade.install(
                            on: channel, route: route, closer: closer, outerTLS: outerTLS,
                            latch: latch, adapter: adapter,
                            classifyTransportError: { [self] error in
                                connector.classifyOuterError(error, verdict: verdict, duringHandshake: true)
                            },
                            onUpgraded: { [progress] in progress.advance(to: .waitingForWindows) })
                    }
                }
            ).whenComplete { [self] result in
                switch result {
                case .failure(let error):
                    latch.recordOuter(connector.classifyRendezvousConnectFailure(error, verdict: verdict))
                    failIfPending(latch.resolve())
                case .success(let channel):
                    connected = true
                    if !channel.isActive { failIfPending(latch.resolve()) }
                }
            }
        }
        return promise.futureResult
    }

    /// Non-blocking, idempotent: marks cancelled, then on `loop` records `latch.recordLocal(.cancelled)`
    /// and `closer.abort()`; if the channel does not exist yet, the initializer closes it on attach
    /// (Android spawns a closer thread, `RemoteHttp.kt:59-62`).
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
        abort()
    }

    private func expire() {
        guard !finished else { return }
        if !latch.hasRecordedError { latch.recordLocal(.timedOut) }
        abort()
        failIfPending(latch.resolve())
    }

    private func abort() {
        closer.abort()
        if !closer.aborted { channel?.close(promise: nil) }
        if channel == nil { failIfPending(latch.resolve()) }
    }

    private func failIfPending(_ error: Error) {
        guard !finished, let completion else { return }
        finished = true
        completion.fail(error)
    }
}
