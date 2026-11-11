import XCTest

@testable import MicDropCore

/// Fixed-label signaling request failure history (`SignalingFailureTest.kt`): route, operation, transport stage,
/// category and elapsed time only.
final class SignalingRequestFailureTests: XCTestCase {
    func testCategoriesUseFixedLabelsThroughWrappers() {
        let cases: [(Error, String)] = [
            (ControlIOError(.timedOut), "timeout"), (SignalingStreamEnded(), "transport_eof"),
            (SessionStopped(), "cancelled"), (ControlIOError(.transportClosed), "network_io"),
            (ControlIOError(.rendezvousFailed), "network_io"),
        ]
        for (error, category) in cases {
            let wrapped = SignalingRequestNotSent(error)
            let text = signalingRequestFailureText(
                direct: false, path: "/status", phase: .waitingForWindows, elapsedMs: 8_123, error: wrapped)
            let expected =
                "route=rendezvous · request=status · phase=waiting_for_windows · category=\(category)"
                + " · elapsed=8123 ms"
            XCTAssertEqual(text, expected)
        }
    }

    func testLabelsCannotExposeArbitraryPathsOrNegativeElapsedTime() {
        let tls = signalingRequestFailureText(
            direct: false, path: "/private-token", phase: .rendezvousConnect, elapsedMs: -5,
            error: SignalingTLSFailure(.rendezvous, .identity))
        let expected =
            "route=rendezvous · request=other · phase=rendezvous_connect · category=tls_rendezvous_identity"
            + " · elapsed=0 ms"
        XCTAssertEqual(tls, expected)
        let http = signalingRequestFailureText(
            direct: true, path: "/microphone", phase: .responseHeaders, elapsedMs: 4, error: HTTPFailure(403))
        XCTAssertTrue(http.contains("category=http_403"), http)
        let handoff = signalingRequestFailureText(
            direct: true, path: "/status", phase: .lanRequest, elapsedMs: 5, error: SignalingNetworkChanged())
        XCTAssertTrue(handoff.hasPrefix("route=lan · request=status · phase=lan_request · category=network_changed"))
    }

    func testHistoryKeepsTheLastFourFailuresWithUptime() {
        var history = SignalingRequestFailures()
        XCTAssertNil(history.text)
        for index in 1...5 { history.record(uptimeMs: Int64(index) * 1_000, "failure \(index)") }
        XCTAssertEqual(
            history.entries,
            ["2000 ms · failure 2", "3000 ms · failure 3", "4000 ms · failure 4", "5000 ms · failure 5"])
        let lines = history.text?.components(separatedBy: "\n") ?? []
        XCTAssertEqual(lines.first, "Recent signaling request failures (phone uptime):")
        XCTAssertEqual(lines.count, 5)
    }

    func testProgressOnlyMovesForwardAndTravelsWithTheHandle() {
        let progress = SignalingRequestProgress(.rendezvousConnect)
        progress.advance(to: .windowsTLS)
        progress.advance(to: .waitingForWindows)
        XCTAssertEqual(progress.phase, .windowsTLS, "a reordered callback cannot regress the stage")
        progress.advance(to: .responseBody)
        XCTAssertEqual(progress.phase, .responseBody)
        let handle = ControlRequestHandle(progress: progress) {}
        XCTAssertTrue(handle.progress === progress)
        let plain = ControlRequestHandle {}
        XCTAssertNil(plain.progress)
    }
}
