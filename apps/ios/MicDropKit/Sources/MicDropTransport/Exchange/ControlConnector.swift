import Foundation
import MicDropCore
import NIOCore
import NIOPosix
import NIOSSL

#if canImport(Network)
    import Network
#endif
#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Which networking stack opens control-plane connections, and how its failures are classified.
///
/// - `.transportServices(…)` (iOS/macOS, `#if canImport(NIOTransportServices)`): NIOTS on
/// Network.framework. LAN: plain TCP with `prohibitedInterfaceTypes = [.cellular]`, `waitForActivity = false`; remote:
/// TCP + outer `NWProtocolTLS` 1.3 with system trust. The production default on Apple platforms.
/// - `.posix(group:)` (every platform): NIOPosix sockets; the remote outer TLS is an outer
/// `NIOSSLClientHandler` ("Alternative"). Used by Linux CI loopback tests to exercise the identical pipelines.
///
/// One connector may serve many exchanges; each exchange runs on `group.next()`.
public struct ControlConnector: Sendable {
    /// The event loop group exchanges run on (app lifetime; never shut down by the transport).
    public let group: EventLoopGroup
    let backend: Backend

    enum Backend: Sendable {
        case posix
        #if canImport(NIOTransportServices)
            case transportServices(LANPathHooks)
        #endif
    }

    /// NIOPosix sockets on `group` (default: the process-wide `MultiThreadedEventLoopGroup.singleton`).
    public static func posix(group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) -> ControlConnector {
        ControlConnector(group: group, backend: .posix)
    }

    /// NIOTS (with no LAN path hooks) on Apple platforms, NIOPosix elsewhere.
    public static var platformDefault: ControlConnector {
        #if canImport(NIOTransportServices)
            return .transportServices()
        #else
            return .posix()
        #endif
    }

    /// The loop for one exchange.
    public func nextLoop() -> EventLoop {
        group.next()
    }

    // MARK: - Used by the exchanges (internal)

    /// Opens the LAN TCP connection to the paired record's endpoint on `loop`, running
    /// `initializer` before the connection starts (handlers present before `channelActive`).
    ///
    /// The returned future fails with an already classified error: connect timeout → `ControlIOError(.timedOut)`;
    /// refused / no route / host down → `.unreachable`; NIOTS path unsatisfied with `.localNetworkDenied` (or DNS
    /// `kDNSServiceErr_PolicyDenied` −65570) → `.localNetworkDenied`; only cellular available →
    /// `.lanNetworkUnavailable` (and `LANPathHooks.onReadyPath(nil)`); other → `.transportClosed`.
    func connectLAN(
        endpoint: LANEndpoint, connectTimeout: TimeAmount, on loop: EventLoop,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        switch backend {
        case .posix:
            return connectLANPosix(
                endpoint: endpoint, connectTimeout: connectTimeout, on: loop,
                initializer: initializer)
        #if canImport(NIOTransportServices)
            case .transportServices(let hooks):
                return connectLANTransportServices(
                    hooks: hooks, endpoint: endpoint, connectTimeout: connectTimeout,
                    on: loop, initializer: initializer)
        #endif
        }
    }

    /// Opens TCP + outer TLS 1.3 to `route.connectHost:route.connectPort`. `initializer` receives the channel and the
    /// outer TLS handler to insert right after the `TransportCloser` (NIOPosix) or `nil` (NIOTS, where the outer TLS is
    /// in the `NWConnection`). The returned future fails with the raw error; classify it with
    /// `classifyRendezvousConnectFailure(_:verdict:)`.
    func connectRendezvous(
        route: RemoteRoute, outerTrust: OuterTrustPolicy, verdict: OuterTrustVerdictBox,
        connectTimeout: TimeAmount, on loop: EventLoop,
        initializer: @escaping @Sendable (Channel, ChannelHandler?) -> EventLoopFuture<Void>
    )
        -> EventLoopFuture<Channel>
    {
        switch backend {
        case .posix:
            return connectRendezvousPosix(
                route: route, outerTrust: outerTrust, verdict: verdict,
                connectTimeout: connectTimeout, on: loop, initializer: initializer)
        #if canImport(NIOTransportServices)
            case .transportServices:
                return connectRendezvousTransportServices(
                    route: route, outerTrust: outerTrust, verdict: verdict,
                    connectTimeout: connectTimeout, on: loop,
                    initializer: initializer)
        #endif
        }
    }

    /// a recorded verdict → `SignalingTLSFailure(.rendezvous, verdict)`; NIOTS `NWError.tls(status)` →
    /// `SignalingTLSFailure(.rendezvous, OuterTLSStatus.problem(status, duringHandshake: true))`; NIOPosix outer
    /// `NIOSSLError.handshakeFailed` → rendezvous TLS (`.identity` for certificate verification failures, else
    /// `.handshake`); everything else (`NWError.dns/.posix`, `ChannelError.connectTimeout`, `NIOConnectionError`,
    /// `NIOTSErrors`) → `ControlIOError(.rendezvousFailed)` (never `HOST_UNREACHABLE` in remote mode).
    func classifyRendezvousConnectFailure(_ error: Error, verdict: OuterTrustVerdictBox) -> Error {
        classifyOuterError(error, verdict: verdict, duringHandshake: true) ?? ControlIOError(.rendezvousFailed)
    }

