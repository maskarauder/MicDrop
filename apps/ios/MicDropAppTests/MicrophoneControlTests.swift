import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Drives `MicrophoneControl` with fake ports, capture and host gate; no audio unit or HTTP is created.
final class MicrophoneControlTests: XCTestCase {
    private static let usb = AudioPortDescriptor(
        uid: "test-usb", type: MicrophoneKind.PortType.usbAudio, isInput: true)

    private final class Session: MicrophoneRouting.SessionControl {
        var available = [MicrophoneControlTests.usb]
        func availableInputs() -> [AudioPortDescriptor]? { available }
        func currentInputs() -> [AudioPortDescriptor] { [MicrophoneControlTests.usb] }
        func currentOutputs() -> [AudioPortDescriptor] { [] }
        var sampleRate: Double { 48_000 }
        var outputNumberOfChannels: Int { 2 }
        var isActive: Bool { true }
        var categoryRawValue: String { AudioSessionPlan.Category.playAndRecord.rawValue }
        var modeRawValue: String { AudioSessionPlan.Mode.default.rawValue }
        var categoryOptionsRawValue: UInt { 0 }
        func setPreferredInput(uid: String?) throws {}
        func reactivate() throws {}
    }

    private final class Calls: MicrophoneRouting.CallActivity {
        var hasActiveCall: Bool { false }
    }

    private final class Host: MicrophoneControl.HostGate {
        var muted: [Bool] = []
        var timeouts: [Int?] = []
        func setHostMicrophoneGate(token: String, muted: Bool, timeoutMs: Int?) throws {
            self.muted.append(muted)
            timeouts.append(timeoutMs)
        }
    }

    private final class Hooks: MicrophoneControl.Hooks {
        var closed = false
        var networkHeld = false
        var now: Int64 = 1_000
        var desiredMuted = true
        var appliedMuted: Bool?
        var controlDirty = false
        var applicationActive: Bool { true }
        var failures: [SessionFailure] = []
        func withAudioLock<T>(_ body: () -> T) -> T { body() }
        func fail(_ message: String, _ code: SessionFailure) { failures.append(code) }
        func onPhase(_ p: SessionPhase) {}
        func onStatus(_ s: String) {}
        func onMicrophoneState(_ muted: Bool, pending: Bool) {}
        func onMicrophoneSelection(_ s: MicrophoneSelection) {}
        func holdOutputForHeadset() {}
        func verifyOutputForHeadset() {}
        func checkpoint() throws {}
        func sleep(ms: Int) throws {}
        func nowMs() -> Int64 { now }
        func notifyControl() {}
        var keepMicrophoneActiveWhileMuted: Bool { true }
    }

    func testOrdinaryGateUsesTransportBudgetsWhileRestorationClampsToRemainingWindow() throws {
        defer { MicrophoneCapture.setApplicationInputMuted(false) }
        let selection = try XCTUnwrap(MicrophoneSelection(port: Self.usb))
        let session = Session()
        let routing = MicrophoneRouting(
            selection: selection, session: session, calls: Calls(), clock: SystemMonotonicClock(),
            lost: {}, monitor: nil)
        defer { try? routing.close() }
        let recovery = HeadsetRecovery()
        let host = Host()
        let hooks = Hooks()
        let control = MicrophoneControl(
            mode: .microphone, selection: selection, routing: routing,
            capture: MicrophoneCapture(input: MicrophoneCapture.InputInitialization()),
            recovery: recovery, host: host, hooks: hooks)

        try control.apply(token: "test-token")

        XCTAssertEqual(host.muted, [true])
        XCTAssertEqual(host.timeouts, [nil], "ordinary /microphone must use LAN_REQUEST / REMOTE_REQUEST")
        XCTAssertEqual(hooks.appliedMuted, true)

        session.available = []
        XCTAssertTrue(recovery.request(nowMs: 1_000))
        hooks.now = 19_500
        try control.restoreHeadset(token: "test-token")

        XCTAssertEqual(host.muted, [true, true])
        XCTAssertEqual(host.timeouts, [nil, 1_500], "restoration keeps clamp(remaining, 1, 2000)")
        XCTAssertTrue(hooks.failures.isEmpty)
    }
}
