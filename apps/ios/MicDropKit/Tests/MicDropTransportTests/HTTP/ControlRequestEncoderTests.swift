import Foundation
import MicDropCore
import XCTest

@testable import MicDropTransport

/// The connection-deadline headers on the wire (Android pairing-check `RemoteTransportPlatformTest.kt:142-145,
/// 214-215`). The Windows host accepts them only on v3 `/offer`, one decimal value each, and answers any other use
/// with 400 "Invalid connection timeouts" before it allocates anything
/// (`internal/session/connection_timeouts.go:18-44`), so the exact bytes matter. Header names are spelled out here
/// rather than taken from `ConnectionPreferences`, so a renamed constant fails this test. The phone-control and
/// session-resume hints follow the same rule (`phone_control.go:13-19`, `resume.go:9-18`), and the body budget is
/// 160 KiB only for a negotiated `/status`
/// (`PhoneControlTest.onlyNegotiatedStatusExchangesReceiveTheSettingsBodyBudget`).
final class ControlRequestEncoderTests: XCTestCase {
    private static let nonce = String(repeating: "n", count: 43)
    private static let recoveryName = "X-MicDrop-Recovery-Window-Ms"
    private static let setupName = "X-MicDrop-Setup-Window-Ms"

    /// The header lines between the request line and the blank line that ends the head.
    private static func headerLines(_ request: ControlRequest) throws -> [String] {
        let endpoint = try LANEndpoint(host: "192.168.1.2", port: 9844)
        let text = String(decoding: try ControlRequestEncoder.encode(request, host: endpoint), as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let end = try XCTUnwrap(lines.firstIndex(of: ""), "no blank line after the head")
        return Array(lines[1..<end])
    }

    private static func lines(_ name: String, in headers: [String]) -> [String] {
        headers.filter { $0.lowercased().hasPrefix(name.lowercased() + ":") }
    }

    private static func offer(_ preferences: ConnectionPreferences?) -> ControlRequest {
        ControlRequest(
            path: ControlRequest.Path.offer, offerAttempt: nonce, trickleHeaders: true,
            body: Data(#"{"version":3}"#.utf8), connectionPreferences: preferences)
    }

    func testOfferTimeoutHeadersAreExactDecimalLines() throws {
        let cases: [(ConnectionPreferences, recovery: String, setup: String)] = [
            (ConnectionPreferences(), "30000", "45000"),
            (try ConnectionPreferences(timeouts: [.recovery: 90_000, .setup: 60_000]), "90000", "60000"),
            (try ConnectionPreferences(timeouts: [.recovery: 300_000, .setup: 120_000]), "300000", "120000"),
            (try ConnectionPreferences(timeouts: [.recovery: 5_000, .setup: 10_000]), "5000", "10000"),
        ]
        for (preferences, recovery, setup) in cases {
            let headers = try Self.headerLines(Self.offer(preferences))
            XCTAssertEqual(Self.lines(Self.recoveryName, in: headers), ["\(Self.recoveryName): \(recovery)"])
            XCTAssertEqual(Self.lines(Self.setupName, in: headers), ["\(Self.setupName): \(setup)"])
            // The other offer headers are unchanged by the deadline negotiation.
            XCTAssertEqual(
                Self.lines("X-MicDrop-Offer-Attempt", in: headers), ["X-MicDrop-Offer-Attempt: \(Self.nonce)"])
            XCTAssertEqual(Self.lines("X-MicDrop-Trickle-ICE", in: headers), ["X-MicDrop-Trickle-ICE: 1"])
            XCTAssertEqual(Self.lines("X-MicDrop-Continuous-ICE", in: headers), ["X-MicDrop-Continuous-ICE: 1"])
        }
        XCTAssertEqual(ConnectionPreferences.recoveryHeader, Self.recoveryName)
        XCTAssertEqual(ConnectionPreferences.setupHeader, Self.setupName)
    }

    func testNoTimeoutHeadersWithoutPreferences() throws {
        let headers = try Self.headerLines(Self.offer(nil))
        XCTAssertTrue(Self.lines(Self.recoveryName, in: headers).isEmpty, "\(headers)")
        XCTAssertTrue(Self.lines(Self.setupName, in: headers).isEmpty, "\(headers)")
        XCTAssertFalse(headers.contains { $0.lowercased().contains("window-ms") }, "\(headers)")
    }

    func testTimeoutHeadersRejectedOutsideOffer() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 90_000, .setup: 60_000])
        let token = String(repeating: "s", count: 43)
        let body = Data(#"{"version":3}"#.utf8)
        let requests = [
            ControlRequest(path: ControlRequest.Path.status, bearer: token, connectionPreferences: preferences),
            ControlRequest(
                path: ControlRequest.Path.recoverOffer, bearer: token, body: body, connectionPreferences: preferences),
            ControlRequest(
                path: ControlRequest.Path.cancelOffer, offerAttempt: Self.nonce, body: body,
                connectionPreferences: preferences),
            ControlRequest(
                path: ControlRequest.Path.answer, bearer: token, body: body, connectionPreferences: preferences),
        ]
        for request in requests {
            try Self.assertRejected(request, .connectionPreferences)
        }
    }

    /// Rejected by the precondition check of both `validate` and `encode`, so no connection is ever opened.
    private static func assertRejected(
        _ request: ControlRequest, _ reason: ControlRequestEncoder.InvalidRequest.Reason,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let endpoint = try LANEndpoint(host: "192.168.1.2", port: 9844)
        let attempts: [() throws -> Void] = [
            { try ControlRequestEncoder.validate(request) },
            { _ = try ControlRequestEncoder.encode(request, host: endpoint) },
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt(), request.path, file: file, line: line) { error in
                let thrown = (error as? ControlRequestEncoder.InvalidRequest)?.reason
                XCTAssertEqual(thrown, reason, request.path, file: file, line: line)
            }
        }
    }

