import Foundation
import MicDropCore
import MicDropIdentity
import NIOCore
import NIOSSL

/// Builds the paired / legacy control-plane TLS client configuration used by every LAN request and by the inner TLS
/// inside the remote rendezvous tunnel.
///
/// One `ControlTLSSetup` is created per request (fresh `lastVerificationFailure`), and one
/// `NIOSSLClientHandler` per connection via `ControlTLSSetup.makeHandler()`.
public enum ControlTLS {
    /// The phone's client credential for paired (v3) links: the self-signed leaf certificate and the key that signs TLS
    /// 1.3 CertificateVerify. Legacy v1/v2 links present no client certificate (`LanInvitation.kt:15`), so the
    /// credential is ignored for them.
    public struct ClientIdentity: Sendable {
        /// The single certificate sent to Windows (leaf only, no chain; Go `tls.go:17`).
        public let certificateDER: [UInt8]
        /// Signs SHA-256 over the unhashed CertificateVerify content (`PhoneTLSKey`).
        public let signer: any PhoneSigner

        public init(certificateDER: [UInt8], signer: any PhoneSigner) {
            self.certificateDER = certificateDER
            self.signer = signer
        }
    }

    /// Programming / identity errors raised before any I/O. Not retryable; `describe` falls through to `SETUP_FAILED`.
    public enum SetupError: Error, Sendable, Equatable {
        /// A paired (v3) link needs the phone certificate and key (Go `RequireAnyClientCert`).
        case clientIdentityRequired
        /// `certificateDER` did not load as an X.509 certificate.
        case invalidClientCertificate
        /// `NIOSSLContext` rejected the configuration.
        case contextUnavailable
    }

    /// TLS 1.3 only, no ALPN, no SNI, `.noHostnameVerification` (verify mode PEER, so the custom callback's failure
    /// aborts the handshake —, never `.none`), trust roots empty (the custom callback with `HostTrustVerifier` is the
    /// only trust decision), client certificate + `PhoneTLSKey` for paired links.
    ///
    /// - Parameters:
    ///   - link: the connection link; `link.hostPin` and `link.endpoint.host` feed the verifier
    ///     (the IP SAN is checked against the paired record's LAN IPv4 on LAN and through the
    ///     tunnel alike, `RemoteHttp.kt:35-39`).
    ///   - client: required for `link.version == .paired`, ignored otherwise.
    public static func setup(for link: ConnectionLink, client: ClientIdentity?) throws -> ControlTLSSetup {
        let verifier = HostTrustVerifier(link: link)
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.applicationProtocols = []
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates([])
        var presentsClientCertificate = false
        if link.version == .paired {
            guard let client else {
                throw SetupError.clientIdentityRequired
            }
            let certificate: NIOSSLCertificate
            do {
                certificate = try NIOSSLCertificate(bytes: client.certificateDER, format: .der)
            } catch {
                throw SetupError.invalidClientCertificate
            }
            configuration.certificateChain = [.certificate(certificate)]
            configuration.privateKey = .privateKey(
                NIOSSLPrivateKey(customPrivateKey: PhoneTLSKey(signer: client.signer)))
            presentsClientCertificate = true
        }
        let context: NIOSSLContext
        do {
            context = try NIOSSLContext(configuration: configuration)
        } catch {
            throw SetupError.contextUnavailable
        }
        return ControlTLSSetup(
            verifier: verifier, context: context,
            presentsClientCertificate: presentsClientCertificate)
    }
}

/// Per-request TLS state: the pinned verifier, the shared `NIOSSLContext`, and the verifier's own verdict from the
/// custom callback so a `handshakeFailed` can be reported precisely as `identity` vs `certificate_time`.
///
/// Thread-safety: the custom callback runs on the channel's event loop; `lastVerificationFailure`
/// is lock-protected so the exchange (same loop) and tests (any thread) may read it.
public final class ControlTLSSetup: @unchecked Sendable {
    /// Classification of an error that reached the inner-TLS consumer.
    public enum InnerErrorVerdict: Sendable, Equatable {
        /// Ragged EOF or EOF during the handshake (`NIOSSLError.uncleanShutdown`, or `handshakeFailed` whose stack is
        /// `eofDuringHandshake`): the transport ended under TLS → `SignalingStreamEnded` (retryable;
        /// `EngineStream.kt:56-57`, for LAN).
        case transportEOF
        /// A TLS failure of the Windows layer with this problem (fatal).
        case failure(SignalingTLSFailure.Problem)
        /// Not a NIOSSL/BoringSSL/`PhoneTLSKey` error (transport-level; classified elsewhere).
        case notTLS
    }

