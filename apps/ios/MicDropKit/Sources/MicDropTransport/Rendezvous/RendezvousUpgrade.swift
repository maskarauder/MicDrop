import MicDropCore
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// The WebSocket upgrade to `GET /v1/tunnel`.
///
/// Pre-upgrade pipeline (head → tail), installed synchronously in the channel initializer:
/// `TransportCloser`, [outer `NIOSSLClientHandler` on the NIOPosix path], `UpgradeByteLimiter`,
/// `HTTPRequestEncoder`, `ByteToMessageHandler(HTTPResponseDecoder)`, `NIOHTTPClientUpgradeHandler`
/// (via `addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, withClientUpgrade:)` — the 101
/// and the 22-byte ready frame can arrive in one read; `.dropBytes` would lose `ready`),
/// `RendezvousUpgradeRequest`. After the 101 the upgrader adds `WebSocketFrameEncoder`,
/// `ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 65536))` and `RendezvousFrameAdapter`;
/// the completion handler removes `RendezvousUpgradeRequest` and `UpgradeByteLimiter`.
public enum RendezvousUpgrade {
    /// `Sec-WebSocket-Protocol` value, exactly one (`server.go:162-165`).
    public static let subprotocol = "micdrop-tls-v1"
    /// Upgrade request target.
    public static let path = "/v1/tunnel"
    /// Inbound frame / message bound (`SetReadLimit(64 KiB)`, `Draft_6455(maxFrameSize = 65536)`).
    public static let maxFrameSize = 65_536

    /// The upgrade request head written by `RendezvousUpgradeRequest` (the upgrade handler adds
    /// `Upgrade`, `Connection`; the upgrader adds `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`).
    /// Never `Origin`, `Content-Length`, `Transfer-Encoding`, `Sec-WebSocket-Extensions` or a query.
    public static func requestHead(for route: RemoteRoute) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: route.hostHeader)
        headers.add(name: "Authorization", value: "Bearer \(route.token)")
        headers.add(name: "Sec-WebSocket-Protocol", value: subprotocol)
        return HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)
    }

    /// Response checks beyond `Sec-WebSocket-Accept` (validated by `NIOWebSocketClientUpgrader`):
    /// `Sec-WebSocket-Protocol == ["micdrop-tls-v1"]` and no `Sec-WebSocket-Extensions`
    /// (`RemoteTunnel.kt:58-60`, Go `client.go:40-43`).
    public static func acceptsResponse(_ head: HTTPResponseHead) -> Bool {
        head.headers["Sec-WebSocket-Protocol"] == [subprotocol]
            && head.headers["Sec-WebSocket-Extensions"].isEmpty
    }

    /// Installs the pre-upgrade pipeline on `channel` (must run on the channel's event loop, inside
    /// the bootstrap's channel initializer).
    ///
    /// - Parameters:
    ///   - outerTLS: the NIOPosix outer `NIOSSLClientHandler`, inserted right after `closer`
    ///     (`nil` on NIOTS, where Network.framework runs the outer TLS).
    ///   - adapter: added by the upgrade pipeline handler once the 101 is accepted.
    ///   - classifyTransportError: maps transport errors reaching the request handler before the
    ///     upgrade to an outer error (`nil` = EOF-like, nothing recorded).
    ///   - onUpgraded: called once the 101 was accepted, before `adapter` is installed (Android
    ///     `WAITING_FOR_WINDOWS`, failure-history evidence only).
    public static func install(
        on channel: Channel, route: RemoteRoute, closer: TransportCloser,
        outerTLS: ChannelHandler?, latch: TerminalErrorLatch,
        adapter: RendezvousFrameAdapter,
        classifyTransportError: @escaping (Error) -> Error?,
        onUpgraded: @escaping @Sendable () -> Void = {}
    ) throws {
        let pipeline = channel.pipeline.syncOperations
        try pipeline.addHandler(closer)
        if let outerTLS { try pipeline.addHandler(outerTLS) }
        let limiter = UpgradeByteLimiter(latch: latch, closer: closer)
        let request = RendezvousUpgradeRequest(
            route: route, latch: latch, closer: closer, classifyTransportError: classifyTransportError)
        try pipeline.addHandler(limiter)
        let upgrader = NIOWebSocketClientUpgrader(
            maxFrameSize: maxFrameSize, automaticErrorHandling: false,
            upgradePipelineHandler: { channel, head in
                channel.eventLoop.makeCompletedFuture {
                    do {
                        guard acceptsResponse(head) else { throw ControlIOError(.invalidRendezvousStream) }
                        onUpgraded()
                        try channel.pipeline.syncOperations.addHandler(adapter)
                    } catch {
                        latch.recordOuter(ControlIOError(.invalidRendezvousStream))
                        closer.abort()
                        throw error
                    }
                }
            })
        try pipeline.addHTTPClientHandlers(
            position: .last, leftOverBytesStrategy: .forwardBytes,
            withClientUpgrade: (
                upgraders: [upgrader],
                completionHandler: { context in
                    context.pipeline.syncOperations.removeHandler(request, promise: nil)
                    context.pipeline.syncOperations.removeHandler(limiter, promise: nil)
                }
            ))
        try pipeline.addHandler(request)
    }
}

