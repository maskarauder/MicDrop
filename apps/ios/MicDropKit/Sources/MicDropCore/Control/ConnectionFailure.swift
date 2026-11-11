import Foundation

/// The single error-classification table of the iOS port (`A/ConnectionFailure.kt:39-91`).
///
/// Classification inspects error *types* only and never derives text from an error. Every
/// function walks the cause chain (`error`, then `UnderlyingErrorProviding.underlying`) up
/// to `maxCauseDepth` levels.
public enum ConnectionFailure {
    public static let maxCauseDepth = 8

    /// HTTP statuses that keep a status exchange inside the recovery window (`:44`).
    public static let retryableHTTPStatuses: Set<Int> = [429, 500, 502, 503, 504]

    /// HTTP statuses a pairing poll retries (`A/PairingClient.kt:117`).
    public static let pairingRetryableHTTPStatuses: Set<Int> = [429, 503]

    // MARK: Detail texts

    public static let keyUpdateDetail =
        "This phone identity was created by an older build without TLS signing support. Tap Forget saved connection, then paste a new Windows pairing invitation and tap Connect."
    public static let certificateTimeDetail =
        "A secure connection certificate is outside its validity period. Check device clocks and the server certificate, then try connecting again."
    public static let tlsIdentityDetail =
        "The secure connection identity could not be verified. Check the saved connection and server certificate before trying again."
    public static let tlsConnectionDetail =
        "The secure signaling connection failed. Copy the last stream report for details, then try reconnecting."
    public static let streamEndedDetail =
        "The secure signaling connection was interrupted. Check network access and try reconnecting."
    /// iOS-only row inserted before `HOST_UNREACHABLE`.
    public static let localNetworkDetail =
        "Allow Local Network access for MicDrop in Settings > Privacy & Security > Local Network, then try again."
    public static let hostUnreachableDetail =
        "Cannot reach Windows. Check the displayed IP, the running host, Wi-Fi, and the Windows private-network firewall rule."
    public static let pairingTimeoutDetail =
        "Windows did not respond in time. Check its IP, Wi-Fi/client isolation, and firewall, then try connecting again."
    public static let stageTimeoutDetail =
        "This connection stage timed out. Check the Windows console and try connecting again."
    /// Unreachable on iOS (WebRTC is linked); kept for completeness.
    public static let nativeLoadDetail = "The native audio library could not load. Reinstall the latest MicDrop build."
    public static let networkIODetail =
        "The network connection stopped. Check the Windows host and network access, then try connecting again."
    public static let setupFailedDetail =
        "Audio connection setup failed. Report this stage and code, and the Windows console result, without the invitation."

    /// HTTP detail texts (`:68-74`), verbatim; 400 is main's platform-neutral text (`:72`), which retires the
    /// adaptation for session, pairing and registration alike.
    public static func httpDetail(status: Int, action: String) -> String {
        switch status {
        case 401:
            return "The connection link was rejected. Paste a new invitation from the running Windows host."
        case 403:
            return
                "This phone is not approved on Windows, or its pairing was revoked. In the Windows app, open Phones → Pair a phone and pair again."
        case 409, 410:
            return
                "The session or link has ended. Use \(action) if the link is still valid; otherwise restart Windows and paste its new link."
        case 423:
            return
                "Windows already has an active session or is finishing one. Stop it or wait for its timeout, then tap \(action). It can take up to 45 seconds after interrupted setup."
        case 400:
            return
                "Windows rejected a connection request. Copy the session report and check that both apps are up to date."
        case 429, 503:
            return "Windows is busy. Wait briefly, then try connecting again."
        default:
            return "Windows could not complete this request. Check the Windows console, then try \(action)."
        }
    }

    // MARK: Cause chain

    /// `error` followed by its `underlying` causes, at most `maxCauseDepth` entries.
    public static func causes(of error: Error) -> [Error] {
        var chain: [Error] = [error]
        var current = error
        while chain.count < maxCauseDepth, let next = (current as? UnderlyingErrorProviding)?.underlying {
            chain.append(next)
            current = next
        }
        return chain
    }

