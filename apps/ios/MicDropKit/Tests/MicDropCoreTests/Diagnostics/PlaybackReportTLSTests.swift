import XCTest

@testable import MicDropCore

/// The optional `tls_certificate_verification` report member (`PlaybackReportTest.kt`
/// `tlsTrustCountersAreOptionalAndContainOnlyBoundedDiagnostics`; `K:PlaybackReport.kt:37,57`).
final class PlaybackReportTLSTests: XCTestCase {
    private func report(
        mode: StreamMode = .playback, routeSelection: RouteSelectionSnapshot? = nil,
        tlsVerification: TurnTLSTrustSnapshot? = nil
    ) -> PlaybackReport {
        PlaybackReport(
            sequence: 1, capturedAt: "2026-10-25T04:26:18Z", uptimeMs: 10_000, environment: nil,
            state: "Connecting", mediaOutput: "waiting",
            snapshot: PlaybackSnapshot(
                codec: "unavailable", path: "unavailable", values: [], transport: .unavailable),
            recovery: nil, microphone: nil, microphoneProcessing: nil, mode: mode, connection: nil,
            lanRecovery: nil, outputControl: nil, iceGathering: nil, mediaTransport: nil,
            routeSelection: routeSelection, tlsVerification: tlsVerification)
    }

    func testMemberIsAbsentByDefaultAndEqualsTheSnapshotWhenSet() throws {
        let absent = try report().json(includeOutput: false, includeConnection: false, platformEnvironment: false)
        XCTAssertNil(absent["tls_certificate_verification"])
        let trust = TurnTLSTrustSnapshot(checks: 2, failures: 1, lastResult: .trusted)
        let present = try report(tlsVerification: trust).json(
            includeOutput: false, includeConnection: false, platformEnvironment: false)
        XCTAssertEqual(present["tls_certificate_verification"], trust.json())
        XCTAssertEqual(
            present["tls_certificate_verification"]?.keys, ["version", "checks", "failures", "last_result"])
    }

    func testMemberFollowsRouteSelectionAndPrecedesAudioDirection() throws {
        let routes = RouteSelectionSnapshot(local: true, remote: true, generation: 0, switches: 2)
        let trust = TurnTLSTrustSnapshot(checks: 0, failures: 0, lastResult: .notChecked)
        let json = try report(mode: .duplex, routeSelection: routes, tlsVerification: trust).json(
            includeOutput: false, includeConnection: true, platformEnvironment: false)
        let keys = try XCTUnwrap(json.keys)
        XCTAssertEqual(
            Array(keys.suffix(4)), ["route_selection", "tls_certificate_verification", "audio_direction", "connection"])
        let encoded = String(decoding: json.encoded(), as: UTF8.self)
        let member = #"{"version":1,"checks":0,"failures":0,"last_result":"not_checked"}"#
        XCTAssertTrue(encoded.contains(#""tls_certificate_verification":"# + member), encoded)
    }
}
