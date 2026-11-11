import MicDropCore
import XCTest

private let a2dp = RouteOutput.PortType.bluetoothA2DP
private let bluetoothLE = RouteOutput.PortType.bluetoothLE
private let speakerPort = RouteOutput.PortType.builtInSpeaker
private let hfpPort = RouteOutput.PortType.bluetoothHFP
private let original = RouteOutput(portType: a2dp, uid: "synthetic-left")
private let other = RouteOutput(portType: a2dp, uid: "synthetic-other")
private let speaker = RouteOutput(portType: speakerPort, uid: "Built-In Speaker")
private let selection = OutputSelection(kind: .bluetooth, portType: a2dp, uid: "synthetic-left")

/// `OutputSelection` with iOS identity `(portType, uid)`. Android port IDs are dropped and "address" is the route uid
/// (`OutputSelectionTest.kt`, `BluetoothOutputSelectionTest.kt`).
final class OutputSelectionTests: XCTestCase {
    func testOnlyTheChosenPortAndUIDCanResolveOrVerify() {
        XCTAssertEqual(selection.resolve([original, other]), original)
        XCTAssertNil(selection.resolve([other]))
        XCTAssertNil(selection.resolve([RouteOutput(portType: hfpPort, uid: original.uid)]))
        XCTAssertNil(selection.resolve([]))
        // Exactly one match; an ambiguous route never chooses the first entry.
        XCTAssertNil(selection.resolve([original, original]))
        XCTAssertTrue(selection.verifies([original]))
        XCTAssertFalse(selection.verifies([]))
        XCTAssertFalse(selection.verifies([original, other]))
        XCTAssertFalse(selection.verifies([RouteOutput(portType: hfpPort, uid: original.uid)]))
        XCTAssertTrue(selection.matches(original))
        XCTAssertFalse(selection.matches(nil))
        XCTAssertFalse(selection.matches(other))
    }

    func testDefaultRoutingAndTheBuiltInSpeakerHaveDifferentContracts() {
        let phone = OutputSelection.restored(.phone)
        XCTAssertEqual(phone.resolve([speaker, original]), speaker)
        XCTAssertTrue(phone.verifies([speaker]))
        // Any built-in speaker uid satisfies a PHONE selection (its uid is empty).
        XCTAssertTrue(phone.verifies([RouteOutput(portType: speakerPort, uid: "another-speaker-uid")]))
        XCTAssertFalse(phone.verifies([original]))
        XCTAssertFalse(phone.verifies([speaker, original]))
        XCTAssertFalse(phone.verifies([RouteOutput(portType: RouteOutput.PortType.builtInReceiver, uid: "receiver")]))
        XCTAssertTrue(OutputSelection().verifies([original]))
        XCTAssertTrue(OutputSelection().verifies([speaker]))
        // DEFAULT accepts any non-empty route, even one whose kind is unknown.
        XCTAssertTrue(OutputSelection().verifies([RouteOutput(portType: hfpPort, uid: "x")]))
        XCTAssertFalse(OutputSelection().verifies([]))
        XCTAssertNil(OutputSelection().resolve([speaker, original]))
        XCTAssertNil(OutputSelection.restored(.bluetooth).resolve([original]))
    }

    func testRestoredKeepsOnlyThePhoneSpeakerAndTheFallbackIsTemporary() {
        XCTAssertEqual(
            OutputSelection.restored(.phone), OutputSelection(kind: .phone, portType: speakerPort, uid: ""))
        for kind in OutputKind.allCases where kind != .phone {
            XCTAssertEqual(OutputSelection.restored(kind), OutputSelection(), "\(kind)")
        }
        XCTAssertEqual(OutputSelection.restored(nil), OutputSelection())
        XCTAssertEqual(OutputSelection.default, OutputSelection())
        let fallback = OutputSelection.fallbackSpeaker()
        XCTAssertEqual(fallback.kind, .phone)
        XCTAssertEqual(fallback.portType, speakerPort)
        XCTAssertEqual(fallback.uid, "")
        XCTAssertTrue(fallback.returnOnBluetooth)
        XCTAssertTrue(fallback.temporarySpeaker)
        XCTAssertTrue(fallback.explicit)
        XCTAssertEqual(fallback.preferenceKind, .default)
        XCTAssertTrue(fallback.verifies([speaker]))
    }

