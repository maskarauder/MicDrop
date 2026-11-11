import Crypto
import Foundation
import MicDropCore
import NIOCore
import NIOEmbedded
import XCTest

@testable import MicDropTransport

/// Transport stage evidence for the session's signaling failure history (`RemoteHttp.kt` /
/// `StreamReceiver.localRequest` `phase`).
final class SignalingRequestProgressTests: XCTestCase {
    func testResponseBodyStageStartsOnlyAfterAnAccepted200HeaderBlock() throws {
        for (head, body) in [("HTTP/1.1 200 OK\r\nContent-", true), ("HTTP/1.1 503 Busy\r\nContent-", false)] {
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }
            let closer = TransportCloser()
            let promise = channel.eventLoop.makePromise(of: ControlResponse.self)
            let progress = SignalingRequestProgress(.lanRequest)
            let exchange = ControlExchangeHandler(
                requestBytes: [], parser: StrictHTTPResponse.Parser(maxBody: 1024),
                latch: TerminalErrorLatch(tunnelled: false), setup: try setup(), completion: promise,
                closer: closer, onProgress: { progress.advance(to: $0) })
            try channel.pipeline.syncOperations.addHandlers([closer, exchange])
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8443)).wait()
            try channel.writeInbound(bytes(head))
            XCTAssertEqual(progress.phase, .lanRequest, "status line alone is still the request stage")
            try channel.writeInbound(bytes("Length: 4\r\n\r\nab"))
            if body {
                XCTAssertEqual(progress.phase, .responseBody)
                try channel.writeInbound(bytes("cd"))
                XCTAssertEqual(try promise.futureResult.wait().body, Array("abcd".utf8))
            } else {
                XCTAssertEqual(progress.phase, .lanRequest, "a non-200 status never reads a body")
                XCTAssertThrowsError(try promise.futureResult.wait()) {
                    XCTAssertEqual($0 as? HTTPFailure, HTTPFailure(503))
                }
            }
        }
    }

    func testUpgradeThenReadyAdvanceRendezvousStages() throws {
        let channel = EmbeddedChannel()
        let latch = TerminalErrorLatch(tunnelled: true)
        let closer = TransportCloser()
        let progress = SignalingRequestProgress(.rendezvousConnect)
        let route = try RemoteRoute(url: "https://relay.example", token: token, forceRelay: false)
        let adapter = RendezvousFrameAdapter(
            latch: latch, closer: closer, classifyTransportError: { $0 },
            onReady: { _ in
                progress.advance(to: .windowsTLS)
                return []
            })
        try RendezvousUpgrade.install(
            on: channel, route: route, closer: closer, outerTLS: nil, latch: latch, adapter: adapter,
            classifyTransportError: { $0 }, onUpgraded: { progress.advance(to: .waitingForWindows) })
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
        defer { _ = try? channel.finish() }
        var request = ""
        while var outbound = try channel.readOutbound(as: ByteBuffer.self) {
            request += outbound.readString(length: outbound.readableBytes) ?? ""
        }
        XCTAssertEqual(progress.phase, .rendezvousConnect)
        let keyLine = try XCTUnwrap(
            request.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("sec-websocket-key:")
            })
        let key = keyLine.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        let hash = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(hash).base64EncodedString()
        let upgrade =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: micdrop-tls-v1\r\n\r\n"
        try channel.writeInbound(bytes(upgrade))
        channel.embeddedEventLoop.run()
        XCTAssertEqual(progress.phase, .waitingForWindows)
        XCTAssertEqual(adapter.state, .awaitingReady)
        var ready = channel.allocator.buffer(capacity: 32)
        ready.writeBytes([UInt8(0x81), UInt8(RendezvousFrameAdapter.ready.count)] + RendezvousFrameAdapter.ready)
        try channel.writeInbound(ready)
        channel.embeddedEventLoop.run()
        XCTAssertEqual(adapter.state, .open)
        XCTAssertEqual(progress.phase, .windowsTLS)
    }

    private let token = String(repeating: "A", count: 43)

    private func bytes(_ text: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }

    private func setup() throws -> ControlTLSSetup {
        let link = try ConnectionLink(
            version: .v1, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: token,
            pin: Array(repeating: 0, count: 32), expiresAt: 0, clientKey: "", remote: nil)
        return try ControlTLS.setup(for: link, client: nil)
    }
}
