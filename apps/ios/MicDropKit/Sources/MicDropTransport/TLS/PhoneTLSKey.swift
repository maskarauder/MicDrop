import Crypto
import Dispatch
import Foundation
import MicDropIdentity
import NIOCore
import NIOSSL

/// The phone's TLS client key as a BoringSSL custom private key (iOS counterpart of Android's "Conscrypt prehashes,
/// Keystore signs NONEwithECDSA", `AndroidIdentity.kt:34-37`).
///
/// - Only `ecdsa_secp256r1_sha256` (0x0403) is offered.
/// - `sign` receives the **unhashed** TLS 1.3 CertificateVerify content; `PhoneSigner.signSHA256`
///   hashes with SHA-256 and signs; the result is the ASN.1 DER ECDSA-Sig-Value.
/// - Secure Enclave signing blocks for milliseconds, so it runs on a background queue and
/// completes an event-loop promise (never on the NIO loop).
/// - Identity (`Hashable`) is the canonical SPKI DER of the public key.
public final class PhoneTLSKey: NIOSSLCustomPrivateKey, Hashable, @unchecked Sendable {
    /// Failures surfaced to BoringSSL (the handshake then fails as `handshakeFailed`). swift-nio-ssl
    /// fires the failed key result just before `handshakeFailed` (`NIOSSLHandler.swift:440-450`), so
    /// `ControlTLSSetup.classify` maps this type to the Windows handshake failure.
    public enum Failure: Error, Sendable, Equatable {
        /// BoringSSL asked for an algorithm other than `ecdsaSecp256R1Sha256`.
        case unsupportedAlgorithm
        /// ECDSA keys never decrypt (TLS 1.3 never asks).
        case decryptUnsupported
        /// `PhoneSigner.signSHA256` threw (e.g. a Secure Enclave / CryptoKit error). Android's
        /// Keystore signer failure is a fatal `SSLHandshakeException` (`ConnectionFailure.kt:41`).
        case signingFailed
    }

    /// The signing key (Secure Enclave in the app, `SoftwareSigner` in tests).
    public let signer: any PhoneSigner
    /// Canonical P-256 SPKI DER of `signer.publicKey` (hash/equality identity).
    public let publicKeyDER: [UInt8]

    private let queue: DispatchQueue

    /// - Parameter queue: where `signSHA256` runs; defaults to a global `.userInitiated` queue.
    public init(signer: any PhoneSigner, queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.signer = signer
        self.publicKeyDER = Array(signer.publicKey.derRepresentation)
        self.queue = queue
    }

    public var signatureAlgorithms: [SignatureAlgorithm] {
        [.ecdsaSecp256R1Sha256]
    }

    public func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard algorithm == .ecdsaSecp256R1Sha256 else {
            return channel.eventLoop.makeFailedFuture(Failure.unsupportedAlgorithm)
        }
        let promise = channel.eventLoop.makePromise(of: ByteBuffer.self)
        let message = Data(data.readableBytesView)
        let signer = self.signer
        queue.async {
            do {
                let signature = try signer.signSHA256(message)
                promise.succeed(ByteBuffer(bytes: signature.derRepresentation))
            } catch {
                promise.fail(Failure.signingFailed)
            }
        }
        return promise.futureResult
    }

    public func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(Failure.decryptUnsupported)
    }

    public static func == (lhs: PhoneTLSKey, rhs: PhoneTLSKey) -> Bool {
        lhs.publicKeyDER == rhs.publicKeyDER
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKeyDER)
    }
}
