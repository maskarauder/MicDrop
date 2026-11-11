import Foundation
import MicDropCore
import XCTest

/// Remembered input/output devices across launches (`audio-devices.json`): what is stored, strict decoding, the
/// restore rules and how a restored identity is matched against the current route. Synthetic uids only.
final class RememberedAudioDevicesTests: XCTestCase {
    private typealias Stored = AudioPreferences.StoredValue

    private static let secret = "A1:B2:C3:D4:E5:F6-synthetic"
    private static let a2dp = RouteOutput.PortType.bluetoothA2DP
    private static let hfp = MicrophoneKind.PortType.bluetoothHFP

    private static let headphones = RouteOutput(portType: a2dp, uid: secret)
    private static let otherHeadphones = RouteOutput(portType: a2dp, uid: "synthetic-other-headphones")
    private static let speaker = RouteOutput(portType: RouteOutput.PortType.builtInSpeaker, uid: "Built-In Speaker")
    private static let pin = OutputSelection(kind: .bluetooth, portType: a2dp, uid: secret)

    private static let builtInPort = AudioPortDescriptor(
        uid: "synthetic-built-in", type: MicrophoneKind.PortType.builtInMic, isInput: true, name: "iPhone Microphone")
    private static let usbPort = AudioPortDescriptor(
        uid: "synthetic-usb-1", type: MicrophoneKind.PortType.usbAudio, isInput: true, name: "Desk Mic")
    private static let headsetPort = AudioPortDescriptor(
        uid: secret, type: hfp, isInput: true, name: "Synthetic Port Name")

    private static func usb() throws -> MicrophoneSelection { try XCTUnwrap(MicrophoneSelection(port: usbPort)) }
    private static func headset() throws -> MicrophoneSelection {
        try XCTUnwrap(MicrophoneSelection(port: headsetPort))
    }

    // MARK: - Relaunch restore

    func testRelaunchRestoresBothRememberedDevicesForTheirPersistedKinds() throws {
        let usb = try Self.usb()
        let devices = RememberedAudioDevices().remembering(output: Self.pin).remembering(input: usb)
        XCTAssertEqual(devices.output, Self.pin)
        XCTAssertEqual(devices.input, usb)

        // A new process reads the file again.
        let relaunched = RememberedAudioDevices.decodeJSON(try devices.encodedJSON())
        XCTAssertEqual(relaunched, devices)
        XCTAssertEqual(relaunched.restoredOutput(preferredKind: .bluetooth), Self.pin)
        XCTAssertEqual(relaunched.restoredInput(preferredKind: .usb), usb)
        let preferences = AudioPreferences(
            microphoneEnabled: true, preferredInputKind: .usb, preferredOutputKind: .bluetooth)
        XCTAssertFalse(preferences.needsOutputSelection(relaunched.restoredOutput(preferredKind: .bluetooth)))
        XCTAssertFalse(preferences.needsInputSelection(relaunched.restoredInput(preferredKind: .usb)))

        // The headset microphone keeps its pinned endpoint, so it resolves exactly as a fresh choice does.
        let headset = try Self.headset()
        let restoredHeadset = RememberedAudioDevices.decodeJSON(
            try RememberedAudioDevices(input: headset).encodedJSON()
        ).restoredInput(preferredKind: .sco)
        XCTAssertEqual(restoredHeadset, headset)
        XCTAssertEqual(restoredHeadset.headsetEndpoint, HeadsetEndpoint(port: Self.headsetPort))
        XCTAssertTrue(restoredHeadset.sameDevice(headset))
    }

