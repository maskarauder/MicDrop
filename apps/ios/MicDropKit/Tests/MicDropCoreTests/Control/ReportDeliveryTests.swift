import Foundation
import XCTest

@testable import MicDropCore

/// Report upload state and the report-only `/status` fallback (`A/PlaybackReport.kt:65-106`,
/// `PlaybackReportTest.kt:16-28,131-214`): a rejected report is retried once without `android`, keeping the
/// exact `phone_control`, `ice` and `continuous_ice` values; Stop, authentication, expiry and transport failures
/// are never retried or hidden.
final class ReportDeliveryTests: XCTestCase {
    private static let report: DiagnosticJSON = .object([(key: "sequence", value: .int(7))])
    private static let update: DiagnosticJSON = .object([
        (key: "version", value: .int(1)), (key: "generation", value: .int(2)), (key: "revision", value: .int(3)),
    ])
    /// A stand-in `phone_control` member (its content is the adapter's concern, never inspected here).
    private static let snapshot: DiagnosticJSON = .object([
        (key: "version", value: .int(1)), (key: "enabled", value: .bool(false)),
    ])
    /// `stopped` of a session that is still running.
    private static let running: () -> Bool = { false }

    /// `value` as the `ice` or `continuous_ice` argument; `field == nil` attaches no ICE member.
    private static func members(
        _ field: String?, _ value: DiagnosticJSON
    ) -> (ice: DiagnosticJSON?, continuous: DiagnosticJSON?) {
        (field == "ice" ? value : nil, field == "continuous_ice" ? value : nil)
    }

    /// The error `run` throws, or nil when it returns.
    private func failure(_ run: () throws -> Void) -> Error? {
        do {
            try run()
            return nil
        } catch {
            return error
        }
    }

    /// Kotlin `assertSame` for message-free value errors: same concrete type and value.
    private func assertSame(_ error: Error?, _ expected: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error else {
            XCTFail("nothing thrown, expected \(expected)", file: file, line: line)
            return
        }
        XCTAssertEqual(ObjectIdentifier(type(of: error)), ObjectIdentifier(type(of: expected)), file: file, line: line)
        XCTAssertEqual(String(reflecting: error), String(reflecting: expected), file: file, line: line)
    }

    // MARK: - reject / acknowledge

    func testSchemaRejectionFallsBackWithoutMaskingSessionErrors() {
        XCTAssertEqual(ReportDelivery.rejectStatuses, [400, 404, 405, 409, 413, 422])
        for status in [400, 404, 405, 409, 413, 422] {
            let delivery = ReportDelivery(version: 1)
            XCTAssertTrue(delivery.reject(status: status), "\(status)")
            XCTAssertFalse(delivery.enabled, "\(status)")
            XCTAssertEqual(delivery.text, ReportDelivery.unavailableText)
        }
        for status in [401, 410, 429, 500, 503] {
            let delivery = ReportDelivery(version: 1)
            XCTAssertFalse(delivery.reject(status: status), "\(status)")
            XCTAssertTrue(delivery.enabled, "\(status)")
            XCTAssertEqual(delivery.text, ReportDelivery.waitingText)
        }
    }

    func testNegotiationAndAcknowledgement() {
        let legacy = ReportDelivery(version: 0)
        XCTAssertFalse(legacy.enabled)
        XCTAssertEqual(legacy.text, ReportDelivery.notNegotiatedText)

        let accepted = ReportDelivery(version: 1)
        accepted.acknowledge(status: "accepted", sequence: 4, expected: 4)
        XCTAssertTrue(accepted.enabled)
        XCTAssertEqual(accepted.text, ReportDelivery.acceptedText)

        let busy = ReportDelivery(version: 1)
        busy.acknowledge(status: "busy", sequence: 4, expected: 4)
        XCTAssertTrue(busy.enabled, "a busy log keeps reporting")
        XCTAssertEqual(busy.text, ReportDelivery.busyText)

        let rows: [(status: String, sequence: Int64)] = [
            ("accepted", 3), ("accepted", -1), ("rejected", 4), ("", 4), ("disabled", 4), ("full", 4),
            ("unavailable", 4), ("closed", 4), ("not_recorded", 3), ("NOT_RECORDED", 4),
        ]
        for row in rows {
            let delivery = ReportDelivery(version: 1)
            delivery.acknowledge(status: row.status, sequence: row.sequence, expected: 4)
            XCTAssertFalse(delivery.enabled, "\(row)")
            XCTAssertEqual(delivery.text, ReportDelivery.unavailableText, "\(row)")
        }
    }

