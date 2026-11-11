import Foundation
import MicDropCore
import MicDropTransport
import XCTest

@testable import MicDrop

/// a media-services reset ends a busy session without an output recovery. Microphone modes fail with
/// `microphone_runtime` only while capture was active, every other case stops with `.failure`, and no playout
/// recreation runs. Creates no audio engine.
final class MediaServicesResetTests: XCTestCase {
    private enum Failure: Error { case unexpectedNative }

    private final class Clock: MonotonicClock, @unchecked Sendable {
        func nowMs() -> Int64 { 1_000 }
    }

    private final class Transport: ControlTransport, @unchecked Sendable {
        func send(_ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws
            -> ControlResponse
        {
            throw Failure.unexpectedNative
        }
    }

    private final class Probe: LocalHostProbing, @unchecked Sendable {
        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool { false }
    }

    private final class ICE: RemoteIceFetching, @unchecked Sendable {
        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            throw Failure.unexpectedNative
        }
    }

    /// Capture primitives that always succeed (`resumeRecording() == 0`).
    private final class CaptureEngine: MicrophoneCapture.Engine {
        func setMicrophoneSampleGate(open: Bool) {}
        func setCaptureRunning(_ running: Bool) -> Int { 0 }
    }

    /// Counts playout recreations (`restartPlayout()`); playout is never active.
    private final class Playout: OutputPlayoutEngine {
        let restarts = Locked(0)
        func setRemotePlayoutMuted(_ muted: Bool) {}
        func restartPlayout() throws { restarts.withLock { $0 += 1 } }
        var playoutActive: Bool { false }
        var playoutGlitches: Int64 { 0 }
        var interrupted: Bool { false }
    }

    override func tearDown() {
        // Closing a microphone session sets the app-wide input mute; restore the launch state.
        MicrophoneCapture.setApplicationInputMuted(false)
        super.tearDown()
    }

