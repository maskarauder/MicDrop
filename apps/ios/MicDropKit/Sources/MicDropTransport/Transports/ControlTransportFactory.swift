import MicDropCore

/// Picks the control transport for a connection link: `RemoteControlTransport` when the link has a rendezvous route,
/// else `LanControlTransport`. Fits `PairingClient.TransportFactory` and `SessionDependencies.transport`.
public enum ControlTransportFactory {
    /// Transport whose TLS setup is rebuilt per request from `client` (`ControlTLS.setup(for:client:)`).
    public static func make(
        for link: ConnectionLink, client: ControlTLS.ClientIdentity?,
        connector: ControlConnector = .platformDefault,
        outerTrust: OuterTrustPolicy = .system, connectTimeoutMs: Int = 8_000
    ) -> any ControlTransport {
        make(
            for: link, connector: connector, outerTrust: outerTrust, connectTimeoutMs: connectTimeoutMs,
            tls: { try ControlTLS.setup(for: link, client: client) })
    }

    /// Transport with a caller-supplied per-request TLS factory.
    public static func make(
        for link: ConnectionLink, connector: ControlConnector = .platformDefault,
        outerTrust: OuterTrustPolicy = .system,
        connectTimeoutMs: Int = 8_000,
        tls: @escaping @Sendable () throws -> ControlTLSSetup
    ) -> any ControlTransport {
        if let route = link.remote {
            return RemoteControlTransport(
                link: link, route: route, connector: connector,
                outerTrust: outerTrust, connectTimeoutMs: connectTimeoutMs, tls: tls)
        }
        return LanControlTransport(link: link, connector: connector, connectTimeoutMs: connectTimeoutMs, tls: tls)
    }
}
