import Crypto
import Foundation
import MicDropCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOSSL
import NIOTLS
import NIOWebSocket
import XCTest

@testable import MicDropTransport

final class RendezvousPipelineTests: XCTestCase {
    func testFragmentedReadyAndBinaryAreReassembledWithPingInterleaving() throws {
        let (channel, adapter, latch) = try frameChannel()
        defer { _ = try? channel.finish() }
        let ready = RendezvousFrameAdapter.ready
        try channel.writeInbound(frame(.text, Array(ready.prefix(5)), fin: false))
        try channel.writeInbound(frame(.ping, [1, 2]))
        let pong = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(pong.opcode, .pong)
        XCTAssertNotNil(pong.maskKey)
        XCTAssertEqual(Array(pong.data.readableBytesView), [1, 2])
        try channel.writeInbound(frame(.continuation, Array(ready.dropFirst(5))))
        XCTAssertEqual(adapter.state, .open)
        XCTAssertTrue(latch.readySeen)
        try channel.writeInbound(frame(.binary, [1, 2], fin: false))
        try channel.writeInbound(frame(.continuation, [3]))
        XCTAssertEqual(Array(try XCTUnwrap(channel.readInbound(as: ByteBuffer.self)).readableBytesView), [1, 2, 3])
    }

    func testOutboundCiphertextIsMaskedAndSplitAtBoundedFrames() throws {
        let (channel, _, _) = try frameChannel()
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame(.text, RendezvousFrameAdapter.ready))
        var buffer = channel.allocator.buffer(capacity: 32_769)
        buffer.writeRepeatingByte(7, count: 32_769)
        try channel.writeOutbound(buffer)
        for size in [16_384, 16_384, 1] {
            let output = try XCTUnwrap(channel.readOutbound(as: WebSocketFrame.self))
            XCTAssertEqual(output.opcode, .binary)
            XCTAssertTrue(output.fin)
            XCTAssertNotNil(output.maskKey)
            XCTAssertEqual(output.data.readableBytes, size)
        }
        XCTAssertNil(try channel.readOutbound(as: WebSocketFrame.self))
    }

    func testReadyGateAndProtocolViolationsAbortWithoutOpeningInnerTLS() throws {
        let invalid = [
            frame(.binary, [1]), frame(.text, Array("wrong ready".utf8)),
            frame(.continuation, [1]), frame(.ping, [], fin: false),
            frame(.ping, Array(repeating: 1, count: 126)),
        ]
        for input in invalid {
            let (channel, adapter, latch) = try frameChannel()
            try channel.writeInbound(input)
            XCTAssertEqual(adapter.state, .closed)
            XCTAssertFalse(latch.readySeen)
            XCTAssertEqual(latch.outer as? ControlIOError, ControlIOError(.invalidRendezvousStream))
            _ = try? channel.finish()
        }
        let (channel, adapter, latch) = try frameChannel()
        defer { _ = try? channel.finish() }
        try channel.writeInbound(frame(.text, RendezvousFrameAdapter.ready))
        try channel.writeInbound(frame(.binary, []))
        XCTAssertEqual(adapter.state, .closed)
        XCTAssertEqual(latch.outer as? ControlIOError, ControlIOError(.invalidRendezvousStream))
    }

    func testFragmentedMessageLimitAndSecondDataStartAreRejected() throws {
        for overflow in [false, true] {
            let (channel, adapter, latch) = try frameChannel()
            try channel.writeInbound(frame(.text, RendezvousFrameAdapter.ready))
            try channel.writeInbound(frame(.binary, Array(repeating: 1, count: 65_536), fin: false))
            try channel.writeInbound(frame(overflow ? .continuation : .binary, [1]))
            XCTAssertEqual(adapter.state, .closed)
            XCTAssertEqual(latch.outer as? ControlIOError, ControlIOError(.invalidRendezvousStream))
            _ = try? channel.finish()
        }
    }

    func testUpgradeAndReadyCanArriveInOneRead() throws {
        let channel = EmbeddedChannel()
        let latch = TerminalErrorLatch(tunnelled: true)
        let closer = TransportCloser()
        let adapter = RendezvousFrameAdapter(
            latch: latch, closer: closer, classifyTransportError: { $0 }, onReady: { _ in [] })
        try RendezvousUpgrade.install(
            on: channel, route: route(), closer: closer, outerTLS: nil, latch: latch,
            adapter: adapter, classifyTransportError: { $0 })
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        defer { _ = try? channel.finish() }
        var request = ""
        while var bytes = try channel.readOutbound(as: ByteBuffer.self) {
            request += bytes.readString(length: bytes.readableBytes) ?? ""
        }
        let keyLine = try XCTUnwrap(
            request.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("sec-websocket-key:")
            })
        let key = keyLine.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        let hash = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(hash).base64EncodedString()
        var response = channel.allocator.buffer(capacity: 256)
        response.writeString(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: micdrop-tls-v1\r\n\r\n"
        )
        response.writeBytes([UInt8(0x81), UInt8(RendezvousFrameAdapter.ready.count)] + RendezvousFrameAdapter.ready)
        try channel.writeInbound(response)
        // HTTP decoder removal and buffered-byte replay run on the next event-loop turn.
        channel.embeddedEventLoop.run()
        XCTAssertEqual(adapter.state, .open)
        XCTAssertTrue(latch.readySeen)
    }

    func testUpgradeRejectsSubprotocolAmbiguityAndExtensions() {
        for headers in [
            HTTPHeaders(), HTTPHeaders([("Sec-WebSocket-Protocol", "other")]),
            HTTPHeaders([("Sec-WebSocket-Protocol", "micdrop-tls-v1"), ("Sec-WebSocket-Protocol", "micdrop-tls-v1")]),
            HTTPHeaders([
                ("Sec-WebSocket-Protocol", "micdrop-tls-v1"), ("Sec-WebSocket-Extensions", "permessage-deflate"),
            ]),
        ] {
            XCTAssertFalse(
                RendezvousUpgrade.acceptsResponse(
                    HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: headers)))
        }
    }

    func testTerminalErrorPrecedenceAndOuterTLSClassification() {
        let latch = TerminalErrorLatch(tunnelled: true)
        latch.recordInner(SignalingTLSFailure(.windows, .handshake))
        latch.recordOuter(SignalingTLSFailure(.rendezvous, .identity))
        XCTAssertEqual(latch.resolve() as? SignalingTLSFailure, SignalingTLSFailure(.rendezvous, .identity))
        latch.recordLocal(.cancelled)
        XCTAssertTrue(latch.resolve() is SessionStopped)
        let connector = ControlConnector.posix(group: EmbeddedEventLoop())
        let verdict = OuterTrustVerdictBox()
        XCTAssertNil(
            connector.classifyOuterError(NIOSSLError.uncleanShutdown, verdict: verdict, duringHandshake: false))
        verdict.record(.certificateTime)
        XCTAssertEqual(
            connector.classifyRendezvousConnectFailure(ChannelError.eof, verdict: verdict) as? SignalingTLSFailure,
            SignalingTLSFailure(.rendezvous, .certificateTime))
    }

    func testCancellationBeforeRunDoesNotOpenLANOrRemoteConnection() throws {
        let loop = EmbeddedEventLoop()
        let connector = ControlConnector.posix(group: loop)
        let link = try ConnectionLink(
            version: .v1, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443),
            token: String(repeating: "A", count: 43), pin: Array(repeating: 0, count: 32),
            expiresAt: 0, clientKey: "", remote: nil)
        let setup = try ControlTLS.setup(for: link, client: nil)
        let lan = LanControlTransport.Exchange(
            endpoint: link.endpoint, setup: setup, requestBytes: [], maxResponseBytes: 1024,
            timeoutMs: 1000, connector: connector)
        lan.cancel()
        lan.cancel()
        let lanResult = lan.run()
        loop.run()
        XCTAssertThrowsError(try lanResult.wait()) { XCTAssertTrue($0 is SessionStopped) }
        let remote = RemoteExchange(
            route: try route(), setup: setup, requestBytes: [], maxResponseBytes: 1024,
            timeoutMs: 1000, connector: connector, outerTrust: .system)
        remote.cancel()
        remote.cancel()
        let remoteResult = remote.run()
        loop.run()
        XCTAssertThrowsError(try remoteResult.wait()) { XCTAssertTrue($0 is SessionStopped) }
    }

    private func route() throws -> RemoteRoute {
        try RemoteRoute(url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: false)
    }

    private func frame(_ opcode: WebSocketOpcode, _ bytes: [UInt8], fin: Bool = true) -> WebSocketFrame {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return WebSocketFrame(fin: fin, opcode: opcode, data: buffer)
    }

    private func frameChannel() throws -> (EmbeddedChannel, RendezvousFrameAdapter, TerminalErrorLatch) {
        let latch = TerminalErrorLatch(tunnelled: true)
        let closer = TransportCloser()
        let adapter = RendezvousFrameAdapter(
            latch: latch, closer: closer, classifyTransportError: { $0 }, onReady: { _ in [] })
        let channel = EmbeddedChannel(handlers: [closer, adapter])
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        return (channel, adapter, latch)
    }
}
