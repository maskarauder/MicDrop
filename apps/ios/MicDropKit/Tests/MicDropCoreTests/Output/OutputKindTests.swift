import MicDropCore
import XCTest

/// `OutputKind` and `RouteOutput` (`OutputSelectionTest.kt:36-42` with iOS ports).
final class OutputKindTests: XCTestCase {
    private typealias Port = RouteOutput.PortType

    func testLabelsAreTheIOSCatalogue() {
        // DEFAULT and PHONE are adapted, every other label is Android's verbatim.
        let labels = OutputKind.allCases.map { $0.label }
        XCTAssertEqual(
            labels,
            [
                "iPhone media output", "iPhone speaker", "wired headphones", "USB audio output",
                "Bluetooth media output", "Bluetooth LE output", "hearing aid output", "audio output",
            ])
        for label in labels {
            XCTAssertFalse(label.contains("Android"), label)
        }
    }

    func testWireLabelsAreExactlyTheHostAllowList() {
        // `internal/diagnostics/output_control.go:20`.
        let wire = OutputKind.allCases.map { $0.wireLabel }
        XCTAssertEqual(wire, ["default", "phone", "wired", "usb", "bluetooth", "le", "hearing_aid", "other"])
        for kind in OutputKind.allCases {
            XCTAssertEqual(kind.rawValue, kind.wireLabel)
            XCTAssertEqual(OutputKind(rawValue: kind.wireLabel), kind)
        }
    }

    func testPersistedNamesAreTheAndroidEnumNamesAndDecodeExactly() {
        XCTAssertEqual(
            OutputKind.allCases.map { $0.persistedName },
            ["DEFAULT", "PHONE", "WIRED", "USB", "BLUETOOTH", "LE", "HEARING_AID", "OTHER"])
        for kind in OutputKind.allCases {
            XCTAssertEqual(OutputKind(persistedName: kind.persistedName), kind)
            // Both owners must write the same `preferredOutputKind` value.
            XCTAssertEqual(kind.persistedName, AudioPreferences.storageName(of: kind))
            XCTAssertEqual(kind.persistedName, kind.wireLabel.uppercased())
        }
        for invalid in ["", "default", "Default", "hearing_aid", "unknown", " DEFAULT", "DEFAULT "] {
            XCTAssertNil(OutputKind(persistedName: invalid), invalid)
        }
    }

    func testOnlyBluetoothLEAndHearingAidKindsAreBluetooth() {
        let bluetooth = OutputKind.allCases.filter { $0.isBluetooth }
        XCTAssertEqual(bluetooth, [.bluetooth, .le, .hearingAid])
    }

    func testMediaRoutesDoNotPretendCommunicationProfilesAreMediaSinks() {
        // `OutputSelectionTest.kt:36-42`: SCO and the microphone are not media outputs.
        XCTAssertNil(OutputKind.forPortType(Port.bluetoothHFP))
        XCTAssertNil(OutputKind.forPortType(Port.builtInMic))
        XCTAssertNil(OutputKind.forPortType(Port.builtInReceiver))
        XCTAssertEqual(OutputKind.forPortType(Port.bluetoothLE), .le)
        XCTAssertEqual(OutputKind.forPortType(Port.bluetoothA2DP), .bluetooth)
    }

    func testEveryIOSPortMapsToTheSpecKind() {
        // table.
        let expected: [(String, OutputKind?)] = [
            (Port.builtInSpeaker, .phone), (Port.builtInReceiver, nil), (Port.headphones, .wired),
            (Port.usbAudio, .usb), (Port.bluetoothA2DP, .bluetooth), (Port.bluetoothLE, .le),
            (Port.bluetoothHFP, nil), (Port.hdmi, .other), (Port.displayPort, .other), (Port.lineOut, .other),
            (Port.airPlay, .other), (Port.carAudio, .other), (Port.thunderbolt, .other), (Port.pci, .other),
            (Port.fireWire, .other), (Port.avb, .other), (Port.virtual, .other), (Port.lineIn, nil),
            (Port.builtInMic, nil), (Port.headsetMic, nil), ("SyntheticFuturePort", .other), ("", .other),
        ]
        for (portType, kind) in expected {
            XCTAssertEqual(OutputKind.forPortType(portType), kind, portType)
            XCTAssertEqual(RouteOutput(portType: portType, uid: "synthetic").kind, kind, portType)
        }
        // HEARING_AID and DEFAULT are never produced from a port on iOS.
        for portType in expected.map({ $0.0 }) {
            XCTAssertNotEqual(OutputKind.forPortType(portType), .hearingAid)
            XCTAssertNotEqual(OutputKind.forPortType(portType), .default)
        }
    }

