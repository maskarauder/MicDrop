import Foundation

/// Pairing progress/result texts and the pairing retry classification (Android `SavedConnections.kt:188-233`,
/// `PairingClient.kt:113-118`; and).
public enum PairingFailureText {
    /// Start of enrollment (`SavedConnections.kt:188`).
    public static let connecting = "Connecting securely to Windows for pairing…"
    /// While a cancel is in progress (`SavedConnections.kt:233`).
    public static let cancelling = "Cancelling pairing…"
    /// Cancelled before the record was saved (`SavedConnections.kt:193`).
    public static let cancelled =
        "Pairing cancelled. If Windows already approved this phone, remove it in the Windows app under Phones → Remove selected phone."
    /// HTTP 409/410, including window exhaustion (`SavedConnections.kt:211-212`).
    public static let windowEnded =
        "Pairing window ended, was rejected, or another phone is pending. In the Windows app, open Phones → Pair a phone for a new invitation."
    /// Appended to every other failure (`SavedConnections.kt:213-214`).
    public static let notSavedSuffix =
        "Pairing was not saved. Windows may already have approved the phone; retry the same invitation while it is valid, or select Pair a phone in Windows for a new one."
    /// UI pre-flight: expired invitation (`MainActivity.kt:956-972`).
    public static let expiredInvitation =
        "That pairing invitation expired. In the Windows app, open Phones → Pair a phone for a new one."
    /// UI pre-flight: unparsable invitation (`MainActivity.kt:956-972`).
    public static let invalidInvitation = "Paste the pairing invitation from the paired Windows host."
    /// Brief notice accompanying an expired link or invitation (`strings.xml`).
    public static let expiredNotice = "This connection link has expired."

    /// Final message for a failed or cancelled enrollment (`SavedConnections.kt:205-215`):
    /// - cancellation (`CancellationError`, `SessionStopped`) → `cancelled`;
    /// - `HTTPFailure` 409 or 410 → `windowEnded`;
    /// - `ControlIOError` `.localNetworkDenied` (window ended with it last) →
    /// `ConnectionFailure.describe(stage: .pairing, …)` alone, i.e. `Connecting securely to Windows failed
    /// [LOCAL_NETWORK].\nAllow Local Network access …`;
    /// - otherwise `ConnectionFailure.describe(stage: .pairing, …) + "\n" + notSavedSuffix`.
    /// The Android-only `PAIRING_KEY_UPDATE` branch has no iOS producer.
    public static func describe(_ error: Error) -> String {
        if isCancellation(error) {
            return cancelled
        }
        if let http = error as? HTTPFailure, http.status == 409 || http.status == 410 {
            return windowEnded
        }
        let base = ConnectionFailure.describe(stage: .pairing, error: error, action: "Reconnect")
        if isLocalNetworkDenied(error) {
            return base
        }
        return base + "\n" + notSavedSuffix
    }

    /// Pairing retry rule (`PairingClient.kt:113-118`), delegated to the single classification table
    /// `ConnectionFailure.pairingRetryable`: `HTTPFailure` iff 429 or 503; `SignalingTLSFailure` never (fatal);
    /// `SignalingStreamEnded` and every `ControlIOError` (unreachable, timed out, Local Network denied, rendezvous,
    /// protocol violation, …) yes; everything else (reply/JSON errors, `ControlResponseError`, `PairingClient.Failure`,
    /// link errors) no. Callers check cancellation first.
    public static func isRetryable(_ error: Error) -> Bool {
        ConnectionFailure.pairingRetryable(error)
    }

    /// `CancellationError` or `SessionStopped` anywhere in the cause chain (last row).
    public static func isCancellation(_ error: Error) -> Bool {
        ConnectionFailure.isCancellation(error)
    }

    /// A `ControlIOError` with kind `.localNetworkDenied` in the cause chain (iOS only).
    public static func isLocalNetworkDenied(_ error: Error) -> Bool {
        ConnectionFailure.causes(of: error).contains { cause in
            guard let io = cause as? ControlIOError else {
                return false
            }
            if case .localNetworkDenied = io.kind {
                return true
            }
            return false
        }
    }
}