    private func session(mode: StreamMode, output: OutputSelection = OutputSelection()) throws -> SessionController {
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: "",
            pin: Array(repeating: 1, count: 32), expiresAt: 0, clientKey: String(repeating: "a", count: 64),
            remote: RemoteRoute(
                url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: false))
        let processing = MicrophoneProcessing()
        let configuration = SessionConfiguration(
            link: link, linkText: "test-only", mode: mode, reconnect: true, fastRecovery: true, baseline: nil,
            initiallyOutputEnabled: true, outputSelection: output, protectedDefaultSpeaker: false,
            microphoneSelection: .builtIn, initiallyMicrophoneMuted: true, processing: processing,
            plan: AudioSessionPlan.make(mode: mode, input: MicrophoneSelection.builtIn.kind, processing: processing))
        let owner = AudioSessionOwner()
        let dependencies = SessionDependencies(
            transport: Transport(), localTransport: { _ in Transport() }, localProbe: { _ in Probe() },
            tls: { _ in throw Failure.unexpectedNative }, iceService: RemoteICEService(fetcher: ICE()),
            engineFactory: { _, _, _ in throw Failure.unexpectedNative },
            arbiter: AudioSessionArbiter(owner: owner), owner: owner, clock: Clock(), journalSave: { _ in },
            runtime: { SessionRuntime() })
        return SessionController(configuration, callbacks: .none, dependencies: dependencies)
    }

    /// Delivers `.mediaServicesWereReset` through a monitor in the app's order: the output observers
    /// first, then the synchronous sinks in registration order — `worker` (a worker step that wins the
    /// race against the engine sink), then the engine sink (`MediaEngine.handle` forwards this event as
    /// `MediaEngineEvents.mediaServicesReset()`).
    private func deliverReset(to controller: SessionController, worker: @escaping @Sendable () -> Void = {}) {
        let monitor = AudioSessionEventMonitor()
        let workerSink = monitor.addSynchronousSink { _ in worker() }
        let engineSink = monitor.addSynchronousSink { event in
            if event == .mediaServicesWereReset { controller.engineEvents.mediaServicesReset() }
        }
        monitor.deliver(.mediaServicesWereReset)
        workerSink.cancel()
        engineSink.cancel()
    }

    func testMutedDuplexResetStopsWithFailureInsteadOfMicrophoneRuntime() throws {
        let controller = try session(mode: .duplex)
        let capture = MicrophoneCapture(input: MicrophoneCapture.InputInitialization())
        controller.microphoneCapture = capture
        XCTAssertFalse(capture.captureActive)
        deliverReset(to: controller)
        XCTAssertTrue(controller.isClosed)
        XCTAssertEqual(controller.stopReasonStorage, StopReason.failure)
        XCTAssertNil(controller.failureMessage, "stop(.failure) keeps the ordinary ended text")
        XCTAssertNil(controller.failureEvidence)
    }

    func testCapturingDuplexResetFailsWithMicrophoneRuntime() throws {
        let controller = try session(mode: .duplex)
        let engine = CaptureEngine()
        let capture = MicrophoneCapture(input: MicrophoneCapture.InputInitialization())
        capture.input.complete(nil)
        capture.attach(engine)
        // The capture holds its engine weakly.
        try withExtendedLifetime(engine) { try capture.resume() }
        XCTAssertTrue(capture.captureActive)
        controller.microphoneCapture = capture
        deliverReset(to: controller)
        XCTAssertTrue(controller.isClosed)
        XCTAssertEqual(controller.stopReasonStorage, StopReason.failure)
        XCTAssertEqual(controller.failureMessage, "The selected microphone stopped unexpectedly.")
        XCTAssertEqual(controller.failureEvidence?.code, SessionFailure.microphoneRuntime)
    }

    func testPinnedPlaybackResetStopsWithFailureInsteadOfOutputRuntime() throws {
        let wired = OutputSelection(kind: .wired, portType: RouteOutput.PortType.headphones, uid: "test-wired")
        let controller = try session(mode: .playback, output: wired)
        let playout = Playout()
        let output = controller.outputController
        output.attach(engine: playout)
        XCTAssertFalse(output.recoverableOutputFailed(), "an explicit wired pin has no output recovery")
        deliverReset(to: controller)
        XCTAssertTrue(controller.isClosed)
        XCTAssertEqual(controller.stopReasonStorage, StopReason.failure)
        XCTAssertNil(controller.failureMessage, "not output_runtime")
        XCTAssertNil(controller.failureEvidence)
        output.step()
        XCTAssertEqual(playout.restarts.value, 0)
    }

    func testDefaultPlaybackResetStopsWithFailureAndNeverRecreatesPlayout() throws {
        let controller = try session(mode: .playback)
        let playout = Playout()
        let output = controller.outputController
        output.attach(engine: playout)
        output.startObservers()
        defer { output.stopObservers() }
        let stepped = Locked(false)
        deliverReset(to: controller) {
            // The output observer already saw the reset; the session is still open for this step.
            XCTAssertFalse(controller.isClosed)
            output.recoverableOutputFailed()
            output.step()
            stepped.value = true
        }
        XCTAssertTrue(stepped.value)
        XCTAssertEqual(playout.restarts.value, 0, "no playout recreation after a reset")
        XCTAssertTrue(controller.isClosed)
        XCTAssertEqual(controller.stopReasonStorage, StopReason.failure)
        XCTAssertNil(controller.failureMessage, "not output_runtime")
        XCTAssertNil(controller.failureEvidence)
        output.step()
        XCTAssertEqual(playout.restarts.value, 0)
    }

    func testDefaultPlaybackRecoveryWithoutResetStillRecreatesPlayout() throws {
        let controller = try session(mode: .playback)
        let playout = Playout()
        let output = controller.outputController
        output.attach(engine: playout)
        XCTAssertTrue(output.recoverableOutputFailed())
        output.step()
        XCTAssertEqual(playout.restarts.value, 1)
        XCTAssertFalse(controller.isClosed)
    }
}
