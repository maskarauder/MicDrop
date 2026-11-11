import MicDropCore
import MicDropIdentity

// Conveniences over MicDropIdentity's `PhoneIdentity` (`ControlTLS.setup(for:identity:)`). The transport core only
// needs `ControlTLS.ClientIdentity`.

extension ControlTLS.ClientIdentity {
    /// The certificate and signer of a loaded phone identity.
    public init(_ identity: PhoneIdentity) {
        self.init(certificateDER: identity.certificateDER, signer: identity.signer)
    }
}

extension ControlTLS {
    /// `setup(for:client:)` with the phone identity (required for paired links, ignored for v1/v2).
    public static func setup(for link: ConnectionLink, identity: PhoneIdentity?) throws -> ControlTLSSetup {
        try setup(for: link, client: identity.map { ClientIdentity($0) })
    }
}

extension LanControlTransport {
    /// `init(link:client:connector:)` with the phone identity (spelling; the `identity` is required for paired links,
    /// ignored for v1/v2).
    public convenience init(
        link: ConnectionLink, identity: PhoneIdentity?,
        connector: ControlConnector = .platformDefault
    ) {
        self.init(link: link, client: identity.map { ControlTLS.ClientIdentity($0) }, connector: connector)
    }
}

extension RemoteControlTransport {
    /// `init?(link:client:connector:outerTrust:)` with the phone identity (spelling); `nil` when `link.remote == nil`.
    public convenience init?(
        link: ConnectionLink, identity: PhoneIdentity?,
        connector: ControlConnector = .platformDefault, outerTrust: OuterTrustPolicy = .system
    ) {
        self.init(
            link: link, client: identity.map { ControlTLS.ClientIdentity($0) }, connector: connector,
            outerTrust: outerTrust)
    }
}

extension ControlTransportFactory {
    /// The LAN or remote transport for `link` with the phone identity (shape).
    public static func make(
        for link: ConnectionLink, identity: PhoneIdentity?,
        connector: ControlConnector = .platformDefault,
        outerTrust: OuterTrustPolicy = .system
    ) -> any ControlTransport {
        make(
            for: link, client: identity.map { ControlTLS.ClientIdentity($0) },
            connector: connector, outerTrust: outerTrust)
    }
}
