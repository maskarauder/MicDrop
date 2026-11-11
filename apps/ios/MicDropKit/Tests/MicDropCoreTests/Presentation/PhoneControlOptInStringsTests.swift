import Foundation
import MicDropCore
import XCTest

/// The phone-local opt-in of phone settings exchange v1 (D046) under **Advanced**.
final class PhoneControlOptInStringsTests: XCTestCase {
    /// Windows asks for exactly this option (`internal/desktop/phone_settings_windows.go:278`), so the label stays
    /// Android's verbatim (`allow_windows_settings`, `strings.xml:23`).
    func testTheLabelIsTheOneWindowsNames() {
        XCTAssertEqual(Strings.allowWindowsSettings, "Allow Windows to change phone settings")
        let windowsHint = "On the phone, enable ‘Allow Windows to change phone settings’ to allow changes here."
        XCTAssertTrue(windowsHint.contains("‘" + Strings.allowWindowsSettings + "’"))
    }

    /// Android's `windows_settings_help` (`strings.xml:24`) adapted to the iPhone: no volume control, the unmute rule
    /// (a microphone already on during this connection, permission, and the background keep-alive), a media output
    /// change applied at once, and the phone-local authorities; no Android wording.
    func testTheHelpStatesTheIPhoneLimits() {
        let help = Strings.allowWindowsSettingsHelp
        XCTAssertEqual(
            help,
            "While connected, your paired Windows host can adjust Audio and Advanced preferences, media output, "
                + "Play desktop audio and microphone mute. Pairing and microphone consent stay on this iPhone. A "
                + "media output change applies at once when desktop audio uses media output; other changes apply "
                + "after Stop and Connect. Windows can unmute the microphone only after it has been on during this "
                + "connection and while microphone access is allowed; while MicDrop is in the background, only if "
                + "it was kept active while muted. iOS does not let apps set the iPhone volume. These controls are "
                + "unavailable while paused or disconnected.")
        for phrase in [
            "While connected, your paired Windows host can adjust Audio and Advanced preferences",
            "media output, Play desktop audio and microphone mute.",
            "Pairing and microphone consent stay on this iPhone.",
            "A media output change applies at once when desktop audio uses media output;",
            "other changes apply after Stop and Connect.", "iOS does not let apps set the iPhone volume.",
            "Windows can unmute the microphone only after it has been on during this connection",
            "while microphone access is allowed", "in the background, only if it was kept active while muted.",
            "These controls are unavailable while paused or disconnected.",
        ] {
            XCTAssertTrue(help.contains(phrase), phrase)
        }
        XCTAssertFalse(help.contains("Android"))
        XCTAssertFalse(help.contains(" phone volume"), "Windows gets no volume control on the iPhone")
        XCTAssertFalse(help.contains("this phone"))
        XCTAssertFalse(help.contains("  "))
        XCTAssertFalse(Strings.allowWindowsSettingsSaveFailed.isEmpty)
    }
}
