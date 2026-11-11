import Foundation

/// The raw body of an HTTP 200 control reply. Callers parse it themselves: `PairingClient.decodeReply` needs the exact
/// bytes for its strict JSON; session callers use `json()` / `ControlTransport.sendJSON`.
public struct ControlResponse: Sendable, Equatable {
    public let body: [UInt8]

    public init(body: [UInt8]) {
        self.body = body
    }

    /// Lenient org.json-style view; not a JSON object → `ControlResponseError(.invalidJSON)`.
    public func json() throws -> ControlJSON {
        try ControlJSON(bytes: body)
    }
}

/// Non-blocking cancellation of one in-flight request (closes its NIO channel / tunnel /
/// URLSession task). Idempotent; the action runs at most once, on the calling thread, and
/// must not block (Android cancels on a helper thread, `A/RemoteHttp.kt:59-62`).
public final class ControlRequestHandle: @unchecked Sendable {
    private let action: Locked<(@Sendable () -> Void)?>
    /// Transport stage evidence for the failure history; nil when the transport reports none.
    public let progress: SignalingRequestProgress?

    public init(_ cancel: @escaping @Sendable () -> Void) {
        action = Locked(cancel)
        progress = nil
    }

    public init(progress: SignalingRequestProgress, _ cancel: @escaping @Sendable () -> Void) {
        action = Locked(cancel)
        self.progress = progress
    }

    public func cancel() {
        let pending = action.exchange(nil)
        pending?()
    }

    public var isCancelled: Bool {
        action.value == nil
    }
}

/// One control request on a **fresh** connection (LAN TCP+TLS, or remote WSS tunnel + inner TLS). Never pools,
/// pipelines or retries — a lost `/offer` response is never resent. Implemented by `LanControlTransport` /
/// `RemoteControlTransport` (MicDropTransport).
///
/// Contract:
/// - validates `request` preconditions before any I/O;
/// - calls `onStart` exactly once, synchronously, as soon as a cancel handle exists (before
///   connecting), so Stop / network handoff can abort it;
/// - returns the body of an HTTP 200 only; any other status → `HTTPFailure(status)` (body
///   never read); a body over `request.maxResponseBytes` → `ControlIOError(.protocolViolation)`;
/// - throws the signaling error types: `HTTPFailure`, `SignalingTLSFailure`, `SignalingStreamEnded`,
///   `ControlIOError`, `ControlResponseError`, `SessionStopped` (handle cancelled or Task
///   cancelled). Raw NIO / Network.framework errors never escape;
/// - `timeoutMs` is the absolute deadline (remote) or the per-read idle timeout with connect
/// `min(timeoutMs, 8000)` (LAN); LAN also ends the whole request at the absolute `min(timeoutMs, connect cap) +
/// timeoutMs`. Callers pass `ControlRequest.effectiveTimeoutMs`.
public protocol ControlTransport: Sendable {
    func send(
        _ request: ControlRequest, timeoutMs: Int,
        onStart: (ControlRequestHandle) -> Void
    ) async throws -> ControlResponse
}

/// Handshake-only reachability of the pinned host. Negative trust/reachability returns false;
/// user cancellation throws. Never sends an invitation or session token.
public protocol LocalHostProbing: Sendable {
    func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool
}

extension ControlTransport {
    /// `send` without a cancel-handle observer.
    public func send(_ request: ControlRequest, timeoutMs: Int) async throws -> ControlResponse {
        try await send(request, timeoutMs: timeoutMs, onStart: { _ in })
    }

    /// `send` + `ControlJSON(bytes:)`; a body that is not a JSON object → `ControlResponseError(.invalidJSON)`
    /// (non-retryable).
    public func sendJSON(
        _ request: ControlRequest, timeoutMs: Int,
        onStart: (ControlRequestHandle) -> Void = { _ in }
    ) async throws -> ControlJSON {
        let response = try await send(request, timeoutMs: timeoutMs, onStart: onStart)
        return try response.json()
    }
}