    /// Errors seen by the rendezvous handlers after the channel became active: NIOTS `NWError.posix` (ECONNRESET,
    /// EPIPE, ENETDOWN, ETIMEDOUT…) → `.rendezvousFailed`; `NWError.tls` closure statuses → `nil` (EOF-like); other
    /// `NWError.tls` → `SignalingTLSFailure(.rendezvous, OuterTLSStatus.problem(status, duringHandshake:))`; NIOPosix:
    /// `IOError` → `.rendezvousFailed`, outer `NIOSSLError.uncleanShutdown` → `nil`, other outer
    /// `NIOSSLError`/`BoringSSLError` → rendezvous TLS; `ChannelError.eof`/ `.ioOnClosedChannel` → `nil`.
    func classifyOuterError(_ error: Error, verdict: OuterTrustVerdictBox, duringHandshake: Bool) -> Error? {
        if let problem = verdict.problem { return SignalingTLSFailure(layer: .rendezvous, problem: problem) }
        #if canImport(Network)
            if let network = error as? NWError {
                if case .tls(let status) = network {
                    return OuterTLSStatus.problem(status, duringHandshake: duringHandshake).map {
                        SignalingTLSFailure(layer: .rendezvous, problem: $0)
                    }
                }
                return ControlIOError(.rendezvousFailed)
            }
        #endif
        if let ssl = error as? NIOSSLError {
            let problem: SignalingTLSFailure.Problem
            switch ssl {
            case .uncleanShutdown:
                if !duringHandshake { return nil }
                problem = .handshake
            case .handshakeFailed: problem = .handshake
            case .unableToValidateCertificate, .noCertificateToValidate, .cannotMatchULabel, .cannotFindPeerIP:
                problem = .identity
            case .readInInvalidTLSState: problem = .protocol
            default: problem = .other
            }
            return SignalingTLSFailure(layer: .rendezvous, problem: problem)
        }
        if let extra = error as? NIOSSLExtraError {
            let identity = extra == .failedToValidateHostname || extra == .serverHostnameImpossibleToMatch
            return SignalingTLSFailure(layer: .rendezvous, problem: identity ? .identity : .other)
        }
        if error is BoringSSLError || error is NIOSSLCloseTimedOutError {
            return SignalingTLSFailure(layer: .rendezvous, problem: duringHandshake ? .handshake : .other)
        }
        if let channelError = error as? ChannelError,
            channelError == .eof || channelError == .ioOnClosedChannel
        {
            return nil
        }
        return ControlIOError(.rendezvousFailed)
    }

    // MARK: - NIOPosix backend

    private func connectLANPosix(
        endpoint: LANEndpoint, connectTimeout: TimeAmount, on loop: EventLoop,
        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    )
        -> EventLoopFuture<Channel>
    {
        ClientBootstrap(group: loop).connectTimeout(connectTimeout).channelInitializer(initializer)
            .connect(host: endpoint.host.description, port: Int(endpoint.port))
            .flatMapErrorThrowing { error in
                if let channel = error as? ChannelError, case .connectTimeout = channel {
                    throw ControlIOError(.timedOut)
                }
                if error is NIOConnectionError { throw ControlIOError(.unreachable) }
                if let io = error as? IOError,
                    [ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN].contains(io.errnoCode)
                {
                    throw ControlIOError(.unreachable)
                }
                if error is ControlTLS.SetupError { throw error }
                throw ControlIOError(.transportClosed)
            }
    }

    private func connectRendezvousPosix(
        route: RemoteRoute, outerTrust: OuterTrustPolicy,
        verdict: OuterTrustVerdictBox, connectTimeout: TimeAmount,
        on loop: EventLoop,
        initializer: @escaping @Sendable (Channel, ChannelHandler?) -> EventLoopFuture<Void>
    )
        -> EventLoopFuture<Channel>
    {
        do {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.minimumTLSVersion = .tlsv13
            configuration.maximumTLSVersion = .tlsv13
            configuration.applicationProtocols = []
            configuration.certificateVerification = .fullVerification
            switch outerTrust {
            case .system: configuration.trustRoots = .default
            case .anchors(let certificates):
                configuration.trustRoots = .certificates(
                    try certificates.map { try NIOSSLCertificate(bytes: $0, format: .der) })
            }
            let context = try NIOSSLContext(configuration: configuration)
            let outer = try NIOSSLClientHandler(
                context: context, serverHostname: route.hostIsIPLiteral ? nil : route.connectHost,
                verificationCallback: { result, certificate in
                    // Preserve the library's chain verdict; this callback only records a safe category.
                    if case .failed = result {
                        let now = Date().timeIntervalSince1970
                        let invalidTime =
                            now < Double(certificate.notValidBefore) || now > Double(certificate.notValidAfter)
                        verdict.record(invalidTime ? .certificateTime : .identity)
                    }
                    return result
                })
            return ClientBootstrap(group: loop).connectTimeout(connectTimeout)
                .channelInitializer { initializer($0, outer) }
                .connect(host: route.connectHost, port: route.connectPort)
        } catch {
            return loop.makeFailedFuture(error)
        }
    }
}
