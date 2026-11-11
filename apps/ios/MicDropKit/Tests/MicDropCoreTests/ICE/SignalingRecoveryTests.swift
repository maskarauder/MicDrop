import XCTest

@testable import MicDropCore

/// Bounded established-session signaling retries (`SignalingRecoveryTest.kt`): the failed request is charged to the
/// original window, retries restore rendezvous priority, and startup, Stop and security failures never enter this
/// recovery.
final class SignalingRecoveryTests: XCTestCase {
    private let interrupted = ControlIOError(.transportClosed)

    func testFadedWifiWithoutCallbackCanRecoverTheSameSessionOnRendezvous() throws {
        let route = SignalingRoute(remote: true)
        try route.initial { true }
        try route.upgrade { false }
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        var calls: [String] = []
        var now: Int64 = 100
        let attemptedAt = now
        var failure: Error?
        XCTAssertThrowsError(
            try route.exchange(
                path: "/status",
                local: { () throws -> Int in
                    calls.append("lan")
                    now += 2_000
                    throw ControlIOError(.timedOut)
                },
                rendezvous: { () throws -> Int in
                    calls.append("rendezvous")
                    now += 8_000
                    throw ControlIOError(.timedOut)
                },
                probeLocal: {
                    calls.append("probe")
                    now += 1_500
                    return false
                }, cancelled: { false })
        ) { failure = $0 }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error is SignalingRoutesUnavailable)
        XCTAssertTrue(recovery.signalingFailed(error, attemptedAt: attemptedAt))
        XCTAssertEqual(recovery.remaining(now), 18_500, "the failed request's start is charged")
        try route.recover()
        let result = try recovery.exchangeStatus(
            now: { now }, beforeRestart: { try route.recover() },
            restore: {
                _ = try route.exchange(
                    path: "/recover-offer",
                    local: { () throws -> Int in
                        XCTFail("LAN before rendezvous")
                        return 0
                    },
                    rendezvous: { () throws -> Int in
                        calls.append("recover")
                        return 1
                    }, probeLocal: { false }, cancelled: { false })
                recovery.answer = "same session answer"
                try recovery.accepted(now)
            }, poll: { "connected" })
        XCTAssertEqual(result, "connected")
        XCTAssertEqual(calls, ["lan", "rendezvous", "probe", "recover"])
        XCTAssertEqual(recovery.generation, 1)
        XCTAssertTrue(recovery.observe(healthy: true, now: now))
        XCTAssertFalse(recovery.active)
    }

    func testRepeatedRouteFailuresAndLateCallbackCannotExtendTheDeadline() throws {
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        XCTAssertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), attemptedAt: 100))
        try recovery.begin(1_100)
        recovery.answer = "prepared"
        XCTAssertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), attemptedAt: 15_000))
        recovery.networkChanged(25_000)
        XCTAssertEqual(recovery.remaining(25_000), 5_100)
        XCTAssertEqual(recovery.generation, 1)
        XCTAssertEqual(recovery.answer, "prepared")
        XCTAssertThrowsError(
            try recovery.exchangeStatus(
                now: { 30_100 }, beforeRestart: { XCTFail("new offer after deadline") },
                restore: { XCTFail("answer after deadline") }, poll: { XCTFail("status after deadline") })
        ) { XCTAssertTrue(ConnectionFailure.isTimeout($0)) }
        XCTAssertFalse(recovery.observe(healthy: true, now: 30_100))
    }

    func testFailedLanFallbackRetriesRendezvousWithThePreparedAnswer() throws {
        let route = SignalingRoute(remote: true)
        try route.recover()
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        recovery.networkChanged(100)
        try recovery.begin(100)
        recovery.answer = "unchanged answer"
        var calls: [String] = []
        var failure: Error?
        XCTAssertThrowsError(
            try recovery.exchangeStatus(
                now: { 200 }, beforeRestart: { XCTFail("new generation") },
                restore: {
                    _ = try route.exchange(
                        path: "/recover-answer",
                        local: { () throws -> Int in
                            calls.append("lan")
                            throw self.interrupted
                        },
                        rendezvous: { () throws -> Int in
                            calls.append("rendezvous")
                            throw self.interrupted
                        }, probeLocal: { true }, cancelled: { false })
                }, poll: { XCTFail("unacknowledged answer") })
        ) { failure = $0 }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error is SignalingRoutesUnavailable)
        XCTAssertTrue(route.direct)
        XCTAssertTrue(recovery.signalingFailed(error, attemptedAt: 200))
        try route.recover()
        try recovery.exchangeStatus(
            now: { 700 }, beforeRestart: { XCTFail("new generation") },
            restore: {
                XCTAssertEqual(recovery.answer, "unchanged answer")
                _ = try route.exchange(
                    path: "/recover-answer",
                    local: { () throws -> Int in
                        XCTFail("sticky LAN fallback")
                        return 0
                    },
                    rendezvous: { () throws -> Int in
                        calls.append("retry rendezvous")
                        return 1
                    }, probeLocal: { false }, cancelled: { false })
                try recovery.accepted(700)
            }, poll: { calls.append("confirm") })
        XCTAssertEqual(calls, ["rendezvous", "lan", "retry rendezvous", "confirm"])
        XCTAssertEqual(recovery.generation, 1)
    }

    func testStartupStopAndSecurityFailuresNeverEnterThisRecovery() {
        let startup = LanRecovery(supported: true)
        XCTAssertFalse(startup.signalingFailed(SignalingRoutesUnavailable(), attemptedAt: 0))
        XCTAssertFalse(startup.active)
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        for error in [SignalingRoutesUnavailable(), interrupted] as [Error] {
            XCTAssertFalse(recovery.signalingFailed(error, attemptedAt: 1, stopped: true))
        }
        let rejected: [Error] = [
            HTTPFailure(401), HTTPFailure(403), HTTPFailure(409), HTTPFailure(410), HTTPFailure(423),
            SignalingTLSFailure(.windows, .handshake), SignalingTLSFailure(.rendezvous, .certificateTime),
            OfferFallbackRequired(), SessionStopped(),
        ]
        for error in rejected { XCTAssertFalse(recovery.signalingFailed(error, attemptedAt: 1)) }
        XCTAssertFalse(recovery.active)
        XCTAssertTrue(recovery.signalingFailed(SignalingRequestNotSent(SignalingRoutesUnavailable()), attemptedAt: 1))
    }

    func testOrdinaryCellularControlFailureDoesNotRequireAnIceDisconnect() {
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        XCTAssertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), attemptedAt: 100))
        XCTAssertTrue(recovery.active)
        XCTAssertTrue(recovery.restartDue(1_100))
        // No successful control response: retries cannot silently reset the clock.
        for index in 0..<5 {
            let attemptedAt = 1_000 + Int64(index) * 4_000
            XCTAssertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), attemptedAt: attemptedAt))
        }
        XCTAssertEqual(recovery.remaining(20_000), 10_100)
    }

    func testHandoffCancelledRequestIsChargedFromItsStart() {
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: 0)
        // A heartbeat started at 1 s and cancelled by a handoff at 7 s keeps the 1 s start.
        XCTAssertTrue(recovery.signalingFailed(SignalingNetworkChanged(), attemptedAt: 1_000))
        recovery.networkChanged(7_000)
        XCTAssertTrue(recovery.restartRequested)
        XCTAssertEqual(recovery.remaining(7_000), recovery.limitMs - 6_000)
    }

    func testRecoveryTextAndExhaustedRouteLabelMatchAndroid() {
        XCTAssertEqual(
            LanRecovery(supported: true, limitMs: 7_500).text(),
            "LAN media recovery: settled · ICE restarts requested: 0 · Window: 7.5 seconds")
        XCTAssertTrue(LanRecovery(supported: false).text().hasSuffix(" · Window: 10 seconds"))
        let exhausted = ConnectionFailure.describe(stage: .playback, error: SignalingRoutesUnavailable())
        XCTAssertTrue(exhausted.hasPrefix("Connection control failed [SIGNALING_UNAVAILABLE].\n"), exhausted)
        let wrapped = ConnectionFailure.describe(
            stage: .pairing, error: SignalingRequestNotSent(SignalingRoutesUnavailable()))
        XCTAssertTrue(wrapped.hasPrefix("Connection control failed [SIGNALING_UNAVAILABLE]."), wrapped)
        let tls = ConnectionFailure.describe(stage: .playback, error: SignalingTLSFailure(.windows, .identity))
        XCTAssertTrue(tls.hasPrefix("Secure signaling failed [TLS_IDENTITY]."), tls)
        let timeout = ConnectionFailure.describe(stage: .playback, error: ControlIOError(.timedOut))
        XCTAssertTrue(timeout.hasPrefix("Receiving audio failed [TIMEOUT]."), timeout)
    }
}