    func testDerivedFlagsAndThePickerRule() {
        let permanent = OutputSelection.restored(.phone)
        let temporary = OutputSelection.fallbackSpeaker()
        XCTAssertFalse(OutputSelection().explicit)
        XCTAssertTrue(permanent.explicit)
        XCTAssertTrue(selection.explicit)
        XCTAssertFalse(permanent.temporarySpeaker)
        // Only PHONE can be temporary.
        let flagged = OutputSelection(kind: .bluetooth, portType: a2dp, uid: "x", returnOnBluetooth: true)
        XCTAssertFalse(flagged.temporarySpeaker)
        XCTAssertEqual(permanent.preferenceKind, .phone)
        XCTAssertEqual(selection.preferenceKind, .bluetooth)
        XCTAssertEqual(OutputSelection().preferenceKind, .default)
        // following the system route keeps the system picker wherever the output menu is; a pin keeps it only while no
        // session is retained (D042, `RememberedDeviceControlsTests`).
        XCTAssertTrue(OutputSelection().followsSystemRoute)
        XCTAssertTrue(temporary.followsSystemRoute)
        XCTAssertFalse(permanent.followsSystemRoute)
        XCTAssertFalse(selection.followsSystemRoute)
    }

    func testSameEndpointUsesKindPortTypeAndUIDOnly() {
        XCTAssertTrue(selection.sameEndpoint(selection))
        XCTAssertFalse(selection.sameEndpoint(OutputSelection(kind: .bluetooth, portType: a2dp, uid: other.uid)))
        XCTAssertFalse(selection.sameEndpoint(OutputSelection(kind: .le, portType: bluetoothLE, uid: original.uid)))
        let otherProfile = OutputSelection(kind: .bluetooth, portType: bluetoothLE, uid: original.uid)
        XCTAssertFalse(selection.sameEndpoint(otherProfile))
        // The temporary flag is not part of the endpoint.
        XCTAssertTrue(OutputSelection.restored(.phone).sameEndpoint(OutputSelection.fallbackSpeaker()))
    }

    func testOnlyTheTemporarySpeakerAcceptsTheReceiversAutomaticReturn() {
        // `SpeakerFallbackReturnTest.kt:112-115`.
        let permanent = OutputSelection.restored(.phone)
        let temporary = OutputSelection.fallbackSpeaker()
        XCTAssertFalse(permanent.acceptsUpdate(OutputSelection()))
        XCTAssertFalse(permanent.acceptsUpdate(temporary))
        XCTAssertTrue(temporary.acceptsUpdate(OutputSelection()))
        XCTAssertFalse(temporary.acceptsUpdate(permanent))
        XCTAssertTrue(temporary.acceptsUpdate(temporary))
        XCTAssertTrue(permanent.acceptsUpdate(permanent))
        XCTAssertTrue(OutputSelection().acceptsUpdate(OutputSelection()))
        XCTAssertFalse(OutputSelection().acceptsUpdate(selection))
        XCTAssertFalse(selection.acceptsUpdate(OutputSelection()))
        XCTAssertTrue(selection.acceptsUpdate(selection))
    }

