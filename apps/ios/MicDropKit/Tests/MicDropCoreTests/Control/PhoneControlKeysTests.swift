import XCTest

@testable import MicDropCore

/// Key parity of phone settings exchange v1 (D046): the iPhone advertises Android's keys in Android's order, with
/// Android's groups, kinds, `int` bounds and `int` defaults, except the two it omits with a reason. `android` is
/// derived from `A/AppPhoneControl.kt:96-136` (keys, groups, kinds and `advanced.max_restarts` 1-10) and
/// `A/ConnectionPreferences.kt:16-35, :51` (every `ConnectionTimeout`, `BLUETOOTH_RECOVERY` included, and the
/// `maxRestarts` default). An Android key that is added or changed must be added here, and then either advertised by
/// the iPhone or listed in `PhoneControlKeys.omitted`.
final class PhoneControlKeysTests: XCTestCase {
    /// One key of Android's snapshot. `bounds` and `defaultValue` are set for an `int` with fixed bounds; `live.volume`
    /// takes the device's stream bounds.
    private struct AndroidKey {
        let key: String
        let group: PhoneSetting.Group
        let kind: PhoneSetting.Kind
        var bounds: ClosedRange<Int>?
        var defaultValue: Int?
    }

    private static func bool(_ key: String, _ group: PhoneSetting.Group = .audio) -> AndroidKey {
        AndroidKey(key: key, group: group, kind: .bool)
    }

    private static func choice(_ key: String, _ group: PhoneSetting.Group) -> AndroidKey {
        AndroidKey(key: key, group: group, kind: .choice)
    }

    /// `advanced.<ConnectionTimeout name lowercased>` with its default and bounds.
    private static func timeout(_ name: String, _ defaultValue: Int, _ bounds: ClosedRange<Int>) -> AndroidKey {
        AndroidKey(key: "advanced." + name, group: .advanced, kind: .int, bounds: bounds, defaultValue: defaultValue)
    }

    private static let android: [AndroidKey] = [
        bool("audio.fast_recovery"), bool("audio.echo_cancellation"), bool("audio.noise_reduction"),
        bool("audio.keep_microphone_active"), bool("audio.le_stereo"),
        choice("audio.input", .audio), choice("audio.output", .audio),
        choice("advanced.initial_order", .advanced), choice("advanced.recovery_order", .advanced),
        AndroidKey(key: "advanced.max_restarts", group: .advanced, kind: .int, bounds: 1...10, defaultValue: 2),
        timeout("recovery", 30_000, 5_000...300_000), timeout("setup", 45_000, 10_000...120_000),
        timeout("busy_host", 5_000, 0...30_000), timeout("restart_delay", 1_000, 0...10_000),
        timeout("restart_interval", 8_000, 5_000...60_000), timeout("lan_probe", 1_500, 250...5_000),
        timeout("lan_status", 2_000, 250...15_000), timeout("lan_request", 8_000, 1_000...30_000),
        timeout("remote_request", 8_000, 1_000...30_000), timeout("ice_service", 8_000, 1_000...30_000),
        timeout("lan_stop", 2_000, 500...10_000), timeout("remote_stop", 5_000, 500...15_000),
        timeout("initial_offer", 40_000, 1_000...60_000), timeout("cancel_offer", 5_000, 500...15_000),
        timeout("initial_ice", 15_000, 1_000...30_000), timeout("initial_sdp", 15_000, 1_000...30_000),
        timeout("recovery_ice", 8_000, 1_000...30_000), timeout("recovery_offer", 18_000, 1_000...30_000),
        timeout("recovery_answer", 5_000, 1_000...30_000), timeout("bluetooth_recovery", 20_000, 5_000...120_000),
        bool("live.output_enabled", .live), bool("live.microphone_muted", .live),
        AndroidKey(key: "live.volume", group: .live, kind: .int),
    ]

    /// 31 of Android's 33 keys, in Android's order, each with Android's group, kind and bounds.
    func testTheIPhoneAdvertisesAndroidsKeysInOrderExceptTheTwoOmitted() {
        XCTAssertEqual(Self.android.count, 33)
        XCTAssertEqual(Set(Self.android.map(\.key)).count, 33, "the fixture has no duplicate")
        let expected = Self.android.filter { PhoneControlKeys.omitted[$0.key] == nil }
        let advertised = PhoneControlKeys.advertised
        XCTAssertEqual(advertised.count, 31)
        XCTAssertEqual(advertised.map(\.key), expected.map(\.key))
        for (field, android) in zip(advertised, expected) {
            XCTAssertEqual(field.group, android.group, field.key)
            XCTAssertEqual(field.kind, android.kind, field.key)
            XCTAssertEqual(field.range, android.bounds, field.key)
            XCTAssertEqual(field.range != nil, field.kind == .int, "only an int has bounds: \(field.key)")
        }
    }

    /// `audio.le_stereo` and `live.volume`, and nothing else, are omitted, each with its reason; the omitted keys are
    /// Android keys and none is advertised.
    func testExactlyTheTwoUnsupportedKeysAreOmittedWithTheirReason() {
        XCTAssertEqual(Set(PhoneControlKeys.omitted.keys), [PhoneControlKeys.leStereo, PhoneControlKeys.volume])
        XCTAssertEqual([PhoneControlKeys.leStereo, PhoneControlKeys.volume], ["audio.le_stereo", "live.volume"])
        let androidKeys = Set(Self.android.map(\.key))
        let advertised = Set(PhoneControlKeys.advertised.map(\.key))
        for (key, reason) in PhoneControlKeys.omitted {
            XCTAssertTrue(androidKeys.contains(key), key)
            XCTAssertFalse(advertised.contains(key), key)
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, key)
        }
        XCTAssertEqual(advertised.union(PhoneControlKeys.omitted.keys), androidKeys)
        XCTAssertTrue(PhoneControlKeys.omitted[PhoneControlKeys.volume]?.contains("system volume") == true)
        XCTAssertTrue(PhoneControlKeys.omitted[PhoneControlKeys.leStereo]?.contains("LE Audio") == true)
    }

    /// The iPhone's `int` defaults equal Android's: the 19 connection timeouts and the restart limit
    /// (`ConnectionPreferences`), and the Bluetooth route recovery window (`AdvancedAudioPreferences`), which Android
    /// keeps among its timeouts.
    func testIntDefaultsMatchAndroid() {
        let connection = ConnectionPreferences()
        let advanced = AdvancedAudioPreferences()
        var checked: [String] = []
        for android in Self.android {
            guard let expected = android.defaultValue else { continue }
            let value: Int?
            if android.key == PhoneControlKeys.maxRestarts {
                value = connection.maxRestarts
            } else if android.key == PhoneControlKeys.bluetoothRecovery {
                value = advanced.bluetoothRecoveryMs
            } else {
                value = ConnectionPreferences.Timeout.allCases.first { PhoneControlKeys.timeout($0) == android.key }
                    .map { connection[$0] }
            }
            XCTAssertEqual(value, expected, android.key)
            checked.append(android.key)
        }
        XCTAssertEqual(checked.count, 21)
        XCTAssertEqual(ConnectionPreferences.Timeout.allCases.count, 19, "Android's 20 less BLUETOOTH_RECOVERY")
        let timeoutKeys = ConnectionPreferences.Timeout.allCases.map(PhoneControlKeys.timeout)
        XCTAssertFalse(timeoutKeys.contains(PhoneControlKeys.bluetoothRecovery), "an Advanced audio value")
    }
}