    func testRouteLabelsComeFromTheHostAllowList() {
        let expected: [(String, String?)] = [
            (Port.builtInSpeaker, "phone speaker"), (Port.builtInReceiver, "earpiece"),
            (Port.headphones, "wired headphones"), (Port.usbAudio, "USB audio"),
            (Port.bluetoothA2DP, "Bluetooth A2DP media"), (Port.bluetoothLE, "Bluetooth LE audio"),
            (Port.bluetoothHFP, "Bluetooth SCO voice"), (Port.hdmi, "HDMI"), (Port.displayPort, "HDMI"),
            (Port.lineOut, "line output"), (Port.airPlay, "other"), (Port.carAudio, "other"),
            (Port.thunderbolt, "other"), (Port.pci, "other"), (Port.fireWire, "other"), (Port.avb, "other"),
            (Port.virtual, "other"), ("SyntheticFuturePort", "other"), (Port.lineIn, nil),
            (Port.builtInMic, nil), (Port.headsetMic, nil),
        ]
        for (portType, label) in expected {
            XCTAssertEqual(OutputKind.routeLabel(portType: portType), label, portType)
            XCTAssertEqual(RouteOutput(portType: portType, uid: "synthetic").routeLabel, label, portType)
            if let label {
                XCTAssertTrue(OutputKind.hostRouteLabels.contains(label), label)
            }
        }
        // `report.go:96`, verbatim and in order.
        XCTAssertEqual(
            OutputKind.hostRouteLabels.joined(separator: "|"),
            "phone speaker|earpiece|wired headphones|USB audio|Bluetooth A2DP media|Bluetooth SCO voice|"
                + "Bluetooth LE audio|hearing aid|HDMI|line output|other")
    }

    func testPortTypeRawValuesAgreeWithTheMicrophoneOwner() {
        // Both owners mirror the same `AVAudioSession.Port` constants.
        XCTAssertEqual(Port.builtInMic, MicrophoneKind.PortType.builtInMic)
        XCTAssertEqual(Port.headsetMic, MicrophoneKind.PortType.headsetMic)
        XCTAssertEqual(Port.usbAudio, MicrophoneKind.PortType.usbAudio)
        XCTAssertEqual(Port.bluetoothHFP, MicrophoneKind.PortType.bluetoothHFP)
    }

    func testPortTypeConstantsAreDistinct() {
        let all = [
            Port.builtInSpeaker, Port.builtInReceiver, Port.headphones, Port.usbAudio, Port.bluetoothA2DP,
            Port.bluetoothLE, Port.bluetoothHFP, Port.hdmi, Port.displayPort, Port.lineOut, Port.airPlay,
            Port.carAudio, Port.thunderbolt, Port.pci, Port.fireWire, Port.avb, Port.virtual, Port.lineIn,
            Port.builtInMic, Port.headsetMic,
        ]
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testRouteOutputIdentityIsPortTypeAndUID() {
        let left = RouteOutput(portType: Port.bluetoothA2DP, uid: "synthetic-left")
        XCTAssertEqual(left, RouteOutput(portType: Port.bluetoothA2DP, uid: "synthetic-left"))
        XCTAssertNotEqual(left, RouteOutput(portType: Port.bluetoothA2DP, uid: "synthetic-right"))
        XCTAssertNotEqual(left, RouteOutput(portType: Port.bluetoothLE, uid: "synthetic-left"))
        XCTAssertEqual(Set([left, left, RouteOutput(portType: Port.bluetoothLE, uid: "synthetic-left")]).count, 2)
    }

    func testRouteOutputTextAndReflectionNeverContainTheUID() {
        let uid = "AA:BB:CC:DD:EE:10-tacl"
        let output = RouteOutput(portType: Port.bluetoothA2DP, uid: uid)
        var dumped = ""
        dump(output, to: &dumped)
        for text in [
            output.description, output.debugDescription, "\(output)", String(describing: output),
            String(reflecting: output), "\([output])", dumped,
        ] {
            XCTAssertFalse(text.contains(uid), text)
            XCTAssertFalse(text.contains("AA:BB"), text)
            XCTAssertTrue(text.contains(Port.bluetoothA2DP), text)
        }
        XCTAssertEqual(output.description, "RouteOutput(BluetoothA2DPOutput)")
    }
}
