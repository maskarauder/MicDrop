import Foundation
import MicDropCore
import NIOCore

/// `ControlTransport` for links with a rendezvous route: one fresh `wss://<rendezvous>/v1/tunnel` + inner paired TLS +
/// HTTP/1.0 exchange per request, absolute deadline `timeoutMs`, non-blocking cancel handle, never retries. Throws
/// `HTTPFailure`, `SignalingTLSFailure` (`.rendezvous` / `.windows`), `SignalingStreamEnded`, `ControlIOError`,
/// `SessionStopped`, `ControlRequestEncoder.InvalidRequest`, `ControlTLS.SetupError`. Returns the raw 200 body (callers
/// parse).
public final class RemoteControlTransport: ControlTransport, @unchecked Sendable {
    /// The paired record (its LAN endpoint is the `Host` header and the IP SAN the inner TLS checks).
    public let link: ConnectionLink
    /// The rendezvous route (`link.remote`).
    public let route: RemoteRoute
    public let connector: ControlConnector
    public let outerTrust: OuterTrustPolicy
    public let connectTimeoutMs: Int

    private let tls: @Sendable () throws -> ControlTLSSetup

    /// - Parameters:
    ///   - tls: builds a **fresh** `ControlTLSSetup` per request (e.g.
    ///     `{ try ControlTLS.setup(for: link, identity: identity) }`).
    public init(
        link: ConnectionLink, route: RemoteRoute, connector: ControlConnector = .platformDefault,
        outerTrust: OuterTrustPolicy = .system, connectTimeoutMs: Int = RemoteExchange.connectTimeoutCapMs,
        tls: @escaping @Sendable () throws -> ControlTLSSetup
    ) {
        self.link = link
        self.route = route
        self.connector = connector
        self.outerTrust = outerTrust
        self.connectTimeoutMs = max(1, min(connectTimeoutMs, 30_000))
        self.tls = tls
    }

    /// `nil` when `link.remote == nil`.
    public convenience init?(
        link: ConnectionLink, client: ControlTLS.ClientIdentity?,
        connector: ControlConnector = .platformDefault, outerTrust: OuterTrustPolicy = .system,
        connectTimeoutMs: Int = RemoteExchange.connectTimeoutCapMs
    ) {
        guard let route = link.remote else {
            return nil
        }
        self.init(
            link: link, route: route, connector: connector, outerTrust: outerTrust, connectTimeoutMs: connectTimeoutMs,
            tls: { try ControlTLS.setup(for: link, client: client) })
    }

    public func send(
        _ request: ControlRequest, timeoutMs: Int,
        onStart: (ControlRequestHandle) -> Void
    ) async throws -> ControlResponse {
        let bytes = try ControlRequestEncoder.encode(request, host: link.endpoint)
        let setup = try tls()
        let progress = SignalingRequestProgress(.rendezvousConnect)
        let exchange = RemoteExchange(
            route: route, setup: setup, requestBytes: bytes,
            maxResponseBytes: request.maxResponseBytes,
            timeoutMs: max(1, timeoutMs), connector: connector, outerTrust: outerTrust,
            connectTimeoutMs: connectTimeoutMs, progress: progress)
        onStart(ControlRequestHandle(progress: progress) { exchange.cancel() })
        return try await withTaskCancellationHandler {
            do {
                return try await exchange.run().get()
            } catch {
                if !exchange.requestWasSent, ConnectionFailure.retryableStatus(error) {
                    throw SignalingRequestNotSent(error)
                }
                throw error
            }
        } onCancel: {
            exchange.cancel()
        }
    }
}