    func testASessionUpdateNeverReplacesAnotherSavedOutput() {
        // `PlaybackService.kt:246-251`, `MicrophoneService.kt:216-221`: Windows saved B during a session on A.
        let pinned = selection
        let windows = OutputSelection(kind: .bluetooth, portType: a2dp, uid: other.uid)
        XCTAssertTrue(OutputSelection.persistsSessionUpdate(saved: pinned, previous: pinned, update: pinned))
        XCTAssertFalse(OutputSelection.persistsSessionUpdate(saved: windows, previous: pinned, update: pinned))
        XCTAssertFalse(
            OutputSelection.persistsSessionUpdate(
                saved: OutputSelection.restored(.phone), previous: OutputSelection(), update: OutputSelection()))
        // The temporary speaker's automatic return: saved as DEFAULT (its `preferenceKind`), the new endpoint.
        let temporary = OutputSelection.fallbackSpeaker()
        XCTAssertTrue(
            OutputSelection.persistsSessionUpdate(
                saved: OutputSelection(), previous: temporary, update: OutputSelection()))
        XCTAssertTrue(
            OutputSelection.persistsSessionUpdate(
                saved: OutputSelection.restored(.phone), previous: temporary, update: OutputSelection()),
            "the speaker the session left is the saved endpoint")
        XCTAssertFalse(
            OutputSelection.persistsSessionUpdate(saved: windows, previous: temporary, update: OutputSelection()))
    }

    func testRefreshRestoresOnlyTheOriginalRouteDevice() {
        // `BluetoothOutputSelectionTest.kt:13-31`: no port ID exists, so the same uid is the same device.
        XCTAssertEqual(selection.refresh([other, original], speakerPinnable: true), selection)
        XCTAssertNil(selection.refresh([other], speakerPinnable: true))
        XCTAssertNil(selection.refresh([RouteOutput(portType: a2dp, uid: "")], speakerPinnable: true))
        XCTAssertNil(selection.refresh([], speakerPinnable: true))
        XCTAssertNil(selection.refresh([original, original], speakerPinnable: true))
        // An empty-uid external pin can never be restored.
        let addressless = OutputSelection(kind: .bluetooth, portType: a2dp, uid: "")
        XCTAssertNil(addressless.refresh([RouteOutput(portType: a2dp, uid: "")], speakerPinnable: true))
    }

    func testRefreshCannotChangeTheBluetoothProfileOrUseAnInputPort() {
        // `BluetoothOutputSelectionTest.kt:33-40`.
        for portType in [hfpPort, bluetoothLE, RouteOutput.PortType.builtInMic] {
            let candidate = RouteOutput(portType: portType, uid: original.uid)
            XCTAssertNil(selection.refresh([candidate], speakerPinnable: false), portType)
            var changed = selection
            changed.portType = portType
            XCTAssertFalse(selection.sameEndpoint(changed), portType)
        }
    }

    func testLEOutputsRetainTheirOwnProfile() {
        // `BluetoothOutputSelectionTest.kt:80-91`.
        let le = RouteOutput(portType: bluetoothLE, uid: "synthetic-le")
        let pin = OutputSelection(kind: .le, portType: bluetoothLE, uid: le.uid)
        XCTAssertEqual(pin.refresh([le], speakerPinnable: false), pin)
        XCTAssertTrue(pin.verifies([le]))
        XCTAssertNil(pin.refresh([RouteOutput(portType: a2dp, uid: le.uid)], speakerPinnable: false))
    }

    func testRefreshOfDefaultAndPhoneDependsOnlyOnSpeakerPinnability() {
        for pinnable in [false, true] {
            XCTAssertEqual(OutputSelection().refresh([], speakerPinnable: pinnable), OutputSelection())
            XCTAssertTrue(OutputSelection().available(in: [], speakerPinnable: pinnable))
        }
        let phone = OutputSelection.restored(.phone)
        // Pinnable: binding moves the route to the speaker, so PHONE is available anywhere.
        XCTAssertEqual(phone.refresh([original], speakerPinnable: true), phone)
        XCTAssertTrue(phone.available(in: [], speakerPinnable: true))
        // Not pinnable (`.playback` category or a wired/USB microphone).
        XCTAssertNil(phone.refresh([original], speakerPinnable: false))
        XCTAssertFalse(phone.available(in: [original], speakerPinnable: false))
        XCTAssertEqual(phone.refresh([speaker], speakerPinnable: false), phone)
        XCTAssertTrue(phone.available(in: [speaker], speakerPinnable: false))
        let temporary = OutputSelection.fallbackSpeaker()
        XCTAssertEqual(temporary.refresh([speaker], speakerPinnable: false), temporary)
        XCTAssertNil(temporary.refresh([original], speakerPinnable: false))
        XCTAssertTrue(selection.available(in: [original], speakerPinnable: false))
        XCTAssertFalse(selection.available(in: [other], speakerPinnable: true))
    }

