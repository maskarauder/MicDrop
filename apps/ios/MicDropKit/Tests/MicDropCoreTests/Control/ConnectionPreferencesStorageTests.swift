import Foundation
import XCTest

@testable import MicDropCore

final class ConnectionPreferencesStorageTests: XCTestCase {
    func testEveryTimeoutRoundTripsExactDecimalSecondsAtBothBounds() {
        for timeout in ConnectionPreferences.Timeout.allCases {
            for milliseconds in [timeout.limits.minimumMs, timeout.limits.defaultMs, timeout.limits.maximumMs] {
                XCTAssertEqual(timeout.parseSeconds(ConnectionPreferences.seconds(milliseconds)), milliseconds)
            }
        }
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseSeconds("1.234"), 1_234)
        XCTAssertEqual(ConnectionPreferences.seconds(1_500), "1.5")
        XCTAssertEqual(ConnectionPreferences.seconds(1_010), "1.01")
        XCTAssertEqual(ConnectionPreferences.seconds(1_001), "1.001")
    }

    func testDecimalInputRejectsRoundingOverflowLocaleAndNonASCII() {
        for text in [
            "", " 1", "1 ", "+1", "-1", "1e3", "1,5", ".5", "1.", "1.2345", "1..2", "NaN", "inf", "١", "9999999999999",
        ] {
            XCTAssertNil(ConnectionPreferences.Timeout.lanProbe.parseSeconds(text), text)
        }
        XCTAssertNil(ConnectionPreferences.Timeout.lanProbe.parseSeconds("0.249"))
        XCTAssertNil(ConnectionPreferences.Timeout.lanProbe.parseSeconds("5.001"))
        XCTAssertEqual(ConnectionPreferences.Timeout.busyHost.parseSeconds("0"), 0)
        XCTAssertNil(ConnectionPreferences.Timeout.recovery.parseSeconds("0"))
    }

    func testTypedInputAcceptsLocaleDecimalSeparatorAndTrimsWhitespace() {
        let german = Locale(identifier: "de_DE")
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(german.decimalSeparator, ",")
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds("2,5", locale: german), 2_500)
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds("0,25", locale: german), 250)
        XCTAssertEqual(ConnectionPreferences.Timeout.lanStatus.parseUserSeconds("0,25", locale: german), 250)
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds("1.5", locale: german), 1_500)
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds("2,5 ", locale: german), 2_500)
        XCTAssertEqual(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds(" 1.5\n", locale: english), 1_500)
        for text in ["1,2,3", "1,2345", "1,2.3", ",5", "1,", "0,249", "+1", "1e3", " "] {
            XCTAssertNil(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds(text, locale: german), text)
        }
        // ',' groups digits where '.' is the separator, so it is never read as a decimal mark there.
        XCTAssertNil(ConnectionPreferences.Timeout.lanProbe.parseUserSeconds("2,5", locale: english))
        for timeout in ConnectionPreferences.Timeout.allCases {
            let text = ConnectionPreferences.seconds(timeout.limits.defaultMs)
            XCTAssertEqual(timeout.parseUserSeconds(text, locale: german), timeout.limits.defaultMs)
            let typed = text.replacingOccurrences(of: ".", with: ",")
            XCTAssertEqual(timeout.parseUserSeconds(typed, locale: german), timeout.limits.defaultMs)
        }
    }

    func testJSONRoundTripPreservesAllChoicesWithoutCredentials() throws {
        let values = Dictionary(
            uniqueKeysWithValues: ConnectionPreferences.Timeout.allCases.map { ($0, $0.limits.minimumMs) })
        let preferences = try ConnectionPreferences(
            initialOrder: .rendezvousFirst, recoveryOrder: .lanFirst, timeouts: values, maxRestarts: 10)
        let data = try preferences.encodedJSON()
        XCTAssertEqual(ConnectionPreferences.decodeJSON(data), preferences)
        XCTAssertEqual(preferences.fields().count, ConnectionPreferences.Timeout.allCases.count + 3)
        XCTAssertEqual(
            ConnectionPreferences.decodeJSON(try ConnectionPreferences().encodedJSON()), ConnectionPreferences())
    }

    func testStoredMistypedAndOutOfRangeValuesFallBackIndependently() throws {
        let fields: [String: Any] = [
            "initialOrder": "RENDEZVOUS_FIRST", "recoveryOrder": "unknown", "maxRestarts": true,
            "RECOVERY": 60_000, "SETUP": "120000", "LAN_PROBE": 1_234.5, "LAN_STATUS": -1,
            "RESTART_DELAY": false, "REMOTE_STOP": 15_001, "ignored": "value",
        ]
        let preferences = ConnectionPreferences.decodeJSON(try JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(preferences.initialOrder, .rendezvousFirst)
        XCTAssertEqual(preferences.recoveryOrder, .rendezvousFirst)
        XCTAssertEqual(preferences.maxRestarts, 2)
        XCTAssertEqual(preferences[.recovery], 60_000)
        for timeout in [ConnectionPreferences.Timeout.setup, .lanProbe, .lanStatus, .restartDelay, .remoteStop] {
            XCTAssertEqual(preferences[timeout], timeout.limits.defaultMs)
        }
        for data in [nil, Data("[]".utf8), Data("{broken".utf8), Data([0xFF])] {
            XCTAssertEqual(ConnectionPreferences.decodeJSON(data), ConnectionPreferences())
        }
    }

    func testBusyRetryHonorsConfiguredWindowWithoutOverflow() {
        let retry = BusyOfferRetry(enabled: true, startedMs: 100, limitMs: 1_000)
        XCTAssertTrue(retry.allow(status: 423, nowMs: 1_099))
        XCTAssertFalse(retry.allow(status: 423, nowMs: 1_100))
        XCTAssertFalse(BusyOfferRetry(enabled: true, startedMs: 0, limitMs: 0).allow(status: 423, nowMs: 0))
        XCTAssertFalse(BusyOfferRetry(enabled: true, startedMs: -1).allow(status: 423, nowMs: Int64.max))
    }
}
