import AVFoundation
import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Output selection during automatic route recovery: the worker publishes recovery of an existing selection as
/// ROUTE_RECOVERING (only a newly requested output is SWITCHING), the UI and the playback controller accept a choice
/// there, and playback stays gated until the replacement's actual route verifies. Drives `OutputRouteController`
/// through its route observer with a fake current route, host and playout; creates no audio engine and touches no
/// `AVAudioSession` state.
final class OutputRouteRecoveryTests: XCTestCase {
    private static let headsetA = RouteOutput(portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-headset-a")
    private static let headsetB = RouteOutput(portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-headset-b")
    private static let speaker = RouteOutput(portType: RouteOutput.PortType.builtInSpeaker, uid: "test-speaker")
    private static let pinA = OutputSelection(
        kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-headset-a")
    private static let pinB = OutputSelection(
        kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-headset-b")
    private static let phone = OutputSelection.restored(.phone)

    private final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
        func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
    }

    /// The current route as `AVAudioSession` would report it; `.playback` category, so the speaker can never be forced
    /// and a PHONE pin verifies only while the route already is the speaker.
    private final class Inspector: AudioRouteInspecting, @unchecked Sendable {
        let route = Locked<[RouteOutput]>([])
        func currentOutputs() -> [RouteOutputInfo] {
            route.value.map { RouteOutputInfo(output: $0, name: "", channels: 2) }
        }
        var speakerOverrideSupported: Bool { false }
        func overrideToSpeaker() throws { XCTFail("the playback category cannot force the speaker") }
        func clearSpeakerOverride() throws {}
    }

    /// Session side of the controller. Every call arrives on the test thread.
    private final class Host: OutputSessionHost {
        private let lock = NSRecursiveLock()
        weak var controller: OutputRouteController?
        private(set) var closed = false
        private(set) var phases: [SessionPhase] = []
        private(set) var selections: [OutputSelection] = []
        private(set) var failures: [SessionFailure] = []
        private(set) var messages: [String] = []
        private(set) var closes: [StopReason] = []

        var isClosed: Bool { closed }
        var networkHeld: Bool { false }
        var headsetRecoveryPending: Bool { false }

        func withAudioLock<R>(_ body: () throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        func withSessionLocks<R>(_ body: () throws -> R) rethrows -> R { try withAudioLock(body) }

        func fail(_ message: String, code: SessionFailure) {
            failures.append(code)
            messages.append(message)
            end()
        }

        func close(reason: StopReason) {
            closes.append(reason)
            end()
        }

        func publishPhase(_ phase: SessionPhase) { phases.append(phase) }
        func publishStatus(_ text: String) {}
        func outputSelectionChanged(_ selection: OutputSelection) { selections.append(selection) }
        func outputStateChanged(pause: OutputPause?, protectedSpeaker: Bool) {}
        func wakeWorker() {}

        /// `SessionController.close`: marks the session closed and closes the output gates.
        private func end() {
            closed = true
            controller?.close()
        }
    }

    /// Records the remote-track mute; playout is never reported active, so a requested recreation runs.
    private final class Playout: OutputPlayoutEngine {
        let lastMute = Locked<Bool?>(nil)
        let restarts = Locked(0)
        func setRemotePlayoutMuted(_ muted: Bool) { lastMute.value = muted }
        func restartPlayout() throws { restarts.withLock { $0 += 1 } }
        var playoutActive: Bool { false }
        var playoutGlitches: Int64 { 0 }
        var interrupted: Bool { false }
    }

    private final class Harness {
        let clock: Clock
        let inspector: Inspector
        let host: Host
        let playout: Playout
        let output: OutputRouteController

        init(
            selection: OutputSelection, route: [RouteOutput],
            bluetoothRecoveryMs: Int64 = OutputRouteChange.bluetoothRecoveryMs
        ) {
            let clock = Clock()
            let inspector = Inspector()
            let host = Host()
            let playout = Playout()
            inspector.route.value = route
            self.clock = clock
            self.inspector = inspector
            self.host = host
            self.playout = playout
            output = OutputRouteController(
                mode: .playback, microphoneKind: .builtIn, selection: selection, initiallyEnabled: true,
                protectedDefaultSpeaker: false, host: host, engine: playout, inspector: inspector, clock: clock,
                bluetoothRecoveryMs: bluetoothRecoveryMs)
            host.controller = output
        }

        /// Worker start (`StreamReceiver.kt:360, 550`): observers, `/answer` submitted, the first playout
        /// edge, then one worker step that verifies the initial route.
        func start() {
            output.startObservers()
            output.markMediaReady()
            output.playoutDidStart()
            output.step()
        }

        /// Desktop playback is muted at the engine (nothing applied yet counts as muted).
        var muted: Bool { playout.lastMute.value ?? true }

        /// The phase the worker publishes after a healthy heartbeat (`SessionController.processHostStatus`).
        var phase: SessionPhase { output.heartbeatPhase(headsetRecovering: false, healthy: true) }

        /// One `routeChangeNotification` through the session's observer (fan-out).
        func routeChanged(_ reason: AVAudioSession.RouteChangeReason, to route: [RouteOutput]) {
            let previous = inspector.route.value
            inspector.route.value = route
            output.observer.routeChanged(OutputRouteObserver.RouteChange(reason: reason, previous: previous))
        }
    }

    /// The output section of a playback session in `phase`.
    private func render(_ phase: SessionPhase, selection: OutputSelection) -> ControlsRender {
        ControlsDeriver.derive(
            ControlsInput(
                session: SessionView(phase: phase, outputSelection: selection),
                saved: ControlsInput.SavedState(message: "", working: false), selectedOutput: selection))
    }

    func testReplacementHeadsetChosenDuringPinnedHeadsetRecoveryStaysGatedUntilVerified() {
        let harness = Harness(selection: Self.pinA, route: [Self.headsetA])
        let output = harness.output
        defer { output.stopObservers() }
        harness.start()
        XCTAssertFalse(harness.muted, "the initial pin verified")
        XCTAssertEqual(harness.phase, .playing)

        // Headset A disappears; iOS moves the route to the connected headset B and playout restarts.
        harness.routeChanged(.oldDeviceUnavailable, to: [Self.headsetB])
        output.playoutDidStop()
        XCTAssertTrue(harness.muted)
        XCTAssertTrue(output.outputSwitchPending())
        XCTAssertTrue(output.selectedOutputRecovering())
        XCTAssertEqual(output.currentPause(), OutputPause.selectedBluetooth)
        XCTAssertEqual(harness.phase, .routeRecovering, "recovering the existing pin is not a new switch")
        XCTAssertTrue(harness.phase.acceptsOutputChoice)
        let recovering = render(harness.phase, selection: Self.pinA)
        XCTAssertTrue(recovering.outputDeviceEnabled, "the app chooser stays usable during recovery")
        XCTAssertFalse(recovering.systemOutputPickerEnabled, "the system picker stays off while pinned")

        output.step()
        XCTAssertTrue(harness.muted, "A is still missing")
        XCTAssertTrue(harness.host.failures.isEmpty)

        // The user selects B before A's recovery window ends.
        output.setOutputSelection(Self.pinB)
        XCTAssertEqual(harness.host.phases.last, SessionPhase.switching)
        XCTAssertEqual(output.selection, Self.pinB)
        XCTAssertFalse(output.selectedOutputRecovering(), "the new choice cancels A's recovery")
        XCTAssertEqual(harness.phase, .switching, "verifying a newly requested output is a switch")
        XCTAssertTrue(harness.muted)

        // B is the route, but playout has not restarted: nothing verifies the actual output yet, so the worker
        // holds B as a selected-Bluetooth recovery (configured window) and the status returns to ROUTE_RECOVERING.
        output.step()
        XCTAssertEqual(harness.phase, .routeRecovering, "B waits for iOS to restart playout")
        XCTAssertEqual(output.selection, Self.pinB)
        XCTAssertTrue(harness.muted, "the gate stays closed until B's actual route verifies")
        XCTAssertEqual(harness.host.selections, [Self.pinA])
        XCTAssertTrue(harness.host.failures.isEmpty)

        output.playoutDidStart()
        XCTAssertTrue(harness.muted)
        output.step()
        XCTAssertFalse(harness.muted, "B verified")
        XCTAssertEqual(harness.host.selections.last, Self.pinB)
        XCTAssertFalse(output.outputSwitchPending())
        XCTAssertEqual(harness.phase, .playing)
        XCTAssertTrue(harness.host.failures.isEmpty)
        XCTAssertTrue(harness.host.closes.isEmpty)
    }

    func testPhoneChosenLateInHeadsetRecoveryGetsItsOwnVerificationWindow() {
        let harness = Harness(selection: Self.pinA, route: [Self.headsetA])
        let output = harness.output
        defer { output.stopObservers() }
        harness.start()

        // Headset A disappears at t = 1 s; its fixed recovery window ends at 21 s.
        harness.routeChanged(.oldDeviceUnavailable, to: [Self.speaker])
        output.playoutDidStop()
        XCTAssertEqual(harness.phase, .routeRecovering)
        XCTAssertTrue(render(harness.phase, selection: Self.pinA).outputDeviceEnabled)
        harness.clock.advance(19_500)
        output.step()
        XCTAssertTrue(harness.muted, "never the speaker while A is restored")
        XCTAssertTrue(harness.host.failures.isEmpty)

        output.setOutputSelection(Self.phone)
        XCTAssertEqual(harness.phase, .switching)
        output.step()
        XCTAssertTrue(harness.muted, "the speaker route is not verified without playout")
        XCTAssertTrue(harness.host.failures.isEmpty)

        // Past A's original deadline: the replacement keeps its own window and verifies.
        harness.clock.advance(1_000)
        output.playoutDidStart()
        output.step()
        XCTAssertFalse(harness.muted)
        XCTAssertEqual(harness.host.selections.last, Self.phone)
        XCTAssertEqual(harness.phase, .playing)
        XCTAssertTrue(harness.host.failures.isEmpty)
    }

    func testConfiguredBluetoothWindowEndsTheRecoveryOnceAtItsLimit() {
        let harness = Harness(selection: Self.pinA, route: [Self.headsetA], bluetoothRecoveryMs: 7_500)
        let output = harness.output
        defer { output.stopObservers() }
        XCTAssertEqual(output.bluetoothRecoveryLimitMs, 7_500)
        harness.start()

        // A disappears at t = 1 s; the configured window ends at 8.5 s. A later route callback never extends it.
        harness.routeChanged(.oldDeviceUnavailable, to: [Self.speaker])
        output.playoutDidStop()
        XCTAssertEqual(harness.phase, .routeRecovering)
        harness.clock.advance(3_000)
        harness.routeChanged(.newDeviceAvailable, to: [Self.speaker, Self.headsetB])
        output.step()
        harness.clock.advance(4_499)
        output.step()
        XCTAssertTrue(harness.host.failures.isEmpty, "inside the configured window")
        XCTAssertTrue(harness.muted)

        harness.clock.advance(1)
        output.step()
        XCTAssertEqual(harness.host.failures, [.outputRuntime])
        XCTAssertEqual(harness.host.messages, [OutputRouteChange.Text.bluetoothRestoreTimeout(seconds: "7.5")])
        XCTAssertTrue(harness.muted, "never the speaker or headset B")
        output.step()
        XCTAssertEqual(harness.host.failures.count, 1, "one bounded termination")
        XCTAssertEqual(harness.host.selections, [Self.pinA])
    }

    func testStopWinsOverAReplacementChosenDuringRecovery() {
        let harness = Harness(selection: Self.pinA, route: [Self.headsetA])
        let output = harness.output
        defer { output.stopObservers() }
        harness.start()
        harness.routeChanged(.oldDeviceUnavailable, to: [Self.headsetB])
        output.setOutputSelection(Self.pinB)
        let published = harness.host.phases

        harness.host.close(reason: .user)
        output.playoutDidStart()
        output.step()
        XCTAssertTrue(harness.muted, "a verified route cannot reopen a stopped gate")
        output.setOutputSelection(Self.phone)
        XCTAssertEqual(harness.host.phases, published, "no selection is accepted after Stop")
        XCTAssertEqual(harness.host.selections, [Self.pinA])
    }

    /// A Windows `audio.output` choice reaches the worker as the phone chooser's own request (the controllers'
    /// `setOutputSelection` forwards it through `StreamReceiving.setOutputSelection`). Desktop audio stays gated while
    /// the newly requested output is verified and opens once the route verifies. An output that never verifies ends the
    /// session closed when its window ends, never playing elsewhere: here a Bluetooth output that left the route after
    /// Windows listed it, which waits for the configured Bluetooth route recovery window.
    func testARequestedOutputStaysGatedUntilVerifiedAndFailsClosedAtItsWindow() {
        let harness = Harness(selection: OutputSelection(), route: [Self.headsetA], bluetoothRecoveryMs: 7_500)
        let output = harness.output
        defer { output.stopObservers() }
        harness.start()
        XCTAssertFalse(harness.muted, "iPhone media output verified")

        output.setOutputSelection(Self.pinA)
        XCTAssertTrue(harness.muted, "gated while the new output is verified")
        XCTAssertEqual(harness.host.phases.last, SessionPhase.switching)
        XCTAssertEqual(harness.phase, .switching)
        output.step()
        XCTAssertFalse(harness.muted, "A is the actual route")
        XCTAssertEqual(harness.host.selections.last, Self.pinA)
        XCTAssertEqual(harness.phase, .playing)

        // B is not in the route: the gate stays closed and the session fails closed when B's window ends.
        output.setOutputSelection(Self.pinB)
        XCTAssertTrue(harness.muted)
        output.step()
        harness.clock.advance(7_499)
        output.step()
        XCTAssertTrue(harness.muted, "never A or the speaker while B is awaited")
        XCTAssertTrue(harness.host.failures.isEmpty, "inside the window")
        harness.clock.advance(1)
        output.step()
        XCTAssertEqual(harness.host.failures, [.outputRuntime])
        XCTAssertEqual(harness.host.messages, [OutputRouteChange.Text.bluetoothRestoreTimeout(seconds: "7.5")])
        XCTAssertTrue(harness.muted)
        XCTAssertEqual(harness.host.selections.last, Self.pinA, "B was never reported as verified")
    }

    func testDefaultRouteProbingPublishesAPhaseInWhichTheChooserAndControllerAcceptAChoice() {
        let harness = Harness(selection: OutputSelection(), route: [Self.speaker])
        let output = harness.output
        defer { output.stopObservers() }
        harness.start()
        XCTAssertFalse(harness.muted)
        XCTAssertEqual(harness.phase, .playing)

        // Headset B connects while following iPhone media output: the default route is probed.
        harness.routeChanged(.newDeviceAvailable, to: [Self.headsetB])
        XCTAssertTrue(harness.muted)
        XCTAssertTrue(output.outputProbing())
        XCTAssertFalse(output.outputSwitchPending())
        XCTAssertEqual(harness.phase, .routeRecovering)
        let probing = render(harness.phase, selection: OutputSelection())
        XCTAssertTrue(probing.outputDeviceEnabled)
        XCTAssertTrue(probing.systemOutputPickerEnabled, "following the system route keeps its picker")
        XCTAssertEqual(probing.outputDeviceEnabled, harness.phase.acceptsOutputChoice)

        output.setOutputSelection(Self.pinB)
        XCTAssertEqual(harness.host.phases.last, SessionPhase.switching)
        XCTAssertEqual(harness.phase, .switching)
        XCTAssertTrue(harness.muted)
        output.step()
        XCTAssertFalse(harness.muted, "B is the actual route")
        XCTAssertEqual(harness.host.selections.last, Self.pinB)
    }
}

/// `PlaybackSessionController.setOutputSelection` and the UI agree in every live phase (the UI enabled the chooser in
/// ROUTE_RECOVERING, which the controller refused). Uses a fake worker and an activation that never touches
/// `RTCAudioSession`.
final class PlaybackOutputChoiceTests: XCTestCase {
    private final class Clock: MonotonicClock, @unchecked Sendable {
        func nowMs() -> Int64 { 1_000 }
    }

    private final class Receiver: StreamReceiving {
        let callbacks: SessionCallbacks
        private(set) var selections: [OutputSelection] = []
        private(set) var closes: [StopReason] = []
        /// Whether a published output state belongs to this worker (`matchesOutputState`).
        var outputStateMatches = false
        init(_ callbacks: SessionCallbacks) { self.callbacks = callbacks }
        func start() {}
        func close(_ reason: StopReason) { closes.append(reason) }
        func setOutputEnabled(_ enabled: Bool) {}
        func setOutputSelection(_ s: OutputSelection) { selections.append(s) }
        func setOutputFocus(_ p: OutputPause?) {}
        func setMicrophoneMuted(_ muted: Bool) {}
        var microphoneMuteRequested: Bool { true }
        func matchesOutputSelection(_ s: OutputSelection) -> Bool { false }
        func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool { outputStateMatches }
        func mediaOutputBecomingNoisy() -> Bool { false }
        func outputSwitchPending() -> Bool { false }
        func expireBackgroundSetup() {}
    }

    private final class Made {
        var receiver: Receiver?
        var configurations: [SessionConfiguration] = []
        /// Background tasks currently begun through the lease backend.
        var leases = 0
    }

    /// A connected playback controller over a fake worker, with a lease backend that counts held tasks and
    /// the given Advanced Bluetooth route recovery window (never the simulator's saved settings).
    @MainActor
    private func connectedController(
        _ made: Made, bluetoothRecoveryMs: Int = AdvancedAudioPreferences.bluetoothRecoveryLimits.defaultMs
    ) throws -> (PlaybackSessionController, Receiver) {
        let advanced = try AdvancedAudioPreferences(bluetoothRecoveryMs: bluetoothRecoveryMs)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let lease = BackgroundExecutionLease.Backend(
            begin: { _, _ in
                made.leases += 1
                return made.leases
            }, end: { _ in made.leases -= 1 })
        let dependencies = PlaybackSessionController.Dependencies(
            arbiter: AudioSessionArbiter(owner: AudioSessionOwner()),
            preferences: AudioPreferencesStore(directory: directory),
            pausedPlayback: PausedPlaybackStore(directory: directory),
            controlLog: ControlEventLog(clock: clock), clock: clock,
            makeReceiver: { configuration, callbacks in
                let receiver = Receiver(callbacks)
                made.configurations.append(configuration)
                made.receiver = receiver
                return receiver
            },
            outputAvailable: { _ in true }, outputRefresh: { $0 }, loadSavedLink: { nil }, rememberLink: { _ in },
            makeLease: { name, onExpire in BackgroundExecutionLease(name: name, backend: lease, onExpire: onExpire) },
            prepareAudio: { plan, completion in
                completion(.success(AudioSessionArbiter.Activation(id: .max, plan: plan)))
            },
            advancedAudio: { advanced })
        let controller = PlaybackSessionController(dependencies: dependencies)
        let link = try ConnectionLink.paired(
            host: "192.168.1.2", port: 8443, hostKey: String(repeating: "ab", count: 32),
            clientKey: String(repeating: "cd", count: 32)
        ).pairedRecord()
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: false, outputEnabled: true,
            outputSelection: OutputSelection())
        return (controller, try XCTUnwrap(made.receiver))
    }

    /// The phone's chooser, the controller and a Windows `audio.output` choice (the session's phone settings binding)
    /// accept an output in exactly the same phases.
    @MainActor
    func testPlaybackControllerAcceptsAnOutputChoiceExactlyWhenTheChooserIsEnabled() throws {
        let made = Made()
        let (controller, receiver) = try connectedController(made)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        let saved = ControlsInput.SavedState(message: "", working: false)
        let connecting = ControlsDeriver.derive(
            ControlsInput(session: controller.view, saved: saved, selectedOutput: controller.view.outputSelection))
        XCTAssertFalse(connecting.outputDeviceEnabled, "CONNECTING")
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()), "CONNECTING")

        // The worker's phases: default-route probing / selected-output recovery first, then the others.
        let choices = [OutputSelection.restored(.phone), OutputSelection()]
        for (index, phase) in [SessionPhase.routeRecovering, .playing, .recovering, .switching].enumerated() {
            receiver.callbacks.onPhase(phase)
            XCTAssertEqual(controller.view.phase, phase)
            let render = ControlsDeriver.derive(
                ControlsInput(
                    session: controller.view, saved: saved, selectedOutput: controller.view.outputSelection))
            let before = receiver.selections.count
            let choice = choices[index % choices.count]
            let accepted = controller.setOutputSelection(choice)
            XCTAssertEqual(accepted, render.outputDeviceEnabled, "UI/controller agreement in \(phase)")
            XCTAssertEqual(accepted, phase.acceptsOutputChoice, "\(phase)")
            let windows = (try? binding.applyOutput(choices[(index + 1) % choices.count])) != nil
            XCTAssertEqual(windows, accepted, "Windows/chooser agreement in \(phase)")
            XCTAssertEqual(receiver.selections.count, before + (accepted ? 2 : 0), "\(phase)")
        }
        XCTAssertEqual(receiver.selections.first, OutputSelection.restored(.phone), "accepted in routeRecovering")

        controller.stop()
        XCTAssertEqual(receiver.closes, [.user])
        receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(controller.view.phase, .ended)
    }

    /// Review of the ROUTE_RECOVERING change: selected-output recovery used to be SWITCHING, which holds the
    /// background lease while the worker restarts playout; ROUTE_RECOVERING with an output pause keeps it.
    @MainActor
    func testMediaOutputRecoveryHoldsTheBackgroundLeaseLikeSwitching() throws {
        let made = Made()
        let (controller, receiver) = try connectedController(made)
        receiver.outputStateMatches = true
        XCTAssertEqual(made.leases, 1, "CONNECTING")
        receiver.callbacks.onPhase(.playing)
        XCTAssertEqual(made.leases, 0, "running playout keeps the app alive")

        for pause in [OutputPause.selectedBluetooth, .route] {
            receiver.callbacks.onOutputState(pause, false)
            receiver.callbacks.onPhase(.routeRecovering)
            XCTAssertEqual(controller.view.outputPause, pause)
            XCTAssertEqual(made.leases, 1, "\(pause): playout may stop and restart during recovery")
            receiver.callbacks.onOutputState(nil, false)
            receiver.callbacks.onPhase(.playing)
            XCTAssertEqual(made.leases, 0, "\(pause): released once the route verified")
        }
        receiver.callbacks.onPhase(.routeRecovering)
        XCTAssertEqual(made.leases, 0, "no output pause: nothing to restore")
        receiver.callbacks.onPhase(.switching)
        XCTAssertEqual(made.leases, 1)

        controller.stop()
        receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(made.leases, 0, "Stop ends every lease")
    }

    /// The injected Advanced window reaches the worker's configuration and the in-app pause text (IOS-06 step 5).
    @MainActor
    func testConfiguredBluetoothWindowReachesTheWorkerAndThePauseText() throws {
        let made = Made()
        let (controller, receiver) = try connectedController(made, bluetoothRecoveryMs: 7_500)
        XCTAssertEqual(made.configurations.map(\.bluetoothRecoveryMs), [7_500])
        receiver.outputStateMatches = true
        receiver.callbacks.onPhase(.playing)
        receiver.callbacks.onOutputState(.selectedBluetooth, false)
        receiver.callbacks.onPhase(.routeRecovering)
        XCTAssertEqual(controller.view.bluetoothRecoveryMs, 7_500)
        let expected = OutputPause.selectedBluetooth.detail(bluetoothRecoveryMs: 7_500)
        XCTAssertTrue(expected.hasSuffix("(up to 7.5 seconds)."))
        XCTAssertEqual(controller.view.outputPauseDetail, expected)
        let render = ControlsDeriver.derive(
            ControlsInput(
                session: controller.view, saved: ControlsInput.SavedState(message: "", working: false),
                selectedOutput: controller.view.outputSelection))
        XCTAssertTrue(render.statusText.contains(expected), render.statusText)
        controller.stop()
    }
}