    /// Pin + LAN IPv4 verifier.
    public let verifier: HostTrustVerifier
    /// `true` for paired (v3) links (client certificate + `PhoneTLSKey` configured).
    public let presentsClientCertificate: Bool

    private let context: NIOSSLContext
    private let failure = Locked<HostTrustFailure?>(nil)

    init(verifier: HostTrustVerifier, context: NIOSSLContext, presentsClientCertificate: Bool) {
        self.verifier = verifier
        self.context = context
        self.presentsClientCertificate = presentsClientCertificate
    }

    /// The verifier's first rejection recorded by the custom callback (or the post-handshake
    /// re-check), `nil` while every evaluation passed.
    public var lastVerificationFailure: HostTrustFailure? {
        failure.value
    }

    /// A fresh client handler for one connection: `serverHostname: nil` (no SNI; swift-nio-ssl rejects IP literals in
    /// SNI), custom verification callback running `HostTrustVerifier` with the current time.
    public func makeHandler() throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(
            context: context,
            serverHostname: nil,
            customVerificationCallback: { [self] certificates, promise in
                let verdict = self.evaluate(certificates, now: Date())
                promise.succeed(verdict == nil ? .certificateVerified : .failed)
            }
        )
    }

    /// Runs the verifier over the presented chain (leaf first) and records the first failure.
    /// A certificate whose DER cannot be re-serialized is `.malformed`.
    @discardableResult
    public func evaluate(_ certificates: [NIOSSLCertificate], now: Date) -> HostTrustFailure? {
        var chain: [[UInt8]] = []
        chain.reserveCapacity(certificates.count)
        var verdict: HostTrustFailure?
        for certificate in certificates {
            guard let der = try? certificate.toDERBytes() else {
                verdict = .malformed
                break
            }
            chain.append(der)
        }
        if verdict == nil {
            verdict = verifier.verify(chainDER: chain, now: now)
        }
        if let verdict {
            failure.withLock { stored in
                if stored == nil {
                    stored = verdict
                }
            }
        }
        return verdict
    }

    /// Defense-in-depth re-check of the negotiated peer leaf after `handshakeCompleted` and before any request byte is
    /// written. `nil` peer → `.chainLength`. Call on the channel's event loop with `try?
    /// context.pipeline.syncOperations.nioSSL_peerCertificate()`.
    @discardableResult
    public func verifyAfterHandshake(peerCertificate: NIOSSLCertificate?, now: Date) -> HostTrustFailure? {
        guard let peerCertificate else {
            failure.withLock { stored in
                if stored == nil {
                    stored = .chainLength
                }
            }
            return .chainLength
        }
        return evaluate([peerCertificate], now: now)
    }

    /// Maps a verifier verdict to the `SignalingTLSFailure` problem.
    public static func problem(for failure: HostTrustFailure) -> SignalingTLSFailure.Problem {
        failure.isCertificateTime ? .certificateTime : .identity
    }

    /// Inner-TLS error classification: `uncleanShutdown` / EOF-during-handshake → `.transportEOF`; `handshakeFailed` →
    /// verifier verdict if recorded (`identity` / `certificate_time`) else `.handshake`; `readInInvalidTLSState` →
    /// `.protocol`; any other `NIOSSLError` / `BoringSSLError` / `NIOSSLCloseTimedOutError` → `.other` (e.g. Windows'
    /// `bad_certificate` alert on the first read after a TLS 1.3 handshake); `PhoneTLSKey.Failure` (the failed
    /// client-key result that swift-nio-ssl fires before `handshakeFailed`) → `.handshake`, never a LAN transport error
    /// (Android: a fatal `SSLHandshakeException`); anything else → `.notTLS`.
    public func classify(_ error: Error) -> InnerErrorVerdict {
        if let ssl = error as? NIOSSLError {
            switch ssl {
            case .uncleanShutdown:
                return .transportEOF
            case .handshakeFailed(let boring):
                if case .sslError(let stack) = boring,
                    stack.contains(BoringSSLInternalError.eofDuringHandshake)
                        || stack.contains(BoringSSLInternalError.eofDuringAdditionalCertficiateChainValidation)
                {
                    return .transportEOF
                }
                if let recorded = lastVerificationFailure {
                    return .failure(Self.problem(for: recorded))
                }
                return .failure(.handshake)
            case .readInInvalidTLSState:
                return .failure(.protocol)
            default:
                return .failure(.other)
            }
        }
        if error is BoringSSLError || error is NIOSSLCloseTimedOutError {
            return .failure(.other)
        }
        if error is PhoneTLSKey.Failure {
            return .failure(.handshake)
        }
        return .notTLS
    }
}
