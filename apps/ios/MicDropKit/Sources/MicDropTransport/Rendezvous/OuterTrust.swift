import MicDropCore

/// Trust policy for the **outer** rendezvous TLS. Outer TLS proves only the
/// rendezvous host name; peer authentication is the inner TLS (`docs/REMOTE_ACCESS.md`).
public enum OuterTrustPolicy: Sendable, Equatable {
    /// Production: the system trust store and policy (normal CA + host-name verification), the only
    /// value reachable from app code.
    case system
    /// Tests only: trust exactly these DER roots (anchors only), mirroring Android's injectable
    /// `outerFactory` (`RemoteTunnel.kt:26`, `RemoteHttp.kt:15`). NIOTS converts them to
    /// `SecCertificate` anchors; the NIOPosix path to `NIOSSLTrustRoots.certificates`.
    case anchors(certificatesDER: [[UInt8]])
}

/// The outer trust evaluator's verdict, recorded from the TLS verify block (Network.framework
/// queue) or the NIOSSL outer handshake, read when the connect fails.
/// First recorded problem wins. Thread-safe.
public final class OuterTrustVerdictBox: @unchecked Sendable {
    private let stored = Locked<SignalingTLSFailure.Problem?>(nil)

    public init() {}

    /// Records `problem` unless one was already recorded.
    public func record(_ problem: SignalingTLSFailure.Problem) {
        stored.withLock { value in
            if value == nil {
                value = problem
            }
        }
    }

    /// The first recorded problem (`.certificateTime` or `.identity`), if any.
    public var problem: SignalingTLSFailure.Problem? {
        stored.value
    }
}

/// Outer `NWError.tls(OSStatus)` → problem table (values from `Security/SecureTransport.h`). Pure (takes the raw
/// `Int32` status) so Linux tests cover it.
public enum OuterTLSStatus {
    /// `errSSLClosedGraceful`, `errSSLClosedAbort`, `errSSLClosedNoNotify`.
    public static let closureStatuses: Set<Int32> = [-9805, -9806, -9816]

    static let certificateTimeStatuses: Set<Int32> = [-9814, -9815, -9828]
    static let identityStatuses: Set<Int32> = [
        -9807, -9808, -9812, -9813, -9843, -9825, -9826, -9827, -9829, -9831,
    ]
    static let protocolStatuses: Set<Int32> = [
        -9800, -9819, -9820, -9821, -9822, -9833, -9845, -9846, -9847, -9849,
    ]
    /// Negotiation, fatal alert, cipher suite and the remaining peer handshake alerts.
    static let handshakeStatuses: Set<Int32> = [
        -9801, -9802, -9818, -9823, -9824, -9830, -9832, -9834, -9835, -9836, -9837, -9838, -9839, -9840,
    ]

    /// - Parameters:
    ///   - status: the `OSStatus` of `NWError.tls`.
    ///   - duringHandshake: `true` before the outer TLS completed (connect future failure).
    /// - Returns: the problem, or `nil` for an EOF-like closure after the handshake
    /// (`errSSLClosedGraceful`/`Abort`/`NoNotify` → no `outer` error; the latch resolves to rendezvous-closed /
    /// stream-ended). During the handshake `ClosedAbort`/`NoNotify` are `.handshake` (Android: EOF during the outer
    /// handshake is a fatal `SSLHandshakeException`).
    public static func problem(_ status: Int32, duringHandshake: Bool) -> SignalingTLSFailure.Problem? {
        if closureStatuses.contains(status) {
            guard duringHandshake else {
                return nil
            }
            return status == -9805 ? .other : .handshake
        }
        if certificateTimeStatuses.contains(status) {
            return .certificateTime
        }
        if identityStatuses.contains(status) {
            return .identity
        }
        if protocolStatuses.contains(status) {
            return .protocol
        }
        if handshakeStatuses.contains(status) {
            return .handshake
        }
        return .other
    }
}
