import MicDropCore
import NIOCore
import NIOEmbedded
import NIOTLS
import XCTest

@testable import MicDropTransport

final class LocalProbeTests: XCTestCase {
    func testProbeRequiresVerifiedHandshakeAndWritesNoApplicationBytes() throws {
        for accepted in [false, true] {
            var verified = 0
            var results: [Bool] = []
            let handler = LocalProbe.ProbeHandler(
                verify: {
                    verified += 1
                    return accepted
                }, complete: { results.append($0) })
            let channel = EmbeddedChannel(handler: handler)
            defer { _ = try? channel.finish() }
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 443)).wait()
            var unexpected = channel.allocator.buffer(capacity: 1)
            unexpected.writeInteger(UInt8(0))
            try channel.writeInbound(unexpected)
            XCTAssertTrue(results.isEmpty)
            channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil))
            XCTAssertEqual(verified, 1)
            XCTAssertEqual(results, [accepted])
            XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
        }
    }

    func testEOFAndTransportFailuresCannotProveReachability() throws {
        let channel = EmbeddedChannel()
        var results: [Bool] = []
        try channel.pipeline.addHandler(
            LocalProbe.ProbeHandler(
                verify: {
                    XCTFail("failed transport verified")
                    return true
                }, complete: { results.append($0) })
        ).wait()
        channel.pipeline.fireErrorCaught(ControlIOError(.unreachable))
        XCTAssertEqual(results, [false])
        _ = try channel.finish()
        XCTAssertTrue(results.allSatisfy { !$0 })
    }

    func testCancellationBeforeRunNeverConnectsAndRemainsIdempotent() throws {
        let loop = EmbeddedEventLoop()
        let link = try makeLink()
        let probe = LocalProbe.Exchange(
            endpoint: link.endpoint, setup: try ControlTLS.setup(for: link, client: nil),
            connector: .posix(group: loop), timeoutMs: 1_500)
        probe.cancel()
        probe.cancel()
        let result = probe.run()
        loop.run()
        XCTAssertThrowsError(try result.wait()) { XCTAssertTrue($0 is SessionStopped) }
    }

    func testOutOfRangeDeadlineFailsBeforeCreatingTLSOrConnecting() async throws {
        let probe = LocalProbe(
            link: try makeLink(),
            tls: {
                XCTFail("invalid deadline created TLS")
                throw ControlResponseError(.invalidReply)
            })
        for timeout in [0, -1, 5_001, Int.max] {
            do {
                _ = try await probe.reachable(timeoutMs: timeout)
                XCTFail("invalid deadline accepted")
            } catch { XCTAssertEqual(error as? ControlResponseError, ControlResponseError(.invalidReply)) }
        }
    }

    private func makeLink() throws -> ConnectionLink {
        try ConnectionLink(
            version: .v1, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443),
            token: String(repeating: "A", count: 43), pin: Array(repeating: 0, count: 32),
            expiresAt: 0, clientKey: "", remote: nil)
    }
}
