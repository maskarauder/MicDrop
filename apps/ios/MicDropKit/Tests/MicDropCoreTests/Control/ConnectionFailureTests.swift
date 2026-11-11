import Foundation
import XCTest

@testable import MicDropCore

/// The platform-neutral HTTP 400 explanation (`A/ConnectionFailure.kt:72`), shared by session, pairing and rendezvous
/// registration failures; it replaces the adaptation.
final class ConnectionFailureTests: XCTestCase {
    private static let badRequestDetail =
        "Windows rejected a connection request. Copy the session report and check that both apps are up to date."
    private static let forbiddenDetail =
        "This phone is not approved on Windows, or its pairing was revoked. In the Windows app, open Phones → Pair a phone and pair again."

    func testHTTP400UsesThePlatformNeutralText() {
        let detail = ConnectionFailure.httpDetail(status: 400, action: "Reconnect")
        XCTAssertEqual(detail, Self.badRequestDetail)
        XCTAssertFalse(detail.contains("iPhone builds"))
        XCTAssertFalse(detail.contains("matching"))
        XCTAssertEqual(ConnectionFailure.httpDetail(status: 400, action: "Connect"), Self.badRequestDetail)
    }

    func testHTTP403NamesPhonesPairAPhone() {
        let detail = ConnectionFailure.httpDetail(status: 403, action: "Reconnect")
        XCTAssertEqual(detail, Self.forbiddenDetail)
        XCTAssertFalse(detail.contains("Open a new pairing window"), detail)
        XCTAssertEqual(
            ConnectionFailure.describe(stage: .pairing, error: HTTPFailure(403)),
            "Connecting securely to Windows failed [HTTP_403].\n" + Self.forbiddenDetail)
    }

    func testHTTP400IsDescribedWithTheSameDetailForSessionsAndPairing() {
        XCTAssertEqual(ConnectionFailure.code(stage: .playback, error: HTTPFailure(400)), "HTTP_400")
        let playback = ConnectionFailure.describe(stage: .playback, error: HTTPFailure(400))
        XCTAssertTrue(playback.hasSuffix("failed [HTTP_400].\n" + Self.badRequestDetail), playback)
        XCTAssertEqual(playback, "Receiving audio failed [HTTP_400].\n" + Self.badRequestDetail)
        let pairing = ConnectionFailure.describe(stage: .pairing, error: HTTPFailure(400), action: "Connect")
        XCTAssertEqual(pairing, "Connecting securely to Windows failed [HTTP_400].\n" + Self.badRequestDetail)
        XCTAssertEqual(ConnectionFailure.code(stage: .pairing, error: HTTPFailure(400)), "HTTP_400")
    }
}