    /// `PlaybackReportTest.liveTelemetryAcknowledgmentDoesNotClaimThatALogWasSaved`: a phone-control host
    /// acknowledges every report it neither accepted nor found busy as `not_recorded` (no log, or a full, failed or
    /// closed log; `server.go:410-414`); reporting stays on so the Windows device row keeps updating, and the text
    /// never claims a saved log.
    func testLiveTelemetryAcknowledgmentDoesNotClaimThatALogWasSaved() {
        XCTAssertEqual(ReportDelivery.notRecordedText, "Live status shared with Windows; not saved to a log")
        let delivery = ReportDelivery(version: 1)
        delivery.acknowledge(status: "not_recorded", sequence: 4, expected: 4)
        XCTAssertTrue(delivery.enabled)
        XCTAssertEqual(delivery.text, ReportDelivery.notRecordedText)
        delivery.acknowledge(status: "not_recorded", sequence: 4, expected: 4)
        XCTAssertTrue(delivery.enabled, "every later live acknowledgment keeps reporting")
        delivery.acknowledge(status: "accepted", sequence: 5, expected: 5)
        XCTAssertEqual(delivery.text, ReportDelivery.acceptedText, "logging turned back on")
        delivery.acknowledge(status: "not_recorded", sequence: 4, expected: 5)
        XCTAssertFalse(delivery.enabled)
        XCTAssertEqual(delivery.text, ReportDelivery.unavailableText)
    }

    // MARK: - exchangeStatus

    func testAnAcceptedBodyIsSentOnceUnchanged() throws {
        let delivery = ReportDelivery(version: 1)
        var bodies: [DiagnosticJSON?] = []
        let response = try delivery.exchangeStatus(
            version: 3, report: Self.report, ice: nil, continuousIce: Self.update, stopped: Self.running
        ) { (body: DiagnosticJSON?) -> String in
            bodies.append(body)
            return "ok"
        }
        XCTAssertEqual(response, "ok")
        XCTAssertEqual(bodies, [StatusBody.make(version: 3, report: Self.report, continuousIce: Self.update)])
        XCTAssertTrue(delivery.enabled)
    }

    func testRejectedReportRetriesWithoutDroppingOrRegeneratingIce() throws {
        for field in [nil, "ice", "continuous_ice"] as [String?] {
            let delivery = ReportDelivery(version: 1)
            let (ice, continuous) = Self.members(field, Self.update)
            let first = StatusBody.make(version: 3, report: Self.report, ice: ice, continuousIce: continuous)
            var calls = 0
            let response = try delivery.exchangeStatus(
                version: 3, report: Self.report, ice: ice, continuousIce: continuous, stopped: Self.running
            ) { (body: DiagnosticJSON?) throws -> String in
                calls += 1
                if calls == 1 {
                    XCTAssertEqual(body, first)
                    XCTAssertEqual(body?.keys, ["version", StatusBody.reportKey] + (field.map { [$0] } ?? []))
                    throw HTTPFailure(400)
                }
                if let field {
                    XCTAssertEqual(body?.keys, ["version", field])
                    XCTAssertEqual(body?["version"], .int(3))
                    XCTAssertEqual(body?[field], Self.update, "the same ICE value, never re-observed")
                } else {
                    XCTAssertNil(body, "only version remains: a body-less GET")
                }
                return "accepted"
            }
            XCTAssertEqual(response, "accepted", "\(String(describing: field))")
            XCTAssertEqual(calls, 2, "\(String(describing: field))")
            XCTAssertFalse(delivery.enabled, "\(String(describing: field))")
            XCTAssertEqual(delivery.text, ReportDelivery.unavailableText)
        }
    }

