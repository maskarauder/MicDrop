import Foundation

/// Terminal-evidence failure codes (`A/SessionEvidence.kt:9-38`; Go allow-list
/// `internal/diagnostics/session.go:61`). Raw values are the wire labels, verbatim.
///
/// Note: `.none` is a real case; write `SessionFailure.none` explicitly where an
/// `Optional<SessionFailure>` is in scope.
public enum SessionFailure: String, Sendable, Equatable, CaseIterable {
    case none
    case peerFailed = "peer_failed"
    case mediaRecoveryTimeout = "media_recovery_timeout"
    case statusRecoveryTimeout = "status_recovery_timeout"
    case hostAudioStopped = "host_audio_stopped"
    case microphoneInit = "microphone_init"
    case microphoneStart = "microphone_start"
    case microphoneRuntime = "microphone_runtime"
    case outputInit = "output_init"
    case outputStart = "output_start"
    case outputRuntime = "output_runtime"
    case inputRouteChanged = "input_route_changed"
    case inputUnverified = "input_unverified"
    case leStereoUnavailable = "le_stereo_unavailable"
    case hostMicrophoneGate = "host_microphone_gate"
    case modeNotConfirmed = "mode_not_confirmed"
    case httpRejected = "http_rejected"
    case tlsFailure = "tls_failure"
    case permissionDenied = "permission_denied"
    case networkIO = "network_io"
    case stageTimeout = "stage_timeout"
    case nativeLoad = "native_load"
    case sessionException = "session_exception"

    /// Wire label (`SessionFailure.wire` in Kotlin).
    public var wire: String { rawValue }

    /// `SessionFailure.from(error)` (`A/SessionEvidence.kt:23-37`, column "SessionFailure.from"), first matching rule
    /// over the whole cause chain: LE-stereo route → `le_stereo_unavailable`; route → `input_unverified`; `HTTPFailure`
    /// → `http_rejected`; TLS → `tls_failure`; `PermissionDeniedError` or `ControlIOError(.localNetworkDenied)` →
    /// `permission_denied`; timeout class → `stage_timeout`; other I/O (`SignalingStreamEnded`, `ControlIOError`) →
    /// `network_io`; else `session_exception`. `native_load` is never produced on iOS.
    public static func from(_ error: Error) -> SessionFailure {
        let chain = ConnectionFailure.causes(of: error)
        if chain.contains(where: { cause in
            if let route = cause as? MicrophoneRouteError, case .leStereoUnavailable = route.problem { return true }
            return false
        }) {
            return .leStereoUnavailable
        }
        if chain.contains(where: { $0 is MicrophoneRouteError }) { return .inputUnverified }
        if chain.contains(where: { $0 is HTTPFailure }) { return .httpRejected }
        if chain.contains(where: { $0 is SignalingTLSFailure }) { return .tlsFailure }
        if chain.contains(where: { cause in
            if cause is PermissionDeniedError { return true }
            if let io = cause as? ControlIOError, io.kind == .localNetworkDenied { return true }
            return false
        }) {
            return .permissionDenied
        }
        if ConnectionFailure.isTimeout(error) { return .stageTimeout }
        if chain.contains(where: {
            $0 is SignalingStreamEnded || $0 is ControlIOError || $0 is RecoveryTimeout
                || $0 is SignalingRoutesUnavailable || $0 is SignalingNetworkChanged || $0 is OfferFallbackRequired
        }) {
            return .networkIO
        }
        return .sessionException
    }

    /// Spelling used by 03 (`SessionFailure.classify`); identical to `from(_:)`.
    public static func classify(_ error: Error) -> SessionFailure {
        from(error)
    }
}
