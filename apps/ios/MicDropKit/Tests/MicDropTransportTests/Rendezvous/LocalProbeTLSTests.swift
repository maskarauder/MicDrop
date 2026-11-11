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

/// Actual TLS 1.3 handshakes between in-memory NIO channels, with ephemeral test keys.
final class LocalProbeTLSTests: XCTestCase {
    func testTrustedPairedProbeCompletesWithoutSendingHTTP() throws {
        let result = try handshake()
        XCTAssertEqual(result.reachable, true)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.applicationBytes, 0)
    }

    func testWrongPinWrongAddressAndExpiredCertificateCannotProveReachability() throws {
        for (wrongPin, wrongAddress, expired, expected) in [
            (true, false, false, HostTrustFailure.pinMismatch),
            (false, true, false, HostTrustFailure.addressMismatch),
            (false, false, true, HostTrustFailure.expired),
        ] {
            let result = try handshake(wrongPin: wrongPin, wrongAddress: wrongAddress, expired: expired)
            XCTAssertEqual(result.reachable, false)
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(result.applicationBytes, 0)
        }
    }

    private func handshake(wrongPin: Bool = false, wrongAddress: Bool = false, expired: Bool = false) throws
        -> (reachable: Bool?, failure: HostTrustFailure?, applicationBytes: Int)
    {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let address: [UInt8] = wrongAddress ? [10, 0, 0, 20] : [192, 168, 1, 20]
        let names = SubjectAlternativeNames([.ipAddress(ASN1OctetString(contentBytes: address[...]))])
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(bytes: [1]),
            publicKey: Certificate.PublicKey(key.publicKey), notValidBefore: now.addingTimeInterval(-3_600),
            notValidAfter: now.addingTimeInterval(expired ? -60 : 3_600),
            issuer: DistinguishedName(), subject: DistinguishedName(), signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions([
                Certificate.Extension(KeyUsage(digitalSignature: true), critical: true),
                Certificate.Extension(ExtendedKeyUsage([.serverAuth]), critical: false),
                Certificate.Extension(BasicConstraints.notCertificateAuthority, critical: true),
                Certificate.Extension(names, critical: true),
            ]), issuerPrivateKey: Certificate.PrivateKey(key))
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let certificateDER = serializer.serializedBytes
        let phone = SoftwareSigner.generate()
        let identity = ControlTLS.ClientIdentity(
            certificateDER: try PhoneCertificateFactory.make(signer: phone, now: now), signer: phone)
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.20", port: 8443), token: "",
            pin: wrongPin ? Array(repeating: 0, count: 32) : SPKIFingerprint.digest(key.publicKey),
            expiresAt: 0, clientKey: phone.fingerprintHex, remote: nil)
        let setup = try ControlTLS.setup(for: link, client: identity)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(key.pemRepresentation.utf8), format: .pem)))
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .none
        let server = EmbeddedChannel()
        let client = EmbeddedChannel()
        let serverCloser = TransportCloser()
        let closer = TransportCloser()
        defer {
            // Embedded time does not advance shutdown timers. Abort below TLS, as production probes do.
            closer.abort()
            serverCloser.abort()
            _ = try? client.finish()
            _ = try? server.finish()
        }
        let recorder = PayloadRecorder()
        try server.pipeline.addHandlers([
            serverCloser, NIOSSLServerHandler(context: NIOSSLContext(configuration: configuration)), recorder,
        ]).wait()
        let tls = try setup.makeHandler()
        var reachable: Bool?
        try client.pipeline.addHandlers([
            closer, tls,
            LocalProbe.ProbeHandler(
                verify: { setup.verifyAfterHandshake(peerCertificate: tls.peerCertificate, now: Date()) == nil },
                complete: { value in
                    if reachable == nil { reachable = value }
                    closer.abort()
                }),
        ]).wait()
        let socket = try SocketAddress(ipAddress: "127.0.0.1", port: 8443)
        server.connect(to: socket, promise: nil)
        client.connect(to: socket, promise: nil)
        for _ in 0..<100 {
            client.embeddedEventLoop.run()
            server.embeddedEventLoop.run()
            var transferred = false
            while let bytes = try client.readOutbound(as: IOData.self) {
                _ = try? server.writeInbound(bytes)
                transferred = true
            }
            while let bytes = try server.readOutbound(as: IOData.self) {
                _ = try? client.writeInbound(bytes)
                transferred = true
            }
            if !transferred { break }
        }
        return (reachable, setup.lastVerificationFailure, recorder.bytes)
    }

    private final class PayloadRecorder: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        var bytes = 0
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { bytes += unwrapInboundIn(data).readableBytes }
        func errorCaught(context: ChannelHandlerContext, error: Error) {}
    }
}
