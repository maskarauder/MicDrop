// Saved-connection view model (`SavedConnections.kt:19-22,55-65`).
//
// Portability note: pure Foundation + MicDropCore. `ControlsInput` (MicDropCore) holds `saved: SavedConnectionView`; if
// that type must see this one, move this file verbatim into `MicDropKit/Sources/MicDropCore/` (it imports nothing
// Apple-only).

import Foundation
import MicDropCore

/// Snapshot published by `SavedConnectionStore`. Defaults equal Android's data-class defaults.
public struct SavedConnectionView: Equatable, Sendable {
    /// Status text for the Connection section (multi-line; may contain the pairing request ID).
    public var message: String
    /// A usable, unexpired saved link exists (enables "Reconnect").
    public var available: Bool
    /// Something exists to Forget (saved link and/or identity).
    public var present: Bool
    /// Keychain IO in progress; Connect/Reconnect/Forget disabled; `connection()` returns nil.
    public var working: Bool
    /// An enrollment is running (shows Cancel pairing).
    public var pairing: Bool
    /// The saved link is v3 (shows Change Windows address).
    public var paired: Bool
    /// Unreadable state; pairing refuses until Forget.
    public var needsForget: Bool
    /// Operation id of a failed, non-cancelled pairing (0 = none). A new non-zero value triggers the failure toast.
    public var pairingFailureID: Int64
    /// Operation id of a saved, non-cancelled pairing (0 = none); consumed by `PairingConnectIntent.take(successID:…)`.
    public var pairingSuccessID: Int64

    public init(
        message: String = Messages.loading, available: Bool = false, present: Bool = false,
        working: Bool = true, pairing: Bool = false, paired: Bool = false,
        needsForget: Bool = false, pairingFailureID: Int64 = 0, pairingSuccessID: Int64 = 0
    ) {
        self.message = message
        self.available = available
        self.present = present
        self.working = working
        self.pairing = pairing
        self.paired = paired
        self.needsForget = needsForget
        self.pairingFailureID = pairingFailureID
        self.pairingSuccessID = pairingSuccessID
    }

    /// Verbatim store messages (`SavedConnections.kt`).
    public enum Messages {
        public static let loading = "Loading saved connection…"
        public static let noSavedConnection = "No saved connection. Paste a Windows link."
        public static let savedUnreadable = "Saved connection could not be read. Tap Forget and connect again."
        public static let savedOrIdentityUnreadable =
            "Saved connection or phone identity could not be read. Tap Forget before pairing again."
        public static let saveNotConfirmed =
            "Playback connected, but saving could not be confirmed. Reconnect still uses the previous entry in this app session."
        public static let forgetting = "Forgetting saved connection…"
        public static let forgotten =
            "Saved connection and phone identity forgotten. Windows may still list the old phone; remove it in the Windows app under Phones → Remove selected phone."
        public static let forgetNotConfirmed = "Could not confirm removal. Tap Forget again."
        public static let pairingRefusedUnreadable =
            "The saved connection or identity is unreadable. Tap Forget before pairing again."
        // The three pairing texts are defined once, in MicDropCore's `PairingFailureText`.
        public static let pairingStarted = PairingFailureText.connecting
        public static let pairingCancelling = PairingFailureText.cancelling
        public static let pairingCancelled = PairingFailureText.cancelled
        static let pairedSuffix = "\nSaved for this phone. Connect uses the audio and microphone options below."
        static let linkExpired = "Link expired. Paste a new Windows link."
    }

    /// `savedView(text)` (`SavedConnections.kt:55-65`).
    ///
    /// - v3: `Paired Windows: <host>:<port>` or `Paired Windows: remote via <URL host>`, then the
    ///   paired suffix; `available = present = paired = true`, `working = false`.
    /// - v2: `Saved Windows: <host>:<port>\n` + expired text or
    ///   `Link expires <date>. Connect uses the audio options below.`; `available = !expired`,
    ///   `present = true`, `working = false`.
    ///
    /// `formatExpiry` renders Unix seconds as short date + short time (`expiryText(_:)`).
    public static func saved(
        _ link: ConnectionLink, now: Int64,
        formatExpiry: (Int64) -> String = SavedConnectionView.expiryText
    ) -> SavedConnectionView {
        let address = "\(link.endpoint.host.description):\(link.endpoint.port)"
        if link.version.rawValue == 3 {
            let target = link.remote.map { "remote via \($0.displayHost)" } ?? address
            return SavedConnectionView(
                message: "Paired Windows: \(target)" + Messages.pairedSuffix,
                available: true, present: true, working: false, paired: true)
        }
        let expired = link.isExpired(now: now)
        let detail =
            expired
            ? Messages.linkExpired
            : "Link expires \(formatExpiry(link.expiresAt)). Connect uses the audio options below."
        return SavedConnectionView(
            message: "Saved Windows: \(address)\n" + detail,
            available: !expired, present: true, working: false)
    }

    /// `DateFormat.getDateTimeInstance(SHORT, SHORT)` equivalent in the user's locale and time zone.
    public static func expiryText(_ unixSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }
}
