import Crypto
import Foundation
import MicDropCore
import MicDropIdentity
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSL
import SwiftASN1
import X509
import XCTest

@testable import MicDropTransport

/// A phone-key signing failure during the paired handshake is the fatal Windows handshake failure on LAN and through
/// the tunnel alike (Android: `SSLHandshakeException`, `ConnectionFailure.kt:41`, `PairingClient.kt:117`), never a
/// retryable transport error.
final class PhoneTLSKeyFailureTests: XCTestCase {
    func testPhoneKeyFailuresClassifyAsWindowsHandshake() throws {
        let setup = try legacySetup()
        for failure in [PhoneTLSKey.Failure.signingFailed, .unsupportedAlgorithm, .decryptUnsupported] {
            XCTAssertEqual(setup.classify(failure), .failure(.handshake))
        }
    }

    func testKeyFailureFiredBeforeHandshakeFailedIsFatalOnLANAndTunnel() throws {
        for tunnelled in [false, true] {
            let latch = TerminalErrorLatch(tunnelled: tunnelled)
            latch.readySeen = true
            let closer = TransportCloser()
            let channel = EmbeddedChannel()
            defer { _ = try? channel.finish() }
            let promise = channel.eventLoop.makePromise(of: ControlResponse.self)
            let exchange = ControlExchangeHandler(
                requestBytes: [], parser: StrictHTTPResponse.Parser(maxBody: 1024), latch: latch,
                setup: try legacySetup(), completion: promise, closer: closer)
            try channel.pipeline.syncOperations.addHandlers([closer, exchange])
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 8443)).wait()
            // `NIOSSLHandler.swift:440-450`: the failed custom-key result first, then `handshakeFailed`.
            channel.pipeline.syncOperations.fireErrorCaught(PhoneTLSKey.Failure.signingFailed)
            channel.pipeline.syncOperations.fireErrorCaught(NIOSSLError.handshakeFailed(.sslError([])))
            XCTAssertEqual(exchange.state, .completed)
            if exchange.state == .completed {
                XCTAssertThrowsError(try promise.futureResult.wait()) { assertFatalWindowsHandshake($0) }
            }
        }
    }

    func testThrowingSignerOnLANIsFatalWindowsHandshake() throws {
        let signer = FailingSigner()
        XCTAssertThrowsError(try loopbackExchange(signer: signer, tunnelled: false)) {
            assertFatalWindowsHandshake($0)
        }
        XCTAssertEqual(signer.calls.value, 1)
    }

    func testThrowingSignerThroughTunnelIsFatalWindowsHandshake() throws {
        let signer = FailingSigner()
        XCTAssertThrowsError(try loopbackExchange(signer: signer, tunnelled: true)) {
            assertFatalWindowsHandshake($0)
        }
        XCTAssertEqual(signer.calls.value, 1)
    }

    private func assertFatalWindowsHandshake(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? SignalingTLSFailure, SignalingTLSFailure(.windows, .handshake), file: file, line: line)
        XCTAssertFalse(ConnectionFailure.retryableStatus(error), file: file, line: line)
        XCTAssertFalse(ConnectionFailure.pairingRetryable(error), file: file, line: line)
        XCTAssertEqual(ConnectionFailure.code(stage: .pairing, error: error), "TLS_CONNECTION", file: file, line: line)
    }

    /// One paired request over loopback TCP to a TLS 1.3 server that requires a client certificate, with
    /// the production inner handlers (`LanControlTransport.swift:13-14`; tunnelled: the handlers that
    /// `RemoteExchange` installs after the ready frame). The idle handler only bounds the test.
    private func loopbackExchange(signer: FailingSigner, tunnelled: Bool) throws -> ControlResponse {
        let host = P256.Signing.PrivateKey()
        let now = Date()
        let identity = ControlTLS.ClientIdentity(
            certificateDER: try PhoneCertificateFactory.make(signer: signer.base, now: now), signer: signer)
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.20", port: 8443), token: "",
            pin: SPKIFingerprint.digest(host.publicKey), expiresAt: 0, clientKey: signer.fingerprintHex,
            remote: nil)
        let setup = try ControlTLS.setup(for: link, client: identity)
        let certificate = try NIOSSLCertificate(bytes: try hostCertificate(host, now: now), format: .der)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(host.pemRepresentation.utf8), format: .pem)))
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        // Sends CertificateRequest and requires the phone certificate (Go `RequireAnyClientCert`).
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates([])
        let serverContext = try NIOSSLContext(configuration: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let tls = NIOSSLServerHandler(
                    context: serverContext,
                    customVerificationCallback: { _, promise in promise.succeed(.certificateVerified) })
                try channel.pipeline.syncOperations.addHandler(tls)
            }
        }
        let server = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        defer { _ = try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)
        let loop = group.next()
        let promise = loop.makePromise(of: ControlResponse.self)
        let client = ClientBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let latch = TerminalErrorLatch(tunnelled: tunnelled)
                // A tunnel adds the inner TLS only once the ready frame was accepted.
                latch.readySeen = true
                let closer = TransportCloser()
                let tls = try setup.makeHandler()
                try channel.pipeline.syncOperations.addHandlers([
                    closer, IdleStateHandler(readTimeout: .seconds(10)), tls,
                    ControlExchangeHandler(
                        requestBytes: [], parser: StrictHTTPResponse.Parser(maxBody: 1024), latch: latch,
                        setup: setup, completion: promise, closer: closer, innerTLS: tls),
                ])
            }
        }
        _ = try client.connect(host: "127.0.0.1", port: port).wait()
        return try promise.futureResult.wait()
    }

    private func hostCertificate(_ key: P256.Signing.PrivateKey, now: Date) throws -> [UInt8] {
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

    private func legacySetup() throws -> ControlTLSSetup {
        let link = try ConnectionLink(
            version: .v1, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443),
            token: String(repeating: "A", count: 43), pin: Array(repeating: 0, count: 32),
            expiresAt: 0, clientKey: "", remote: nil)
        return try ControlTLS.setup(for: link, client: nil)
    }

    /// A phone key whose signing throws, as a Secure Enclave key can (`SecureEnclaveSigner.signSHA256`).
    /// The certificate is made with `base`, so only the TLS CertificateVerify signature fails.
    private struct FailingSigner: PhoneSigner {
        struct Unavailable: Error {}

        let base = SoftwareSigner.generate()
        let calls = Locked(0)

        var publicKey: P256.Signing.PublicKey { base.publicKey }

        var certificatePrivateKey: Certificate.PrivateKey { base.certificatePrivateKey }

        func signSHA256(_ message: Data) throws -> P256.Signing.ECDSASignature {
            calls.withLock { $0 += 1 }
            throw Unavailable()
        }
    }
}
