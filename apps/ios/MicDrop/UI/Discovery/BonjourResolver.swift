// Bonjour service → IPv4 address resolution ("Address resolution", risk 4).
//
// A UDP `NWConnection` to the `.service` endpoint resolves it without sending packets; once `.ready`,
// `currentPath.remoteEndpoint` holds the resolved address. IPv4 only, cellular prohibited, no
// peer-to-peer. One address per service (Windows advertises exactly one A record). Fallback if a
// future iOS stops exposing the resolved endpoint: `DNSServiceResolve` + `DNSServiceGetAddrInfo`
// (`kDNSServiceProtocol_IPv4`).

import Foundation
import Network

@MainActor
final class BonjourResolver: BonjourResolving {
    /// Why a resolution produced no address.
    enum ResolveError: Error, Equatable, Sendable {
        /// The path's remote endpoint is not an IPv4 host/port.
        case noIPv4Address
        /// The connection failed or waited (no route, Local Network denied, service gone).
        case unreachable
    }

    init() {}

    func resolve(
        _ endpoint: NWEndpoint,
        completion: @escaping @MainActor (Result<BonjourResolvedAddress, Error>) -> Void
    ) -> BonjourCancellable {
        let parameters = NWParameters.udp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        let connection = NWConnection(to: endpoint, using: parameters)
        let resolution = Resolution(connection: connection, completion: completion)
        connection.stateUpdateHandler = { [weak resolution] state in
            MainActor.assumeIsolated { resolution?.handle(state) }
        }
        connection.start(queue: .main)
        return resolution
    }

    /// Formats 4 raw IPv4 bytes as dotted decimal (never `IPv4Address.debugDescription`, which may carry
    /// an `%interface` suffix).
    nonisolated static func dotted(_ address: IPv4Address) -> String? {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return nil }
        return bytes.map(String.init).joined(separator: ".")
    }

    /// One in-flight resolution; completes at most once.
    @MainActor
    private final class Resolution: BonjourCancellable {
        private let connection: NWConnection
        private var completion: (@MainActor (Result<BonjourResolvedAddress, Error>) -> Void)?

        init(connection: NWConnection, completion: @escaping @MainActor (Result<BonjourResolvedAddress, Error>) -> Void)
        {
            self.connection = connection
            self.completion = completion
        }

        func handle(_ state: NWConnection.State) {
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                    case .ipv4(let address) = host,
                    let text = BonjourResolver.dotted(address)
                {
                    finish(.success(BonjourResolvedAddress(host: text, port: Int(port.rawValue))))
                } else {
                    finish(.failure(ResolveError.noIPv4Address))
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
                finish(.failure(ResolveError.unreachable))
            default:
                break
            }
        }

        func cancel() {
            completion = nil
            connection.cancel()
        }

        private func finish(_ result: Result<BonjourResolvedAddress, Error>) {
            guard let completion else { return }
            self.completion = nil
            completion(result)
        }
    }
}
