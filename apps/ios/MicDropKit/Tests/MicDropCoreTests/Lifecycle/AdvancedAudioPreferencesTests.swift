import Foundation
import MicDropCore
import XCTest

/// Advanced audio settings: defaults, validation bounds, strict storage and the copy-report line.
final class AdvancedAudioPreferencesTests: XCTestCase {
    func testDefaultsKeepTheExistingKeepAliveAndTwentySecondWindows() throws {
        let defaults = AdvancedAudioPreferences()
        XCTAssertTrue(defaults.keepMicrophoneActiveWhileMuted)
        XCTAssertEqual(defaults.bluetoothRecoveryMs, 20_000)
        XCTAssertEqual(defaults.bluetoothRecoveryWindowMs, OutputRouteChange.bluetoothRecoveryMs)
        XCTAssertEqual(defaults.bluetoothRecoveryWindowMs, HeadsetRecovery.windowMs)
        XCTAssertEqual(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true), defaults)
        XCTAssertEqual(AdvancedAudioPreferences.fileName, "advanced-audio-settings.json")
        XCTAssertNotEqual(AdvancedAudioPreferences.fileName, AudioPreferences.fileName)
        XCTAssertNotEqual(AdvancedAudioPreferences.fileName, ConnectionPreferences.fileName)
    }

    func testBluetoothRecoveryBoundsAreValidated() throws {
        let limits = AdvancedAudioPreferences.bluetoothRecoveryLimits
        XCTAssertEqual(limits.minimumMs, 5_000)
        XCTAssertEqual(limits.maximumMs, 120_000)
        XCTAssertEqual(AdvancedAudioPreferences.bluetoothRecoveryRange, 5_000...120_000)
        for invalid in [Int.min, -1, 0, 4_999, 120_001, Int.max] {
            XCTAssertThrowsError(try AdvancedAudioPreferences(bluetoothRecoveryMs: invalid), "\(invalid)") { error in
                XCTAssertEqual(error as? AdvancedAudioPreferences.ValidationError, .bluetoothRecoveryOutOfRange)
            }
        }
        for valid in [5_000, 7_500, 20_000, 45_001, 120_000] {
            let custom = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: valid)
            XCTAssertEqual(custom.bluetoothRecoveryMs, valid)
            XCTAssertFalse(custom.keepMicrophoneActiveWhileMuted)
        }
        XCTAssertEqual(AdvancedAudioPreferences.boundedBluetoothRecoveryMs(.min), 5_000)
        XCTAssertEqual(AdvancedAudioPreferences.boundedBluetoothRecoveryMs(4_999), 5_000)
        XCTAssertEqual(AdvancedAudioPreferences.boundedBluetoothRecoveryMs(30_000), 30_000)
        XCTAssertEqual(AdvancedAudioPreferences.boundedBluetoothRecoveryMs(.max), 120_000)
    }

    func testTypedSecondsUseTheConnectionTimeoutRules() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        func parse(_ text: String, _ locale: Locale = english) -> Int? {
            AdvancedAudioPreferences.parseBluetoothRecoverySeconds(text, locale: locale)
        }
        XCTAssertEqual(parse("5"), 5_000)
        XCTAssertEqual(parse("7.5"), 7_500)
        XCTAssertEqual(parse(" 20\n"), 20_000)
        XCTAssertEqual(parse("45.125"), 45_125)
        XCTAssertEqual(parse("120"), 120_000)
        XCTAssertEqual(parse("7,5", german), 7_500)
        XCTAssertNil(parse("7,5"))
        for invalid in ["", "4.999", "120.001", "0", "-5", "+5", "5.", ".5", "5.0001", "1e2", "abc", "20 s"] {
            XCTAssertNil(parse(invalid), invalid)
        }
        // The shared parser is the one the connection timeouts use.
        XCTAssertEqual(ConnectionPreferences.parseSeconds("7.5", minimumMs: 5_000, maximumMs: 120_000), 7_500)
        XCTAssertNil(ConnectionPreferences.parseSeconds("7.5", minimumMs: 8_000, maximumMs: 1_000))
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseSeconds("1.234"), 1_234)
        XCTAssertEqual(AdvancedAudioPreferences.seconds(20_000), "20")
        XCTAssertEqual(AdvancedAudioPreferences.seconds(7_500), "7.5")
    }

    func testStorageRoundTripsExactlyTwoKeysWithoutIdentity() throws {
        let custom = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 45_500)
        let data = try custom.encodedJSON()
        XCTAssertEqual(AdvancedAudioPreferences.decodeJSON(data), custom)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["bluetoothRecoveryMs", "keepMicrophoneActiveWhileMuted"])
        XCTAssertEqual((object["bluetoothRecoveryMs"] as? NSNumber)?.intValue, 45_500)
        XCTAssertEqual(custom.fields()["keepMicrophoneActiveWhileMuted"], .bool(false))
        XCTAssertEqual(custom.fields()["bluetoothRecoveryMs"], .number(45_500))
        XCTAssertEqual(Set(custom.fields().keys), Set(AdvancedAudioPreferences.Key.allCases.map(\.rawValue)))
        let defaults = try AdvancedAudioPreferences().encodedJSON()
        XCTAssertEqual(AdvancedAudioPreferences.decodeJSON(defaults), AdvancedAudioPreferences())
    }

    func testStrictDecodingFallsBackPerKey() throws {
        func decode(_ json: String) -> AdvancedAudioPreferences {
            AdvancedAudioPreferences.decodeJSON(Data(json.utf8))
        }
        let defaults = AdvancedAudioPreferences()
        XCTAssertEqual(AdvancedAudioPreferences.decodeJSON(nil), defaults)
        XCTAssertEqual(decode("not json"), defaults)
        XCTAssertEqual(decode("[true, 30000]"), defaults)
        XCTAssertEqual(decode("{}"), defaults)
        // A number is never a Bool, and a Bool or string is never a window.
        XCTAssertEqual(decode("{\"keepMicrophoneActiveWhileMuted\":0,\"bluetoothRecoveryMs\":true}"), defaults)
        XCTAssertEqual(
            decode("{\"keepMicrophoneActiveWhileMuted\":\"false\",\"bluetoothRecoveryMs\":\"30000\"}"), defaults)
        XCTAssertEqual(decode("{\"keepMicrophoneActiveWhileMuted\":null,\"bluetoothRecoveryMs\":null}"), defaults)
        // Out-of-range or fractional windows keep the default without discarding a valid Bool.
        for window in ["4999", "120001", "30000.5", "-20000", "1e9"] {
            let decoded = decode("{\"keepMicrophoneActiveWhileMuted\":false,\"bluetoothRecoveryMs\":\(window)}")
            XCTAssertFalse(decoded.keepMicrophoneActiveWhileMuted, window)
            XCTAssertEqual(decoded.bluetoothRecoveryMs, 20_000, window)
        }
        let window = decode("{\"bluetoothRecoveryMs\":30000.0,\"unknown\":\"ignored\"}")
        XCTAssertEqual(window, try AdvancedAudioPreferences(bluetoothRecoveryMs: 30_000))
    }

    func testCopyReportLineNamesTheEffectiveWindowAndKeepAlive() {
        XCTAssertEqual(
            AdvancedAudioPreferences.text(bluetoothRecoveryMs: 20_000, keepMicrophoneActiveWhileMuted: nil),
            "Bluetooth route recovery: 20 s (default)")
        XCTAssertEqual(
            AdvancedAudioPreferences.text(bluetoothRecoveryMs: 7_500, keepMicrophoneActiveWhileMuted: true),
            "Bluetooth route recovery: 7.5 s · Keep microphone active while muted in background: on")
        XCTAssertEqual(
            AdvancedAudioPreferences.text(bluetoothRecoveryMs: 120_000, keepMicrophoneActiveWhileMuted: false),
            "Bluetooth route recovery: 120 s · Keep microphone active while muted in background: off")
    }

    /// Android's verbatim line (`StreamReceiver.kt:783` on main `87b15af`): the saved option and the actual state.
    func testMutedCaptureLineSeparatesTheOptionFromActualRetainedCapture() {
        for option in [true, false] {
            for retained in [true, false] {
                XCTAssertEqual(
                    AdvancedAudioPreferences.mutedCaptureText(option: option, retained: retained),
                    "Muted capture option: \(option) · Capture retained while muted: \(retained)")
            }
        }
        XCTAssertEqual(
            AdvancedAudioPreferences.mutedCaptureText(option: true, retained: false),
            "Muted capture option: true · Capture retained while muted: false")
        XCTAssertEqual(
            AdvancedAudioPreferences.mutedCaptureText(option: false, retained: false),
            "Muted capture option: false · Capture retained while muted: false")
    }

    /// The Connection settings sheet's Save keeps a Windows edit of the value the user did not change.
    func testSheetSaveKeepsWindowsEditsOfTheOtherValue() throws {
        let opened = AdvancedAudioPreferences()
        let windows = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 30_000)
        let shownWindow = try AdvancedAudioPreferences(bluetoothRecoveryMs: 7_500)
        XCTAssertEqual(
            try shownWindow.merged(onto: windows, since: opened),
            try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 7_500))
        let shownKeepAlive = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false)
        let keepAliveWindows = try AdvancedAudioPreferences(bluetoothRecoveryMs: 30_000)
        XCTAssertEqual(
            try shownKeepAlive.merged(onto: keepAliveWindows, since: opened),
            try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 30_000))
        XCTAssertEqual(try opened.merged(onto: windows, since: opened), windows, "nothing changed in the sheet")
        XCTAssertEqual(try shownWindow.merged(onto: opened, since: opened), shownWindow, "no Windows edit")
    }
}