    func testAnIdentityIsRestoredOnlyForTheKindThePreferencesStillName() throws {
        let devices = RememberedAudioDevices(output: Self.pin, input: try Self.usb())
        // The kind changed (another write, an older file): no identity is substituted, the kind alone gates.
        for kind in [OutputKind.wired, .usb, .le, .other] {
            let restored = devices.restoredOutput(preferredKind: kind)
            XCTAssertEqual(restored, OutputSelection(), "\(kind)")
            XCTAssertTrue(AudioPreferences(preferredOutputKind: kind).needsOutputSelection(restored), "\(kind)")
        }
        XCTAssertEqual(devices.restoredOutput(preferredKind: .default), OutputSelection())
        XCTAssertEqual(devices.restoredOutput(preferredKind: .phone), OutputSelection.restored(.phone))
        XCTAssertEqual(devices.restoredOutput(preferredKind: nil), OutputSelection())
        XCTAssertTrue(AudioPreferences(preferredOutputKind: nil).needsOutputSelection(OutputSelection()))

        for kind in [MicrophoneKind.wired, .sco, .le] {
            let restored = devices.restoredInput(preferredKind: kind)
            XCTAssertEqual(restored, MicrophoneSelection(), "\(kind)")
            let enabled = AudioPreferences(microphoneEnabled: true, preferredInputKind: kind)
            XCTAssertTrue(enabled.needsInputSelection(restored), "never silently the built-in microphone (\(kind))")
        }
        XCTAssertEqual(devices.restoredInput(preferredKind: .builtIn), MicrophoneSelection())
        XCTAssertEqual(devices.restoredInput(preferredKind: nil), MicrophoneSelection())

        // Without a file the previous kind-only behavior remains: external kinds must be chosen again.
        let none = RememberedAudioDevices.decodeJSON(nil)
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.restoredOutput(preferredKind: .bluetooth), OutputSelection())
        XCTAssertTrue(AudioPreferences(preferredOutputKind: .bluetooth).needsOutputSelection(OutputSelection()))
    }

    func testWiredChoicesAskForReselectionAfterARelaunch() throws {
        // Wired ports report a port-wide uid on iOS (one identity for every wired device), so a relaunch must not
        // accept whichever wired headphones or headset microphone is plugged in.
        let headphones = OutputSelection(
            kind: .wired, portType: RouteOutput.PortType.headphones, uid: "Wired Headphones")
        let microphone = MicrophoneSelection(
            kind: .wired, portUID: "Wired Microphone", portType: MicrophoneKind.PortType.headsetMic)
        let devices = RememberedAudioDevices(output: Self.pin, input: try Self.usb())
            .remembering(output: headphones).remembering(input: microphone)
        XCTAssertTrue(devices.isEmpty, "the previous pin and input are forgotten as well")
        let relaunched = RememberedAudioDevices.decodeJSON(try devices.encodedJSON())
        let output = relaunched.restoredOutput(preferredKind: .wired)
        XCTAssertEqual(output, OutputSelection())
        XCTAssertTrue(AudioPreferences(preferredOutputKind: .wired).needsOutputSelection(output))
        let input = relaunched.restoredInput(preferredKind: .wired)
        XCTAssertEqual(input, MicrophoneSelection())
        let enabled = AudioPreferences(microphoneEnabled: true, preferredInputKind: .wired)
        XCTAssertTrue(enabled.needsInputSelection(input), "never silently the built-in microphone")

        // A file that names a wired identity (an earlier build) restores nothing either.
        let stored = RememberedAudioDevices.from([
            "outputKind": Stored.string(OutputKind.wired.persistedName),
            "outputPortType": .string(RouteOutput.PortType.headphones), "outputUID": .string("Wired Headphones"),
            "inputKind": .string(AudioPreferences.storageName(of: MicrophoneKind.wired)),
            "inputPortType": .string(MicrophoneKind.PortType.headsetMic), "inputUID": .string("Wired Microphone"),
        ])
        XCTAssertTrue(stored.isEmpty)
    }

    func testRememberedChoicesGrantNoCaptureOrConsent() throws {
        let devices = RememberedAudioDevices(input: try Self.headset())
        let preferences = AudioPreferences(preferredInputKind: .sco)
        XCTAssertFalse(preferences.microphoneEnabled, "the default stays off")
        XCTAssertEqual(preferences.connectionMode, .playback)
        XCTAssertEqual(devices.restoredInput(preferredKind: preferences.preferredInputKind).kind, .sco)
        // Only the device keys are stored: no enable flag, stream mode or ticket.
        let keys = Set(RememberedAudioDevices(output: Self.pin, input: try Self.headset()).fields().keys)
        XCTAssertEqual(keys, Set(RememberedAudioDevices.Key.allCases.map { $0.rawValue }))
        XCTAssertEqual(AudioPreferences.from(preferences.fields()), preferences)
        XCTAssertEqual(Set(preferences.fields().keys), Set(AudioPreferences.Key.allCases.map { $0.rawValue }))
    }

    // MARK: - What is remembered

    func testOnlyExplicitExternalChoicesAreRemembered() throws {
        let remembered = RememberedAudioDevices(output: Self.pin, input: try Self.usb())
        for cleared in [OutputSelection(), OutputSelection.restored(.phone), OutputSelection.fallbackSpeaker()] {
            let next = remembered.remembering(output: cleared)
            XCTAssertNil(next.output, "\(cleared)")
            XCTAssertEqual(next.input, remembered.input, "an output choice keeps the input")
        }
        var returning = Self.pin
        returning.returnOnBluetooth = true
        XCTAssertEqual(RememberedAudioDevices(output: returning).output, Self.pin)
        let usb = OutputSelection(kind: .usb, portType: RouteOutput.PortType.usbAudio, uid: "synthetic-usb")
        let car = OutputSelection(kind: .other, portType: RouteOutput.PortType.carAudio, uid: "synthetic-car")
        let hearing = OutputSelection(kind: .le, portType: RouteOutput.PortType.bluetoothLE, uid: "synthetic-le")
        for pin in [usb, car, hearing] {
            XCTAssertEqual(RememberedAudioDevices(output: pin).output, pin, "\(pin)")
        }
        let invalid = [
            // Wired headphones have a port-wide uid on iOS: remembering it would accept any wired device.
            OutputSelection(kind: .wired, portType: RouteOutput.PortType.headphones, uid: "Wired Headphones"),
            OutputSelection(kind: .bluetooth, portType: Self.a2dp, uid: ""),
            OutputSelection(kind: .bluetooth, portType: Self.a2dp, uid: String(repeating: "x", count: 513)),
            OutputSelection(kind: .bluetooth, portType: RouteOutput.PortType.headphones, uid: "synthetic"),
            OutputSelection(kind: .bluetooth, portType: RouteOutput.PortType.bluetoothHFP, uid: "synthetic"),
            OutputSelection(kind: .hearingAid, portType: RouteOutput.PortType.bluetoothLE, uid: "synthetic"),
            OutputSelection(kind: .phone, portType: RouteOutput.PortType.builtInSpeaker, uid: "synthetic"),
        ]
        for selection in invalid {
            XCTAssertNil(RememberedAudioDevices(output: selection).output, "\(selection)")
        }
        let limit = OutputSelection(
            kind: .bluetooth, portType: Self.a2dp, uid: String(repeating: "x", count: RememberedAudioDevices.uidLimit))
        XCTAssertEqual(RememberedAudioDevices(output: limit).output, limit)

        let builtIn = remembered.remembering(input: MicrophoneSelection())
        XCTAssertNil(builtIn.input, "the built-in microphone forgets the previous input")
        XCTAssertEqual(builtIn.output, Self.pin, "an input choice keeps the output")
        let wiredInput = try XCTUnwrap(
            MicrophoneSelection(
                port: AudioPortDescriptor(
                    uid: "Wired Microphone", type: MicrophoneKind.PortType.headsetMic, isInput: true)))
        XCTAssertNil(RememberedAudioDevices(input: wiredInput).input, "a port-wide wired uid is never remembered")
        XCTAssertNil(remembered.remembering(input: wiredInput).input, "a wired choice forgets the previous input")
        let invalidInputs = [
            MicrophoneSelection(kind: .le, portUID: "synthetic", portType: "BluetoothLE"),
            MicrophoneSelection(kind: .wired),
            MicrophoneSelection(kind: .usb, portUID: "", portType: MicrophoneKind.PortType.usbAudio),
            MicrophoneSelection(kind: .usb, portUID: "synthetic", portType: MicrophoneKind.PortType.headsetMic),
            MicrophoneSelection(
                kind: .sco, portUID: "synthetic", portType: Self.hfp,
                headsetEndpoint: HeadsetEndpoint(type: MicrophoneKind.PortType.usbAudio, uid: "synthetic")),
        ]
        for selection in invalidInputs {
            XCTAssertNil(RememberedAudioDevices(input: selection).input, "\(selection)")
        }
        // An HFP selection built without an endpoint is stored with one, as `MicrophoneSelection(port:)` builds it.
        let bare = MicrophoneSelection(kind: .sco, portUID: Self.secret, portType: Self.hfp)
        XCTAssertEqual(RememberedAudioDevices(input: bare).input, try Self.headset())
    }

    // MARK: - Matching a restored identity against the current route

    func testReconnectingTheSameDeviceMakesTheRestoredSelectionUsableAgain() throws {
        let restored = RememberedAudioDevices(output: Self.pin).restoredOutput(preferredKind: .bluetooth)
        // Missing at launch: unavailable, never resolved to the speaker that is playing instead.
        XCTAssertNil(restored.refresh([Self.speaker], speakerPinnable: true))
        XCTAssertFalse(restored.available(in: [Self.speaker], speakerPinnable: true))
        XCTAssertFalse(restored.available(in: [], speakerPinnable: false))
        // The same headphones return: the remembered selection is retained as is.
        XCTAssertEqual(restored.refresh([Self.headphones], speakerPinnable: false), restored)
        XCTAssertTrue(restored.verifies([Self.headphones]))
        XCTAssertEqual(restored.resolve([Self.speaker, Self.headphones]), Self.headphones)
        XCTAssertFalse(restored.verifies([Self.speaker, Self.headphones]), "audio stays gated off a mixed route")

        let usb = RememberedAudioDevices(input: try Self.usb()).restoredInput(preferredKind: .usb)
        XCTAssertNil(usb.resolveInput([Self.builtInPort]), "never the built-in microphone instead")
        XCTAssertEqual(usb.resolveInput([Self.builtInPort, Self.usbPort]), Self.usbPort)

        let headset = RememberedAudioDevices(input: try Self.headset()).restoredInput(preferredKind: .sco)
        XCTAssertNil(headset.refreshBluetooth([Self.builtInPort]))
        XCTAssertEqual(headset.refreshBluetooth([Self.builtInPort, Self.headsetPort]), try Self.headset())
        XCTAssertEqual(headset.resolveInput([Self.headsetPort]), Self.headsetPort)
    }

    func testMissingChangedOrDuplicatedIdentitiesStayUnavailable() throws {
        let restored = RememberedAudioDevices(output: Self.pin).restoredOutput(preferredKind: .bluetooth)
        let sameNameNewUID = RouteOutput(portType: Self.a2dp, uid: "synthetic-same-model")
        let otherProfiles = [
            RouteOutput(portType: RouteOutput.PortType.bluetoothLE, uid: Self.secret),
            RouteOutput(portType: RouteOutput.PortType.bluetoothHFP, uid: Self.secret),
        ]
        for route in [[Self.otherHeadphones], [sameNameNewUID], otherProfiles, [Self.headphones, Self.headphones]] {
            XCTAssertNil(restored.refresh(route, speakerPinnable: true), "\(route)")
            XCTAssertNil(restored.resolve(route), "\(route)")
            XCTAssertFalse(restored.available(in: route, speakerPinnable: true), "\(route)")
        }
        // The output menu offers the other headphones, but only an explicit choice can select them.
        let route = [(output: Self.otherHeadphones, name: "Headphones")]
        let choices = OutputChoice.list(route: route, speakerPinnable: false)
        XCTAssertFalse(choices.contains { $0.selection == restored })

        let usb = RememberedAudioDevices(input: try Self.usb()).restoredInput(preferredKind: .usb)
        let renamed = AudioPortDescriptor(
            uid: "synthetic-usb-2", type: MicrophoneKind.PortType.usbAudio, isInput: true, name: "Desk Mic")
        XCTAssertNil(usb.resolveInput([renamed]), "a changed uid with the same name is another device")
        XCTAssertNil(usb.resolveInput([Self.usbPort, Self.usbPort]), "a duplicated uid is ambiguous")

        let headset = RememberedAudioDevices(input: try Self.headset()).restoredInput(preferredKind: .sco)
        let endpoint = try XCTUnwrap(headset.headsetEndpoint)
        let otherHeadset = AudioPortDescriptor(uid: "synthetic-other-headset", type: Self.hfp, isInput: true)
        XCTAssertEqual(endpoint.inspect([Self.builtInPort]).state, .profileMissing)
        XCTAssertEqual(endpoint.inspect([otherHeadset]).state, .identityMissing)
        XCTAssertEqual(endpoint.inspect([Self.headsetPort, Self.headsetPort]).state, .ambiguous)
        for inputs in [[Self.builtInPort], [otherHeadset], [Self.headsetPort, Self.headsetPort]] {
            XCTAssertNil(headset.refreshBluetooth(inputs), "\(inputs)")
            XCTAssertNil(headset.resolveInput(inputs), "\(inputs)")
        }
    }

    // MARK: - Storage

    func testStrictDecodingDropsOnlyTheMalformedDevice() throws {
        let valid: [String: Stored] = [
            "outputKind": .string("BLUETOOTH"), "outputPortType": .string(Self.a2dp), "outputUID": .string(Self.secret),
            "inputKind": .string("SCO"), "inputPortType": .string(Self.hfp), "inputUID": .string(Self.secret),
            "unknown": .bool(true),
        ]
        let decoded = RememberedAudioDevices.from(valid)
        XCTAssertEqual(decoded.output, Self.pin)
        XCTAssertEqual(decoded.input, try Self.headset())

        let malformedOutputs: [[String: Stored]] = [
            ["outputKind": .string("bluetooth")],
            ["outputKind": .string("DEFAULT"), "outputPortType": .string("")],
            ["outputKind": .string("PHONE"), "outputPortType": .string(RouteOutput.PortType.builtInSpeaker)],
            ["outputKind": .string("WIRED")],
            ["outputUID": .number(1)],
            ["outputUID": .null],
            ["outputUID": .string("")],
            ["outputPortType": .other],
        ]
        for change in malformedOutputs {
            let fields = valid.merging(change) { _, new in new }
            let result = RememberedAudioDevices.from(fields)
            XCTAssertNil(result.output, "\(change.keys.sorted())")
            XCTAssertEqual(result.input, try Self.headset(), "the input survives a malformed output")
        }
        var missingType = valid
        missingType["outputPortType"] = nil
        XCTAssertNil(RememberedAudioDevices.from(missingType).output)

        let malformedInputs: [[String: Stored]] = [
            ["inputKind": .string("BUILT_IN")], ["inputKind": .string("LE")], ["inputKind": .string("sco")],
            ["inputKind": .string("USB")], ["inputUID": .bool(true)], ["inputUID": .string("")],
            ["inputPortType": .string(RouteOutput.PortType.bluetoothA2DP)],
        ]
        for change in malformedInputs {
            let result = RememberedAudioDevices.from(valid.merging(change) { _, new in new })
            XCTAssertNil(result.input, "\(change.keys.sorted())")
            XCTAssertEqual(result.output, Self.pin, "the output survives a malformed input")
        }

        for data in [nil, Data(), Data("not json".utf8), Data("[]".utf8), Data("\"x\"".utf8)] as [Data?] {
            XCTAssertEqual(RememberedAudioDevices.decodeJSON(data), RememberedAudioDevices())
        }
        XCTAssertEqual(try RememberedAudioDevices().encodedJSON(), Data("{}".utf8))
        XCTAssertEqual(RememberedAudioDevices.fileName, "audio-devices.json")
        XCTAssertNotEqual(RememberedAudioDevices.fileName, AudioPreferences.fileName)
        XCTAssertNotEqual(RememberedAudioDevices.fileName, AdvancedAudioPreferences.fileName)
    }

    func testStoredFieldsUseEnumNamesAndRoundTrip() throws {
        let devices = RememberedAudioDevices(output: Self.pin, input: try Self.usb())
        let fields = devices.fields()
        XCTAssertEqual(fields["outputKind"], .string("BLUETOOTH"))
        XCTAssertEqual(fields["outputPortType"], .string(Self.a2dp))
        XCTAssertEqual(fields["outputUID"], .string(Self.secret))
        XCTAssertEqual(fields["inputKind"], .string("USB"))
        XCTAssertEqual(fields["inputPortType"], .string(MicrophoneKind.PortType.usbAudio))
        XCTAssertEqual(fields["inputUID"], .string("synthetic-usb-1"))
        XCTAssertEqual(RememberedAudioDevices.from(fields), devices)
        XCTAssertEqual(RememberedAudioDevices(output: Self.pin).fields().count, 3)
        XCTAssertTrue(RememberedAudioDevices().fields().isEmpty)
        let text = String(decoding: try devices.encodedJSON(), as: UTF8.self)
        XCTAssertFalse(text.contains("Desk Mic"), "port names are not stored")
    }

    // MARK: - Redaction

    func testIdentifiersStayOutOfTextReflectionAndReports() throws {
        let headset = try Self.headset()
        let devices = RememberedAudioDevices(output: Self.pin, input: headset)
        let endpoint = try XCTUnwrap(headset.headsetEndpoint)
        let values: [Any] = [
            devices, Self.pin, Self.headphones, headset, endpoint, Self.headsetPort,
            endpoint.inspect([Self.headsetPort]),
            OutputChoice(selection: Self.pin, title: "Bluetooth media output 1"),
            MicrophoneChoice(selection: headset, title: "Bluetooth SCO microphone 1"),
            Optional(devices) as Any, [devices],
        ]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            for text in [String(describing: value), String(reflecting: value), "\(value)", dumped] {
                XCTAssertFalse(text.contains(Self.secret), "uid leaked: \(type(of: value))")
                XCTAssertFalse(text.contains("Synthetic Port Name"), "port name leaked: \(type(of: value))")
            }
        }
        XCTAssertEqual(devices.description, "RememberedAudioDevices(output: bluetooth, input: SCO)")
        XCTAssertEqual(RememberedAudioDevices().description, "RememberedAudioDevices(output: none, input: none)")
        // Copy-report texts name kinds and states only.
        XCTAssertFalse(Self.pin.reportState(recovering: false, pending: false).contains(Self.secret))
        XCTAssertFalse(HeadsetEndpoint.identityText.contains(Self.secret))
        XCTAssertFalse(String(decoding: try AudioPreferences().encodedJSON(), as: UTF8.self).contains("UID"))
    }
}