/// Counts inbound bytes until removed after the upgrade; more than `limit` (8192 upgrade header bound + one ready frame
/// + slack) → `ControlIOError(.invalidRendezvousStream)` and abort (Android `BoundedDraft`, `RemoteTunnel.kt:36-38`).
public final class UpgradeByteLimiter: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    /// 8192 + 64.
    public static let defaultLimit = 8256

    public let limit: Int
    public private(set) var received = 0
    private let latch: TerminalErrorLatch
    private let closer: TransportCloser

    public init(limit: Int = UpgradeByteLimiter.defaultLimit, latch: TerminalErrorLatch, closer: TransportCloser) {
        self.limit = limit
        self.latch = latch
        self.closer = closer
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received += buffer.readableBytes
        if received > limit {
            latch.recordOuter(ControlIOError(.invalidRendezvousStream))
            closer.abort()
            return
        }
        context.fireChannelRead(data)
    }
}

/// Writes the upgrade request on `channelActive` (or on `handlerAdded` if the channel is already active) and turns any
/// non-upgrade outcome into an outer rendezvous failure:
/// - a forwarded non-101 response head (401/403/429/503/400…) → `ControlIOError(.rendezvousClosed)`
/// — **never** `HTTPFailure`; the body is not read;
/// - `NIOHTTPClientUpgradeError` (bad `Sec-WebSocket-Accept`, missing `Upgrade`) or HTTP decoder
///   errors → `ControlIOError(.invalidRendezvousStream)`;
/// - other errors → `classifyTransportError` (outer TLS / transport), recorded as outer;
/// then `closer.abort()`.
public final class RendezvousUpgradeRequest: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart

    private let route: RemoteRoute
    private let latch: TerminalErrorLatch
    private let closer: TransportCloser
    private let classifyTransportError: (Error) -> Error?
    private var requestWritten = false

    public init(
        route: RemoteRoute, latch: TerminalErrorLatch, closer: TransportCloser,
        classifyTransportError: @escaping (Error) -> Error?
    ) {
        self.route = route
        self.latch = latch
        self.closer = closer
        self.classifyTransportError = classifyTransportError
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            writeRequest(context: context)
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        writeRequest(context: context)
        context.fireChannelActive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        latch.recordOuter(ControlIOError(.rendezvousClosed))
        closer.abort()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if error is NIOHTTPClientUpgradeError || error is HTTPParserError {
            latch.recordOuter(ControlIOError(.invalidRendezvousStream))
        } else if let outer = classifyTransportError(error) {
            latch.recordOuter(outer)
        }
        closer.abort()
    }

    /// `RendezvousUpgrade.requestHead(for:)` + `.end(nil)`, flushed immediately after the outer TLS completed (the
    /// rendezvous `ReadHeaderTimeout` is 5 s). Written once.
    private func writeRequest(context: ChannelHandlerContext) {
        guard !requestWritten else {
            return
        }
        requestWritten = true
        context.write(wrapOutboundOut(.head(RendezvousUpgrade.requestHead(for: route))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
