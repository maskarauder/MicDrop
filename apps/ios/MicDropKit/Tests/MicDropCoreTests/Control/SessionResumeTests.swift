import XCTest

@testable import MicDropCore

/// `SessionResumeTest.kt`: the resume hint and its reason exist only on a paired v3 `/offer` of an intentional resume
/// or input-switch replacement. The host answers them anywhere else with 400 "Invalid session resume hint"
/// (`internal/session/resume.go`).
final class SessionResumeTests: XCTestCase {
    func testPairedResumeIsDistinctFromExplicitConnect() {
        for reason in SessionResume.Reason.allCases {
            XCTAssertEqual(SessionResume.offerHeader(version: 3, path: "/offer", resume: reason), "1")
        }
        XCTAssertNil(SessionResume.offerHeader(version: 3, path: "/offer", resume: nil))
        XCTAssertNil(SessionResume.reasonHeader(version: 3, path: "/offer", resume: nil))
        XCTAssertTrue(SessionResume.offerHeaders(version: 3, path: "/offer", resume: nil).isEmpty)
        XCTAssertEqual(SessionResume.header, "X-MicDrop-Session-Resume")
        XCTAssertEqual(ControlRequest.Header.sessionResume, SessionResume.header)
    }

    func testReasonsUseTheHostsFixedLabels() {
        XCTAssertEqual(SessionResume.reasonHeader, "X-MicDrop-Session-Resume-Reason")
        XCTAssertEqual(ControlRequest.Header.sessionResumeReason, SessionResume.reasonHeader)
        XCTAssertEqual(SessionResume.Reason.allCases.map(\.wire), ["manual", "automatic", "focus_regain"])
        for reason in SessionResume.Reason.allCases {
            XCTAssertEqual(SessionResume.reasonHeader(version: 3, path: "/offer", resume: reason), reason.wire)
            XCTAssertTrue((1...32).contains(reason.wire.utf8.count))
            XCTAssertTrue(reason.wire.allSatisfy { ($0 >= "a" && $0 <= "z") || $0 == "_" })
        }
    }

    func testTheReasonFollowsTheResumeHintExactlyOnce() {
        for reason in SessionResume.Reason.allCases {
            let headers = SessionResume.offerHeaders(version: 3, path: "/offer", resume: reason)
            XCTAssertEqual(headers.count, 2)
            XCTAssertEqual(headers.first?.0, SessionResume.header)
            XCTAssertEqual(headers.first?.1, "1")
            XCTAssertEqual(headers.last?.0, SessionResume.reasonHeader)
            XCTAssertEqual(headers.last?.1, reason.wire)
        }
    }

    func testResumeNeverEntersLegacyOrOrdinaryControlRequests() {
        for reason in SessionResume.Reason.allCases {
            for version in [1, 2] {
                XCTAssertNil(SessionResume.offerHeader(version: version, path: "/offer", resume: reason), "v\(version)")
                XCTAssertNil(
                    SessionResume.reasonHeader(version: version, path: "/offer", resume: reason), "v\(version)")
                XCTAssertTrue(
                    SessionResume.offerHeaders(version: version, path: "/offer", resume: reason).isEmpty, "v\(version)")
            }
            for path in [
                "/status", "/stop", "/answer", "/cancel-offer", "/recover-offer", "/recover-answer", "/microphone",
                "/pair",
            ] {
                XCTAssertNil(SessionResume.offerHeader(version: 3, path: path, resume: reason), path)
                XCTAssertNil(SessionResume.reasonHeader(version: 3, path: path, resume: reason), path)
                XCTAssertTrue(SessionResume.offerHeaders(version: 3, path: path, resume: reason).isEmpty, path)
            }
        }
        XCTAssertFalse(ControlRequest(path: ControlRequest.Path.status).sessionResume)
        XCTAssertNil(ControlRequest(path: ControlRequest.Path.status).sessionResumeReason)
        XCTAssertFalse(ControlRequest(path: ControlRequest.Path.offer).sessionResume)
        XCTAssertNil(ControlRequest(path: ControlRequest.Path.offer).sessionResumeReason)
        XCTAssertFalse(ControlRequest(path: ControlRequest.Path.offer).phoneControlOffer)
    }

    func testEntryPointsReportDistinctCauses() {
        // Play, Resume duplex, notification/lock-screen Resume and a queued Play are manual.
        XCTAssertEqual(SessionResume.resumed(userRequested: true), .manual)
        XCTAssertEqual(SessionResume.resumed(userRequested: false), .focusRegain)
        // the input-switch replacement has neither a Play command nor a focus signal.
        XCTAssertEqual(SessionResume.inputSwitch, .automatic)
    }
}
