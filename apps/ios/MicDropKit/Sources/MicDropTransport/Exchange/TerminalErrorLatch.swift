import MicDropCore

/// Terminal-error precedence for one exchange (MUST).
///
/// Event-loop confined (no locking): every record happens on the exchange's channel loop.
/// Each slot keeps its first value.
///
/// `resolve()` order:
/// 1. `local` (cancel → `SessionStopped()`; deadline / LAN idle → `ControlIOError(.timedOut)`; the LAN
///    deadline records it only when no other error was recorded first) —
///    Android checks the checkpoint first (`RemoteTunnel.kt:98`, `RemoteHttp.kt:19-22`);
/// 2. `outer` — a published outer failure (rendezvous TLS or generic) beats EOF and any inner
///    consequence (`RemoteTunnel.kt:99-104,113-114,127`; `RemoteTransportPlatformTest.kt:174-182`).
///    On LAN this slot holds TCP-level transport errors;
/// 3. `inner` — `SignalingTLSFailure(.windows, …)` or `ControlIOError(.protocolViolation)`;
/// 4. tunnelled and `!readySeen` → `ControlIOError(.rendezvousClosed)` (`RemoteTunnel.kt:103`);
/// 5. else `SignalingStreamEnded()` (the stream ended under inner TLS, also mid-handshake;
///    `SignalingFailureTest.kt:10-16`; LAN).
public final class TerminalErrorLatch {
    /// Local terminal reasons.
    public enum Local: Sendable, Equatable {
        /// `ControlRequestHandle.cancel()` / Task cancellation → `SessionStopped`.
        case cancelled
        /// Remote or LAN absolute deadline, or LAN read-inactivity timeout → `ControlIOError(.timedOut)`.
        case timedOut
    }

    /// `true` for the remote tunnel (enables rule 4), `false` for LAN.
    public let tunnelled: Bool
    public private(set) var local: Local?
    public private(set) var outer: Error?
    public private(set) var inner: Error?
    /// Set by `NIOSSLError.uncleanShutdown` / EOF during the inner handshake.
    public var uncleanEOF = false
    /// Set when the rendezvous ready frame was accepted (always `true` on LAN).
    public var readySeen: Bool

    public init(tunnelled: Bool) {
        self.tunnelled = tunnelled
        self.readySeen = !tunnelled
    }

    public func recordLocal(_ reason: Local) {
        if local == nil {
            local = reason
        }
    }

    public func recordOuter(_ error: Error) {
        if outer == nil {
            outer = error
        }
    }

    public func recordInner(_ error: Error) {
        if inner == nil {
            inner = error
        }
    }

    /// `true` if any of `local`, `outer`, `inner` is set.
    public var hasRecordedError: Bool {
        local != nil || outer != nil || inner != nil
    }

    /// The single terminal error by precedence (see type documentation).
    public func resolve() -> Error {
        if let local {
            switch local {
            case .cancelled:
                return SessionStopped()
            case .timedOut:
                return ControlIOError(.timedOut)
            }
        }
        if let outer {
            return outer
        }
        if let inner {
            return inner
        }
        if tunnelled && !readySeen {
            return ControlIOError(.rendezvousClosed)
        }
        return SignalingStreamEnded()
    }
}
