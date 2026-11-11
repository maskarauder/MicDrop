import Foundation
import MicDropCore
import NIOCore
import NIOSSL
import NIOTLS

/// Verifies the saved Windows host without sending HTTP, invitation or session tokens.
/// Paired TLS verifies the pin, certificate validity and the saved literal IP SAN.
public final class LocalProbe: LocalHostProbing, @unchecked Sendable {
    private let endpoint: LANEndpoint
    private let connector: ControlConnector
    private let tls: @Sendable () throws -> ControlTLSSetup

    public init(
        link: ConnectionLink, connector: ControlConnector = .platformDefault,
        tls: @escaping @Sendable () throws -> ControlTLSSetup
    ) {
        endpoint = link.endpoint
        self.connector = connector
        self.tls = tls
    }

    public func reachable(
        timeoutMs: Int, onStart: (ControlRequestHandle) -> Void = { _ in }
    ) async throws -> Bool {
        guard (1...5_000).contains(timeoutMs) else { throw ControlResponseError(.invalidReply) }
        let exchange = Exchange(endpoint: endpoint, setup: try tls(), connector: connector, timeoutMs: timeoutMs)
        onStart(ControlRequestHandle { exchange.cancel() })
        return try await withTaskCancellationHandler {
            try await exchange.run().get()
        } onCancel: {
            exchange.cancel()
        }
    }

    final class Exchange: @unchecked Sendable {
        private let endpoint: LANEndpoint
        private let setup: ControlTLSSetup
        private let connector: ControlConnector
        private let timeoutMs: Int
        let loop: EventLoop
        private let cancelled = Locked(false)
        private let closer = TransportCloser()
        private var channel: Channel?
        private var completion: EventLoopPromise<Bool>?
        private var deadline: Scheduled<Void>?
        private var finished = false

        init(endpoint: LANEndpoint, setup: ControlTLSSetup, connector: ControlConnector, timeoutMs: Int) {
            self.endpoint = endpoint
            self.setup = setup
            self.connector = connector
            self.timeoutMs = timeoutMs
            loop = connector.nextLoop()
        }

        func run() -> EventLoopFuture<Bool> {
            let promise = loop.makePromise(of: Bool.self)
            loop.execute { [self] in
                guard completion == nil else {
                    promise.fail(ControlResponseError(.invalidReply))
                    return
                }
                completion = promise
                guard !cancelled.value else {
                    finish(false)
                    return
                }
                deadline = loop.scheduleTask(in: .milliseconds(Int64(timeoutMs))) { [self] in finish(false) }
                connector.connectLAN(
                    endpoint: endpoint, connectTimeout: .milliseconds(Int64(timeoutMs)), on: loop,
                    initializer: { [self] channel in
                        self.channel = channel
                        guard !finished, !cancelled.value else {
                            channel.close(promise: nil)
                            return loop.makeFailedFuture(SessionStopped())
                        }
                        return loop.makeCompletedFuture {
                            let handler = try setup.makeHandler()
                            try channel.pipeline.syncOperations.addHandlers([
                                closer, handler,
                                ProbeHandler(
                                    verify: { [self] in
                                        setup.verifyAfterHandshake(
                                            peerCertificate: handler.peerCertificate, now: Date()) == nil
                                    }, complete: { [self] in finish($0) }),
                            ])
                        }
                    }
                ).whenFailure { [self] _ in finish(false) }
            }
            return promise.futureResult
        }

        func cancel() {
            guard !cancelled.exchange(true) else { return }
            loop.execute { [self] in finish(false) }
        }

        private func finish(_ reachable: Bool) {
            guard !finished, let completion else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            if cancelled.value { completion.fail(SessionStopped()) } else { completion.succeed(reachable) }
            closer.abort()
            if !closer.aborted { channel?.close(promise: nil) }
        }
    }

    /// Reads only handshake completion; never creates or writes an application buffer.
    final class ProbeHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        private let verify: () -> Bool
        private let complete: (Bool) -> Void

        init(verify: @escaping () -> Bool, complete: @escaping (Bool) -> Void) {
            self.verify = verify
            self.complete = complete
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls { complete(verify()) }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
        func errorCaught(context: ChannelHandlerContext, error: Error) { complete(false) }
        func channelInactive(context: ChannelHandlerContext) { complete(false) }
    }
}
