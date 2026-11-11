import MicDropCore
import XCTest

private let builtInMic = MicrophoneKind.PortType.builtInMic
private let headsetMic = MicrophoneKind.PortType.headsetMic
private let usbAudio = MicrophoneKind.PortType.usbAudio
private let hfp = MicrophoneKind.PortType.bluetoothHFP

private func source(_ uid: String, _ type: String, name: String = "") -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: true, name: name)
}

private func sink(_ uid: String, _ type: String) -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: false)
}

/// `T/MicrophoneSelectionTest.kt` adapted to iOS ports: uids instead of ids/addresses; no LE stereo, no masked
/// addresses, no recreated ports.
final class MicrophoneSelectionTests: XCTestCase {
    func testOutputOnlyPortsCannotBeChosenAsMicrophones() {
        XCTAssertNil(MicrophoneSelection().resolveInput([sink("phone", builtInMic)]))
        for type in ["BluetoothA2DPOutput", "Headphones", "BluetoothLEOutput", "Speaker", "Receiver", "HDMIOutput"] {
            XCTAssertNil(MicrophoneSelection(port: source("x", type)), type)
            XCTAssertNil(MicrophoneSelection(port: sink("x", type)), type)
        }
        for type in [builtInMic, headsetMic, usbAudio, hfp] {
            XCTAssertNil(MicrophoneSelection(port: sink("x", type)), type)
        }
    }

    func testDirectSelectionNeverFallsBackToAnotherAttachedInput() {
        for type in [usbAudio, headsetMic] {
            let kind = MicrophoneKind(portTypeRaw: type)!
            let first = source("\(type)-10", type)
            let second = source("\(type)-20", type)
            let phone = source("phone", builtInMic)
            let selected = MicrophoneSelection(kind: kind, portUID: "\(type)-20", portType: type)
            XCTAssertEqual(selected.resolveInput([phone, first, second]), second)
            XCTAssertNil(selected.resolveInput([phone, first]))
            XCTAssertFalse(selected.matchesInput(first))
            XCTAssertFalse(selected.matchesInput(phone))
            XCTAssertTrue(selected.matchesInput(second))
            XCTAssertFalse(selected.matchesInput(sink("\(type)-20", type)))
            XCTAssertFalse(selected.matchesInput(nil))
            XCTAssertEqual(MicrophoneSelection().resolveInput([first, phone]), phone)
        }
    }

    func testDirectSelectionRejectsAmbiguousAndRetypedPorts() {
        let selected = MicrophoneSelection(kind: .usb, portUID: "usb-1", portType: usbAudio)
        // `singleOrNull`: more than one candidate with the selected uid is no proof of the chosen port.
        XCTAssertNil(selected.resolveInput([source("usb-1", usbAudio), source("usb-1", usbAudio, name: "twin")]))
        XCTAssertNil(selected.resolveInput([source("usb-1", headsetMic)]))
        XCTAssertFalse(selected.matchesInput(source("usb-1", headsetMic)))
        XCTAssertNil(selected.resolveInput([sink("usb-1", usbAudio)]))
    }

    func testBuiltInSelectionUsesTheFirstBuiltInInput() {
        let first = source("bottom", builtInMic)
        let second = source("front", builtInMic)
        XCTAssertEqual(MicrophoneSelection().resolveInput([source("usb", usbAudio), first, second]), first)
        XCTAssertTrue(MicrophoneSelection().matchesInput(second))
        XCTAssertFalse(MicrophoneSelection().matchesInput(source("usb", usbAudio)))
        XCTAssertFalse(MicrophoneSelection().matchesInput(sink("bottom", builtInMic)))
    }

    func testBluetoothRequiresThePinnedHeadsetAndItsMatchingInput() throws {
        let input = source("selected", hfp, name: "Headset")
        let selected = try XCTUnwrap(MicrophoneSelection(port: input))
        let wrong = source("other", hfp)
        XCTAssertEqual(selected.resolveInput([wrong, input]), input)
        XCTAssertNil(selected.resolveInput([wrong]))
        XCTAssertNil(selected.resolveInput([]))
        XCTAssertFalse(selected.matchesOutput(input))  // An input is never the output check.
        XCTAssertTrue(selected.matchesOutput(sink("selected", hfp)))
        XCTAssertFalse(selected.matchesOutput(sink("other", hfp)))
        XCTAssertFalse(selected.matchesOutput(nil))
        XCTAssertFalse(selected.matchesInput(wrong))
        XCTAssertFalse(selected.matchesInput(source("selected", builtInMic)))
        XCTAssertTrue(selected.matchesInput(input))
    }

    func testADuplicatedHeadsetIdentityMustBeUnambiguous() throws {
        // `missingBluetoothAddressMustBeUnambiguous`: never pick the first of several Bluetooth microphones.
        let selected = try XCTUnwrap(MicrophoneSelection(port: source("hfp-30", hfp)))
        XCTAssertEqual(selected.resolveInput([source("hfp-30", hfp)]), source("hfp-30", hfp))
        XCTAssertNil(selected.resolveInput([source("hfp-30", hfp), source("hfp-30", hfp, name: "twin")]))
        XCTAssertFalse(selected.matchesOutput(sink("hfp-30", "BluetoothA2DPOutput")))
    }