    // MARK: - X-MicDrop-Phone-Control and X-MicDrop-Session-Resume

    private static let phoneControlName = "X-MicDrop-Phone-Control"
    private static let sessionResumeName = "X-MicDrop-Session-Resume"
    private static let sessionResumeReasonName = "X-MicDrop-Session-Resume-Reason"
    private static let token = String(repeating: "s", count: 43)
    private static let versionBody = Data(#"{"version":3}"#.utf8)

    /// A v3 `/offer` as `transportRequest` builds it, with the negotiation and resume hints set as given.
    private static func v3Offer(phoneControl: Bool, resume: SessionResume.Reason? = nil) -> ControlRequest {
        ControlRequest(
            path: ControlRequest.Path.offer, offerAttempt: nonce, trickleHeaders: true, body: versionBody,
            connectionPreferences: ConnectionPreferences(), phoneControlOffer: phoneControl,
            sessionResume: resume != nil, sessionResumeReason: resume)
    }

    /// Every control request except `/offer`, as the worker and `PairingClient` build them.
    private static var otherRequests: [ControlRequest] {
        [
            ControlRequest.cancelOffer(version: 3, token: "", attempt: nonce),
            ControlRequest.status(session: token, body: nil),
            ControlRequest.status(session: token, body: versionBody, phoneControlNegotiated: true),
            ControlRequest.answer(version: 3, sdp: "v=0\r\n", session: token),
            ControlRequest.stop(session: token, reason: "user_stop"),
            ControlRequest.microphone(session: token, muted: true),
            ControlRequest.recoverOffer(session: token, generation: 1),
            ControlRequest.recoverAnswer(session: token, generation: 1, sdp: "v=0\r\n"),
            PairingClient.request(body: Array(#"{"version":1}"#.utf8)),
        ]
    }

    /// `PhoneControlTest.malformedEnvelopeAndUnknownFieldsAreRejected` (offerHeader) and the Go negotiation rule
    /// (`internal/session/phone_control.go:13-19`): exactly one `1` on a v3 `/offer`, after the offer nonce.
    func testPhoneControlHeaderIsOneLineOnTheV3Offer() throws {
        let headers = try Self.headerLines(Self.v3Offer(phoneControl: true))
        XCTAssertEqual(Self.lines(Self.phoneControlName, in: headers), ["\(Self.phoneControlName): 1"])
        let attempt = try XCTUnwrap(headers.firstIndex(of: "X-MicDrop-Offer-Attempt: \(Self.nonce)"))
        XCTAssertEqual(headers[attempt + 1], "\(Self.phoneControlName): 1")
        XCTAssertEqual(ControlRequest.Header.phoneControl, Self.phoneControlName)
        XCTAssertEqual(PhoneControl.offerHeader(version: 3, path: "/offer"), "1")
        XCTAssertNil(PhoneControl.offerHeader(version: 2, path: "/offer"))
        XCTAssertNil(PhoneControl.offerHeader(version: 1, path: "/offer"))
        XCTAssertNil(PhoneControl.offerHeader(version: 3, path: "/status"))
    }

    func testNoHintHeadersOnOtherRequestsOrWithoutTheFlags() throws {
        for request in Self.otherRequests + [Self.v3Offer(phoneControl: false)] {
            let headers = try Self.headerLines(request)
            XCTAssertTrue(Self.lines(Self.phoneControlName, in: headers).isEmpty, "\(request.path) \(headers)")
            XCTAssertTrue(Self.lines(Self.sessionResumeName, in: headers).isEmpty, "\(request.path) \(headers)")
            XCTAssertTrue(Self.lines(Self.sessionResumeReasonName, in: headers).isEmpty, "\(request.path) \(headers)")
            XCTAssertFalse(request.phoneControlOffer, request.path)
            XCTAssertFalse(request.sessionResume, request.path)
            XCTAssertNil(request.sessionResumeReason, request.path)
        }
    }

    func testHintFlagsOutsideOfferThrowBeforeAnyIO() throws {
        for path in ["/cancel-offer", "/status", "/answer", "/stop", "/recover-offer", "/microphone", "/pair"] {
            try Self.assertRejected(
                ControlRequest(path: path, bearer: Self.token, body: Self.versionBody, phoneControlOffer: true),
                .phoneControl)
            try Self.assertRejected(
                ControlRequest(path: path, bearer: Self.token, body: Self.versionBody, sessionResume: true),
                .sessionResume)
            try Self.assertRejected(
                ControlRequest(path: path, bearer: Self.token, body: Self.versionBody, sessionResumeReason: .manual),
                .sessionResume)
        }
        try Self.assertRejected(
            ControlRequest(
                path: ControlRequest.Path.offer, offerAttempt: Self.nonce, body: Self.versionBody,
                sessionResume: false, sessionResumeReason: .manual),
            .sessionResume)
    }

    /// `SessionResumeTest` on the wire: `X-MicDrop-Session-Resume: 1` and `X-MicDrop-Session-Resume-Reason: <wire>`
    /// right after the phone-control line (or the offer nonce), and every other header byte unchanged by the hints.
    func testSessionResumeLineFollowsTheNegotiationLines() throws {
        let plain = try Self.headerLines(Self.v3Offer(phoneControl: true))
        for reason in SessionResume.Reason.allCases {
            let resumed = try Self.headerLines(Self.v3Offer(phoneControl: true, resume: reason))
            XCTAssertEqual(Self.lines(Self.sessionResumeName, in: resumed), ["\(Self.sessionResumeName): 1"])
            XCTAssertEqual(
                Self.lines(Self.sessionResumeReasonName, in: resumed),
                ["\(Self.sessionResumeReasonName): \(reason.wire)"])
            let control = try XCTUnwrap(resumed.firstIndex(of: "\(Self.phoneControlName): 1"))
            XCTAssertEqual(resumed[control + 1], "\(Self.sessionResumeName): 1")
            XCTAssertEqual(resumed[control + 2], "\(Self.sessionResumeReasonName): \(reason.wire)")
            let stripped = resumed.filter {
                $0 != "\(Self.sessionResumeName): 1" && $0 != "\(Self.sessionResumeReasonName): \(reason.wire)"
            }
            XCTAssertEqual(stripped, plain)

            let alone = try Self.headerLines(Self.v3Offer(phoneControl: false, resume: reason))
            let attempt = try XCTUnwrap(alone.firstIndex(of: "X-MicDrop-Offer-Attempt: \(Self.nonce)"))
            XCTAssertEqual(alone[attempt + 1], "\(Self.sessionResumeName): 1")
            XCTAssertEqual(alone[attempt + 2], "\(Self.sessionResumeReasonName): \(reason.wire)")
        }
        XCTAssertEqual(ControlRequest.Header.sessionResume, Self.sessionResumeName)
        XCTAssertEqual(ControlRequest.Header.sessionResumeReason, Self.sessionResumeReasonName)
    }

    // MARK: - Body budget (`PhoneControl.kt:82-86`, `RemoteHttp.kt:63-65`)

    func testOnlyANegotiatedStatusGetsTheSettingsBodyBudget() throws {
        XCTAssertEqual(ControlRequest.phoneControlBodyBytes, 163_840)
        let large = Data(repeating: 0x20, count: 98_305)
        let unnegotiated = ControlRequest.status(session: Self.token, body: large)
        XCTAssertEqual(unnegotiated.bodyBudget, 98_304)
        XCTAssertEqual(unnegotiated.maxResponseBytes, 98_304)
        try Self.assertRejected(unnegotiated, .bodyTooLarge)

        let negotiated = ControlRequest.status(session: Self.token, body: large, phoneControlNegotiated: true)
        XCTAssertEqual(negotiated.bodyBudget, 163_840)
        XCTAssertEqual(negotiated.maxResponseBytes, 163_840)
        XCTAssertNoThrow(try ControlRequestEncoder.validate(negotiated))
        let atLimit = ControlRequest.status(
            session: Self.token, body: Data(repeating: 0x20, count: 163_840), phoneControlNegotiated: true)
        XCTAssertNoThrow(try ControlRequestEncoder.validate(atLimit))
        for negotiated in [false, true] {
            let tooLarge = ControlRequest.status(
                session: Self.token, body: Data(repeating: 0x20, count: 163_841), phoneControlNegotiated: negotiated)
            try Self.assertRejected(tooLarge, .bodyTooLarge)
        }
    }

    func testOtherPathsKeepTheDefaultBudgetWhenNegotiated() throws {
        let large = Data(repeating: 0x20, count: 98_305)
        for path in ["/offer", "/answer", "/recover-offer", "/recover-answer", "/stop", "/microphone"] {
            let request = ControlRequest(path: path, bearer: Self.token, body: large, phoneControlNegotiated: true)
            XCTAssertEqual(request.bodyBudget, 98_304, path)
            XCTAssertEqual(request.maxResponseBytes, 98_304, path)
            try Self.assertRejected(request, .bodyTooLarge)
        }
        // A larger response cap is never allowed outside a negotiated `/status`, and `/pair` keeps 1024.
        try Self.assertRejected(
            ControlRequest(path: ControlRequest.Path.status, bearer: Self.token, maxResponseBytes: 98_305),
            .responseCap)
        try Self.assertRejected(
            ControlRequest(
                path: ControlRequest.Path.status, bearer: Self.token, maxResponseBytes: 163_841,
                phoneControlNegotiated: true),
            .responseCap)
        XCTAssertEqual(PairingClient.request(body: []).maxResponseBytes, 1_024)
    }
}
