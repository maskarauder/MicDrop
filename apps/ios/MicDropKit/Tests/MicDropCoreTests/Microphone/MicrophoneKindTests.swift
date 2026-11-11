import MicDropCore
import XCTest

/// (`A/MicrophoneSelection.kt:5-19`): persisted names, fixed labels and the iOS port mapping.
final class MicrophoneKindTests: XCTestCase {
    func testPersistedNamesAreTheAndroidEnumNamesInOrder() {
        XCTAssertEqual(MicrophoneKind.allCases.map(\.rawValue), ["BUILT_IN", "WIRED", "USB", "SCO", "LE"])
        for kind in MicrophoneKind.allCases {
            XCTAssertEqual(MicrophoneKind(rawValue: kind.rawValue), kind)
        }
        XCTAssertNil(MicrophoneKind(rawValue: ""))
        XCTAssertNil(MicrophoneKind(rawValue: "built_in"))
    }

    func testLabelsAreTheHostAcceptedRouteLabels() {
        XCTAssertEqual(
            MicrophoneKind.allCases.map(\.label),
            [
                "built-in microphone", "wired headset microphone", "USB microphone", "Bluetooth SCO microphone",
                "Bluetooth LE microphone",
            ])
        XCTAssertEqual(MicrophoneKind.routeLabels, MicrophoneKind.allCases.map(\.label))
        XCTAssertEqual(MicrophoneKind.unavailableRouteLabel, "unavailable")
        XCTAssertFalse(MicrophoneKind.routeLabels.contains(MicrophoneKind.unavailableRouteLabel))
    }

    func testOnlyScoAndLEAreBluetoothAndLEIsNeverSelectableOnIOS() {
        for kind in MicrophoneKind.allCases {
            XCTAssertEqual(kind.isBluetooth, kind == .sco || kind == .le, kind.rawValue)
            XCTAssertEqual(kind.bluetooth, kind.isBluetooth, kind.rawValue)
            XCTAssertEqual(kind.isSelectableOnIOS, kind != .le, kind.rawValue)
        }
    }

    func testPortTypeConstantsAreTheAVAudioSessionPortRawValues() {
        // The app test target re-checks these against AVAudioSession.Port (AVFoundation is not on Linux).
        XCTAssertEqual(MicrophoneKind.PortType.builtInMic, "MicrophoneBuiltIn")
        XCTAssertEqual(MicrophoneKind.PortType.headsetMic, "MicrophoneWired")
        XCTAssertEqual(MicrophoneKind.PortType.usbAudio, "USBAudio")
        XCTAssertEqual(MicrophoneKind.PortType.bluetoothHFP, "BluetoothHFP")
    }

    func testPortTypesMapToKindsAndBack() {
        XCTAssertEqual(MicrophoneKind(portTypeRaw: "MicrophoneBuiltIn"), .builtIn)
        XCTAssertEqual(MicrophoneKind(portTypeRaw: "MicrophoneWired"), .wired)
        XCTAssertEqual(MicrophoneKind(portTypeRaw: "USBAudio"), .usb)
        XCTAssertEqual(MicrophoneKind(portTypeRaw: "BluetoothHFP"), .sco)
        for kind in MicrophoneKind.allCases where kind != .le {
            XCTAssertNotNil(kind.portTypeRaw, kind.rawValue)
            XCTAssertEqual(kind.portTypeRaw.flatMap { MicrophoneKind(portTypeRaw: $0) }, kind, kind.rawValue)
        }
        XCTAssertNil(MicrophoneKind.le.portTypeRaw)
    }

    func testOutputOnlyAndUnsupportedPortsAreNotMicrophoneKinds() {
        // `T/MicrophoneSelectionTest.kt:11-17` adapted: A2DP, headphones, LE output, speakers, line in, car audio,
        // continuity microphone and unknown types are never inputs on iOS.
        for raw in [
            "BluetoothA2DPOutput", "Headphones", "BluetoothLEOutput", "Speaker", "Receiver", "HDMIOutput",
            "AirPlay", "LineOut", "LineIn", "CarAudio", "ContinuityMicrophone", "Virtual", "", "microphonebuiltin",
            "MicrophoneBuiltIn ",
        ] {
            XCTAssertNil(MicrophoneKind(portTypeRaw: raw), raw)
            XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: raw), "unavailable", raw)
        }
    }

    func testRouteLabelForRoutedPortTypes() {
        XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: nil), "unavailable")
        XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: "MicrophoneBuiltIn"), "built-in microphone")
        XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: "MicrophoneWired"), "wired headset microphone")
        XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: "USBAudio"), "USB microphone")
        // HFP voice uses SCO/eSCO transport; the label is accurate and `Bluetooth LE microphone` is never produced.
        XCTAssertEqual(MicrophoneKind.routeLabel(portTypeRaw: "BluetoothHFP"), "Bluetooth SCO microphone")
    }
}

/// the platform-neutral port descriptor never prints identity.
final class AudioPortDescriptorTests: XCTestCase {
    func testDefaultsAndKind() {
        let port = AudioPortDescriptor(uid: "uid-1", type: "USBAudio", isInput: true)
        XCTAssertEqual(port.name, "")
        XCTAssertEqual(port.microphoneKind, .usb)
        XCTAssertNil(AudioPortDescriptor(uid: "x", type: "Speaker", isInput: false).microphoneKind)
        // Direction is not part of the kind; callers check `isInput`.
        XCTAssertEqual(AudioPortDescriptor(uid: "x", type: "BluetoothHFP", isInput: false).microphoneKind, .sco)
    }

    func testEqualityCoversEveryField() {
        let port = AudioPortDescriptor(uid: "a", type: "MicrophoneWired", isInput: true, name: "Headset")
        XCTAssertEqual(port, AudioPortDescriptor(uid: "a", type: "MicrophoneWired", isInput: true, name: "Headset"))
        XCTAssertNotEqual(port, AudioPortDescriptor(uid: "b", type: "MicrophoneWired", isInput: true, name: "Headset"))
        XCTAssertNotEqual(port, AudioPortDescriptor(uid: "a", type: "USBAudio", isInput: true, name: "Headset"))
        XCTAssertNotEqual(port, AudioPortDescriptor(uid: "a", type: "MicrophoneWired", isInput: false, name: "Headset"))
        XCTAssertNotEqual(port, AudioPortDescriptor(uid: "a", type: "MicrophoneWired", isInput: true, name: "Other"))
        XCTAssertEqual(Set([port, port]).count, 1)
    }

    func testDescriptionsNeverContainTheUIDOrName() {
        let port = AudioPortDescriptor(uid: "SECRET-UID-12", type: "BluetoothHFP", isInput: true, name: "Secret Pods")
        for text in [
            port.description, port.debugDescription, "\(port)", String(describing: port), String(reflecting: port),
        ] {
            XCTAssertFalse(text.contains("SECRET-UID-12"), text)
            XCTAssertFalse(text.contains("Secret Pods"), text)
        }
        XCTAssertEqual(port.description, "AudioPortDescriptor(type: BluetoothHFP, input)")
        XCTAssertEqual(
            AudioPortDescriptor(uid: "u", type: "Speaker", isInput: false).description,
            "AudioPortDescriptor(type: Speaker, output)")
    }
}
