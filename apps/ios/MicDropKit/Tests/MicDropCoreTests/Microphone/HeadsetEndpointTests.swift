import MicDropCore
import XCTest

private let hfp = MicrophoneKind.PortType.bluetoothHFP

private func input(_ uid: String, _ type: String = hfp, name: String = "") -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: true, name: name)
}

private func output(_ uid: String, _ type: String = hfp) -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: false)
}

/// `T/HeadsetEndpointTest.kt` adapted to iOS: the port `uid` is the identity, so there is no recreated port, no address
/// masking and no paired-address lookup.
final class HeadsetEndpointTests: XCTestCase {
    private let original = input("headset-uid-30", name: "AirPods Pro")

    private func pinned() throws -> HeadsetEndpoint {
        try XCTUnwrap(HeadsetEndpoint(port: original))
    }

    func testATemporarilyMissingEndpointCanReturnOnItsOriginalPort() throws {
        let endpoint = try pinned()
        XCTAssertNil(endpoint.resolve([]))
        XCTAssertEqual(endpoint.resolve([original]), original)
        XCTAssertTrue(endpoint.matches(original))
        XCTAssertEqual(endpoint.type, hfp)
        XCTAssertEqual(endpoint.uid, "headset-uid-30")
    }

    func testANewPortIdentityIsNeverAcceptedAsTheSameHeadset() throws {
        // Android accepts a recreated port with the same stable address; on iOS a different uid is a
        // different headset, even with the same name.
        let endpoint = try pinned()
        let renamedTwin = input("headset-uid-31", name: "AirPods Pro")
        XCTAssertNil(endpoint.resolve([renamedTwin]))
        XCTAssertEqual(endpoint.inspect([renamedTwin]).state, .identityMissing)
        XCTAssertFalse(endpoint.matches(renamedTwin))
        XCTAssertEqual(endpoint.resolve([renamedTwin, original]), original)
    }

    func testSameTypeDifferentUIDCannotAuthorizeAnotherHeadset() throws {
        // `aReusedPortIdCannotAuthorizeAnotherHeadset`: a car or another headset of the same profile.
        let endpoint = try pinned()
        let car = input("car-uid-50", name: "Car")
        XCTAssertNil(endpoint.resolve([car]))
        XCTAssertFalse(endpoint.matches(car))
        XCTAssertFalse(endpoint.matches(output("car-uid-50")))
        XCTAssertEqual(endpoint.resolve([car, original]), original)
    }

    func testAmbiguousPortsCannotBeSelected() throws {
        let endpoint = try pinned()
        let duplicate = input("headset-uid-30", name: "Duplicate")
        XCTAssertNil(endpoint.resolve([original, duplicate]))
        XCTAssertEqual(endpoint.inspect([original, duplicate]).state, .ambiguous)
        XCTAssertNil(endpoint.inspect([original, duplicate]).port)
        // An unchanged, unique original port still proves the explicit selection.
        XCTAssertEqual(endpoint.resolve([original, input("other-uid")]), original)
    }

    func testAnEmptyUIDIsRefused() {
        XCTAssertNil(HeadsetEndpoint(type: hfp, uid: ""))
        XCTAssertNil(HeadsetEndpoint(port: input("")))
        XCTAssertNotNil(HeadsetEndpoint(type: hfp, uid: " "))
    }

    func testRecoveryCannotSubstituteAnotherProfileOrAnOutput() throws {
        let endpoint = try pinned()
        for other in ["BluetoothA2DPOutput", "BluetoothLEOutput", MicrophoneKind.PortType.builtInMic, "USBAudio"] {
            let sameUID = input("headset-uid-30", other)
            XCTAssertNil(endpoint.resolve([sameUID]), other)
            XCTAssertEqual(endpoint.inspect([sameUID]).state, .profileMissing, other)
            XCTAssertFalse(endpoint.matches(sameUID), other)
        }
        // Inspection looks at inputs only: the headset's output port never resolves as its microphone.
        XCTAssertNil(endpoint.resolve([output("headset-uid-30")]))
        XCTAssertEqual(endpoint.inspect([output("headset-uid-30")]).state, .profileMissing)
    }

