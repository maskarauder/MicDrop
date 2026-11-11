import Foundation
import XCTest

@testable import MicDropCore

/// The iPhone `audio.output` rules of phone settings exchange v1: where a Windows choice applies live, which outputs it
/// may name, and the value and choices Windows sees. Synthetic uids only; the test token is the readable identity
/// instead of the app's salted SHA-256.
final class PhoneOutputControlTests: XCTestCase {
    private static let speaker = RouteOutput(portType: RouteOutput.PortType.builtInSpeaker, uid: "synthetic-speaker")
    private static let headphones = RouteOutput(portType: RouteOutput.PortType.headphones, uid: "synthetic-wired")
    private static let bluetooth = RouteOutput(
        portType: RouteOutput.PortType.bluetoothA2DP, uid: "11:22:33:44:55:66-synthetic")
    private static let pin = OutputSelection(kind: .bluetooth, portType: bluetooth.portType, uid: bluetooth.uid)
    private static let wired = OutputSelection(kind: .wired, portType: headphones.portType, uid: headphones.uid)
    private static let usb = OutputSelection(
        kind: .usb, portType: RouteOutput.PortType.usbAudio, uid: "synthetic-usb-output")

    private static func token(_ selection: OutputSelection) -> String {
        "\(selection.kind.rawValue)|\(selection.portType)|\(selection.uid)|\(selection.returnOnBluetooth)"
    }

    private static func route(_ outputs: [RouteOutput], pinnable: Bool = false) -> [OutputChoice] {
        OutputChoice.list(route: outputs.map { (output: $0, name: "Synthetic") }, speakerPinnable: pinnable)
    }

    private static func field(
        _ route: [OutputChoice], session: OutputSelection?, saved: OutputSelection = OutputSelection(),
        available: Bool = false, maxListed: Int = 31
    ) -> (value: String, entries: [PhoneOutputControl.Entry]) {
        PhoneOutputControl.choices(
            route: route, session: session, saved: saved, maxListed: maxListed, available: { _ in available },
            token: token)
    }

    /// `live` exactly where a Windows choice switches the running route: playback and duplex with a phone, wired or
    /// USB microphone (`StreamMode.usesMediaOutput`, which the controllers report as `outputAppliesLive`);
    /// `next_connection` with a Bluetooth headset microphone and for microphone-only.
    func testTheOutputIsLiveOnlyWhereTheSessionPlaysThroughAMediaOutput() {
        XCTAssertEqual(PhoneOutputControl.effect(appliesLive: true), .live)
        XCTAssertEqual(PhoneOutputControl.effect(appliesLive: false), .nextConnection)
        for kind in MicrophoneKind.allCases {
            XCTAssertTrue(StreamMode.playback.usesMediaOutput(kind), "playback, \(kind)")
            XCTAssertFalse(StreamMode.microphone.usesMediaOutput(kind), "microphone-only, \(kind)")
            XCTAssertEqual(StreamMode.duplex.usesMediaOutput(kind), !kind.isBluetooth, "duplex, \(kind)")
        }
        XCTAssertTrue(StreamMode.duplex.usesMediaOutput(MicrophoneKind.builtIn))
        XCTAssertTrue(StreamMode.duplex.usesMediaOutput(MicrophoneKind.wired))
        XCTAssertTrue(StreamMode.duplex.usesMediaOutput(MicrophoneKind.usb))
        XCTAssertFalse(StreamMode.duplex.usesMediaOutput(MicrophoneKind.sco))
    }

    /// Windows may name only an output the next Connect can restore: never wired headphones (port-wide uid) and never
    /// the temporary iPhone speaker (saved as iPhone media output).
    func testSavableExcludesWiredHeadphonesAndTheTemporarySpeaker() {
        XCTAssertTrue(PhoneOutputControl.savable(OutputSelection()))
        XCTAssertTrue(PhoneOutputControl.savable(OutputSelection.restored(.phone)))
        XCTAssertTrue(PhoneOutputControl.savable(Self.pin))
        XCTAssertTrue(PhoneOutputControl.savable(Self.usb))
        XCTAssertFalse(PhoneOutputControl.savable(OutputSelection.fallbackSpeaker()))
        XCTAssertFalse(PhoneOutputControl.savable(Self.wired))
        XCTAssertFalse(PhoneOutputControl.savable(OutputSelection(kind: .bluetooth, portType: Self.pin.portType)))
    }

