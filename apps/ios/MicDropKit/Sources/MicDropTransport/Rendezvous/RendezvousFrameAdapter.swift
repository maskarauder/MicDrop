import MicDropCore
import NIOCore
import NIOTLS
import NIOWebSocket

/// WebSocket frames ⇄ the inner-TLS byte stream, with the ready gate.
///
/// Inbound:
/// - reassembles messages (a non-FIN `.text`/`.binary` starts one, `.continuation` appends; total
///   ≤ 65 536; a new data frame while one is open or a stray continuation is a violation);
/// - complete `.text` == `micdrop-tls-v1 ready` while `.awaitingReady` → `state = .open`,
///   `latch.readySeen = true`, then installs `onReady(context)`'s handlers (inner
///   `NIOSSLClientHandler` + `ControlExchangeHandler`) **synchronously** at `.after(self)` so no later
///   frame can bypass them; any other text, or a text after ready → violation
///   (`RemoteTunnel.kt:61-63`);
/// - complete `.binary`: before ready or empty → violation; else `fireChannelRead(payload)`
///   (`RemoteTunnel.kt:64-66`);
/// - `.ping` → masked `.pong` with the same payload; `.pong` → ignored;
/// - `.connectionClose` → transport EOF: `closer.abort()` (no close echo, `RemoteTunnel.kt:134-139`);
/// - violation or WebSocket decoder error (`NIOWebSocketError`, `ByteToMessageDecoderError`) →
///   `latch.recordOuter(ControlIOError(.invalidRendezvousStream))`, abort (`RemoteTunnel.kt:77`);
/// - other errors (outer TLS / transport) → `classifyTransportError` → `latch.recordOuter`, then
///   forwarded (the exchange handler ignores non-TLS errors when tunnelled).
///
/// Outbound: `write(ByteBuffer)` (inner ciphertext) skips empty buffers, splits into slices of
/// ≤ 16 384 bytes, each `WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data:)`
/// (client frames MUST be masked; `WebSocketFrameEncoder` masks only when `maskKey` is set); the
/// caller's promise is chained to the last slice. Writes before ready fail the promise with
/// `ControlIOError(.invalidRendezvousStream)`. Never emits text frames, empty frames or pings.
public final class RendezvousFrameAdapter: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = WebSocketFrame
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = WebSocketFrame

    /// The 20-byte ready text payload (`server.go:17,195`).
    public static let ready: [UInt8] = Array("micdrop-tls-v1 ready".utf8)
    /// Largest accepted inbound message (`server.go:18`).
    public static let maxMessage = 65_536
    /// Largest outbound binary frame (`RemoteTunnel.kt:124`; Go host `client.go:65-78`).
    public static let maxOutboundFrame = 16_384

    /// Gate state.
    public enum State: Sendable, Equatable {
        case awaitingReady
        case open
        case closed
    }

    public private(set) var state: State = .awaitingReady

    private let latch: TerminalErrorLatch
    private let closer: TransportCloser
    private let classifyTransportError: (Error) -> Error?
    private let onReady: (ChannelHandlerContext) throws -> [ChannelHandler]
    private var message: (opcode: WebSocketOpcode, payload: ByteBuffer)?

    /// - Parameters:
    ///   - classifyTransportError: maps a non-WebSocket error to an outer error (`nil` = EOF-like).
    ///   - onReady: builds the handlers to install after this adapter once ready is accepted
    ///     (throws → recorded as an inner setup failure and abort).
    public init(
        latch: TerminalErrorLatch, closer: TransportCloser,
        classifyTransportError: @escaping (Error) -> Error?,
        onReady: @escaping (ChannelHandlerContext) throws -> [ChannelHandler]
    ) {
        self.latch = latch
        self.closer = closer
        self.classifyTransportError = classifyTransportError
        self.onReady = onReady
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state != .closed else { return }
        let frame = unwrapInboundIn(data)
        // The server must not mask frames or negotiate extensions. The NIO decoder only bounds length.
        guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3,
            frame.extensionData == nil, frame.length <= Self.maxMessage
        else {
            reject()
            return
        }
        var payload = frame.unmaskedData
        switch frame.opcode {
        case .ping, .pong, .connectionClose:
            guard frame.fin, payload.readableBytes <= 125 else {
                reject()
                return
            }
            if frame.opcode == .ping {
                context.writeAndFlush(
                    wrapOutboundOut(
                        WebSocketFrame(
                            fin: true, opcode: .pong, maskKey: .random(), data: payload)), promise: nil)
            } else if frame.opcode == .connectionClose {
                state = .closed
                message = nil
                closer.abort()
            }
        case .text, .binary:
            guard message == nil else {
                reject()
                return
            }
            if frame.fin {
                accept(opcode: frame.opcode, payload: payload, context: context)
            } else {
                message = (frame.opcode, payload)
            }
        case .continuation:
            guard var pending = message,
                payload.readableBytes <= Self.maxMessage - pending.payload.readableBytes
            else {
                reject()
                return
            }
            pending.payload.writeBuffer(&payload)
            if frame.fin {
                message = nil
                accept(opcode: pending.opcode, payload: pending.payload, context: context)
            } else {
                message = pending
            }
        default: reject()
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard state == .open else {
            promise?.fail(ControlIOError(.invalidRendezvousStream))
            return
        }
        var buffer = unwrapOutboundIn(data)
        guard buffer.readableBytes > 0 else {
            promise?.succeed(())
            return
        }
        while let slice = buffer.readSlice(length: min(buffer.readableBytes, Self.maxOutboundFrame)),
            slice.readableBytes > 0
        {
            context.write(
                wrapOutboundOut(
                    WebSocketFrame(
                        fin: true, opcode: .binary, maskKey: .random(), data: slice)),
                promise: buffer.readableBytes == 0 ? promise : nil)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if error is NIOWebSocketError || error is ByteToMessageDecoderError {
            reject()
            return
        }
        if let outer = classifyTransportError(error) { latch.recordOuter(outer) }
        context.fireErrorCaught(error)
        closer.abort()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // Outer TLS notifications must never masquerade as the inner Windows handshake/close.
        if !(event is TLSUserEvent) { context.fireUserInboundEventTriggered(event) }
    }

    private func accept(opcode: WebSocketOpcode, payload: ByteBuffer, context: ChannelHandlerContext) {
        if opcode == .text {
            guard state == .awaitingReady, Array(payload.readableBytesView) == Self.ready else {
                reject()
                return
            }
            state = .open
            latch.readySeen = true
            do {
                try context.pipeline.syncOperations.addHandlers(try onReady(context), position: .after(self))
            } catch {
                latch.recordInner(error)
                state = .closed
                closer.abort()
            }
        } else {
            guard state == .open, payload.readableBytes > 0 else {
                reject()
                return
            }
            context.fireChannelRead(wrapInboundOut(payload))
        }
    }

    private func reject() {
        latch.recordOuter(ControlIOError(.invalidRendezvousStream))
        state = .closed
        message = nil
        closer.abort()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        state = .closed
        message = nil
        context.fireChannelInactive()
    }
}