    func testReportStateUsesTheIOSWording() {
        // `StreamReceiver.kt:743-744`,.
        XCTAssertEqual(
            OutputSelection().reportState(recovering: false, pending: false), "iPhone media output · iOS routing")
        XCTAssertEqual(
            OutputSelection().reportState(recovering: false, pending: true), "iPhone media output · verifying")
        XCTAssertEqual(selection.reportState(recovering: false, pending: false), "Bluetooth media output · verified")
        XCTAssertEqual(selection.reportState(recovering: false, pending: true), "Bluetooth media output · verifying")
        XCTAssertEqual(
            selection.reportState(recovering: true, pending: true),
            "Bluetooth media output · restoring selected output")
        XCTAssertEqual(
            OutputSelection.fallbackSpeaker().reportState(recovering: false, pending: false),
            "iPhone speaker · verified")
    }

    func testTextAndReflectionRedactTheUID() {
        let uid = "AA:BB:CC:DD:EE:10-tacl"
        let pinned = OutputSelection(kind: .bluetooth, portType: a2dp, uid: uid)
        let choice = OutputChoice(selection: pinned, title: "Bluetooth media output 1")
        var dumped = ""
        dump(pinned, to: &dumped)
        var dumpedChoice = ""
        dump(choice, to: &dumpedChoice)
        for text in [
            pinned.description, pinned.debugDescription, "\(pinned)", String(reflecting: pinned), "\([pinned])",
            "\(choice)", String(reflecting: choice), dumped, dumpedChoice,
        ] {
            XCTAssertFalse(text.contains(uid), text)
            XCTAssertFalse(text.contains("AA:BB"), text)
        }
        XCTAssertEqual(
            pinned.description,
            "OutputSelection(kind: bluetooth, portType: BluetoothA2DPOutput, uid: redacted, returnOnBluetooth: false)")
        XCTAssertEqual(
            OutputSelection().description,
            "OutputSelection(kind: default, portType: none, uid: none, returnOnBluetooth: false)")
    }
}

/// Output menu choices (`OutputDevices.kt:39-53`).
final class OutputChoiceListTests: XCTestCase {
    private func titles(_ choices: [OutputChoice]) -> [String] { choices.map { $0.title } }

    func testDefaultIsAlwaysFirstAndTheSpeakerNeedsAPinOrTheCurrentRoute() {
        XCTAssertEqual(titles(OutputChoice.list(route: [], speakerPinnable: false)), ["iPhone media output"])
        XCTAssertEqual(
            titles(OutputChoice.list(route: [], speakerPinnable: true)), ["iPhone media output", "iPhone speaker 1"])
        let onSpeaker = OutputChoice.list(route: [(output: speaker, name: "Speaker")], speakerPinnable: false)
        XCTAssertEqual(titles(onSpeaker), ["iPhone media output", "iPhone speaker 1"])
        XCTAssertEqual(onSpeaker[0].selection, OutputSelection())
        XCTAssertEqual(onSpeaker[1].selection, OutputSelection.restored(.phone))
        // A multi-output route that merely includes the speaker is not "on the speaker".
        let mixed = OutputChoice.list(
            route: [(output: speaker, name: "Speaker"), (output: original, name: "Headset")], speakerPinnable: false)
        XCTAssertEqual(titles(mixed), ["iPhone media output", "Bluetooth media output 1 · Headset"])
    }

