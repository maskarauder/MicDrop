import Crypto
import Foundation
import MicDropCore
import MicDropIdentity
import NIOCore
import NIOEmbedded
import NIOSSL
import SwiftASN1
import X509
import XCTest

@testable import MicDropTransport

/// The absolute deadline of one LAN request (`LanControlTransport.requestDeadlineMs`). The read-idle
/// timeout resets on every inbound read, so without this bound a slow LAN `/pair` reply could hold the
/// pairing loop past its request and approval window.
///
/// Real paired TLS 1.3 between in-memory channels on one `EmbeddedEventLoop`, whose manual clock drives
/// the scripted connect, the idle timeout and the deadline. Ephemeral test keys only.
final class LanControlTransportDeadlineTests: XCTestCase {
    func testRequestDeadlineIsConnectBudgetPlusOneReadWindowInsideTheWorkerBound() throws {
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 5_000), 10_000)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 1), 2)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 0), 2)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: -1), 2)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 40_000), 48_000)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 40_000, connectTimeoutMs: 30_000), 70_000)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 40_000, connectTimeoutMs: 60_000), 70_000)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 2_000, connectTimeoutMs: 30_000), 4_000)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: 5_000, connectTimeoutMs: 0), 5_001)
        XCTAssertEqual(LanControlTransport.requestDeadlineMs(timeoutMs: .max), .max)
        // The session worker's outer bound stays longer, so its timeout behavior is unchanged.
        for timeout in [1, 2_000, 5_000, 8_000, 18_000, 40_000] {
            for connect in [1, 8_000, 30_000] {
                XCTAssertLessThan(
                    LanControlTransport.requestDeadlineMs(timeoutMs: timeout, connectTimeoutMs: connect),
                    2 * timeout + SessionWorkerWait.transportGraceMs)
            }
        }
        // A LAN `/pair` poll (`clamp(remaining, 1, 5000)`) on the production connect cap.
        for remaining: Int64 in [1, 900, 5_000, 300_000] {
            let timeout = PairingClient.requestTimeoutMs(remainingMs: remaining, remote: false)
            XCTAssertLessThanOrEqual(LanControlTransport.requestDeadlineMs(timeoutMs: timeout), 10_000)
        }
        let harness = try Harness()
        defer { harness.finish() }
        let exchange = LanControlTransport.Exchange(
            endpoint: harness.link.endpoint, setup: harness.setup, requestBytes: [], maxResponseBytes: 1_024,
            timeoutMs: 3_000, connector: .posix(group: harness.loop), connectTimeoutMs: 2_500)
        XCTAssertEqual(exchange.deadlineMs, 5_500)
    }

    func testConnectionPlusResponseTimeIsBoundedByTheTotalBudget() throws {
        // Within the 2 s budget: a 900 ms connect, then a reply 900 ms later.
        let fast = try Harness()
        defer { fast.finish() }
        fast.start(timeoutMs: 1_000, connectDelayMs: 900)
        fast.advance(by: 900)
        XCTAssertFalse(fast.responder.request.isEmpty)
        fast.advance(by: 900)
        fast.responder.send(Harness.approvedResponse)
        fast.pump()
        XCTAssertEqual(try fast.result?.get(), ControlResponse(body: Harness.approvedBody))
        XCTAssertEqual(fast.connectTimeouts, [.milliseconds(1_000)])
        // A completed request cancels its deadline; a later cancel changes nothing.
        fast.advance(by: 5_000)
        fast.exchange?.cancel()
        fast.loop.run()
        XCTAssertEqual(try fast.result?.get(), ControlResponse(body: Harness.approvedBody))

        // Every read arrives inside the idle window, but connect plus response exceeds the budget.
        let slow = try Harness()
        defer { slow.finish() }
        slow.start(timeoutMs: 1_000, connectDelayMs: 999)
        slow.advance(by: 999)
        XCTAssertFalse(slow.responder.request.isEmpty)
        slow.advance(by: 900)
        slow.responder.send("HTTP/1.0 200 OK\r\n")
        slow.pump()
        slow.advance(by: 100)
        XCTAssertNil(slow.result, "1999 ms is inside the 2000 ms budget")
        slow.advance(by: 1)
        assertTimedOut(slow.result)
        XCTAssertFalse(slow.client.isActive, "expiry closes the connection")
        slow.advance(by: 799)
        slow.responder.send("Content-Length: \(Harness.approvedBody.count)\r\n\r\n")
        slow.pump()
        assertTimedOut(slow.result)
    }

    func testContinuingReadsCannotExtendTheRequestAndLateCompletionIsIgnored() throws {
        let harness = try Harness()
        defer { harness.finish() }
        // Network.framework reports a close asynchronously: completion must not wait for it.
        harness.hold.holding = true
        harness.start(timeoutMs: 1_000)
        XCTAssertFalse(harness.responder.request.isEmpty)
        harness.responder.send("HTTP/1.0 200 OK\r\nContent-Length: 64\r\n\r\n")
        harness.pump()
        let readsBeforeTrickle = harness.clientReads
        for _ in 0..<4 {
            harness.advance(by: 400)
            harness.responder.send("x")
            harness.pump()
        }
        XCTAssertEqual(harness.clientReads - readsBeforeTrickle, 4, "each body byte resets the idle timeout")
        harness.advance(by: 399)
        XCTAssertNil(harness.result)
        harness.advance(by: 1)
        assertTimedOut(harness.result)
        XCTAssertTrue(harness.client.isActive, "the close is still pending")
        XCTAssertGreaterThan(harness.hold.closeRequests, 0)

        // Late cancel and a late complete reply cannot replace the first outcome.
        harness.exchange?.cancel()
        harness.loop.run()
        harness.responder.send(String(repeating: "x", count: 60))
        harness.pump()
        assertTimedOut(harness.result)
        harness.hold.release()
        harness.pump()
        XCTAssertFalse(harness.client.isActive)
        assertTimedOut(harness.result)
    }

    func testDeadlineCoversTheConnectAttemptAndIgnoresLateConnectResults() throws {
        // The channel exists, but the connect never finishes inside the budget.
        let connecting = try Harness()
        defer { connecting.finish() }
        connecting.start(timeoutMs: 1_000, connectDelayMs: 2_500)
        connecting.advance(by: 1_999)
        XCTAssertNil(connecting.result)
        connecting.advance(by: 1)
        assertTimedOut(connecting.result)
        XCTAssertTrue(connecting.clientClosed, "expiry closes the connect attempt")
        connecting.advance(by: 1_000)
        assertTimedOut(connecting.result)
        XCTAssertTrue(connecting.responder.request.isEmpty)

        // The connect has not even created its channel yet (address resolution, path evaluation).
        let resolving = try Harness()
        defer { resolving.finish() }
        resolving.start(timeoutMs: 1_000, initializeDelayMs: 2_500)
        resolving.advance(by: 2_000)
        assertTimedOut(resolving.result)
        resolving.advance(by: 1_000)
        assertTimedOut(resolving.result)
        XCTAssertFalse(resolving.initialized, "a late channel is closed without a pipeline")
        XCTAssertTrue(resolving.clientClosed)
        XCTAssertTrue(resolving.responder.request.isEmpty)
    }

    func testTrustFailureAndCancellationRecordedFirstKeepTheirClassification() throws {
        // Wrong pin, close still pending when the deadline fires: the trust failure stays fatal.
        let held = try Harness(wrongPin: true)
        defer { held.finish() }
        held.hold.holding = true
        held.deliversServerBytes = false
        held.start(timeoutMs: 1_000, connectDelayMs: 900)
        held.advance(by: 900)
        held.advance(by: 600)
        held.deliversServerBytes = true
        held.pump()
        XCTAssertEqual(held.setup.lastVerificationFailure, .pinMismatch)
        XCTAssertNil(held.result, "the close is still pending")
        held.advance(by: 500)
        assertTLSFailure(held.result)
        XCTAssertTrue(held.responder.request.isEmpty, "nothing is sent to an unverified host")

        // Wrong pin, ordinary close: the failure completes before the deadline, which stays silent.
        let direct = try Harness(wrongPin: true)
        defer { direct.finish() }
        direct.start(timeoutMs: 1_000)
        assertTLSFailure(direct.result)
        direct.advance(by: 3_000)
        assertTLSFailure(direct.result)

        // Stop with the close still pending: the deadline reports the cancellation, not a timeout.
        let cancelled = try Harness()
        defer { cancelled.finish() }
        cancelled.hold.holding = true
        cancelled.start(timeoutMs: 1_000)
        XCTAssertFalse(cancelled.responder.request.isEmpty)
        cancelled.advance(by: 500)
        cancelled.exchange?.cancel()
        cancelled.loop.run()
        XCTAssertNil(cancelled.result)
        cancelled.advance(by: 1_500)
        assertStopped(cancelled.result)
        cancelled.responder.send(Harness.approvedResponse)
        cancelled.pump()
        assertStopped(cancelled.result)
        cancelled.hold.release()
        cancelled.pump()
        assertStopped(cancelled.result)
    }

    // MARK: - Assertions

    private func assertTimedOut(
        _ result: Result<ControlResponse, Error>?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error)? = result else {
            return XCTFail("expected a timeout, got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertEqual(error as? ControlIOError, ControlIOError(.timedOut), file: file, line: line)
        XCTAssertTrue(PairingFailureText.isRetryable(error), file: file, line: line)
    }

    private func assertTLSFailure(
        _ result: Result<ControlResponse, Error>?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error)? = result else {
            return XCTFail("expected a TLS failure, got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertEqual(
            error as? SignalingTLSFailure, SignalingTLSFailure(.windows, .identity), file: file, line: line)
        XCTAssertFalse(PairingFailureText.isRetryable(error), file: file, line: line)
    }

    private func assertStopped(
        _ result: Result<ControlResponse, Error>?, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error)? = result else {
            return XCTFail("expected a cancellation, got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertTrue(error is SessionStopped, file: file, line: line)
        XCTAssertTrue(PairingFailureText.isCancellation(error), file: file, line: line)
    }

    // MARK: - Harness

    /// One paired LAN `/pair` exchange whose connect is scripted on the embedded loop; the Windows side
    /// is an in-memory TLS 1.3 server. Every call happens on the test thread (the loop's thread).
    private final class Harness {
        static let address = try! SocketAddress(ipAddress: "192.168.1.20", port: 8443)
        static let approvedBody = Array("{\"version\":1,\"state\":\"approved\",\"request_id\":\"\"}".utf8)
        static let approvedResponse =
            "HTTP/1.0 200 OK\r\nContent-Length: \(approvedBody.count)\r\n\r\n"
            + String(decoding: approvedBody, as: UTF8.self)

        let loop: EmbeddedEventLoop
        let client: EmbeddedChannel
        let server: EmbeddedChannel
        let link: ConnectionLink
        let setup: ControlTLSSetup
        let responder = Responder()
        let hold = CloseHold()
        /// `false` keeps the server's TLS records queued (a slow handshake).
        var deliversServerBytes = true
        private(set) var exchange: LanControlTransport.Exchange?
        private(set) var result: Result<ControlResponse, Error>?
        private(set) var connectTimeouts: [TimeAmount] = []
        /// `true` once the exchange's initializer built its pipeline.
        private(set) var initialized = false
        /// Server records delivered to the client.
        private(set) var clientReads = 0
        /// The client channel's `closeFuture` completed.
        private(set) var clientClosed = false
        /// Head-most on each side: test teardown closes below TLS.
        private let clientCloser = TransportCloser()
        private let serverCloser = TransportCloser()

        init(wrongPin: Bool = false) throws {
            let loop = EmbeddedEventLoop()
            self.loop = loop
            client = EmbeddedChannel(loop: loop)
            server = EmbeddedChannel(loop: loop)
            let host = P256.Signing.PrivateKey()
            let now = Date()
            let phone = SoftwareSigner.generate()
            link = try ConnectionLink(
                version: .paired, endpoint: LANEndpoint(host: "192.168.1.20", port: 8443), token: "",
                pin: wrongPin ? Array(repeating: 0, count: 32) : SPKIFingerprint.digest(host.publicKey),
                expiresAt: 0, clientKey: phone.fingerprintHex, remote: nil)
            setup = try ControlTLS.setup(
                for: link,
                client: ControlTLS.ClientIdentity(
                    certificateDER: try PhoneCertificateFactory.make(signer: phone, now: now), signer: phone))
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: [
                    .certificate(try NIOSSLCertificate(bytes: try Harness.certificate(host, now: now), format: .der))
                ],
                privateKey: .privateKey(
                    try NIOSSLPrivateKey(bytes: Array(host.pemRepresentation.utf8), format: .pem)))
            configuration.minimumTLSVersion = .tlsv13
            configuration.maximumTLSVersion = .tlsv13
            configuration.certificateVerification = .none
            try server.pipeline.syncOperations.addHandlers([
                serverCloser, NIOSSLServerHandler(context: NIOSSLContext(configuration: configuration)), responder,
            ])
            server.connect(to: Harness.address, promise: nil)
            client.closeFuture.whenComplete { [self] _ in clientClosed = true }
        }

        /// Runs the `/pair` request: after `initializeDelayMs` the exchange's initializer builds the
        /// pipeline; `connectDelayMs` later the connection becomes active.
        func start(timeoutMs: Int, connectDelayMs: Int64 = 0, initializeDelayMs: Int64 = 0) {
            let client = client
            let head: [ChannelHandler] = [clientCloser, hold]
            let body = PairingClient.requestBody(secret: String(repeating: "C", count: 43), label: "iPhone")
            let exchange = LanControlTransport.Exchange(
                endpoint: link.endpoint, setup: setup,
                requestBytes: try! ControlRequestEncoder.encode(PairingClient.request(body: body), host: link.endpoint),
                maxResponseBytes: PairingClient.maxReplyBytes, timeoutMs: timeoutMs,
                connector: .posix(group: loop), connectTimeoutMs: LanControlTransport.connectTimeoutCapMs,
                progress: SignalingRequestProgress(.lanRequest),
                connect: { [self] _, timeout, loop, initializer in
                    connectTimeouts.append(timeout)
                    let connected = loop.makePromise(of: Channel.self)
                    let open = { [self] in
                        try! client.pipeline.syncOperations.addHandlers(head)
                        initializer(client).whenComplete { [self] result in
                            switch result {
                            case .failure(let error):
                                connected.fail(error)
                            case .success:
                                initialized = true
                                loop.scheduleTask(in: .milliseconds(connectDelayMs)) {
                                    client.connect(to: Harness.address).map { client as Channel }.cascade(to: connected)
                                }
                            }
                        }
                    }
                    if initializeDelayMs > 0 {
                        loop.scheduleTask(in: .milliseconds(initializeDelayMs)) { open() }
                    } else {
                        open()
                    }
                    return connected.futureResult
                })
            self.exchange = exchange
            exchange.run().whenComplete { [self] in result = $0 }
            pump()
        }

        func advance(by milliseconds: Int64) {
            loop.advanceTime(by: .milliseconds(milliseconds))
            pump()
        }

        /// Moves TLS records between the two channels until both are idle.
        func pump() {
            for _ in 0..<100 {
                loop.run()
                var moved = false
                while let bytes = try? client.readOutbound(as: IOData.self) {
                    if server.isActive { _ = try? server.writeInbound(bytes) }
                    moved = true
                }
                while deliversServerBytes, let bytes = try? server.readOutbound(as: IOData.self) {
                    if client.isActive {
                        clientReads += 1
                        _ = try? client.writeInbound(bytes)
                    }
                    moved = true
                }
                if !moved { break }
            }
        }

        /// Closes both channels below TLS (embedded time never runs NIOSSL's shutdown timer) and drops
        /// every remaining scheduled task.
        func finish() {
            hold.release()
            clientCloser.abort()
            serverCloser.abort()
            _ = try? client.finish(acceptAlreadyClosed: true)
            _ = try? server.finish(acceptAlreadyClosed: true)
            exchange = nil
        }

        private static func certificate(_ key: P256.Signing.PrivateKey, now: Date) throws -> [UInt8] {
            let address: [UInt8] = [192, 168, 1, 20]
            let names = SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: address[...]))])
            let certificate = try Certificate(
                version: .v3, serialNumber: Certificate.SerialNumber(bytes: [1]),
                publicKey: Certificate.PublicKey(key.publicKey), notValidBefore: now.addingTimeInterval(-3_600),
                notValidAfter: now.addingTimeInterval(3_600),
                issuer: DistinguishedName(), subject: DistinguishedName(), signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions([
                    Certificate.Extension(KeyUsage(digitalSignature: true), critical: true),
                    Certificate.Extension(ExtendedKeyUsage([.serverAuth]), critical: false),
                    Certificate.Extension(BasicConstraints.notCertificateAuthority, critical: true),
                    Certificate.Extension(names, critical: true),
                ]), issuerPrivateKey: Certificate.PrivateKey(key))
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return serializer.serializedBytes
        }
    }

    /// The Windows side above its TLS: records the decrypted request and writes scripted reply bytes.
    private final class Responder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private(set) var request: [UInt8] = []
        private var context: ChannelHandlerContext?

        func handlerAdded(context: ChannelHandlerContext) { self.context = context }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            request += unwrapInboundIn(data).readableBytesView
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {}

        func send(_ text: String) {
            guard let context else { return }
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: text)), promise: nil)
        }
    }

    /// Client handler below the exchange's own handlers that can defer closes, as a Network.framework
    /// connection reports its cancellation only later.
    private final class CloseHold: ChannelOutboundHandler, RemovableChannelHandler {
        typealias OutboundIn = NIOAny
        typealias OutboundOut = NIOAny

        var holding = false
        private(set) var closeRequests = 0
        private var held: [(ChannelHandlerContext, CloseMode, EventLoopPromise<Void>?)] = []

        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            closeRequests += 1
            if holding {
                held.append((context, mode, promise))
            } else {
                context.close(mode: mode, promise: promise)
            }
        }

        func release() {
            holding = false
            let pending = held
            held = []
            for (context, mode, promise) in pending { context.close(mode: mode, promise: promise) }
        }
    }
}
