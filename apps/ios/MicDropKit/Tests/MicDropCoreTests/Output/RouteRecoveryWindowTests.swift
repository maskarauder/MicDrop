import MicDropCore
import XCTest

private let selected = OutputSelection(
    kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "synthetic-headset-window")

/// The configurable Bluetooth route recovery window (Advanced): one fixed deadline per episode for the selected
/// Bluetooth output (`OutputRouteChange`) and the Bluetooth headset microphone (`HeadsetRecovery`), with the
/// gates held until verification, bounded expiry, and Stop / user silence taking precedence.
final class RouteRecoveryWindowTests: XCTestCase {
    func testDefaultAndCustomOutputWindowsEndAtTheirLimit() throws {
        for (window, start) in [(Int64(20_000), Int64(1_000)), (5_000, 0), (45_500, 10_000), (120_000, 3_000)] {
            let route =
                window == OutputRouteChange.bluetoothRecoveryMs
                ? OutputRouteChange(selected) : OutputRouteChange(selected, bluetoothRecoveryMs: window)
            XCTAssertEqual(route.bluetoothRecoveryLimitMs, window)
            XCTAssertEqual(route.limitMs, OutputRouteChange.defaultLimitMs, "verification keeps its own 5 s window")
            XCTAssertTrue(route.verified(route.ticket))
            XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: start))
            XCTAssertFalse(route.expired(start + window - 1), "\(window)")
            XCTAssertTrue(route.expired(start + window), "\(window)")
        }
    }

    func testRepeatedOutputCallbacksCannotExtendACustomEpisode() {
        let route = OutputRouteChange(selected, bluetoothRecoveryMs: 7_500)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 1_000))
        // Every later route-change, noisy or inventory callback during the episode is refused.
        for now in stride(from: Int64(1_500), through: 8_000, by: 500) {
            XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: now))
        }
        XCTAssertTrue(route.rebind(route.ticket, selected))
        route.beginCheck(route.ticket, nowMs: 6_000)
        route.trackStarted()
        route.beginCheck(route.ticket, nowMs: 8_000)
        XCTAssertTrue(route.recovering)
        XCTAssertFalse(route.expired(8_499))
        XCTAssertTrue(route.expired(8_500))
    }

    func testGatesStayHeldUntilVerificationAndUserSilenceAndStopWin() {
        for enabled in [false, true] {
            let route = OutputRouteChange(selected, bluetoothRecoveryMs: 30_000)
            var gate = AudioOutputGate(enabled: enabled)
            XCTAssertTrue(route.verified(route.ticket))
            XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 0))
            gate.hold()
            XCTAssertTrue(gate.muted, "held while recovering")
            let old = route.ticket
            route.trackStarted()
            XCTAssertFalse(route.verified(old), "an earlier acknowledgment cannot release the gate")
            XCTAssertTrue(gate.muted)
            if route.verified(route.ticket) { gate.verified() }
            XCTAssertEqual(gate.muted, !enabled, "user silence survives the verified route")
        }
        let route = OutputRouteChange(selected, bluetoothRecoveryMs: 30_000)
        var gate = AudioOutputGate(enabled: true)
        XCTAssertTrue(route.verified(route.ticket))
        route.recoverBluetooth(route.ticket, nowMs: 0)
        gate.hold()
        let ticket = route.ticket
        route.stop()
        gate.stop()
        XCTAssertFalse(route.verified(ticket))
        XCTAssertFalse(route.expired(Int64.max), "Stop ends the episode instead of a later timeout")
        XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: 40_000))
        gate.verified()
        XCTAssertTrue(gate.muted)
    }

    func testANewChoiceReplacesTheEpisodeAndANewEpisodeGetsTheFullWindow() {
        let route = OutputRouteChange(selected, bluetoothRecoveryMs: 10_000)
        XCTAssertTrue(route.verified(route.ticket))
        route.recoverBluetooth(route.ticket, nowMs: 0)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 50_000))
        XCTAssertFalse(route.expired(59_999))
        XCTAssertTrue(route.expired(60_000))
        // A replacement during recovery gets the 5 s verification window, not the Bluetooth window.
        XCTAssertTrue(route.request(OutputSelection.restored(.phone)))
        XCTAssertFalse(route.recovering)
        route.beginCheck(route.ticket, nowMs: 55_000)
        XCTAssertFalse(route.expired(59_999))
        XCTAssertTrue(route.expired(60_000))
    }

    func testTimeoutAndPauseTextsNameTheSessionWindow() {
        XCTAssertEqual(
            OutputRouteChange(selected, bluetoothRecoveryMs: 7_500).bluetoothRestoreTimeoutText,
            "iOS did not restore the selected Bluetooth output within 7.5 seconds. Playback stayed silenced. "
                + "Choose an available output and Connect again.")
        XCTAssertEqual(
            OutputRouteChange(selected).bluetoothRestoreTimeoutText,
            OutputRouteChange.Text.bluetoothRestoreTimeout(seconds: "20"))
        XCTAssertEqual(
            OutputPause.selectedBluetooth.detail(bluetoothRecoveryMs: 45_000),
            "Playback paused while waiting for the selected Bluetooth output to return (up to 45 seconds).")
        XCTAssertEqual(
            OutputPause.selectedBluetooth.detail(bluetoothRecoveryMs: 20_000),
            "Playback paused while waiting for the selected Bluetooth output to return (up to 20 seconds).")
        XCTAssertFalse(OutputPause.selectedBluetooth.detail.contains("20"), "the UI detail names no fixed window")
        for pause in OutputPause.allCases where pause != .selectedBluetooth {
            XCTAssertEqual(pause.detail(bluetoothRecoveryMs: 45_000), pause.detail)
        }
    }

    func testStatusOutputHelpAndDuplexNameTheSessionWindow() {
        let expected = "Playback paused while waiting for the selected Bluetooth output to return (up to 7.5 seconds)."
        var view = PresentationFixtures.session(
            .routeRecovering, outputSelection: PresentationFixtures.a2dp, outputPause: .selectedBluetooth)
        view.bluetoothRecoveryMs = 7_500
        XCTAssertEqual(view.outputPauseDetail, expected)
        let playback = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.session = view
            input.selectedOutput = PresentationFixtures.a2dp
        }
        XCTAssertTrue(playback.statusText.contains(expected), playback.statusText)
        XCTAssertTrue(playback.outputHelp.hasPrefix(expected + "\n\n"), playback.outputHelp)
        let duplex = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.mic = MicrophoneView(session: view, muted: true, mode: .duplex)
            input.selectedOutput = PresentationFixtures.a2dp
        }
        XCTAssertTrue(duplex.statusText.contains(expected), duplex.statusText)

        // Before a session is configured the pause names no time; other pauses never do.
        view.bluetoothRecoveryMs = nil
        XCTAssertEqual(view.outputPauseDetail, OutputPause.selectedBluetooth.detail)
        view.bluetoothRecoveryMs = 7_500
        view.outputPause = .route
        XCTAssertEqual(view.outputPauseDetail, OutputPause.route.detail)
        view.outputPause = nil
        XCTAssertNil(view.outputPauseDetail)
    }

    func testHeadsetWindowIsFixedPerEpisodeAndRepeatedLossesDoNotExtendIt() throws {
        XCTAssertEqual(HeadsetRecovery().limitMs, HeadsetRecovery.windowMs)
        let recovery = HeadsetRecovery(limitMs: 45_000)
        XCTAssertEqual(recovery.limitMs, 45_000)
        XCTAssertTrue(recovery.request(nowMs: 1_000))
        let first = try XCTUnwrap(recovery.current())
        for now in stride(from: Int64(2_000), through: 45_000, by: 1_000) {
            XCTAssertTrue(recovery.request(nowMs: now), "a repeated route callback only bumps the revision")
        }
        let latest = try XCTUnwrap(recovery.current())
        XCTAssertEqual(latest.episode, first.episode)
        XCTAssertGreaterThan(latest.revision, first.revision)
        XCTAssertEqual(recovery.remaining(nowMs: 45_999), 1)
        XCTAssertEqual(recovery.remaining(nowMs: 46_000), 0)
        XCTAssertFalse(recovery.complete(first, nowMs: 10_000), "a stale acknowledgment cannot complete")
        XCTAssertFalse(recovery.complete(latest, nowMs: 46_000), "expiry wins over a late completion")
        XCTAssertFalse(recovery.reselectionDue(nowMs: 46_000))
        XCTAssertTrue(recovery.complete(latest, nowMs: 45_999))
        // The next loss is a new episode with the whole configured window.
        XCTAssertTrue(recovery.request(nowMs: 100_000))
        XCTAssertEqual(recovery.remaining(nowMs: 100_000), 45_000)
        XCTAssertEqual(try XCTUnwrap(recovery.current()).episode, first.episode + 1)
    }

    func testStopCancelsAHeadsetEpisodeBeforeItsDeadline() throws {
        for window: Int64 in [5_000, 20_000, 120_000] {
            let recovery = HeadsetRecovery(limitMs: window)
            recovery.request(nowMs: 0)
            let ticket = try XCTUnwrap(recovery.current())
            recovery.cancel()
            XCTAssertFalse(recovery.pending())
            XCTAssertNil(recovery.current())
            XCTAssertFalse(recovery.complete(ticket, nowMs: 1), "Stop wins an in-flight completion")
            XCTAssertFalse(recovery.request(nowMs: 2), "no new episode after Stop")
            XCTAssertEqual(recovery.remaining(nowMs: 2), 0)
            XCTAssertTrue(recovery.text().contains("stopped"))
        }
    }
}