    func testCurrentRouteOutputsBecomeGuardedPinsNumberedPerKind() {
        let usbA = RouteOutput(portType: RouteOutput.PortType.usbAudio, uid: "usb-a")
        let usbB = RouteOutput(portType: RouteOutput.PortType.usbAudio, uid: "usb-b")
        let airPlay = RouteOutput(portType: RouteOutput.PortType.airPlay, uid: "airplay-1")
        let wired = RouteOutput(portType: RouteOutput.PortType.headphones, uid: "wired-1")
        let choices = OutputChoice.list(
            route: [
                (output: original, name: "AirPods Pro"), (output: usbA, name: "Dock"), (output: usbB, name: "DAC"),
                (output: airPlay, name: "Living Room"), (output: wired, name: ""),
            ],
            speakerPinnable: true)
        XCTAssertEqual(
            titles(choices),
            [
                "iPhone media output", "iPhone speaker 1", "Bluetooth media output 1 · AirPods Pro",
                "USB audio output 1 · Dock", "USB audio output 2 · DAC", "audio output 1 · Living Room",
                "wired headphones 1",
            ])
        XCTAssertEqual(choices[2].selection, selection)
        XCTAssertEqual(choices[3].selection, OutputSelection(kind: .usb, portType: usbA.portType, uid: usbA.uid))
        XCTAssertEqual(
            choices[5].selection, OutputSelection(kind: .other, portType: airPlay.portType, uid: airPlay.uid))
        XCTAssertEqual(Set(choices.map { $0.id }).count, choices.count)
        for choice in choices {
            XCTAssertEqual(choice.id, choice.title)
            XCTAssertFalse(choice.selection.returnOnBluetooth)
            for uid in ["synthetic-left", "usb-a", "usb-b", "airplay-1", "wired-1"] {
                XCTAssertFalse(choice.title.contains(uid), choice.title)
            }
        }
    }

    func testNonMediaAndUnidentifiableOutputsAreNeverOffered() {
        let route: [(output: RouteOutput, name: String)] = [
            (output: RouteOutput(portType: hfpPort, uid: "hfp"), name: "Headset"),
            (output: RouteOutput(portType: RouteOutput.PortType.builtInReceiver, uid: "receiver"), name: "Receiver"),
            (output: RouteOutput(portType: a2dp, uid: ""), name: "No identity"),
            (output: RouteOutput(portType: speakerPort, uid: "speaker-2"), name: "Second speaker"),
        ]
        XCTAssertEqual(titles(OutputChoice.list(route: route, speakerPinnable: false)), ["iPhone media output"])
    }

    func testNamesDropControlCharactersAndKeepSixtyCharacters() {
        XCTAssertEqual(OutputChoice.nameLimit, 60)
        XCTAssertEqual(OutputChoice.sanitizedName("Pixel\u{0007} Buds\u{009F}\n"), "Pixel Buds")
        XCTAssertEqual(OutputChoice.sanitizedName("\u{0000}\u{001F}\u{007F}\u{0080}"), "")
        // U+00A0 is not an ISO control character.
        XCTAssertEqual(OutputChoice.sanitizedName("A\u{00A0}B"), "A\u{00A0}B")
        let long = String(repeating: "x", count: 70)
        XCTAssertEqual(OutputChoice.sanitizedName(long), String(repeating: "x", count: 60))
        // Characters, not code units: a composed emoji is never split.
        let thumbsUp = "\u{1F44D}\u{1F3FD}"
        XCTAssertEqual(thumbsUp.count, 1)
        let emoji = String(repeating: thumbsUp, count: 61)
        XCTAssertEqual(OutputChoice.sanitizedName(emoji), String(repeating: thumbsUp, count: 60))
        let choices = OutputChoice.list(route: [(output: original, name: "\u{0001}" + long)], speakerPinnable: false)
        XCTAssertEqual(choices.last?.title, "Bluetooth media output 1 · " + String(repeating: "x", count: 60))
        // A name made only of control characters is omitted like an empty name.
        let silent = OutputChoice.list(route: [(output: original, name: "\u{0002}\u{0003}")], speakerPinnable: false)
        XCTAssertEqual(silent.last?.title, "Bluetooth media output 1")
    }
}
