import XCTest

@testable import MicDropCore

/// Periodic copy-report order for the TURN/TLS trust lines (`StreamReceiver.kt:809-811`): after the initial
/// gathering line, before trickle/continuous ICE and route selection. Also the muted-capture line of microphone
/// reports (`StreamReceiver.kt:781-783` on main `87b15af`): right after the microphone lines, before the codec.
final class ReportTextPeriodicTests: XCTestCase {
    private static let gathering = "Initial iPhone ICE gathering: complete"
    private static let trickle = "Trickle ICE: complete"
    private static let routes = "Route renomination: not negotiated"
    private static let trust = TurnTLSTrustSnapshot(checks: 0, failures: 0, lastResult: .notChecked).text()
    private static let microphone = MicrophoneSnapshot(
        state: "muted", route: "USB microphone", sampleRate: 48_000, channels: 1, requestedRoute: "USB microphone",
        routeVerified: true)
    private static let advancedAudio = AdvancedAudioPreferences.text(
        bluetoothRecoveryMs: 7_500, keepMicrophoneActiveWhileMuted: true)

    private func periodic(
        mode: StreamMode = .playback, iceGatheringText: String?, tlsTrustText: String?,
        mutedCaptureText: String? = nil
    ) -> [String] {
        let input = ReportText.Periodic(
            mode: mode, capturedAt: "2026-10-25T04:26:18Z", environment: nil, state: "Connected",
            mediaOutput: "running", deliveryText: "Reports: sent to Windows", host: ReportText.HostFigures(),
            snapshot: PlaybackSnapshot(codec: "Opus", path: "relay / udp", values: [], transport: .unavailable),
            connection: ConnectionSnapshot(peer: "connected", ice: "connected", host: "connected", runtime: nil),
            signalingText: ReportText.remoteSignaling(forceRelay: true) + "\n" + Self.advancedAudio,
            lanRecoveryText: "Media recovery: settled", routeSelectionText: Self.routes, phoneTurnText: "udp",
            hostTurnText: "udp", outputEnabled: true, microphoneText: mode.hasMicrophone ? Self.microphone.text() : nil,
            mutedCaptureText: mutedCaptureText, iceGatheringText: iceGatheringText, tlsTrustText: tlsTrustText,
            trickleText: Self.trickle)
        return ReportText.periodic(input).components(separatedBy: "\n")
    }

    func testMutedCaptureLineFollowsTheMicrophoneLinesInMicrophoneAndDuplexReports() throws {
        for (option, retained) in [(true, false), (true, true), (false, false)] {
            let text = AdvancedAudioPreferences.mutedCaptureText(option: option, retained: retained)
            for mode in [StreamMode.microphone, .duplex] {
                let lines = periodic(mode: mode, iceGatheringText: nil, tlsTrustText: nil, mutedCaptureText: text)
                let microphone = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Microphone: ") }, "\(mode)")
                XCTAssertEqual(
                    Array(lines[microphone...].prefix(4)),
                    [
                        "Microphone: muted \u{00B7} Input: USB microphone \u{00B7} 48000 Hz / 1 channels",
                        "Selected input: USB microphone \u{00B7} Route verified: true",
                        text,
                        "Codec: Opus \u{00B7} Media path: relay / udp",
                    ], "\(mode)")
                XCTAssertEqual(lines.filter { $0.hasPrefix("Muted capture option:") }.count, 1, "\(mode)")
                XCTAssertTrue(lines.contains(Self.advancedAudio), "the Advanced audio line is unchanged")
            }
        }
    }

    func testPlaybackReportsHaveNoMutedCaptureLine() {
        let text = AdvancedAudioPreferences.mutedCaptureText(option: true, retained: true)
        for mutedCapture in [nil, text] {
            let lines = periodic(iceGatheringText: nil, tlsTrustText: nil, mutedCaptureText: mutedCapture)
            XCTAssertFalse(lines.contains { $0.hasPrefix("Muted capture option:") })
            XCTAssertTrue(lines.contains(Self.advancedAudio))
        }
    }

    func testTrustLinesFollowInitialGatheringAndPrecedeTrickle() throws {
        let lines = periodic(iceGatheringText: Self.gathering, tlsTrustText: Self.trust)
        let gathering = try XCTUnwrap(lines.firstIndex(of: Self.gathering))
        XCTAssertEqual(
            Array(lines[gathering...].prefix(4)),
            [
                Self.gathering,
                "iPhone TURN/TLS trust fallback: checks=0 \u{00B7} failures=0 \u{00B7} last=not_checked",
                "Certificate-chain checks do not prove hostname validation, TURN allocation or media delivery.",
                Self.trickle,
            ])
    }

    func testTrustLinesPrecedeRouteSelectionWithoutGatheringText() throws {
        let lines = periodic(iceGatheringText: nil, tlsTrustText: Self.trust)
        let trust = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("iPhone TURN/TLS trust fallback:") })
        let trickle = try XCTUnwrap(lines.firstIndex(of: Self.trickle))
        let routes = try XCTUnwrap(lines.firstIndex(of: Self.routes))
        XCTAssertEqual(trickle, trust + 2)
        XCTAssertLessThan(trickle, routes)
    }

    func testOutputIsUnchangedWithoutTrustText() {
        let without = periodic(iceGatheringText: Self.gathering, tlsTrustText: nil)
        let withTrust = periodic(iceGatheringText: Self.gathering, tlsTrustText: Self.trust)
        XCTAssertEqual(withTrust.filter { !Self.trust.components(separatedBy: "\n").contains($0) }, without)
        XCTAssertFalse(without.contains { $0.contains("TURN/TLS trust") })
    }
}
