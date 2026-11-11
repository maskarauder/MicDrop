import Foundation

// Concrete thrown types of the control plane. Every type is message-free: no URL, token, SDP, address or
// server-controlled text is ever stored in an error, so neither the UI nor a report can leak one
// (`A/ConnectionFailure.kt:49-50`, `A/SignalingFailure.kt:7-8`). User text comes only from
// `ConnectionFailure.describe`.

/// An error that wraps a cause. Classification walks `error`, then `underlying`, up to
/// `ConnectionFailure.maxCauseDepth` (8) levels (Kotlin `generateSequence { it.cause }.take(8)`).
public protocol UnderlyingErrorProviding: Error {
    var underlying: Error? { get }
}

/// A non-200 HTTP status from Windows (or from `/v1/ice`). The response body is never read or shown (rule 8,
/// `A/ConnectionFailure.kt:26`).
public struct HTTPFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }

    public init(_ status: Int) {
        self.status = status
    }

    public var description: String { "HTTPFailure(\(status))" }
}

/// Fixed-label TLS failure (`A/SignalingFailure.kt:9-30`). Never retryable.
public struct SignalingTLSFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Wire/report labels are the raw values, verbatim (`layer.name.lowercase()`).
    public enum Layer: String, Sendable, Equatable, CaseIterable {
        case rendezvous
        case windows
        case iceService = "ice_service"
    }

    /// Wire/report labels are the raw values, verbatim (`problem.name.lowercase()`).
    public enum Problem: String, Sendable, Equatable, CaseIterable {
        case certificateTime = "certificate_time"
        case identity
        /// Android-only key-policy upgrade; never produced on iOS (row 3).
        case keyUpdate = "key_update"
        case handshake
        case `protocol`
        case other
    }

    public let layer: Layer
    public let problem: Problem

    public init(layer: Layer, problem: Problem) {
        self.layer = layer
        self.problem = problem
    }

    public init(_ layer: Layer, _ problem: Problem) {
        self.layer = layer
        self.problem = problem
    }

    /// `Secure signaling failure: layer=<layer> · category=<problem>` (`A/SignalingFailure.kt:18`).
    public var text: String {
        "Secure signaling failure: layer=\(layer.rawValue) · category=\(problem.rawValue)"
    }

    public var description: String { text }

    /// The first `SignalingTLSFailure` in the cause chain, if any. Kotlin `wrap` returns an
    /// existing wrapper unchanged, so the first (innermost-recorded) layer wins
    /// (`A/SignalingFailure.kt:14`).
    public static func existing(in error: Error) -> SignalingTLSFailure? {
        ConnectionFailure.causes(of: error).lazy.compactMap { $0 as? SignalingTLSFailure }.first
    }

    /// Kotlin `SignalingTlsFailure.wrap(error, layer)` (`A/SignalingFailure.kt:20-32`): an existing wrapper anywhere in
    /// the first eight causes is returned unchanged (the first layer wins, so an outer `rendezvous` verdict is never
    /// relabelled `windows`); otherwise a new message-free failure with `layer` and the `problem` the caller classified
    /// (Swift has no Java exception hierarchy to derive it from). No cause is retained.
    public static func wrap(_ error: Error, layer: Layer, problem: Problem) -> SignalingTLSFailure {
        existing(in: error) ?? SignalingTLSFailure(layer: layer, problem: problem)
    }
}

/// A positively observed EOF of the underlying byte stream while TLS still expected data
/// (`A/SignalingFailure.kt:36-38`). Retryable.
public struct SignalingStreamEnded: Error, Sendable, Equatable, CustomStringConvertible {
    public static let text = "Secure signaling failure: layer=windows · category=transport_eof"

    public init() {}

    public var description: String { "SignalingStreamEnded" }
}

/// The session was stopped (Kotlin `InterruptedException("Session stopped")`, `A/SessionWorkerWait.kt:9`). Thrown by
/// `SessionWorkerWait.checkpoint()` and by cancelled control requests. Never reported as a failure.
public struct SessionStopped: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "SessionStopped" }
}

