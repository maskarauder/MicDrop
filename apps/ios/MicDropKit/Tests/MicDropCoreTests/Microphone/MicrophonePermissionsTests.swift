import MicDropCore
import XCTest

/// `T/MicrophonePermissionsTest.kt` adapted: every iOS kind needs only the record permission; there is no
/// Nearby-devices permission and notifications never authorize capture.
final class MicrophonePermissionsTests: XCTestCase {
    private let deniedText =
        "Microphone permission was denied. Desktop playback still works without it. "
        + "Allow microphone access for MicDrop in Settings, then tap Connect."

    func testEveryKindRequiresOnlyTheRecordPermission() {
        for kind in MicrophoneKind.allCases {
            XCTAssertNil(MicrophonePermissions.denial(kind: kind, status: .granted), kind.rawValue)
            XCTAssertEqual(MicrophonePermissions.denial(kind: kind, status: .denied), deniedText, kind.rawValue)
            XCTAssertEqual(MicrophonePermissions.denial(kind: kind, status: .undetermined), deniedText, kind.rawValue)
        }
    }

    func testBluetoothNeverRaisesTheNearbyDevicesProblem() {
        let nearby = MicrophoneRouteProblem.bluetoothPermission.detail
        for kind in MicrophoneKind.allCases {
            for status in MicrophonePermissions.Status.allCases {
                XCTAssertNotEqual(MicrophonePermissions.denial(kind: kind, status: status), nearby)
            }
        }
    }

    func testDeniedTextKeepsTheAndroidSentencesAndPointsToSettings() {
        XCTAssertEqual(MicrophonePermissions.deniedText, deniedText)
        XCTAssertTrue(
            MicrophonePermissions.deniedText.hasPrefix(
                "Microphone permission was denied. Desktop playback still works without it."))
        XCTAssertTrue(MicrophonePermissions.deniedText.contains("Settings"))
    }

    func testOnlyAnUndeterminedStatusIsPromptedAndOnlyGrantedCounts() {
        XCTAssertTrue(MicrophonePermissions.needsRequest(.undetermined))
        XCTAssertFalse(MicrophonePermissions.needsRequest(.denied))  // iOS cannot re-prompt.
        XCTAssertFalse(MicrophonePermissions.needsRequest(.granted))
        XCTAssertTrue(MicrophonePermissions.isGranted(.granted))
        XCTAssertFalse(MicrophonePermissions.isGranted(.denied))
        XCTAssertFalse(MicrophonePermissions.isGranted(.undetermined))
        XCTAssertEqual(MicrophonePermissions.Status.allCases.map(\.rawValue), ["undetermined", "denied", "granted"])
        let alias: MicrophonePermissionStatus = .granted
        XCTAssertEqual(alias, MicrophonePermissions.Status.granted)
    }
}

/// and / problem details (iOS wording where the Android text names Android) and the thrown error type.
final class MicrophoneRouteProblemTests: XCTestCase {
    func testDetailsAreVerbatimOrTheCriticIOSText() {
        XCTAssertEqual(
            MicrophoneRouteProblem.unavailable.detail,
            "The selected microphone is unavailable. Tap Microphone input, choose a connected input and start again.")
        XCTAssertEqual(
            MicrophoneRouteProblem.inUse.detail,
            "iPhone is in a call or another app is using audio. "
                + "End that session before selecting a Bluetooth microphone.")
        XCTAssertEqual(
            MicrophoneRouteProblem.unverified.detail,
            "iOS could not verify the selected microphone route. "
                + "Check the headset connection, choose an available input and start again.")
        XCTAssertEqual(
            MicrophoneRouteProblem.bluetoothPermission.detail,
            "Allow Nearby devices permission for MicDrop to identify and recover your selected headset. "
                + "You can still use the phone or a wired microphone without it.")
        XCTAssertEqual(
            MicrophoneRouteProblem.leStereoUnavailable.detail,
            "Android could not provide verified stereo output on the selected LE Audio headset. "
                + "Turn off LE Audio stereo playback to try mono compatibility, "
                + "or choose the phone microphone for media playback.")
    }

    func testProblemsThatIOSRaisesNeverMentionAndroid() {
        for problem in [MicrophoneRouteProblem.unavailable, .inUse, .unverified] {
            XCTAssertFalse(problem.detail.contains("Android"), problem.rawValue)
        }
    }

    func testRawValuesAreTheAndroidEnumNames() {
        XCTAssertEqual(
            MicrophoneRouteProblem.allCases.map(\.rawValue),
            ["BLUETOOTH_PERMISSION", "UNAVAILABLE", "IN_USE", "UNVERIFIED", "LE_STEREO_UNAVAILABLE"])
    }

    func testErrorCarriesOnlyTheProblem() {
        let error = MicrophoneRouteError(.unverified)
        XCTAssertEqual(error, MicrophoneRouteError(problem: .unverified))
        XCTAssertNotEqual(error, MicrophoneRouteError(.unavailable))
        XCTAssertEqual(error.problem, .unverified)
        XCTAssertEqual(error.detail, MicrophoneRouteProblem.unverified.detail)
        XCTAssertEqual(error.description, "MicrophoneRouteError(UNVERIFIED)")
        XCTAssertEqual("\(MicrophoneRouteError(.inUse))", "MicrophoneRouteError(IN_USE)")
        let thrown: Error = MicrophoneRouteError(.inUse)
        XCTAssertEqual((thrown as? MicrophoneRouteError)?.problem, .inUse)
        XCTAssertEqual(Set(MicrophoneRouteProblem.allCases.map { MicrophoneRouteError($0) }).count, 5)
    }

    func testThrowingAndCatchingByProblem() {
        func preflight(_ available: Bool) throws {
            if !available { throw MicrophoneRouteError(.unavailable) }
        }
        XCTAssertNoThrow(try preflight(true))
        XCTAssertThrowsError(try preflight(false)) { error in
            XCTAssertEqual(error as? MicrophoneRouteError, MicrophoneRouteError(.unavailable))
        }
    }
}
