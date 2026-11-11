import Foundation
import MicDropCore
import NIOCore
import NIOSSL
import NIOTLS

/// The one-request HTTP/1.0 exchange above the inner `NIOSSLClientHandler`, shared by LAN and remote.
///
/// - `TLSUserEvent.handshakeCompleted`: defense-in-depth peer re-check (failure →
///   `latch.recordInner(SignalingTLSFailure(.windows, problem))`, abort, nothing written), then
///   `writeAndFlush(requestBytes)` (header + body in one buffer; frame boundaries are meaningless).
/// - `channelRead`: feed `parser`. `.complete(body)` → succeed `completion` with
///   `ControlResponse(body:)`, then `closer.abort()`. `HTTPFailure` → fail `completion`
///   immediately, abort. Framing violation → `latch.recordInner`, abort.
/// - `errorCaught`: `setup.classify(error)`: `.transportEOF` → `latch.uncleanEOF = true`;
///   `.failure(p)` → `latch.recordInner(SignalingTLSFailure(layer: .windows, problem: p))`;
///   `.notTLS` → on LAN (`!latch.tunnelled`) `latch.recordOuter(ControlIOError(.transportClosed))`,
///   remote: ignored (the frame adapter already recorded the outer error). Never completes here.
/// - `userInboundEventTriggered(IdleStateHandler.IdleStateEvent.read)` (LAN only) →
///   `latch.recordLocal(.timedOut)`, abort.
/// - `TLSUserEvent.shutdownCompleted` → the peer's `close_notify` was seen (clean EOF).
/// - `channelInactive`: if not completed: `parser.canCompleteOnCleanEOF && !latch.uncleanEOF &&
/// !latch.hasRecordedError` → succeed with `parser.finish(cleanEOF: true)`; else record any `parser.finish(cleanEOF)`
/// violation as inner and fail with `latch.resolve`.
///
/// Completion always closes through `TransportCloser.abort()` (no inner `close_notify` wait).
public final class ControlExchangeHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    /// Exchange progress.
    public enum State: Sendable, Equatable {
        case awaitingHandshake
        case awaitingResponse
        case completed
    }

    public private(set) var state: State = .awaitingHandshake

    private let requestBytes: [UInt8]
    private var parser: StrictHTTPResponse.Parser
    private let latch: TerminalErrorLatch
    private let setup: ControlTLSSetup
    private let completion: EventLoopPromise<ControlResponse>
    private let closer: TransportCloser
    private let innerTLS: NIOSSLClientHandler?
    private let onRequestSent: () -> Void
    private let onProgress: (SignalingRequestPhase) -> Void
    private var sawCloseNotify = false
    private var readingBody = false

    /// - Parameters:
    ///   - requestBytes: `ControlRequestEncoder.encode(_:host:)` output.
    ///   - parser: `StrictHTTPResponse.Parser(maxBody: request.maxResponseBytes)`.
    ///   - completion: completed exactly once (later completions are ignored).
    ///   - onProgress: `.requestWrite` before the write, `.responseHeaders` once it was written and
    ///     `.responseBody` after an accepted 200 header block (failure-history evidence only).
    public init(
        requestBytes: [UInt8], parser: StrictHTTPResponse.Parser, latch: TerminalErrorLatch,
        setup: ControlTLSSetup, completion: EventLoopPromise<ControlResponse>, closer: TransportCloser,
        innerTLS: NIOSSLClientHandler? = nil, onRequestSent: @escaping () -> Void = {},
        onProgress: @escaping (SignalingRequestPhase) -> Void = { _ in }
    ) {
        self.requestBytes = requestBytes
        self.parser = parser
        self.latch = latch
        self.setup = setup
        self.completion = completion
        self.closer = closer
        self.innerTLS = innerTLS
        self.onRequestSent = onRequestSent
        self.onProgress = onProgress
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard state != .completed else { return }
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                guard state == .awaitingHandshake else { return }
                // A remote POSIX pipeline has two SSL handlers. Never re-check the outer certificate.
                let certificate =
                    innerTLS != nil
                    ? innerTLS?.peerCertificate
                    : (try? context.pipeline.syncOperations.nioSSL_peerCertificate())
                if let failure = setup.verifyAfterHandshake(peerCertificate: certificate, now: Date()) {
                    latch.recordInner(
                        SignalingTLSFailure(layer: .windows, problem: ControlTLSSetup.problem(for: failure)))
                    closer.abort()
                    return
                }
                state = .awaitingResponse
                var bytes = context.channel.allocator.buffer(capacity: requestBytes.count)
                bytes.writeBytes(requestBytes)
                onRequestSent()
                onProgress(.requestWrite)
                let written = context.eventLoop.makePromise(of: Void.self)
                written.futureResult.assumeIsolated().whenSuccess { [self] _ in
                    if state == .awaitingResponse && !readingBody { onProgress(.responseHeaders) }
                }
                context.writeAndFlush(wrapOutboundOut(bytes), promise: written)
            case .shutdownCompleted:
                sawCloseNotify = true
            }
        } else if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            latch.recordLocal(.timedOut)
            closer.abort()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state != .completed else { return }
        var buffer = unwrapInboundIn(data)
        do {
            if case .complete(let body)? = try parser.feed(&buffer) {
                state = .completed
                if latch.hasRecordedError {
                    completion.fail(latch.resolve())
                } else {
                    completion.succeed(ControlResponse(body: body))
                }
                closer.abort()
            } else if parser.readingBody && !readingBody {
                readingBody = true
                onProgress(.responseBody)
            }
        } catch let failure as HTTPFailure {
            state = .completed
            completion.fail(latch.hasRecordedError ? latch.resolve() : failure)
            closer.abort()
        } catch {
            latch.recordInner(error)
            closer.abort()
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard state != .completed else { return }
        switch setup.classify(error) {
        case .transportEOF: latch.uncleanEOF = true
        case .failure(let problem): latch.recordInner(SignalingTLSFailure(layer: .windows, problem: problem))
        case .notTLS:
            if !latch.tunnelled { latch.recordOuter(ControlIOError(.transportClosed)) }
        }
        closer.abort()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        if state != .completed {
            state = .completed
            do {
                let outcome = try parser.finish(cleanEOF: sawCloseNotify && !latch.uncleanEOF)
                if !latch.hasRecordedError, case .complete(let body) = outcome {
                    completion.succeed(ControlResponse(body: body))
                } else {
                    completion.fail(latch.resolve())
                }
            } catch {
                if let violation = error as? ControlIOError { latch.recordInner(violation) }
                completion.fail(latch.resolve())
            }
        }
        context.fireChannelInactive()
    }
}
