import NIOCore

/// Head-most pipeline handler (position 1 on LAN and remote): a pass-through whose `abort()` closes the channel from
/// the bottom of the pipeline, so the close travels only toward the head and never through NIOSSL's graceful shutdown
/// (no `close_notify` wait; Android just closes the socket, `RemoteTunnel.kt:134-139`).
///
/// Event-loop confined: call `abort()` on the channel's loop.
public final class TransportCloser: ChannelOutboundHandler, RemovableChannelHandler {
    public typealias OutboundIn = NIOAny
    public typealias OutboundOut = NIOAny

    private var context: ChannelHandlerContext?
    /// `true` once `abort()` ran (idempotent).
    public private(set) var aborted = false

    public init() {}

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    /// `context.close(mode: .all)` from this handler's context; no-op after the first effective
    /// call. Before the handler is in a pipeline it does nothing (the exchange then closes the
    /// channel itself when it attaches, `RemoteTunnel.kt:83-95` owned-socket rule).
    public func abort() {
        guard !aborted, let context else {
            return
        }
        aborted = true
        context.close(mode: .all, promise: nil)
    }
}