    func testANewCarConnectionDoesNotAuthorizeItsOutputOrMicrophone() throws {
        let selectedSource = source("headset", hfp)
        let headset = try XCTUnwrap(MicrophoneSelection(port: selectedSource))
        let carSink = sink("car", hfp)
        let carSource = source("car", hfp)
        XCTAssertEqual(headset.resolveInput([carSource, selectedSource]), selectedSource)
        XCTAssertFalse(headset.matchesOutput(carSink))
        XCTAssertFalse(headset.matchesInput(carSource))
        // Removing the selected input never falls back to another HFP input.
        XCTAssertNil(headset.resolveInput([carSource]))
        XCTAssertNil(headset.refreshBluetooth([carSource]))
    }

    func testVoiceInputAndOutputChannelsPerKind() {
        for kind in MicrophoneKind.allCases {
            let selection = MicrophoneSelection(kind: kind)
            XCTAssertEqual(selection.voiceInput, kind == .sco, kind.rawValue)
            XCTAssertEqual(selection.outputChannels, kind == .sco ? 1 : 2, kind.rawValue)
            XCTAssertEqual(selection.isBluetooth, kind.isBluetooth, kind.rawValue)
            XCTAssertTrue(selection.acceptsOutputChannels(selection.outputChannels), kind.rawValue)
            XCTAssertFalse(selection.acceptsOutputChannels(0), kind.rawValue)
            XCTAssertFalse(selection.acceptsOutputChannels(3 - selection.outputChannels), kind.rawValue)
        }
    }

    func testSameDeviceComparesKindUIDAndType() throws {
        let selected = try XCTUnwrap(MicrophoneSelection(port: source("hfp-30", hfp)))
        var withoutEndpoint = selected
        withoutEndpoint.headsetEndpoint = nil
        XCTAssertTrue(selected.sameDevice(withoutEndpoint))
        XCTAssertNotEqual(selected, withoutEndpoint)
        var otherUID = selected
        otherUID.portUID = "hfp-31"
        XCTAssertFalse(selected.sameDevice(otherUID))
        var otherType = selected
        otherType.portType = usbAudio
        XCTAssertFalse(selected.sameDevice(otherType))
        var otherKind = selected
        otherKind.kind = .le
        XCTAssertFalse(selected.sameDevice(otherKind))
        XCTAssertTrue(MicrophoneSelection().sameDevice(.builtIn))
    }

    func testExplicitHeadsetChoiceRetainsIdentityForAFreshManualConnection() throws {
        let original = source("hfp-30", hfp)
        let selected = try XCTUnwrap(
            MicrophoneSelection(kind: .sco, portUID: "hfp-30", portType: hfp).refreshBluetooth([original]))
        XCTAssertEqual(selected.headsetEndpoint, HeadsetEndpoint(type: hfp, uid: "hfp-30"))
        XCTAssertNil(selected.refreshBluetooth([]))
        let car = source("hfp-50", hfp)
        let refreshed = try XCTUnwrap(selected.refreshBluetooth([car, original]))
        XCTAssertEqual(refreshed.portUID, "hfp-30")
        XCTAssertEqual(refreshed.headsetEndpoint, selected.headsetEndpoint)
        XCTAssertEqual(refreshed.resolveInput([car, original]), original)
        XCTAssertNil(refreshed.refreshBluetooth([car]))
        XCTAssertNil(refreshed.refreshBluetooth([original, source("hfp-30", hfp, name: "twin")]))
        // iOS port identity is the uid: a "recreated" port is another headset.
        XCTAssertNil(refreshed.refreshBluetooth([source("hfp-31", hfp)]))
    }

    func testRefreshPreservesTheProfileAndNeverInfersIdentity() throws {
        let selected = try XCTUnwrap(MicrophoneSelection(port: source("hfp-30", hfp)))
        XCTAssertNil(selected.refreshBluetooth([source("hfp-30", builtInMic)]))
        XCTAssertNil(selected.refreshBluetooth([source("hfp-30", "BluetoothLEOutput")]))
        XCTAssertNil(selected.refreshBluetooth([sink("hfp-30", hfp)]))  // inputs only
        XCTAssertNil(MicrophoneSelection().refreshBluetooth([source("hfp-30", hfp)]))
        XCTAssertNil(
            MicrophoneSelection(kind: .usb, portUID: "hfp-30", portType: usbAudio)
                .refreshBluetooth([source("hfp-30", usbAudio)]))
        // An empty uid can never pin a headset.
        XCTAssertNil(MicrophoneSelection(kind: .sco, portUID: "", portType: hfp).refreshBluetooth([source("", hfp)]))
        XCTAssertNil(MicrophoneSelection(kind: .sco, portType: hfp).refreshBluetooth([source("hfp-30", hfp)]))
        // A persisted LE choice has no iOS port and always needs reselection.
        XCTAssertNil(
            MicrophoneSelection(kind: .le, portUID: "le-1", portType: "BluetoothLEOutput")
                .refreshBluetooth([source("le-1", "BluetoothLEOutput")]))
        XCTAssertNil(MicrophoneSelection(kind: .le).resolveInput([source("hfp-30", hfp)]))
    }