    /// The first `HTTPFailure` status in the chain (terminal evidence `http_status`).
    public static func httpStatus(in error: Error) -> Int? {
        causes(of: error).lazy.compactMap { $0 as? HTTPFailure }.first?.status
    }

    /// Any TLS failure in the chain (Android `SSLException`/`CertificateException`).
    public static func isTLSFailure(_ error: Error) -> Bool {
        causes(of: error).contains { $0 is SignalingTLSFailure }
    }

    /// Android `IOException` family: `HTTPFailure`, `SignalingTLSFailure` (an `SSLException`),
    /// `SignalingStreamEnded`, `ControlIOError`, `RecoveryTimeout` (05).
    public static func isIOClass(_ error: Error) -> Bool {
        causes(of: error).contains(where: isIOClassCause)
    }

    /// `SessionStopped` or Swift `CancellationError` anywhere in the chain.
    public static func isCancellation(_ error: Error) -> Bool {
        causes(of: error).contains { $0 is SessionStopped || $0 is CancellationError }
    }

    /// A timeout-class cause: `ControlIOError(.timedOut)`, `RecoveryTimeout`, `StageTimeoutError`.
    public static func isTimeout(_ error: Error) -> Bool {
        causes(of: error).contains(where: isTimeoutCause)
    }

    // MARK: Retry

    /// `retryableStatus` (`:40-46`): TLS anywhere → false; else an `HTTPFailure` decides
    /// (429/500/502/503/504); else any I/O-class cause → true. `StageTimeoutError`,
    /// `PermissionDeniedError`, `ControlResponseError`, cancellation and everything else → false.
    public static func retryableStatus(_ error: Error, establishedSession: Bool = false) -> Bool {
        let chain = causes(of: error)
        if chain.contains(where: { $0 is OfferFallbackRequired || $0 is SessionStopped || $0 is CancellationError }) {
            return false
        }
        if chain.contains(where: { $0 is SignalingTLSFailure }) { return false }
        if let http = chain.lazy.compactMap({ $0 as? HTTPFailure }).first {
            return retryableHTTPStatuses.contains(http.status)
        }
        if chain.contains(where: { $0 is SignalingRoutesUnavailable }) { return establishedSession }
        return chain.contains(where: isIOClassCause)
    }

    /// Pairing poll retry rule (`A/PairingClient.kt:113-118`): an I/O-class error that is not TLS and not an
    /// `HTTPFailure` outside {429, 503}. `ControlIOError(.localNetworkDenied)` is retried.
    public static func pairingRetryable(_ error: Error) -> Bool {
        let chain = causes(of: error)
        guard chain.contains(where: isIOClassCause) else { return false }
        if chain.contains(where: { $0 is SignalingTLSFailure }) { return false }
        if let http = chain.lazy.compactMap({ $0 as? HTTPFailure }).first {
            return pairingRetryableHTTPStatuses.contains(http.status)
        }
        return true
    }

    // MARK: describe

    /// `"<label> failed [<CODE>].\n<detail>"` (`:53-98`). Label is `Connection control` when the chain holds
    /// `SignalingRoutesUnavailable`, else `Secure signaling` when it holds a `SignalingTLSFailure` or
    /// `SignalingStreamEnded`, else `stage.label`. `action` is `StreamMode.reconnectAction` (`Reconnect` / `Connect`).
    public static func describe(stage: ConnectionStage, error: Error, action: String = "Reconnect") -> String {
        let chain = causes(of: error)
        let row = classify(stage: stage, chain: chain, action: action)
        let label: String
        if chain.contains(where: { $0 is SignalingRoutesUnavailable }) {
            label = "Connection control"
        } else {
            label = usesSecureSignalingLabel(chain) ? "Secure signaling" : stage.label
        }
        return "\(label) failed [\(row.code)].\n\(row.detail)"
    }

