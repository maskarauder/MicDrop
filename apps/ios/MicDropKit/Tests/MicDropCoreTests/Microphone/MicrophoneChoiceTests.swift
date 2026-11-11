import MicDropCore
import XCTest

private let builtInMic = MicrophoneKind.PortType.builtInMic
private let headsetMic = MicrophoneKind.PortType.headsetMic
private let usbAudio = MicrophoneKind.PortType.usbAudio
private let hfp = MicrophoneKind.PortType.bluetoothHFP

private func source(_ uid: String, _ type: String, name: String = "") -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: true, name: name)
}

/// Selector rows (`A/MicrophoneRouting.kt:249-268`): fixed first row, direct inputs then Bluetooth, per-kind numbering,
/// sanitized names, never the uid in a title.
final class MicrophoneChoiceTests: XCTestCase {
    func testOrderNumberingAndTitles() {
        let ports = [
            source("phone-bottom", builtInMic, name: "iPhone Microphone"),
            source("hfp-1", hfp, name: "AirPods Pro"),
            source("usb-1", usbAudio, name: "Blue Yeti"),
            source("wired-1", headsetMic),
            source("usb-2", usbAudio, name: "Mic\u{07}2"),
            source("hfp-2", hfp),
            AudioPortDescriptor(uid: "hfp-1", type: hfp, isInput: false, name: "AirPods Pro"),
            source("a2dp", "BluetoothA2DPOutput", name: "Speaker"),
            source("line", "LineIn", name: "Line"),
        ]
        let choices = MicrophoneChoice.list(ports: ports, includeBluetooth: true)
        XCTAssertEqual(
            choices.map(\.title),
            [
                "Built-in phone microphone",
                "USB microphone 1 · Blue Yeti",
                "wired headset microphone 1",
                "USB microphone 2 · Mic2",
                "Bluetooth SCO microphone 1 · AirPods Pro",
                "Bluetooth SCO microphone 2",
            ])
        XCTAssertEqual(choices[0].selection, MicrophoneSelection())
        XCTAssertEqual(choices[1].selection, MicrophoneSelection(kind: .usb, portUID: "usb-1", portType: usbAudio))
        XCTAssertEqual(
            choices[2].selection, MicrophoneSelection(kind: .wired, portUID: "wired-1", portType: headsetMic))
        XCTAssertEqual(choices[3].selection.portUID, "usb-2")
        XCTAssertEqual(choices[4].selection.kind, .sco)
        XCTAssertEqual(choices[4].selection.headsetEndpoint, HeadsetEndpoint(type: hfp, uid: "hfp-1"))
        XCTAssertEqual(choices[5].selection.headsetEndpoint, HeadsetEndpoint(type: hfp, uid: "hfp-2"))
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        XCTAssertEqual(choices.map(\.id), choices.map(\.title))
        for choice in choices {
            XCTAssertFalse(choice.title.contains("hfp-"), choice.title)
            XCTAssertFalse(choice.title.contains("usb-"), choice.title)
        }
    }

    func testBluetoothRowsAreOmittedWhenTheyCannotBeListedWithoutRerouting() {
        let ports = [source("usb-1", usbAudio), source("hfp-1", hfp, name: "Headset")]
        XCTAssertEqual(
            MicrophoneChoice.list(ports: ports, includeBluetooth: false).map(\.title),
            ["Built-in phone microphone", "USB microphone 1"])
        XCTAssertEqual(MicrophoneChoice.bluetoothUnavailableFooter, "Stop to choose a Bluetooth headset microphone.")
    }

    func testBluetoothPortsWithoutIdentityAreSkippedWithoutConsumingANumber() {
        let ports = [source("", hfp, name: "Ghost"), source("hfp-3", hfp, name: "Real")]
        XCTAssertEqual(
            MicrophoneChoice.list(ports: ports, includeBluetooth: true).map(\.title),
            ["Built-in phone microphone", "Bluetooth SCO microphone 1 · Real"])
    }

    func testTheBuiltInRowIsAlwaysFirstAndOnlyOnce() {
        let empty = MicrophoneChoice.list(ports: [], includeBluetooth: true)
        XCTAssertEqual(empty, [MicrophoneChoice(selection: MicrophoneSelection(), title: "Built-in phone microphone")])
        let builtIns = MicrophoneChoice.list(
            ports: [source("a", builtInMic), source("b", builtInMic)], includeBluetooth: true)
        XCTAssertEqual(builtIns.count, 1)
        XCTAssertEqual(MicrophoneChoice.builtInTitle, "Built-in phone microphone")
    }

    func testDisplayNameRemovesISOControlCharactersAndKeepsSixtyCharacters() {
        XCTAssertEqual(MicrophoneChoice.nameLimit, 60)
        XCTAssertEqual(MicrophoneChoice.displayName("A\u{00}B\u{1F}C\u{7F}D\u{85}E\u{9F}F\nG\tH"), "ABCDEFGH")
        // U+00A0 (no-break space) and U+00A1 are not ISO controls.
        XCTAssertEqual(MicrophoneChoice.displayName("A\u{A0}B\u{A1}"), "A\u{A0}B\u{A1}")
        XCTAssertEqual(MicrophoneChoice.displayName(""), "")
        XCTAssertEqual(MicrophoneChoice.displayName("\u{01}\u{02}"), "")
        let long = String(repeating: "x", count: 61)
        XCTAssertEqual(MicrophoneChoice.displayName(long), String(repeating: "x", count: 60))
        XCTAssertEqual(
            MicrophoneChoice.displayName(String(repeating: "y", count: 60)), String(repeating: "y", count: 60))
        // Controls are removed before truncation.
        let padded = String(repeating: "\u{01}", count: 10) + String(repeating: "z", count: 60)
        XCTAssertEqual(MicrophoneChoice.displayName(padded), String(repeating: "z", count: 60))
        // Never splits a character.
        let emoji = String(repeating: "\u{1F3A7}", count: 70)
        XCTAssertEqual(MicrophoneChoice.displayName(emoji).count, 60)
        XCTAssertEqual(MicrophoneChoice.displayName(emoji), String(repeating: "\u{1F3A7}", count: 60))
    }

    func testTitlesUseTheSanitizedName() {
        let name = "Studio\u{0B}Mic " + String(repeating: "n", count: 80)
        let choices = MicrophoneChoice.list(ports: [source("usb-1", usbAudio, name: name)], includeBluetooth: false)
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices[1].title, "USB microphone 1 · " + MicrophoneChoice.displayName(name))
        XCTAssertTrue(choices[1].title.hasSuffix(String(repeating: "n", count: 50)))
        XCTAssertFalse(choices[1].title.contains("\u{0B}"))
    }
}