    func testIceRejectionAfterRemovingReportIsStillFatal() {
        let stale: DiagnosticJSON = .object([(key: "generation", value: .int(99))])
        for field in ["ice", "continuous_ice"] {
            let delivery = ReportDelivery(version: 1)
            let (ice, continuous) = Self.members(field, stale)
            var calls = 0
            let error = failure {
                try delivery.exchangeStatus(
                    version: 3, report: Self.report, ice: ice, continuousIce: continuous, stopped: Self.running
                ) { (body: DiagnosticJSON?) throws -> Void in
                    calls += 1
                    XCTAssertEqual(body?[field], stale)
                    if calls == 1 { throw HTTPFailure(400) }
                    XCTAssertNil(body?[StatusBody.reportKey])
                    throw HTTPFailure(422)
                }
            }
            assertSame(error, HTTPFailure(422))
            XCTAssertEqual(calls, 2, field)
        }
        // Without ICE the retry is a GET, and its failure is the session's failure.
        let delivery = ReportDelivery(version: 1)
        var calls = 0
        let error = failure {
            try delivery.exchangeStatus(
                version: 3, report: Self.report, ice: nil, continuousIce: nil, stopped: Self.running
            ) { (body: DiagnosticJSON?) throws -> Void in
                calls += 1
                if calls == 1 { throw HTTPFailure(400) }
                XCTAssertNil(body)
                throw HTTPFailure(401)
            }
        }
        assertSame(error, HTTPFailure(401))
        XCTAssertEqual(calls, 2)
    }

    func testReportFallbackDoesNotRetryAuthenticationExpiryOrTransportFailures() {
        let failures: [Error] = [
            HTTPFailure(401), HTTPFailure(403), HTTPFailure(410), HTTPFailure(429), HTTPFailure(500),
            HTTPFailure(503), ControlIOError(.timedOut), SignalingTLSFailure(.windows, .handshake), SessionStopped(),
            CancellationError(), SignalingNetworkChanged(), SignalingRoutesUnavailable(),
        ]
        for thrown in failures {
            let delivery = ReportDelivery(version: 1)
            var calls = 0
            let error = failure {
                try delivery.exchangeStatus(
                    version: 3, report: Self.report, ice: nil, continuousIce: Self.update, stopped: Self.running
                ) { (_: DiagnosticJSON?) throws -> Void in
                    calls += 1
                    throw thrown
                }
            }
            assertSame(error, thrown)
            XCTAssertEqual(calls, 1, "\(thrown)")
            XCTAssertTrue(delivery.enabled, "\(thrown)")
        }
    }

    // MARK: - Phone settings snapshot (`phone_control`)

    /// Android's member order (`StreamReceiver.kt:688-693`); a snapshot alone is a POST (`server.go:302`), and a
    /// body with nothing but `version` stays a GET.
    func testStatusBodyOrdersTheSettingsSnapshotFirstAndSendsItAlone() {
        let full = StatusBody.make(
            version: 3, phoneControl: Self.snapshot, report: Self.report, ice: Self.update, continuousIce: Self.update)
        XCTAssertEqual(
            full?.keys, ["version", StatusBody.phoneControlKey, StatusBody.reportKey, "ice", "continuous_ice"])
        XCTAssertEqual(full?[StatusBody.phoneControlKey], Self.snapshot)
        let alone = StatusBody.make(version: 3, phoneControl: Self.snapshot, report: nil)
        XCTAssertEqual(alone?.keys, ["version", "phone_control"])
        XCTAssertEqual(alone?["version"], .int(3))
        XCTAssertNil(StatusBody.make(version: 3, phoneControl: nil, report: nil))
        XCTAssertEqual(
            StatusBody.make(version: 3, report: Self.report, continuousIce: Self.update)?.keys,
            ["version", "android", "continuous_ice"], "no member is added without a snapshot")
    }

