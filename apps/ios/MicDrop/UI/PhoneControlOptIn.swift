// The phone-local opt-in of phone settings exchange v1 (D046, `docs/PHONE_CONTROL_V1.md`; Android's checkbox,
// `MainActivity.kt:463-468`, `:1341`).

import Foundation
import Observation

/// "Allow Windows to change phone settings" in **Advanced**. Off by default and saved at once in
/// `PhoneControlPreferenceStore` (`PhoneControlOptInStoring`), not by the Connection settings sheet; changeable at
/// any time, also during a session. The session's settings adapter reads the store for every heartbeat snapshot and
/// again before applying a Windows command (`PhoneControlAdapter`). Turning it off therefore reaches Windows on the
/// next `/status` as an `enabled: false` snapshot whose new revision bypasses the 5 s de-duplication and clears a
/// pending Windows edit (`internal/phonecontrol/state.go:32-35`); turning it on lets Windows edit after the next
/// snapshot. It never grants pairing, permissions or microphone consent, and never starts a session or capture.
@MainActor
@Observable
final class PhoneControlOptIn {
    /// The saved choice the toggle shows.
    private(set) var allowed: Bool
    /// The last change could not be written; `allowed` shows the choice that is in effect.
    private(set) var saveFailed = false
    /// Counts `set` calls. The toggle is identified by it, so every attempt re-renders the switch from `allowed`,
    /// also a second failed save in a row, which changes neither `allowed` nor `saveFailed` (Observation does not
    /// notify for an unchanged Equatable value).
    private(set) var saveAttempt: UInt64 = 0
    private let store: any PhoneControlOptInStoring

    init(store: any PhoneControlOptInStoring) {
        self.store = store
        allowed = store.allowWindows()
    }

    /// Saves `allow` at once (Android `AppPhoneControlSettings.setEnabled`) and shows the failure text until the
    /// next change when the write fails. A failed opt-in leaves Windows control off; turning it off always takes
    /// effect, for the toggle and for Windows alike (`PhoneControlPreferenceStore.setAllowWindows`).
    func set(_ allow: Bool) {
        saveAttempt &+= 1
        do {
            try store.setAllowWindows(allow)
            saveFailed = false
        } catch {
            saveFailed = true
        }
        allowed = store.allowWindows()
    }
}
