#if canImport(NIOTransportServices)
    import Dispatch
    import Foundation
    import MicDropCore
    import Network
    import NIOCore
    import NIOTransportServices

    extension ControlConnector {
        /// Per-session LAN hooks. The app passes `LanSignalingRoute.configure` and `LanSignalingRoute.recordReadyPath`
        /// (app target).
        public struct LANPathHooks: Sendable {
            /// Applied to the LAN `NWParameters` after the transport set
            /// `prohibitedInterfaceTypes = [.cellular]` (never routes LAN control over cellular,
            /// `LanNetwork.kt:43-69`).
            public var configureParameters: (@Sendable (NWParameters) -> Void)?
            /// Called with the connection's `currentPath` after `channelActive`
            /// (`NIOTSChannelOptions.currentPath`), or with `nil` when a connect failed because no
            /// eligible (non-cellular) path exists — `LanSignalingRoute` then records `unavailable`.
            public var onReadyPath: (@Sendable (NWPath?) -> Void)?

            public init(
                configureParameters: (@Sendable (NWParameters) -> Void)? = nil,
                onReadyPath: (@Sendable (NWPath?) -> Void)? = nil
            ) {
                self.configureParameters = configureParameters
                self.onReadyPath = onReadyPath
            }
        }

        /// NIOTS on `group` (default: `NIOTSEventLoopGroup.singleton`, app lifetime).
        public static func transportServices(
            group: NIOTSEventLoopGroup = .singleton,
            lanHooks: LANPathHooks = LANPathHooks()
        ) -> ControlConnector {
            ControlConnector(group: group, backend: .transportServices(lanHooks))
        }

        /// LAN over NIOTS: builds its own `NWConnection` with `NWParameters(tls: nil, tcp:)`, `prohibitedInterfaceTypes
        /// = [.cellular]`, then `hooks.configureParameters`; `NIOTSConnectionBootstrap(group: loop)
        /// .connectTimeout(connectTimeout).channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        /// .channelInitializer(initializer).withExistingNWConnection(connection)`. On success reads
        /// `channel.getOption(NIOTSChannelOptions.currentPath)` → `hooks.onReadyPath`. On failure reads
        /// `connection.currentPath` before classifying: `unsatisfiedReason == .localNetworkDenied` or
        /// `NWError.dns(-65570)` → `ControlIOError(.localNetworkDenied)`; unsatisfied with no non-cellular interface →
        /// `.lanNetworkUnavailable` + `onReadyPath(nil)`;
        /// `NWError.posix(ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|EHOSTDOWN)` → `.unreachable`;
        /// `ChannelError.connectTimeout` → `.timedOut`; else `.transportClosed`.
        func connectLANTransportServices(
            hooks: LANPathHooks, endpoint: LANEndpoint, connectTimeout: TimeAmount,
            on loop: EventLoop,
            initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
        )
            -> EventLoopFuture<Channel>
        {
            let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
            parameters.prohibitedInterfaceTypes = [.cellular]
            hooks.configureParameters?(parameters)
            var prohibited = parameters.prohibitedInterfaceTypes ?? []
            if !prohibited.contains(.cellular) {
                prohibited.append(.cellular)
            }
            parameters.prohibitedInterfaceTypes = prohibited
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                return loop.makeFailedFuture(ControlIOError(.unreachable))
            }
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host.description), port: port, using: parameters)
            return NIOTSConnectionBootstrap(group: loop).connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .channelInitializer(initializer).withExistingNWConnection(connection)
                .flatMap { channel in
                    channel.getOption(NIOTSChannelOptions.currentPath).map { path in
                        hooks.onReadyPath?(path)
                        return channel
                    }
                }.flatMapErrorThrowing { error in
                    let path = connection.currentPath
                    if path?.unsatisfiedReason == .localNetworkDenied {
                        throw ControlIOError(.localNetworkDenied)
                    }
                    if let network = error as? NWError, case .dns(let code) = network, code == -65570 {
                        throw ControlIOError(.localNetworkDenied)
                    }
                    if let path, path.status == .unsatisfied,
                        !path.availableInterfaces.contains(where: { $0.type != .cellular && $0.type != .loopback })
                    {
                        hooks.onReadyPath?(nil)
                        throw ControlIOError(.lanNetworkUnavailable)
                    }
                    if let channel = error as? ChannelError, case .connectTimeout = channel {
                        throw ControlIOError(.timedOut)
                    }
                    if let network = error as? NWError, case .posix(let code) = network,
                        [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN].contains(code)
                    {
                        throw ControlIOError(.unreachable)
                    }
                    if error is ControlTLS.SetupError { throw error }
                    throw ControlIOError(.transportClosed)
                }
        }

        /// Rendezvous over NIOTS: `NIOTSConnectionBootstrap(group: loop)
        /// .connectTimeout(connectTimeout).channelOption(NIOTSChannelOptions.waitForActivity, value: false)
        /// .tlsOptions(RendezvousOuterTLS.makeOptions(route:verdict:policy:queue:)) .channelInitializer {
        /// initializer($0, nil) }.connect(host: route.connectHost, port: route.connectPort)`. Default `NWParameters`
        /// (allows expensive/constrained paths, follows the system VPN).
        func connectRendezvousTransportServices(
            route: RemoteRoute, outerTrust: OuterTrustPolicy,
            verdict: OuterTrustVerdictBox, connectTimeout: TimeAmount,
            on loop: EventLoop,
            initializer: @escaping @Sendable (Channel, ChannelHandler?) -> EventLoopFuture<Void>
        )
            -> EventLoopFuture<Channel>
        {
            NIOTSConnectionBootstrap(group: loop).connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .tlsOptions(
                    RendezvousOuterTLS.makeOptions(
                        route: route, verdict: verdict, policy: outerTrust, queue: .global(qos: .userInitiated))
                )
                .channelInitializer { initializer($0, nil) }
                .connect(host: route.connectHost, port: route.connectPort)
        }
    }
#endif
