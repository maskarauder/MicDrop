import AVFoundation
import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Exercises the live event fan-out with fake ports and capture; no audio unit is created.
final class MicrophoneRoutingTests: XCTestCase {
    private static let usb = AudioPortDescriptor(
        uid: "test-usb", type: MicrophoneKind.PortType.usbAudio, isInput: true)
    private static let builtIn = AudioPortDescriptor(
        uid: "test-built-in", type: MicrophoneKind.PortType.builtInMic, isInput: true)

    private final class Session: MicrophoneRouting.SessionControl {
        var available = [MicrophoneRoutingTests.usb]
        var inputs = [MicrophoneRoutingTests.usb]
        var preferredUID: String?
        func availableInputs() -> [AudioPortDescriptor]? { available }
        func currentInputs() -> [AudioPortDescriptor] { inputs }
        func currentOutputs() -> [AudioPortDescriptor] { [] }
        var sampleRate: Double { 48_000 }
        var outputNumberOfChannels: Int { 2 }
        var isActive: Bool { true }
        var categoryRawValue: String { AudioSessionPlan.Category.playAndRecord.rawValue }
        var modeRawValue: String { AudioSessionPlan.Mode.default.rawValue }
        var categoryOptionsRawValue: UInt { 0 }
        func setPreferredInput(uid: String?) throws { preferredUID = uid }
        func reactivate() throws {}
    }

    private final class Calls: MicrophoneRouting.CallActivity {
        var hasActiveCall: Bool { false }
    }

    private final class CaptureEngine: MicrophoneCapture.Engine {
        func setMicrophoneSampleGate(open: Bool) {}
        func setCaptureRunning(_ running: Bool) -> Int { 0 }
    }

    private func routing(
        session: Session, monitor: AudioSessionEventMonitor,
        lost: @escaping @Sendable () -> Void
    ) throws -> MicrophoneRouting {
        let selection = try XCTUnwrap(MicrophoneSelection(port: Self.usb))
        let routing = MicrophoneRouting(
            selection: selection, session: session, calls: Calls(), clock: SystemMonotonicClock(),
            lost: lost, monitor: monitor)
        _ = try routing.prepare(cancelled: { false })
        return routing
    }

    private static var routeChanged: AudioSessionEventMonitor.Event {
        .routeChanged(
            AudioSessionEventMonitor.RouteChange(
                reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                previousOutputs: [], currentOutputs: [], previousInputs: [usb], currentInputs: [builtIn]))
    }

    func testRemovedSelectedInputClosesGateOnPostingThread() throws {
        let monitor = AudioSessionEventMonitor(center: NotificationCenter())
        let session = Session()
        let gateOpen = Locked(true)
        let controller = try routing(session: session, monitor: monitor) { gateOpen.value = false }
        defer { try? controller.close() }
        session.available = [Self.builtIn]
        session.inputs = [Self.builtIn]

        monitor.deliver(Self.routeChanged)

        XCTAssertFalse(gateOpen.value, "route loss must gate before event delivery returns")
    }

    func testInputProbeInvalidatesImmediatelyWhenSelectionRemainsAvailable() throws {
        let monitor = AudioSessionEventMonitor(center: NotificationCenter())
        let session = Session()
        let losses = Locked(0)
        let controller = try routing(session: session, monitor: monitor) { losses.withLock { $0 += 1 } }
        defer { try? controller.close() }
        let input = MicrophoneCapture.InputInitialization()
        input.complete(nil)
        let capture = MicrophoneCapture(input: input)
        let engine = CaptureEngine()
        defer { withExtendedLifetime(engine) {} }
        capture.attach(engine)
        try capture.resume()
        let probe = MicrophoneInputProbe(routing: controller, capture: capture)
        let gateOpen = Locked(true)
        XCTAssertTrue(probe.watch { gateOpen.value = false })
        session.inputs = [Self.builtIn]

        monitor.deliver(Self.routeChanged)

        XCTAssertEqual(losses.value, 0, "availability alone remains healthy; the actual-input watcher must fire")
        XCTAssertFalse(gateOpen.value)
    }

    func testRouteDisconnectedInterruptionUsesRouteLossFanOut() throws {
        let monitor = AudioSessionEventMonitor(center: NotificationCenter())
        let session = Session()
        let losses = Locked(0)
        let controller = try routing(session: session, monitor: monitor) { losses.withLock { $0 += 1 } }
        defer { try? controller.close() }
        session.available = []

        monitor.deliver(.interruptionBegan(.routeDisconnected))

        XCTAssertEqual(losses.value, 1)
    }

    func testFocusAndSuspensionInterruptionsDoNotTriggerRouteLoss() throws {
        let monitor = AudioSessionEventMonitor(center: NotificationCenter())
        let session = Session()
        let losses = Locked(0)
        let controller = try routing(session: session, monitor: monitor) { losses.withLock { $0 += 1 } }
        defer { try? controller.close() }
        session.available = []

        monitor.deliver(.interruptionBegan(.default))
        monitor.deliver(.interruptionBegan(.appWasSuspended))

        XCTAssertEqual(losses.value, 0)
    }

    func testCloseDetachesRouteSinkAndClearsWatchers() throws {
        let monitor = AudioSessionEventMonitor(center: NotificationCenter())
        let session = Session()
        let callbacks = Locked(0)
        let controller = try routing(session: session, monitor: monitor) { callbacks.withLock { $0 += 1 } }
        controller.addRouteWatcher { callbacks.withLock { $0 += 1 } }
        try controller.close()
        session.available = []

        monitor.deliver(Self.routeChanged)
        monitor.deliver(.interruptionBegan(.routeDisconnected))

        XCTAssertNil(session.preferredUID)
        XCTAssertEqual(callbacks.value, 0)
    }
}
