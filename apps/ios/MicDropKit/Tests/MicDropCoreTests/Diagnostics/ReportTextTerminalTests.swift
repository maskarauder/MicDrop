import XCTest

@testable import MicDropCore

/// Terminal copy-report refresh (`StreamReceiver.kt:839-866`): request failures, the worker's current recovery state
/// and fresh signaling lines, with or without a periodic snapshot.
final class ReportTextTerminalTests: XCTestCase {
    func testSetupFailureWithoutPeriodicSnapshotStillReportsFailuresAndRecovery() {
        var failures = SignalingRequestFailures()
        failures.record(uptimeMs: 9_000, "route=rendezvous · request=offer")
        let snapshot = ReportText.refreshedFinalSnapshot(
            "", headsetLines: nil, outputRecoveryText: nil, signalingFailureText: nil,
            requestFailuresText: failures.text, recoveryText: LanRecovery(supported: false).text(),
            recoveryRemainingMs: 10_000, offerReply: .none)
        let lines = snapshot.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("Recent signaling request failures (phone uptime):"), snapshot)
        XCTAssertTrue(lines.contains("9000 ms · route=rendezvous · request=offer"), snapshot)
        XCTAssertTrue(lines.contains("Media recovery: not negotiated (no Windows offer reply)"), snapshot)
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("Recovery time remaining:") }), snapshot)
        let delivery = ReportText.TerminalDelivery.delivery(reply: .none, connectionNegotiated: false)
        XCTAssertEqual(delivery, "not sent; no Windows offer reply")
        let report = ReportText.terminal(
            finalSnapshot: snapshot, signalingText: "Signaling: HTTPS rendezvous", result: "Stopped",
            terminal: nil, delivery: delivery)
        let tail =
            "Media recovery: not negotiated (no Windows offer reply)\nSignaling: HTTPS rendezvous\n\nSession result: Stopped"
        XCTAssertTrue(report.contains(tail), report)
        XCTAssertTrue(report.hasSuffix("Windows terminal diagnostics: not sent; no Windows offer reply"), report)
    }

    func testTerminalDeliveryAndMediaRecoveryLabelsDistinguishNoOfferRejectedAndAccepted() {
        XCTAssertEqual(
            ReportText.TerminalDelivery.delivery(reply: .none, connectionNegotiated: false),
            "not sent; no Windows offer reply")
        XCTAssertEqual(
            ReportText.TerminalDelivery.delivery(reply: .none, connectionNegotiated: true),
            "not sent; no Windows offer reply")
        XCTAssertEqual(
            ReportText.TerminalDelivery.delivery(reply: .rejected, connectionNegotiated: false),
            "not sent; Windows offer reply rejected")
        XCTAssertEqual(
            ReportText.TerminalDelivery.delivery(reply: .accepted, connectionNegotiated: false),
            "not requested by Windows (older Windows or logging off)")
        XCTAssertEqual(
            ReportText.TerminalDelivery.delivery(reply: .accepted, connectionNegotiated: true),
            "not confirmed")

        XCTAssertEqual(
            ReportText.TerminalDelivery.mediaRecovery(
                reply: .none, recoveryText: LanRecovery(supported: false).text(), recoveryRemainingMs: 10_000),
            "Media recovery: not negotiated (no Windows offer reply)")
        XCTAssertEqual(
            ReportText.TerminalDelivery.mediaRecovery(
                reply: .rejected, recoveryText: LanRecovery(supported: false).text(), recoveryRemainingMs: 10_000),
            "Media recovery: not negotiated (Windows offer reply rejected)")
        XCTAssertEqual(
            ReportText.TerminalDelivery.mediaRecovery(
                reply: .accepted, recoveryText: LanRecovery(supported: false).text(), recoveryRemainingMs: 10_000),
            "Media recovery: settled · ICE restarts requested: 0 · Window: 10 seconds\nRecovery time remaining: 10000 ms"
        )
    }

    func testStaleSignalingAndRecoveryLinesAreReplaced() {
        let periodic = [
            "Playback snapshot: earlier",
            "Signaling: direct LAN · Local probe: verified · Fallback: none",
            "Cellular media candidates: allowed · Force TURN relay: false",
            "Signaling history: Connect: LAN verified",
            "LAN signaling route: wifi · Cellular media candidates: excluded",
            "Media recovery: settled · ICE restarts requested: 0 · Window: 30 seconds",
            "Network handoffs detected: 1 · Signaling: rendezvous · Default network: wifi",
        ].joined(separator: "\n")
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        recovery.observe(healthy: false, now: 100)
        let snapshot = ReportText.refreshedFinalSnapshot(
            periodic, headsetLines: nil, outputRecoveryText: nil, signalingFailureText: nil,
            requestFailuresText: nil, recoveryText: recovery.text(), recoveryRemainingMs: recovery.remaining(10_100))
        let lines = snapshot.components(separatedBy: "\n")
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("Signaling") }), snapshot)
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("Cellular media candidates:") }), snapshot)
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("LAN signaling route:") }), snapshot)
        let recoveryLines = lines.filter { $0.hasPrefix("Media recovery:") }
        XCTAssertEqual(recoveryLines, ["Media recovery: recovering · ICE restarts requested: 0 · Window: 30 seconds"])
        XCTAssertTrue(lines.contains("Network handoffs detected: 1 · Signaling: rendezvous · Default network: wifi"))
        XCTAssertEqual(lines.first, "Playback snapshot: earlier")
        XCTAssertEqual(lines.last, "Recovery time remaining: 20000 ms")
    }
}
