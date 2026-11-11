import XCTest

@testable import MicDropCore

final class SignalingRouteTests: XCTestCase {
    private let interrupted = ControlIOError(.transportClosed)

    func testFreshConnectVerifiesLANWithoutContactingRendezvous() throws {
        let route = SignalingRoute(remote: true)
        var calls: [String] = []
        try route.initial {
            calls.append("probe")
            return true
        }
        let value = try route.exchange(
            path: "/offer",
            local: { () throws -> Int in
                calls.append("LAN")
                return 1
            },
            rendezvous: { () throws -> Int in
                XCTFail("rendezvous before verified LAN")
                return 0
            },
            probeLocal: {
                XCTFail("second probe")
                return false
            }, cancelled: { false })
        XCTAssertEqual(value, 1)
        XCTAssertEqual(calls, ["probe", "LAN"])
        XCTAssertFalse(route.needsRemoteICE(forceRelay: false))
        XCTAssertTrue(route.needsRemoteICE(forceRelay: true))
        try route.recover()
        XCTAssertFalse(route.direct)
    }

    func testFailedInitialProbeCannotLoopBackToLAN() throws {
        let route = SignalingRoute(remote: true)
        try route.initial { false }
        XCTAssertThrowsError(
            try route.exchange(
                path: "/offer",
                local: { () throws -> Int in
                    XCTFail("unavailable LAN retried")
                    return 0
                },
                rendezvous: { () throws -> Int in throw self.interrupted },
                probeLocal: {
                    XCTFail("probe repeated")
                    return true
                },
                cancelled: { false })
        ) { XCTAssertTrue($0 is SignalingRoutesUnavailable) }
    }

    func testAmbiguousLANOfferRequiresCancellationOnRendezvous() throws {
        let route = SignalingRoute(remote: true)
        try route.initial { true }
        XCTAssertThrowsError(
            try route.exchange(
                path: "/offer", local: { () throws -> Int in throw self.interrupted },
                rendezvous: { () throws -> Int in
                    XCTFail("ambiguous offer replayed")
                    return 0
                }, probeLocal: { false }, cancelled: { false }
            )
        ) { XCTAssertTrue($0 is OfferFallbackRequired) }
        XCTAssertFalse(route.direct)
        XCTAssertEqual(route.fallback, "LAN interrupted")
    }

    func testOnlyAcknowledgedCancellationRotatesOfferNonce() throws {
        let attempt = OfferAttempt(supported: true, nonce: String(repeating: "a", count: 43))
        attempt.begin()
        let old = attempt.header(for: "/offer")
        XCTAssertThrowsError(try attempt.cancelledForFallback(acknowledged: false))
        XCTAssertEqual(old, attempt.header(for: "/cancel-offer"))
        try attempt.cancelledForFallback(acknowledged: true)
        XCTAssertFalse(attempt.needsCancellation(nil))
        XCTAssertNil(attempt.header(for: "/offer"))
        attempt.begin()
        XCTAssertNotEqual(old, attempt.header(for: "/offer"))
        XCTAssertEqual(attempt.header(for: "/offer"), attempt.header(for: "/cancel-offer"))
        XCTAssertThrowsError(try OfferAttempt(supported: false).cancelledForFallback(acknowledged: true))
    }

    func testOnlyProvablyUnsentOfferCanFallBackWithoutCancellation() throws {
        for unsent in [false, true] {
            let route = SignalingRoute(remote: true, initialOrder: .rendezvousFirst)
            try route.initial {
                XCTFail("rendezvous first probed")
                return false
            }
            var offers = 0
            func exchange() throws -> Int {
                try route.exchange(
                    path: "/offer",
                    local: { () throws -> Int in
                        offers += 1
                        return 1
                    },
                    rendezvous: { () throws -> Int in
                        throw unsent ? SignalingRequestNotSent(self.interrupted) as Error : self.interrupted
                    },
                    probeLocal: { true }, cancelled: { false })
            }
            if unsent {
                XCTAssertEqual(try exchange(), 1)
            } else {
                XCTAssertThrowsError(try exchange()) { XCTAssertTrue($0 is OfferFallbackRequired) }
            }
            XCTAssertEqual(offers, unsent ? 1 : 0)
            XCTAssertTrue(route.direct)
        }
    }

    func testAmbiguousAnswerNeverReplaysButUnsentAnswerCanUseVerifiedLAN() throws {
        for unsent in [false, true] {
            let route = SignalingRoute(remote: true)
            var probes = 0
            func exchange() throws -> Int {
                try route.exchange(
                    path: "/answer", local: { () throws -> Int in 1 },
                    rendezvous: { () throws -> Int in
                        throw unsent ? SignalingRequestNotSent(self.interrupted) as Error : self.interrupted
                    },
                    probeLocal: {
                        probes += 1
                        return true
                    }, cancelled: { false })
            }
            if unsent { XCTAssertEqual(try exchange(), 1) } else { XCTAssertThrowsError(try exchange()) }
            XCTAssertEqual(probes, unsent ? 1 : 0)
        }
    }

    func testRepeatableOperationsTryEachRouteOnlyOnce() throws {
        for path in ["/status", "/recover-offer", "/recover-answer", "/microphone", "/stop", "/cancel-offer"] {
            let route = SignalingRoute(remote: true)
            var calls: [String] = []
            XCTAssertThrowsError(
                try route.exchange(
                    path: path,
                    local: { () throws -> Int in
                        calls.append("LAN")
                        throw self.interrupted
                    },
                    rendezvous: { () throws -> Int in
                        calls.append("remote")
                        throw self.interrupted
                    },
                    probeLocal: {
                        calls.append("probe")
                        return true
                    }, cancelled: { false }
                ) as Int
            ) { XCTAssertTrue($0 is SignalingRoutesUnavailable) }
            XCTAssertEqual(calls, ["remote", "probe", "LAN"])
        }
    }

