import MicDropCore
import XCTest

private let a2dp = RouteOutput.PortType.bluetoothA2DP
private let selected = OutputSelection(kind: .bluetooth, portType: a2dp, uid: "synthetic-headset-10")

/// Selected Bluetooth output recovery (b, `BluetoothOutputRecoveryTest.kt`). iOS has no port IDs: Android's "same
/// headset on a recreated port" rebind is the same `(portType, uid)`.
final class OutputBluetoothRecoveryTests: XCTestCase {
    func testRecoveryWaitsTwentySecondsAndRejectsTheOldTracksAcknowledgment() {
        let route = OutputRouteChange(selected)
        let old = route.ticket
        XCTAssertTrue(route.verified(old))
        XCTAssertTrue(route.recoverBluetooth(old, nowMs: 1_000))
        XCTAssertTrue(route.pending)
        XCTAssertTrue(route.recovering)
        XCTAssertFalse(route.verified(old))
        XCTAssertFalse(route.rebind(old, selected))
        XCTAssertFalse(route.expired(20_999))
        XCTAssertTrue(route.expired(21_000))
    }

    func testRepeatedEventsRebindAndTrackRestartCannotExtendTheDeadline() {
        let route = OutputRouteChange(selected)
        route.verified(route.ticket)
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 1_000))
        XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: 9_000))
        XCTAssertTrue(route.rebind(route.ticket, selected))
        route.beginCheck(route.ticket, nowMs: 15_000)
        route.trackStarted()
        route.beginCheck(route.ticket, nowMs: 20_000)
        XCTAssertTrue(route.recovering)
        XCTAssertFalse(route.expired(20_999))
        XCTAssertTrue(route.expired(21_000))
    }

    func testRebindCannotChangeHeadsetProfileOrPhysicalIdentity() {
        let route = OutputRouteChange(selected)
        route.verified(route.ticket)
        route.recoverBluetooth(route.ticket, nowMs: 0)
        XCTAssertFalse(route.rebind(route.ticket, OutputSelection(kind: .bluetooth, portType: a2dp, uid: "other-20")))
        XCTAssertFalse(
            route.rebind(
                route.ticket,
                OutputSelection(kind: .le, portType: RouteOutput.PortType.bluetoothLE, uid: selected.uid)))
        let ticket = route.ticket
        XCTAssertTrue(route.rebind(route.ticket, selected))
        XCTAssertEqual(route.selection, selected)
        XCTAssertEqual(route.ticket, ticket)
    }

    func testRecoveryNeedsAVerifiedCurrentBluetoothPin() {
        // Non-Bluetooth pins and DEFAULT never start the 20 s episode.
        for selection in [
            OutputSelection(), OutputSelection.restored(.phone), OutputSelection.fallbackSpeaker(),
            OutputSelection(kind: .wired, portType: RouteOutput.PortType.headphones, uid: "wired"),
        ] {
            let route = OutputRouteChange(selection)
            route.verified(route.ticket)
            XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: 0), "\(selection)")
        }
        // An LE pin recovers like A2DP.
        let le = OutputRouteChange(OutputSelection(kind: .le, portType: RouteOutput.PortType.bluetoothLE, uid: "le"))
        XCTAssertTrue(le.recoverBluetooth(le.ticket, nowMs: 0))
        // A stale ticket cannot start it either; an unverified initial pin can (a loss during verification).
        let route = OutputRouteChange(selected)
        XCTAssertFalse(route.recoverBluetooth(route.ticket + 1, nowMs: 0))
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 0))
    }

    func testSuccessfulRecoveryPreservesUserSilenceAndAllowsANewIndependentEpisode() {
        for enabled in [false, true] {
            let route = OutputRouteChange(selected)
            var gate = AudioOutputGate(enabled: enabled)
            route.verified(route.ticket)
            route.recoverBluetooth(route.ticket, nowMs: 0)
            gate.hold()
            XCTAssertTrue(gate.muted)
            if route.verified(route.ticket) { gate.verified() }
            XCTAssertEqual(gate.muted, !enabled)
            XCTAssertFalse(route.recovering)
            XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 30_000))
            XCTAssertFalse(route.expired(49_999))
            XCTAssertTrue(route.expired(50_000))
        }
    }

    func testStopOrANewOutputChoiceCancelsTheOriginalRecovery() {
        let route = OutputRouteChange(selected)
        route.verified(route.ticket)
        route.recoverBluetooth(route.ticket, nowMs: 0)
        let old = route.ticket
        XCTAssertTrue(route.request(OutputSelection()))
        XCTAssertFalse(route.recovering)
        XCTAssertFalse(route.verified(old))
        XCTAssertFalse(route.rebind(old, selected))
        XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: 10_000))
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.request(selected))
        route.recoverBluetooth(route.ticket, nowMs: 10_000)
        let stopped = route.ticket
        route.stop()
        XCTAssertFalse(route.verified(stopped))
        XCTAssertFalse(route.rebind(stopped, selected))
        XCTAssertFalse(route.recoverBluetooth(stopped, nowMs: 30_000))
        route.trackStarted()
        XCTAssertFalse(route.pending)
        XCTAssertFalse(route.recovering)
    }

    func testRecoveryPublishesTheSelectedBluetoothPause() {
        let route = OutputRouteChange(selected)
        let policy = DefaultOutputPolicy(selected)
        route.verified(route.ticket)
        XCTAssertNil(
            OutputPause.current(
                usesMediaOutput: true, focus: nil, route: route, policy: policy, bluetoothAvailable: false))
        route.recoverBluetooth(route.ticket, nowMs: 0)
        XCTAssertEqual(
            OutputPause.current(
                usesMediaOutput: true, focus: nil, route: route, policy: policy, bluetoothAvailable: true),
            .selectedBluetooth)
        XCTAssertEqual(
            OutputControlSnapshot.Phase.of(
                closed: false, recovering: route.recovering, pending: route.pending, defaultHeld: policy.held),
            .restoring)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertEqual(
            OutputControlSnapshot.Phase.of(
                closed: false, recovering: route.recovering, pending: route.pending, defaultHeld: policy.held),
            .verified)
    }

    func testSelectedOutputRecoveryLeavesBothDuplexMicrophoneMuteChoicesUsable() {
        for muted in [false, true] {
            for enabled in [false, true] {
                let view = MicrophoneView(
                    session: SessionView(phase: .playing, outputEnabled: enabled, outputPause: .selectedBluetooth),
                    muted: muted, mode: .duplex)
                XCTAssertTrue(view.ownsSession)
                XCTAssertTrue(view.canSetMuted(!muted))
                XCTAssertTrue(view.canChooseInput)
                XCTAssertTrue(view.session.canSetOutput)
                XCTAssertFalse(view.canResume)
            }
        }
    }

    func testSettlingClearsQueuedRecreationWithoutRenewingTheFiniteBudget() {
        let budget = OutputRestartBudget()
        budget.request()
        XCTAssertTrue(budget.take(nowMs: 0))
        budget.request()
        budget.settled()
        XCTAssertFalse(budget.take(nowMs: 1_000))
        budget.request()
        XCTAssertTrue(budget.take(nowMs: 1_000))
        budget.request()
        budget.settled()
        budget.request()
        XCTAssertFalse(budget.take(nowMs: 5_000))
        budget.newRoute()
        budget.request()
        XCTAssertTrue(budget.take(nowMs: 10_000))
    }
}