    /// Unlabeled spelling used by 10 (`ConnectionFailure.describe(.pairing, error)`).
    public static func describe(_ stage: ConnectionStage, _ error: Error, action: String = "Reconnect") -> String {
        describe(stage: stage, error: error, action: action)
    }

    /// The `<CODE>` that `describe` would print (e.g. `HTTP_403`, `LOCAL_NETWORK`).
    public static func code(stage: ConnectionStage, error: Error) -> String {
        classify(stage: stage, chain: causes(of: error), action: "Reconnect").code
    }

    /// Whether `describe` uses the `Secure signaling` label (`:89`).
    public static func usesSecureSignalingLabel(_ error: Error) -> Bool {
        usesSecureSignalingLabel(causes(of: error))
    }

    // MARK: Private

    private static func usesSecureSignalingLabel(_ chain: [Error]) -> Bool {
        chain.contains { $0 is SignalingTLSFailure || $0 is SignalingStreamEnded }
    }

    private static func isIOClassCause(_ cause: Error) -> Bool {
        cause is HTTPFailure || cause is SignalingTLSFailure || cause is SignalingStreamEnded
            || cause is ControlIOError || cause is RecoveryTimeout || cause is SignalingNetworkChanged
            || cause is SignalingRoutesUnavailable || cause is OfferFallbackRequired
    }

    private static func isTimeoutCause(_ cause: Error) -> Bool {
        if let io = cause as? ControlIOError, io.kind == .timedOut { return true }
        return cause is RecoveryTimeout || cause is StageTimeoutError
    }

    private static func controlIOKind(_ chain: [Error], _ kind: ControlIOError.Kind) -> Bool {
        chain.contains { ($0 as? ControlIOError)?.kind == kind }
    }

    /// First matching row of the `describe` table, in Android order with `LOCAL_NETWORK` inserted before
    /// `HOST_UNREACHABLE`.
    private static func classify(stage: ConnectionStage, chain: [Error], action: String) -> (
        code: String, detail: String
    ) {
        if chain.contains(where: { $0 is SignalingRoutesUnavailable }) {
            return (
                "SIGNALING_UNAVAILABLE",
                "The control request could not complete through rendezvous or direct LAN. Copy the session report, then tap \(action)."
            )
        }
        if let route = chain.lazy.compactMap({ $0 as? MicrophoneRouteError }).first {
            return ("MICROPHONE_ROUTE", route.problem.detail)
        }
        if stage == .inputRoute {
            return ("MICROPHONE_ROUTE", MicrophoneRouteProblem.unverified.detail)
        }
        let tls = chain.lazy.compactMap { $0 as? SignalingTLSFailure }.first
        if tls?.problem == .keyUpdate {
            return ("PAIRING_KEY_UPDATE", keyUpdateDetail)
        }
        if let http = chain.lazy.compactMap({ $0 as? HTTPFailure }).first {
            return ("HTTP_\(http.status)", httpDetail(status: http.status, action: action))
        }
        if tls?.problem == .certificateTime {
            return ("CERTIFICATE_TIME", certificateTimeDetail)
        }
        if tls?.problem == .identity {
            return ("TLS_IDENTITY", tlsIdentityDetail)
        }
        if tls != nil {
            return ("TLS_CONNECTION", tlsConnectionDetail)
        }
        if chain.contains(where: { $0 is SignalingStreamEnded }) {
            return ("NETWORK_IO", streamEndedDetail)
        }
        if controlIOKind(chain, .localNetworkDenied) {
            return ("LOCAL_NETWORK", localNetworkDetail)
        }
        if controlIOKind(chain, .unreachable) {
            return ("HOST_UNREACHABLE", hostUnreachableDetail)
        }
        if chain.contains(where: isTimeoutCause) {
            return ("TIMEOUT", stage == .pairing ? pairingTimeoutDetail : stageTimeoutDetail)
        }
        // NATIVE_LOAD: no Swift error type produces it on iOS.
        if chain.contains(where: { $0 is ControlIOError }) {
            return ("NETWORK_IO", networkIODetail)
        }
        return ("SETUP_FAILED", setupFailedDetail)
    }
}