    /// `PlaybackReportTest.diagnosticsFallbackPreservesTheSettingsSnapshot`: the report-less retry removes only
    /// `android` and keeps the exact snapshot (and any ICE value); a rejection of the retry still propagates.
    func testDiagnosticsFallbackPreservesTheSettingsSnapshot() throws {
        for field in [nil, "ice", "continuous_ice"] as [String?] {
            let delivery = ReportDelivery(version: 1)
            let (ice, continuous) = Self.members(field, Self.update)
            var calls = 0
            try delivery.exchangeStatus(
                version: 3, phoneControl: Self.snapshot, report: Self.report, ice: ice, continuousIce: continuous,
                stopped: Self.running
            ) { (body: DiagnosticJSON?) throws -> Void in
                calls += 1
                if calls == 1 {
                    XCTAssertEqual(
                        body?.keys, ["version", "phone_control", StatusBody.reportKey] + (field.map { [$0] } ?? []))
                    throw HTTPFailure(400)
                }
                XCTAssertEqual(body?.keys, ["version", "phone_control"] + (field.map { [$0] } ?? []))
                XCTAssertEqual(body?[StatusBody.phoneControlKey], Self.snapshot, "the same snapshot, never rebuilt")
                if let field { XCTAssertEqual(body?[field], Self.update) }
            }
            XCTAssertEqual(calls, 2, "\(String(describing: field))")
            XCTAssertFalse(delivery.enabled)
        }
        let delivery = ReportDelivery(version: 1)
        var calls = 0
        let error = failure {
            try delivery.exchangeStatus(
                version: 3, phoneControl: Self.snapshot, report: Self.report, ice: nil, continuousIce: nil,
                stopped: Self.running
            ) { (body: DiagnosticJSON?) throws -> Void in
                calls += 1
                XCTAssertEqual(body?[StatusBody.phoneControlKey], Self.snapshot)
                throw HTTPFailure(calls == 1 ? 400 : 422)
            }
        }
        assertSame(error, HTTPFailure(422))
        XCTAssertEqual(calls, 2)
    }

    /// A snapshot without a report never enters the report fallback: the host's rejection of the snapshot (or of
    /// the ICE beside it) is the session's failure, and reporting stays enabled.
    func testASnapshotWithoutAReportIsNotRetried() {
        for ice in [nil, Self.update] as [DiagnosticJSON?] {
            let delivery = ReportDelivery(version: 1)
            var calls = 0
            let error = failure {
                try delivery.exchangeStatus(
                    version: 3, phoneControl: Self.snapshot, report: nil, ice: ice, continuousIce: nil,
                    stopped: Self.running
                ) { (body: DiagnosticJSON?) throws -> Void in
                    calls += 1
                    XCTAssertEqual(
                        body, StatusBody.make(version: 3, phoneControl: Self.snapshot, report: nil, ice: ice))
                    throw HTTPFailure(400)
                }
            }
            assertSame(error, HTTPFailure(400))
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(delivery.enabled)
        }
    }

    func testStopAndRequestsWithoutDiagnosticsCannotEnterReportFallback() {
        let cases: [(report: DiagnosticJSON?, ice: DiagnosticJSON?, continuous: DiagnosticJSON?)] = [
            (nil, nil, nil), (nil, Self.update, nil), (nil, nil, Self.update), (Self.report, nil, nil),
        ]
        for members in cases {
            let delivery = ReportDelivery(version: 1)
            var calls = 0
            var stopped = false
            let isStopped = { stopped }
            let error = failure {
                try delivery.exchangeStatus(
                    version: 3, report: members.report, ice: members.ice, continuousIce: members.continuous,
                    stopped: isStopped
                ) { (body: DiagnosticJSON?) throws -> Void in
                    calls += 1
                    XCTAssertEqual(
                        body,
                        StatusBody.make(
                            version: 3, report: members.report, ice: members.ice, continuousIce: members.continuous))
                    // Stop arrives while the report request is in flight.
                    stopped = members.report != nil
                    throw HTTPFailure(400)
                }
            }
            assertSame(error, HTTPFailure(400))
            XCTAssertEqual(calls, 1, "\(members)")
            XCTAssertTrue(delivery.enabled, "Stop is checked before reject: \(members)")
        }
    }
}