    func testThePinnedEndpointIsTheIdentityForBluetoothMatches() throws {
        let endpoint = try XCTUnwrap(HeadsetEndpoint(type: hfp, uid: "pinned"))
        let selection = MicrophoneSelection(kind: .sco, portUID: "stale", portType: hfp, headsetEndpoint: endpoint)
        XCTAssertTrue(selection.matchesInput(source("pinned", hfp)))
        XCTAssertFalse(selection.matchesInput(source("stale", hfp)))
        XCTAssertTrue(selection.matchesOutput(sink("pinned", hfp)))
        XCTAssertFalse(selection.matchesOutput(sink("stale", hfp)))
        XCTAssertEqual(selection.resolveInput([source("stale", hfp), source("pinned", hfp)]), source("pinned", hfp))
        XCTAssertEqual(selection.refreshBluetooth([source("pinned", hfp)])?.portUID, "pinned")
    }

    func testOutputChecksApplyOnlyToBluetoothSelections() {
        let usb = MicrophoneSelection(kind: .usb, portUID: "usb-1", portType: usbAudio)
        XCTAssertFalse(usb.matchesOutput(sink("usb-1", usbAudio)))
        XCTAssertFalse(MicrophoneSelection().matchesOutput(sink("phone", "Speaker")))
        XCTAssertFalse(MicrophoneSelection(kind: .sco, portType: hfp).matchesOutput(sink("", hfp)))
    }

    func testExplicitMonoCapabilitiesRejectStereo() {
        let sco = MicrophoneSelection(kind: .sco, portUID: "hfp-30", portType: hfp)
        XCTAssertTrue(sco.supportsOutputChannels([]))  // Nothing advertised.
        XCTAssertTrue(sco.supportsOutputChannels([0, -1]))  // Nothing positive advertised.
        XCTAssertTrue(sco.supportsOutputChannels([1, 2]))
        XCTAssertTrue(sco.supportsOutputChannels([1]))
        XCTAssertFalse(sco.supportsOutputChannels([2]))
        XCTAssertFalse(sco.supportsOutputChannels([0, 2]))
        XCTAssertTrue(MicrophoneSelection().supportsOutputChannels([2]))
        XCTAssertFalse(MicrophoneSelection().supportsOutputChannels([1]))
    }

    func testSelectionFromASelectorPort() throws {
        XCTAssertEqual(MicrophoneSelection(port: source("bottom", builtInMic)), MicrophoneSelection())
        let wired = try XCTUnwrap(MicrophoneSelection(port: source("wired-1", headsetMic)))
        XCTAssertEqual(wired, MicrophoneSelection(kind: .wired, portUID: "wired-1", portType: headsetMic))
        XCTAssertNil(wired.headsetEndpoint)
        let usb = try XCTUnwrap(MicrophoneSelection(port: source("usb-1", usbAudio)))
        XCTAssertEqual(usb.kind, .usb)
        XCTAssertEqual(usb.portUID, "usb-1")
        let headset = try XCTUnwrap(MicrophoneSelection(port: source("hfp-1", hfp)))
        XCTAssertEqual(headset.kind, .sco)
        XCTAssertEqual(headset.portUID, "hfp-1")
        XCTAssertEqual(headset.portType, hfp)
        XCTAssertEqual(headset.headsetEndpoint, HeadsetEndpoint(type: hfp, uid: "hfp-1"))
        XCTAssertNil(MicrophoneSelection(port: source("", hfp)))
        XCTAssertNil(MicrophoneSelection(port: source("line", "LineIn")))
    }

    func testDefaultsAndRedactedDescriptions() throws {
        let selection = MicrophoneSelection()
        XCTAssertEqual(selection.kind, .builtIn)
        XCTAssertNil(selection.portUID)
        XCTAssertEqual(selection.portType, builtInMic)
        XCTAssertNil(selection.headsetEndpoint)
        XCTAssertEqual(selection, MicrophoneSelection.builtIn)
        XCTAssertEqual(MicrophoneSelection(kind: .wired).portType, headsetMic)
        XCTAssertEqual(MicrophoneSelection(kind: .le).portType, "")
        let headset = try XCTUnwrap(MicrophoneSelection(port: source("SECRET-UID", hfp, name: "Secret Pods")))
        for text in [headset.description, headset.debugDescription, "\(headset)", String(reflecting: headset)] {
            XCTAssertFalse(text.contains("SECRET-UID"), text)
            XCTAssertFalse(text.contains("Secret Pods"), text)
        }
        XCTAssertEqual(headset.description, "MicrophoneSelection(kind: SCO)")
    }
}