    func testHTTPTrustAndCancellationFailuresNeverTriggerFallback() throws {
        let errors: [Error] = [
            HTTPFailure(403), HTTPFailure(500), HTTPFailure(503),
            SignalingTLSFailure(.windows, .identity), SignalingTLSFailure(.rendezvous, .certificateTime),
            SessionStopped(),
        ]
        for error in errors {
            let route = SignalingRoute(remote: true)
            XCTAssertThrowsError(
                try route.exchange(
                    path: "/status",
                    local: { () throws -> Int in
                        XCTFail("forbidden fallback")
                        return 0
                    }, rendezvous: { () throws -> Int in throw error },
                    probeLocal: {
                        XCTFail("forbidden probe")
                        return true
                    }, cancelled: { false }))
        }
        let route = SignalingRoute(remote: true)
        XCTAssertThrowsError(
            try route.exchange(
                path: "/status",
                local: { () throws -> Int in
                    XCTFail("cancelled fallback")
                    return 0
                },
                rendezvous: { () throws -> Int in throw self.interrupted },
                probeLocal: {
                    XCTFail("cancelled probe")
                    return true
                },
                cancelled: { true }))
    }

    func testHealthyUpgradeIsOneShotAndRecoveryUsesConfiguredOrder() throws {
        let route = SignalingRoute(remote: true)
        try route.upgrade { true }
        XCTAssertTrue(route.direct)
        try route.upgrade {
            XCTFail("repeat healthy probe")
            return false
        }
        try route.recover {
            XCTFail("default recovery must use rendezvous first")
            return true
        }
        XCTAssertFalse(route.direct)
        try route.upgrade { true }
        XCTAssertTrue(route.direct)
        let localFirst = SignalingRoute(remote: true, initialOrder: .rendezvousFirst, recoveryOrder: .lanFirst)
        try localFirst.initial {
            XCTFail("wrong initial order")
            return true
        }
        try localFirst.recover { true }
        XCTAssertTrue(localFirst.direct)
    }

    func testNetworkChangePreventsTransportFallbackAndStillAllowsCleanup() throws {
        for path in ["/status", "/recover-offer", "/recover-answer", "/microphone"] {
            let route = SignalingRoute(remote: true)
            XCTAssertThrowsError(
                try route.exchange(
                    path: path,
                    local: { () throws -> Int in
                        XCTFail("old network LAN")
                        return 0
                    },
                    rendezvous: { () throws -> Int in
                        XCTFail("old network rendezvous")
                        return 0
                    },
                    probeLocal: {
                        XCTFail("old network probe")
                        return true
                    }, cancelled: { false }, networkPending: { true }
                )
            ) { XCTAssertTrue($0 is SignalingNetworkChanged) }
        }
        let route = SignalingRoute(remote: true)
        XCTAssertEqual(
            try route.exchange(
                path: "/stop", local: { () throws -> Int in 1 }, rendezvous: { () throws -> Int in 2 },
                probeLocal: { true },
                cancelled: { false }, networkPending: { true }), 2)
    }

    func testNetworkChangeDuringProbeCannotIssueANewRequest() throws {
        let route = SignalingRoute(remote: true)
        var pending = false
        XCTAssertThrowsError(
            try route.exchange(
                path: "/status",
                local: { () throws -> Int in
                    XCTFail("request issued after handoff")
                    return 0
                },
                rendezvous: { () throws -> Int in throw self.interrupted },
                probeLocal: {
                    pending = true
                    return true
                },
                cancelled: { false }, networkPending: { pending }
            )
        ) { XCTAssertTrue($0 is SignalingNetworkChanged) }
    }

    func testPlainLANDiagnosticsAndExhaustedRoutesClassification() throws {
        let route = SignalingRoute(remote: false)
        try route.initial {
            XCTFail("plain LAN probe")
            return false
        }
        try route.recover()
        XCTAssertEqual(
            try route.exchange(
                path: "/offer", local: { () throws -> Int in 1 },
                rendezvous: { () throws -> Int in
                    XCTFail("plain LAN rendezvous")
                    return 0
                },
                probeLocal: { false }, cancelled: { false }), 1)
        XCTAssertFalse(ConnectionFailure.retryableStatus(SignalingRoutesUnavailable()))
        XCTAssertTrue(ConnectionFailure.retryableStatus(SignalingRoutesUnavailable(), establishedSession: true))
        XCTAssertFalse(ConnectionFailure.retryableStatus(OfferFallbackRequired(), establishedSession: true))
        XCTAssertEqual(SessionFailure.from(SignalingRoutesUnavailable()), .networkIO)
        XCTAssertEqual(
            ConnectionFailure.code(stage: .pairing, error: SignalingRoutesUnavailable()), "SIGNALING_UNAVAILABLE")
    }

    func testHistoryIsBoundedAndSuppressesConsecutiveDuplicates() throws {
        let route = SignalingRoute(remote: true)
        for _ in 0..<20 {
            try route.recover()
            try route.upgrade { true }
        }
        XCTAssertEqual(route.history.count, 8)
        XCTAssertEqual(route.reportRoute("wifi"), "wifi")
        let text = route.text(forceRelay: false)
        XCTAssertTrue(text.contains("Local probe: verified"))
        XCTAssertTrue(text.contains("Signaling history:"))
    }
}