/// A bounded worker wait (SDP completion, stats, gathering) expired. Android `java.util.concurrent.TimeoutException`:
/// `TIMEOUT` / `stage_timeout`, **not** retryable.
public struct StageTimeoutError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Fixed internal label for debugging only (never shown, never serialized).
    public let operation: String

    public init(_ operation: String = "wait") {
        self.operation = operation
    }

    public var description: String { "StageTimeoutError(\(operation))" }
}

/// A required runtime permission is missing at worker start (Android `SecurityException`): `describe` → `SETUP_FAILED`,
/// wire → `permission_denied`, not retryable.
public struct PermissionDeniedError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Permission: String, Sendable, Equatable {
        case microphone
    }

    public let permission: Permission

    public init(_ permission: Permission = .microphone) {
        self.permission = permission
    }

    public var description: String { "PermissionDeniedError(\(permission.rawValue))" }
}

/// The Android `IOException` family of the control transport. Every kind is retryable I/O for
/// `ConnectionFailure.retryableStatus`; `describe` maps `.localNetworkDenied` → `LOCAL_NETWORK`, `.unreachable` →
/// `HOST_UNREACHABLE`, `.timedOut` → `TIMEOUT`, everything else → `NETWORK_IO`.
public struct ControlIOError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Remote ICE configuration refusals that are I/O-class on Android (`A/RemoteIce.kt:22-26,36,67`).
    public enum ICEReason: String, Sendable, Equatable {
        /// "Remote ICE configuration temporarily unavailable" (30 s throttle).
        case throttled
        /// "ICE configuration too large" (> 16384 bytes).
        case tooLarge = "too_large"
        /// "Forced relay requires TURN on the server".
        case forcedRelayRequiresTURN = "forced_relay_requires_turn"
    }

    public enum Kind: Sendable, Equatable {
        /// "Rendezvous connection failed" (DNS/TCP/outer connect failure before TLS).
        case rendezvousFailed
        /// "Rendezvous stream closed" (refused upgrade, no host within 25 s, close before ready).
        case rendezvousClosed
        /// "Invalid rendezvous stream" (frame/ready violations).
        case invalidRendezvousStream
        /// "Rendezvous transport closed".
        case transportClosed
        /// Deadline / connect timeout / idle read timeout (Android `SocketTimeoutException`).
        case timedOut
        /// LAN connect refused / no route to host.
        case unreachable
        /// iOS only: `NWPath.unsatisfiedReason == .localNetworkDenied` or DNS policy denied.
        case localNetworkDenied
        /// "LAN network unavailable": only cellular exists for a LAN host.
        case lanNetworkUnavailable
        /// Strict HTTP framing violation (steps 1-3, 5-7) or a body over `ControlRequest.maxResponseBytes`. The text is
        /// a fixed internal label.
        case protocolViolation(String)
        /// URLSession transport error for `/v1/ice`.
        case iceServiceUnavailable
        /// Throttle / too large / forced relay without TURN.
        case iceUnavailable(ICEReason)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public init(kind: Kind) {
        self.kind = kind
    }

    public var description: String { "ControlIOError(\(kind))" }
}

/// A 200 response whose body is not acceptable. Never retryable; `SETUP_FAILED`, `session_exception`.
public struct ControlResponseError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        /// Body is not UTF-8 JSON with a top-level object (org.json `JSONException`).
        case invalidJSON = "invalid_json"
        /// `/v1/ice` JSON violates the rules of steps 9-12.
        case invalidICE = "invalid_ice"
        /// A required field is missing/mistyped or a `check`/`require` on the reply failed.
        case invalidReply = "invalid_reply"
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public init(kind: Kind) {
        self.kind = kind
    }

    public var description: String { "ControlResponseError(\(kind.rawValue))" }
}

/// `signalingFailureText` (`A/SignalingFailure.kt:40-45`): the TLS failure's fixed text, or the
/// transport-EOF text, or nil. Appended to diagnostics as `lastSignalingFailure`.
public func signalingFailureText(_ error: Error) -> String? {
    let chain = ConnectionFailure.causes(of: error)
    if let tls = chain.lazy.compactMap({ $0 as? SignalingTLSFailure }).first {
        return tls.text
    }
    if chain.contains(where: { $0 is SignalingStreamEnded }) {
        return SignalingStreamEnded.text
    }
    return nil
}