    func testDiagnosticStatesDistinguishMissingIdentityFromMissingProfile() throws {
        let endpoint = try pinned()
        XCTAssertEqual(endpoint.inspect([original]), HeadsetEndpoint.Match(port: original, state: .original))
        XCTAssertEqual(endpoint.inspect([]), HeadsetEndpoint.Match(port: nil, state: .profileMissing))
        XCTAssertEqual(
            endpoint.inspect([input(MicrophoneKind.PortType.builtInMic, MicrophoneKind.PortType.builtInMic)]).state,
            .profileMissing)
        XCTAssertEqual(
            endpoint.inspect([input("car-uid-50")]), HeadsetEndpoint.Match(port: nil, state: .identityMissing))
        XCTAssertEqual(
            endpoint.inspect([original, input("headset-uid-30")]), HeadsetEndpoint.Match(port: nil, state: .ambiguous))
    }

    func testRecreatedAndAddressMissingAreNeverProducedOnIOS() throws {
        let endpoint = try pinned()
        let lists: [[AudioPortDescriptor]] = [
            [], [original], [original, original], [input("x")], [input("x"), input("y")], [output("headset-uid-30")],
            [input("headset-uid-30", "USBAudio")], [original, input("x"), output("x")],
        ]
        for ports in lists {
            let state = endpoint.inspect(ports).state
            XCTAssertNotEqual(state, .recreated)
            XCTAssertNotEqual(state, .addressMissing)
            XCTAssertEqual(endpoint.resolve(ports), endpoint.inspect(ports).port)
        }
    }

    func testMatchesComparesTypeAndUIDInEitherDirection() throws {
        let endpoint = try pinned()
        XCTAssertTrue(endpoint.matches(output("headset-uid-30")))
        XCTAssertTrue(endpoint.matches(input("headset-uid-30", name: "renamed")))
        XCTAssertFalse(endpoint.matches(nil))
        XCTAssertFalse(endpoint.matches(output("headset-uid-30", "BluetoothA2DPOutput")))
    }

    func testStateTextsAreVerbatim() {
        let expected: [(HeadsetEndpoint.State, String)] = [
            (.original, "original port available"),
            (.recreated, "same headset available on a recreated port"),
            (.profileMissing, "selected audio profile unavailable"),
            (.identityMissing, "original headset identity unavailable"),
            (.addressMissing, "original port missing; stable Bluetooth address unavailable"),
            (.ambiguous, "original headset identity ambiguous"),
        ]
        XCTAssertEqual(HeadsetEndpoint.State.allCases.count, expected.count)
        for (state, text) in expected {
            XCTAssertEqual(state.text, text)
            XCTAssertEqual(state.rawValue, text)
        }
        let alias: HeadsetEndpointState = .original
        XCTAssertEqual(alias, HeadsetEndpoint.State.original)
        let match: HeadsetEndpointMatch = HeadsetEndpoint.Match(port: nil, state: .ambiguous)
        XCTAssertNil(match.port)
    }

    func testIdentityIsNeverPrinted() throws {
        let endpoint = try pinned()
        for text in [endpoint.description, endpoint.debugDescription, "\(endpoint)", String(reflecting: endpoint)] {
            XCTAssertFalse(text.contains("headset-uid-30"), text)
        }
        XCTAssertEqual(endpoint.description, "HeadsetEndpoint(type: BluetoothHFP)")
        XCTAssertEqual(
            HeadsetEndpoint.identityText,
            "Selected headset identity: port UID · Bluetooth permission: not required on iOS")
        XCTAssertTrue(HeadsetEndpoint.identityText.hasPrefix(HeadsetEndpoint.identityTextPrefix + " "))
        XCTAssertEqual(HeadsetEndpoint.identityTextPrefix, "Selected headset identity:")
    }

    func testEquatableAndHashableUseTypeAndUID() throws {
        let endpoint = try pinned()
        XCTAssertEqual(endpoint, HeadsetEndpoint(type: hfp, uid: "headset-uid-30"))
        XCTAssertNotEqual(endpoint, HeadsetEndpoint(type: hfp, uid: "headset-uid-31"))
        XCTAssertNotEqual(endpoint, HeadsetEndpoint(type: "USBAudio", uid: "headset-uid-30"))
        let again = try pinned()
        XCTAssertEqual(Set([endpoint, again]).count, 1)
    }
}
