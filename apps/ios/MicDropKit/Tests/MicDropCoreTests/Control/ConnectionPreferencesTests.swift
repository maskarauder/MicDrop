import XCTest

@testable import MicDropCore

final class ConnectionPreferencesTests: XCTestCase {
    func testEveryTimeoutRejectsOutOfRangeValues() throws {
        for timeout in ConnectionPreferences.Timeout.allCases {
            let limits = timeout.limits
            XCTAssertThrowsError(try ConnectionPreferences(timeouts: [timeout: limits.minimumMs - 1]))
            XCTAssertThrowsError(try ConnectionPreferences(timeouts: [timeout: limits.maximumMs + 1]))
            let minimum = try ConnectionPreferences(timeouts: [timeout: limits.minimumMs])
            let maximum = try ConnectionPreferences(timeouts: [timeout: limits.maximumMs])
            XCTAssertEqual(minimum[timeout], limits.minimumMs)
            XCTAssertEqual(maximum[timeout], limits.maximumMs)
        }
        XCTAssertThrowsError(try ConnectionPreferences(timeouts: [:], maxRestarts: 0))
        XCTAssertThrowsError(try ConnectionPreferences(timeouts: [:], maxRestarts: 11))
    }

    /// The Windows host's header rule (`internal/session/connection_timeouts.go:24,30-37`): recovery
    /// 5000-300000 ms and setup 10000-120000 ms, each sent as 1-6 ASCII digits with no sign or separator.
    func testHeaderBoundsMatchWindowsHost() throws {
        XCTAssertEqual(ConnectionPreferences.recoveryHeader, "X-MicDrop-Recovery-Window-Ms")
        XCTAssertEqual(ConnectionPreferences.setupHeader, "X-MicDrop-Setup-Window-Ms")
        let hostBounds: [(ConnectionPreferences.Timeout, ClosedRange<Int>)] = [
            (.recovery, 5_000...300_000), (.setup, 10_000...120_000),
        ]
        func isHostDecimal(_ text: String) -> Bool {
            (1...6).contains(text.utf8.count) && text.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
        for (timeout, bounds) in hostBounds {
            let limits = timeout.limits
            XCTAssertEqual(limits.minimumMs...limits.maximumMs, bounds, "\(timeout)")
            XCTAssertTrue(bounds.contains(limits.defaultMs), "\(timeout)")
            for value in [limits.minimumMs, limits.defaultMs, limits.maximumMs] {
                let preferences = try ConnectionPreferences(timeouts: [timeout: value])
                // `ControlRequestEncoder` interpolates the value exactly like this.
                XCTAssertTrue(isHostDecimal("\(preferences[timeout])"), "\(timeout)=\(value)")
            }
            XCTAssertThrowsError(try ConnectionPreferences(timeouts: [timeout: bounds.lowerBound - 1]))
            XCTAssertThrowsError(try ConnectionPreferences(timeouts: [timeout: bounds.upperBound + 1]))
        }
    }

    func testLegacyHostsRetainTheirWatchdogLimits() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 120_000, .setup: 120_000])
        let restart = preferences.legacy(restartSupported: true)
        XCTAssertEqual(restart.recoveryMs, 30_000)
        XCTAssertEqual(restart.setupMs, 45_000)
        XCTAssertEqual(restart.heartbeatMs, 35_000)
        XCTAssertFalse(restart.confirmed)
        let old = preferences.legacy(restartSupported: false)
        XCTAssertEqual(old.recoveryMs, 10_000)
        XCTAssertEqual(old.heartbeatMs, 15_000)
    }

    func testCustomWindowsRequireExactVersionOneAcknowledgment() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 60_000, .setup: 90_000])
        let confirmed = try preferences.negotiated(
            restartSupported: true, version: 1, recoveryMs: 60_000, setupMs: 90_000, heartbeatMs: 65_000)
        XCTAssertTrue(confirmed.confirmed)
        XCTAssertThrowsError(
            try preferences.negotiated(
                restartSupported: true, version: 1, recoveryMs: 60_000, setupMs: 90_000, heartbeatMs: 64_999))
        XCTAssertThrowsError(
            try preferences.negotiated(
                restartSupported: true, version: 1, recoveryMs: 59_999, setupMs: 90_000, heartbeatMs: 64_999))
        XCTAssertThrowsError(
            try preferences.negotiated(
                restartSupported: true, version: 1, recoveryMs: 60_000, setupMs: 89_999, heartbeatMs: 65_000))
        let unknown = try preferences.negotiated(
            restartSupported: true, version: 2, recoveryMs: 60_000, setupMs: 90_000, heartbeatMs: 65_000)
        XCTAssertEqual(unknown, preferences.legacy(restartSupported: true))
        let unsupportedRestart = try preferences.negotiated(
            restartSupported: false, version: 1, recoveryMs: 10_000, setupMs: 90_000, heartbeatMs: 15_000)
        XCTAssertEqual(unsupportedRestart.recoveryMs, 10_000)
    }

    func testBudgetClampsEachOperationAndRejectsExpiredWindows() throws {
        let deadlines = ConnectionPreferences().legacy(restartSupported: true)
        XCTAssertEqual(
            try deadlines.budget(
                requestedMs: 8_000, nowMs: 44_000, setupStartedMs: 0, recoveryRemainingMs: nil), 1_000)
        XCTAssertEqual(
            try deadlines.budget(
                requestedMs: 8_000, nowMs: 44_000, setupStartedMs: 0, recoveryRemainingMs: 500), 500)
        XCTAssertEqual(
            try deadlines.budget(
                requestedMs: 8_000, nowMs: 0, setupStartedMs: nil, recoveryRemainingMs: nil), 8_000)
        for now in [Int64(45_000), Int64.max] {
            XCTAssertThrowsError(
                try deadlines.budget(
                    requestedMs: 8_000, nowMs: now, setupStartedMs: -1, recoveryRemainingMs: nil)
            ) {
                XCTAssertEqual($0 as? ControlIOError, ControlIOError(.timedOut))
            }
        }
        XCTAssertThrowsError(
            try deadlines.budget(
                requestedMs: 8_000, nowMs: 0, setupStartedMs: nil, recoveryRemainingMs: 0))
    }

    /// The Connection settings sheet's Save: values the user changed replace the store's current values, every
    /// other value keeps the store's current one, so a Windows edit made while the sheet was open survives.
    func testSheetSaveKeepsWindowsEditsOfOtherValues() throws {
        let opened = ConnectionPreferences()
        let latest = try ConnectionPreferences(
            recoveryOrder: .lanFirst, timeouts: [.lanStatus: 3_000, .setup: 60_000], maxRestarts: 5)
        let shown = try ConnectionPreferences(
            initialOrder: .rendezvousFirst, timeouts: [.recovery: 90_000, .setup: 20_000], maxRestarts: 2)
        let merged = try shown.merged(onto: latest, since: opened)
        XCTAssertEqual(merged.initialOrder, .rendezvousFirst, "the user's edit")
        XCTAssertEqual(merged.recoveryOrder, .lanFirst, "Windows' edit")
        XCTAssertEqual(merged[.recovery], 90_000, "the user's edit")
        XCTAssertEqual(merged[.setup], 20_000, "the user changed the value Windows also changed")
        XCTAssertEqual(merged[.lanStatus], 3_000, "Windows' edit")
        XCTAssertEqual(merged.maxRestarts, 5, "unchanged in the sheet, so Windows' value")
        for timeout in ConnectionPreferences.Timeout.allCases where ![.recovery, .setup, .lanStatus].contains(timeout) {
            XCTAssertEqual(merged[timeout], timeout.limits.defaultMs, "\(timeout)")
        }
        XCTAssertEqual(try opened.merged(onto: latest, since: opened), latest, "nothing changed in the sheet")
        XCTAssertEqual(try shown.merged(onto: opened, since: opened), shown, "no Windows edit")
        let loadedCustom = try ConnectionPreferences(timeouts: [.setup: 60_000])
        XCTAssertEqual(
            try opened.merged(onto: latest, since: loadedCustom)[.setup], 45_000,
            "a value changed back to its default is an edit too")
    }

    func testUnnegotiatedAndRejectedDeadlinesDoNotBlameALegacyWindowsHost() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 60_000, .setup: 90_000])
        let unnegotiated = preferences.unnegotiated()
        XCTAssertEqual(unnegotiated.state, .notNegotiated)
        XCTAssertFalse(unnegotiated.confirmed)
        let unnegotiatedText = preferences.text(deadlines: unnegotiated)
        XCTAssertTrue(
            unnegotiatedText.contains(
                "Connection deadlines — requested recovery: 60000 ms · requested setup: 90000 ms · not negotiated (no Windows offer reply)"
            ), unnegotiatedText)
        XCTAssertFalse(unnegotiatedText.contains("legacy Windows limits"), unnegotiatedText)
        XCTAssertFalse(unnegotiatedText.contains("update Windows"), unnegotiatedText)

        var rejected = unnegotiated
        rejected.state = .rejected
        let rejectedText = preferences.text(deadlines: rejected)
        XCTAssertTrue(
            rejectedText.contains(
                "Connection deadlines — requested recovery: 60000 ms · requested setup: 90000 ms · not negotiated (Windows offer reply rejected)"
            ), rejectedText)
        XCTAssertFalse(rejectedText.contains("legacy Windows limits"), rejectedText)

        let legacyText = preferences.text(deadlines: preferences.legacy(restartSupported: true))
        XCTAssertTrue(
            legacyText.contains(
                "Connection deadlines — requested recovery: 60000 ms · effective: 30000 ms · setup: 45000 ms · Windows heartbeat: 35000 ms · legacy Windows limits (update Windows for custom deadlines)"
            ), legacyText)
    }
}