    /// With a session output the value is that output: listed once when savable and in the route; otherwise one
    /// entry is added for it, "(in use)" when the next Connect could not restore it, else the saved labels.
    func testTheSessionOutputIsTheValueAndAnUnsavableOneIsShownInUse() {
        let wiredRoute = Self.route([Self.headphones])
        XCTAssertEqual(wiredRoute.map(\.title), ["iPhone media output", "wired headphones 1 · Synthetic"])
        let wired = Self.field(wiredRoute, session: Self.wired)
        XCTAssertEqual(wired.value, Self.token(Self.wired))
        XCTAssertEqual(
            wired.entries.map(\.label), ["iPhone media output", "wired headphones 1 · Synthetic (in use)"],
            "the session's own title, so Windows shows what plays")
        XCTAssertEqual(wired.entries.map(\.token), [Self.token(OutputSelection()), Self.token(Self.wired)])
        XCTAssertFalse(PhoneOutputControl.savable(wired.entries[1].selection), "apply rejects the in-use entry")

        let temporary = Self.field(Self.route([Self.speaker]), session: .fallbackSpeaker())
        XCTAssertEqual(
            temporary.entries.map(\.label), ["iPhone media output", "iPhone speaker 1", "iPhone speaker (in use)"],
            "the temporary speaker is not the permanent pin")
        XCTAssertEqual(temporary.value, Self.token(.fallbackSpeaker()))

        let routed = Self.field(Self.route([Self.bluetooth]), session: Self.pin, saved: Self.usb)
        XCTAssertEqual(routed.entries.map(\.label), ["iPhone media output", "Bluetooth media output 1 · Synthetic"])
        XCTAssertEqual(routed.value, Self.token(Self.pin), "no saved entry beside the session's output")

        let recovering = Self.field(Self.route([Self.speaker]), session: Self.pin)
        XCTAssertEqual(recovering.entries.last?.label, "Bluetooth media output (saved; unavailable)")
        XCTAssertEqual(recovering.value, Self.token(Self.pin))
        let available = Self.field(Self.route([Self.speaker]), session: Self.pin, available: true)
        XCTAssertEqual(available.entries.last?.label, "Bluetooth media output (saved)")

        for field in [wired, temporary, routed, recovering, available] {
            XCTAssertTrue(field.entries.contains { $0.token == field.value }, "the value is one of the choices")
        }
    }

    /// Without a session output (microphone-only) the saved output is the value, as on Android; a saved selection
    /// is never called "in use".
    func testWithoutASessionOutputTheSavedOutputIsTheValue() {
        let route = Self.route([Self.speaker])
        let missing = Self.field(route, session: nil, saved: Self.pin)
        XCTAssertEqual(
            missing.entries.map(\.label),
            ["iPhone media output", "iPhone speaker 1", "Bluetooth media output (saved; unavailable)"])
        XCTAssertEqual(missing.value, Self.token(Self.pin))
        let saved = Self.field(route, session: nil, saved: Self.pin, available: true)
        XCTAssertEqual(saved.entries.last?.label, "Bluetooth media output (saved)")
        let listed = Self.field(Self.route([Self.bluetooth]), session: nil, saved: Self.pin)
        XCTAssertEqual(listed.entries.count, 2, "a listed saved output appears once")
        XCTAssertEqual(listed.value, listed.entries.last?.token)
        XCTAssertEqual(
            Self.field(Self.route([Self.headphones]), session: nil, saved: Self.wired).entries.map(\.label),
            ["iPhone media output", "wired headphones (saved; unavailable)"])
        XCTAssertEqual(Self.field(route, session: nil).value, Self.token(OutputSelection()))
    }

    /// At most 31 listed outputs plus the value's entry (Go allows 32 choices), each label within the host's 160
    /// bytes without control characters, and one entry per token.
    func testTheChoicesStayWithinTheHostRules() {
        let many = (0..<40).map {
            RouteOutput(portType: RouteOutput.PortType.bluetoothA2DP, uid: "synthetic-bluetooth-\($0)")
        }
        let route = OutputChoice.list(
            route: many.map { (output: $0, name: "Out\u{0007}put " + String(repeating: "é", count: 200)) },
            speakerPinnable: false)
        let field = Self.field(route, session: Self.wired)
        XCTAssertEqual(field.entries.count, 32)
        XCTAssertEqual(field.entries.last?.label, "wired headphones (in use)")
        XCTAssertEqual(Set(field.entries.map(\.token)).count, 32)
        for entry in field.entries {
            XCTAssertLessThanOrEqual(entry.label.utf8.count, PhoneControl.maxLabelBytes)
            XCTAssertFalse(entry.label.unicodeScalars.contains { PhoneControl.isControl($0) })
        }
        let twice = Self.field(Self.route([Self.bluetooth, Self.bluetooth]), session: Self.pin)
        XCTAssertEqual(
            twice.entries.map(\.label), ["iPhone media output", "Bluetooth media output 1 · Synthetic"],
            "the same endpoint twice keeps its first entry")
    }
}
