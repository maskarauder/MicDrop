import XCTest

@testable import MicDropCore

/// `/offer` capability parsing for the TURN/TLS trust report member (`StreamReceiver.kt:408`: org.json
/// `optInt("tls_certificate_diagnostics_version", 0) == 1`; host `internal/session/server.go:183`).
final class OfferCapabilitiesTests: XCTestCase {
    private static let session = String(repeating: "s", count: 43)

    private func capabilities(_ version: String?) throws -> OfferCapabilities {
        let member = version.map { #","tls_certificate_diagnostics_version":\#($0)"# } ?? ""
        let json = try ControlTestSupport.json(#"{"version":3,"session":"\#(Self.session)""# + member + "}")
        return try OfferCapabilities(json, invitationVersion: 3)
    }

    func testVersionOneEnablesTheMemberWithOptIntCoercion() throws {
        for version in ["1", #""1""#, "1.0"] {
            let offer = try capabilities(version)
            XCTAssertEqual(offer.tlsCertificateDiagnosticsVersion, 1, version)
            XCTAssertTrue(offer.includeTlsVerification, version)
            XCTAssertTrue(DiagnosticsCapabilities(offer).tlsVerification, version)
        }
    }

    func testOtherValuesLeaveTheMemberOff() throws {
        for version in [nil, "0", "2", "true", #""x""#, "null"] {
            let offer = try capabilities(version)
            XCTAssertFalse(offer.includeTlsVerification, version ?? "missing")
            XCTAssertFalse(DiagnosticsCapabilities(offer).tlsVerification, version ?? "missing")
        }
    }

    func testNotNegotiatedProjectionOmitsTheMember() {
        XCTAssertFalse(DiagnosticsCapabilities.notNegotiated.tlsVerification)
    }

    // MARK: - phone_control_version (`StreamReceiver.kt:397`, host `server.go:202`)

    private func phoneControl(_ value: String?, version: Int = 3) throws -> OfferCapabilities {
        let member = value.map { #","phone_control_version":\#($0)"# } ?? ""
        let json = try ControlTestSupport.json(#"{"version":\#(version),"session":"\#(Self.session)""# + member + "}")
        return try OfferCapabilities(json, invitationVersion: version)
    }

    func testPhoneControlIsNegotiatedOnlyByVersionOneOnAPairedLink() throws {
        // optInt semantics: a numeric string counts, anything else is 0.
        for value in ["1", #""1""#] {
            let offer = try phoneControl(value)
            XCTAssertEqual(offer.phoneControlVersion, 1, value)
            XCTAssertTrue(offer.phoneControlNegotiated, value)
        }
        for value in [nil, "0", "2", "true", #""x""#, "null"] {
            XCTAssertFalse(try phoneControl(value).phoneControlNegotiated, value ?? "missing")
        }
        XCTAssertEqual(try phoneControl(nil).phoneControlVersion, 0)
        for version in [1, 2] {
            XCTAssertFalse(try phoneControl("1", version: version).phoneControlNegotiated, "v\(version)")
        }
    }
}
