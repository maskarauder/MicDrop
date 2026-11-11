import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// `PlaybackSessionController` over a fake worker (parity): the resume hint marks only Play and focus resumes
/// (`PlaybackService.kt:325, 372, 409`), the phone settings binding exposes and applies "Play desktop audio"
/// (`PlaybackService.kt:234-241`) for the session only and, under phone-control rules, switches the session's output
/// live through `setOutputSelection` so later resumes keep working, and automatic route updates never overwrite an
/// output saved for the next connection outside the session (`PlaybackService.kt:246-251`). Creates no audio session,
/// capture or HTTP; the activation never touches `RTCAudioSession` and the stores live in a temporary directory.
final class PlaybackSessionControllerTests: XCTestCase {
    private static let pin = OutputSelection(
        kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-bluetooth-output")

    private final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
        func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
    }

    private final class Receiver: StreamReceiving {
        let callbacks: SessionCallbacks
        private(set) var closes: [StopReason] = []
        private(set) var outputEnabled: [Bool] = []
        /// Every output switch forwarded to this worker (`setOutputSelection`, the gated route change).
        private(set) var selections: [OutputSelection] = []
        /// Whether a reported output selection belongs to this worker (`matchesOutputSelection`).
        var outputSelectionMatches = false
        init(_ callbacks: SessionCallbacks) { self.callbacks = callbacks }
        func start() {}
        func close(_ reason: StopReason) { closes.append(reason) }
        func setOutputEnabled(_ enabled: Bool) { outputEnabled.append(enabled) }
        func setOutputSelection(_ s: OutputSelection) { selections.append(s) }
        func setOutputFocus(_ p: OutputPause?) {}
        func setMicrophoneMuted(_ muted: Bool) { XCTFail("playback has no microphone") }
        var microphoneMuteRequested: Bool { true }
        func matchesOutputSelection(_ s: OutputSelection) -> Bool { outputSelectionMatches }
        func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool { false }
        func mediaOutputBecomingNoisy() -> Bool { false }
        func outputSwitchPending() -> Bool { false }
        func expireBackgroundSetup() {}
    }

    private final class Made {
        var receivers: [Receiver] = []
        /// Every worker configuration, in Connect order.
        var configurations: [SessionConfiguration] = []
        var store: AudioPreferencesStore?
        let clock = Clock()
        /// The provider refresh accepts the iPhone speaker pin only while this is true (the playback plan's
        /// `speakerPinnable`); every other output always refreshes.
        var speakerPinnable = true
    }

    /// The live settings of a playback session: "Play desktop audio" and its output, which applies live.
    private static func live(_ enabled: Bool, _ output: OutputSelection = OutputSelection()) -> PhoneLiveSettings {
        PhoneLiveSettings(outputEnabled: enabled, output: output, outputAppliesLive: true)
    }

    private static func pairedLink() throws -> String {
        try ConnectionLink.paired(
            host: "192.168.1.2", port: 8443, hostKey: String(repeating: "ab", count: 32),
            clientKey: String(repeating: "cd", count: 32)
        ).pairedRecord()
    }

    /// A playback controller whose saved connection is `pairedLink()` (so a media-Play lookup matches the ticket),
    /// connected once with a fake worker that is still CONNECTING. `outputEnabled` is the saved "Play desktop audio",
    /// which the Connect passes as the UI does (`MainViewModel.swift:865`).
    @MainActor
    private func connectedController(_ made: Made, outputEnabled: Bool = true) throws -> PlaybackSessionController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let link = try Self.pairedLink()
        let store = AudioPreferencesStore(directory: directory)
        store.update { previous in
            var next = previous
            next.outputEnabled = outputEnabled
            return next
        }
        made.store = store
        let lease = BackgroundExecutionLease.Backend(begin: { _, _ in 1 }, end: { _ in })
        let dependencies = PlaybackSessionController.Dependencies(
            arbiter: AudioSessionArbiter(owner: AudioSessionOwner()),
            preferences: store,
            pausedPlayback: PausedPlaybackStore(directory: directory),
            controlLog: ControlEventLog(clock: made.clock), clock: made.clock,
            makeReceiver: { configuration, callbacks in
                let receiver = Receiver(callbacks)
                made.receivers.append(receiver)
                made.configurations.append(configuration)
                return receiver
            },
            outputAvailable: { _ in true },
            outputRefresh: { selection in made.speakerPinnable || selection.kind != .phone ? selection : nil },
            loadSavedLink: { link }, rememberLink: { _ in },
            makeLease: { name, onExpire in BackgroundExecutionLease(name: name, backend: lease, onExpire: onExpire) },
            prepareAudio: { plan, completion in
                completion(.success(AudioSessionArbiter.Activation(id: .max, plan: plan)))
            },
            advancedAudio: { AdvancedAudioPreferences() })
        let controller = PlaybackSessionController(dependencies: dependencies)
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: false, outputEnabled: store.load().outputEnabled,
            outputSelection: OutputSelection())
        XCTAssertEqual(made.configurations.count, 1)
        return controller
    }

    /// The newest worker, after it reported PLAYING (the session is resumable from here).
    @MainActor
    private func playing(_ made: Made) throws -> Receiver {
        let receiver = try XCTUnwrap(made.receivers.last)
        receiver.callbacks.onPhase(.playing)
        return receiver
    }

    /// Pause, and the worker's end after its `/stop user_pause`.
    @MainActor
    private func pauseAndEnd(_ controller: PlaybackSessionController, _ receiver: Receiver) {
        controller.pause()
        XCTAssertEqual(controller.view.phase, .pausing)
        receiver.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(controller.view.phase, .paused)
    }

    /// The media-Play lookup is a main-actor `Task`: run the main queue until `condition` holds.
    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: - Resume hint

    /// Lock-screen/Control Center Play from PAUSED (the saved-ticket lookup) and a Play queued during PAUSING are
    /// manual resumes; the first Connect is not.
    @MainActor
    func testMediaPlayAndAQueuedPlayCarryTheResumeHint() throws {
        let made = Made()
        let controller = try connectedController(made)
        XCTAssertEqual(made.configurations.map(\.resume), [nil], "Connect")

        pauseAndEnd(controller, try playing(made))
        controller.playFromMediaControls()
        waitUntil { made.configurations.count == 2 }
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .manual], "media Play from PAUSED")

        let second = try playing(made)
        controller.pause()
        controller.playFromMediaControls()
        XCTAssertEqual(made.configurations.count, 2, "queued until the worker ended")
        second.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .manual, .manual], "a Play queued during PAUSING")
        XCTAssertEqual(made.configurations.map(\.reconnect), [false, true, true])
        controller.stop()
    }

    /// Every interruption resume carries its specific reason: `focusRegain` for focus return, `manual` for a user Play
    /// while INTERRUPTED and `manual` for a Play after the 5-minute window turned the interruption into PAUSED.
    @MainActor
    func testInterruptionResumesCarryTheResumeHint() throws {
        let made = Made()
        let controller = try connectedController(made)
        func interrupt(_ receiver: Receiver) {
            controller.interruptionBegan()
            receiver.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
            XCTAssertEqual(controller.view.phase, .interrupted)
        }

        interrupt(try playing(made))
        controller.interruptionEnded(shouldResume: true)
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .focusRegain], "focus return")

        interrupt(try playing(made))
        controller.playFromMediaControls()
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .focusRegain, .manual], "Play while INTERRUPTED")

        interrupt(try playing(made))
        made.clock.advance(PlaybackSessionController.interruptionWindowMs)
        controller.playFromMediaControls()
        XCTAssertEqual(controller.view.phase, .paused, "the window lapsed: PAUSED, then the saved-ticket lookup")
        waitUntil { made.configurations.count == 4 }
        XCTAssertEqual(made.configurations.last?.resume, .manual, "Play after the interruption window")
        controller.stop()
    }

    /// Connect or Reconnect while PAUSED, and Connect after Stop while paused, are explicit connections: Windows
    /// still remembers the pause and only the missing hint makes them new (`controller.go:300-305`).
    @MainActor
    func testConnectAndReconnectNeverCarryTheResumeHint() throws {
        let made = Made()
        let controller = try connectedController(made)
        let link = try Self.pairedLink()
        pauseAndEnd(controller, try playing(made))
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: true, outputEnabled: true,
            outputSelection: OutputSelection())
        XCTAssertEqual(made.configurations.map(\.resume), [nil, nil], "Reconnect while PAUSED")

        pauseAndEnd(controller, try playing(made))
        controller.stop()
        XCTAssertEqual(controller.view.phase, .ended)
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: false, outputEnabled: true,
            outputSelection: OutputSelection())
        XCTAssertEqual(made.configurations.map(\.resume), [nil, nil, nil], "Connect after Stop")
        controller.stop()
    }

    // MARK: - Phone settings exchange v1 (D046)

    /// The binding exposes "Play desktop audio" and the session's output only while the session is active and neither
    /// PAUSING nor STOPPING, applies "Play desktop audio" through `setOutputEnabled` (forwarded, but not saved, so the
    /// next Connect keeps the phone's value) and refuses a microphone field. The session itself, Play from PAUSED
    /// included, keeps the Windows value.
    @MainActor
    func testTheLiveBindingExposesAndAppliesPlayDesktopAudio() throws {
        let made = Made()
        let controller = try connectedController(made)
        let store = try XCTUnwrap(made.store)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        XCTAssertEqual(binding.current(), Self.live(true), "CONNECTING")
        let receiver = try playing(made)
        XCTAssertEqual(binding.current(), Self.live(true))

        try binding.apply(PhoneLiveSettings(outputEnabled: false))
        XCTAssertFalse(controller.view.outputEnabled)
        XCTAssertTrue(store.load().outputEnabled, "a Windows edit is not saved for the next Connect")
        XCTAssertEqual(receiver.outputEnabled, [false])
        XCTAssertEqual(binding.current(), Self.live(false))
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(microphoneMuted: true)), "no microphone")
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(outputEnabled: true, microphoneMuted: false)))
        XCTAssertThrowsError(
            try binding.apply(PhoneLiveSettings(outputEnabled: true, output: Self.pin)), "the output has its own hook")
        XCTAssertEqual(receiver.outputEnabled, [false], "a refused command changes nothing")
        XCTAssertTrue(receiver.selections.isEmpty)

        controller.pause()
        XCTAssertNil(binding.current(), "pausing")
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(outputEnabled: true)))
        receiver.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertNil(binding.current(), "paused: Windows changes nothing until Play")
        XCTAssertTrue(store.load().outputEnabled)

        controller.playFromMediaControls()
        waitUntil { made.configurations.count == 2 }
        let resumed = try XCTUnwrap(made.configurations.last?.phoneControl)
        XCTAssertEqual(resumed.current(), Self.live(false))
        XCTAssertNil(binding.current(), "the earlier session's binding stays empty")
        let resumedReceiver = try playing(made)
        controller.setOutputEnabled(false)
        XCTAssertFalse(store.load().outputEnabled, "the phone's own toggle still saves")
        XCTAssertEqual(resumedReceiver.outputEnabled, [false])
        controller.stop()
        XCTAssertNil(resumed.current(), "stopping")
    }

    /// the ON direction: with "Play desktop audio" saved off, a Windows ON plays desktop audio in this session and is
    /// never saved; Play from PAUSED is the same session and keeps the Windows ON; an explicit Connect from PAUSED,
    /// which the UI makes with the saved value, starts OFF again, so Windows changed no later Connect.
    @MainActor
    func testAWindowsPlayDesktopAudioOnLastsOnlyForTheSession() throws {
        let made = Made()
        let controller = try connectedController(made, outputEnabled: false)
        let store = try XCTUnwrap(made.store)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        XCTAssertEqual(made.configurations.last?.initiallyOutputEnabled, false)
        let receiver = try playing(made)
        XCTAssertEqual(binding.current(), Self.live(false))

        try binding.apply(PhoneLiveSettings(outputEnabled: true))
        XCTAssertTrue(controller.view.outputEnabled)
        XCTAssertEqual(receiver.outputEnabled, [true])
        XCTAssertEqual(binding.current(), Self.live(true))
        XCTAssertFalse(store.load().outputEnabled, "a Windows ON is not saved")

        pauseAndEnd(controller, receiver)
        controller.playFromMediaControls()
        waitUntil { made.configurations.count == 2 }
        XCTAssertEqual(made.configurations.last?.resuming, true)
        XCTAssertEqual(made.configurations.last?.initiallyOutputEnabled, true, "Play from PAUSED keeps the Windows ON")
        XCTAssertEqual(try XCTUnwrap(made.configurations.last?.phoneControl).current(), Self.live(true))
        XCTAssertFalse(store.load().outputEnabled)

        pauseAndEnd(controller, try playing(made))
        controller.connect(
            text: try Self.pairedLink(), fastRecovery: true, baseline: nil, reconnect: true,
            outputEnabled: store.load().outputEnabled, outputSelection: OutputSelection())
        XCTAssertEqual(made.configurations.count, 3)
        XCTAssertEqual(made.configurations.last?.resuming, false, "an explicit Connect")
        XCTAssertEqual(made.configurations.last?.initiallyOutputEnabled, false, "the saved OFF again")
        XCTAssertFalse(controller.view.outputEnabled)
        XCTAssertEqual(try XCTUnwrap(made.configurations.last?.phoneControl).current(), Self.live(false))
        XCTAssertFalse(store.load().outputEnabled)
        controller.stop()
    }

    /// a Windows output choice in PLAYING takes the phone's own `setOutputSelection`: forwarded to the worker (which
    /// keeps playback gated until the new route verifies), adopted by the session and saved like a local choice. So
    /// Play from PAUSED, a Play queued during PAUSING and an interruption resume reuse it and pass the output
    /// preflight; a choice that was only saved ended each of them with `output_reselect`. CONNECTING, SWITCHING and
    /// PAUSED refuse it, nothing reconnects, and "Play desktop audio" is unchanged.
    @MainActor
    func testAWindowsOutputChoiceAppliesToTheRunningSessionAndItsResumes() throws {
        let made = Made()
        let controller = try connectedController(made)
        let store = try XCTUnwrap(made.store)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        XCTAssertThrowsError(try binding.applyOutput(Self.pin), "CONNECTING")
        let receiver = try playing(made)
        XCTAssertTrue(receiver.selections.isEmpty)

        try binding.applyOutput(Self.pin)
        XCTAssertEqual(receiver.selections, [Self.pin], "the worker's gated, verified switch")
        XCTAssertEqual(controller.view.outputSelection, Self.pin)
        XCTAssertEqual(binding.current(), Self.live(true, Self.pin), "Windows now sees the session's new output")
        XCTAssertEqual(store.restoredOutputSelection(), Self.pin, "saved like a local choice")
        XCTAssertEqual(store.load().preferredOutputKind, .bluetooth)
        XCTAssertEqual(store.selectionGeneration, 0, "not a next-connection save")
        XCTAssertTrue(controller.view.outputEnabled)
        XCTAssertTrue(receiver.outputEnabled.isEmpty, "Play desktop audio untouched")
        XCTAssertEqual(made.configurations.count, 1, "no reconnect")

        receiver.callbacks.onPhase(.switching)
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()), "SWITCHING")
        XCTAssertEqual(receiver.selections, [Self.pin])
        receiver.callbacks.onPhase(.playing)

        pauseAndEnd(controller, receiver)
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()), "PAUSED: no live binding")
        controller.playFromMediaControls()
        waitUntil { made.configurations.count == 2 }
        XCTAssertEqual(controller.view.phase, .connecting, "Play from PAUSED passed the output preflight")
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin)

        let second = try playing(made)
        controller.pause()
        controller.playFromMediaControls()
        second.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 3)
        XCTAssertEqual(controller.view.phase, .connecting, "a Play queued during PAUSING")
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin)

        let third = try playing(made)
        controller.interruptionBegan()
        third.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.phase, .interrupted)
        controller.interruptionEnded(shouldResume: true)
        XCTAssertEqual(made.configurations.count, 4)
        XCTAssertEqual(controller.view.phase, .connecting, "an interruption resume")
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin)
        XCTAssertEqual(made.configurations.map(\.initiallyOutputEnabled), [true, true, true, true])
        controller.stop()
    }

    /// Stop right after a Windows output choice wins: the worker closes for the user, the binding goes empty and
    /// refuses a later choice, and nothing restarts when the worker ends.
    @MainActor
    func testStopRightAfterAWindowsOutputChoiceWins() throws {
        let made = Made()
        let controller = try connectedController(made)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        let receiver = try playing(made)
        try binding.applyOutput(Self.pin)
        controller.stop()
        XCTAssertEqual(receiver.closes, [.user])
        XCTAssertNil(binding.current(), "stopping")
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()))
        XCTAssertEqual(receiver.selections, [Self.pin])
        receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(controller.view.phase, .ended)
        XCTAssertEqual(made.configurations.count, 1, "nothing restarts")
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()), "ended")
    }

    /// Windows may pin the iPhone speaker under the in-app chooser's rules only: the provider refresh refuses it while
    /// the plan cannot force the speaker, so the command fails and nothing changes; once it can, the speaker switch is
    /// the same gated request as the phone's own.
    @MainActor
    func testAWindowsSpeakerPinFollowsTheChoosersPinnableRule() throws {
        let made = Made()
        made.speakerPinnable = false
        let controller = try connectedController(made)
        let store = try XCTUnwrap(made.store)
        let binding = try XCTUnwrap(made.configurations.last?.phoneControl)
        let receiver = try playing(made)
        let speaker = OutputSelection.restored(.phone)
        XCTAssertThrowsError(try binding.applyOutput(speaker))
        XCTAssertFalse(controller.setOutputSelection(speaker), "the phone's chooser refuses it the same way")
        XCTAssertTrue(receiver.selections.isEmpty)
        XCTAssertEqual(controller.view.outputSelection, OutputSelection())
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection())

        made.speakerPinnable = true
        try binding.applyOutput(speaker)
        XCTAssertEqual(receiver.selections, [speaker])
        XCTAssertEqual(controller.view.outputSelection, speaker)
        controller.stop()
    }

    /// An automatic route update is saved only while the saved output is the session's previous or new endpoint; an
    /// output saved for the next connection outside this session (modelled with the Windows next-connection save, which
    /// applies only to microphone-only sessions) survives it, and an explicit local choice still saves.
    @MainActor
    func testAnAutomaticOutputUpdateNeverOverwritesAnOutputSavedOutsideTheSession() throws {
        let made = Made()
        let controller = try connectedController(made)
        let store = try XCTUnwrap(made.store)
        let receiver = try playing(made)
        receiver.outputSelectionMatches = true

        // A kind the update will rewrite but that still restores DEFAULT, the session's endpoint: the guard lets a
        // matching update through and it is saved (Android `savedOutput.sameEndpoint(outputSelection)`).
        store.update { previous in
            var next = previous
            next.preferredOutputKind = nil
            return next
        }
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection())
        receiver.callbacks.onOutputSelection(OutputSelection())
        XCTAssertEqual(store.load().preferredOutputKind, .default, "the saved output was the session's: saved")

        let speaker = OutputSelection.restored(.phone)
        store.saveOutputForNextConnection(speaker)
        receiver.callbacks.onOutputSelection(OutputSelection())
        XCTAssertEqual(store.restoredOutputSelection(), speaker, "the other choice is kept for the next Connect")
        XCTAssertEqual(store.load().preferredOutputKind, .phone)
        XCTAssertEqual(controller.view.outputSelection, OutputSelection(), "the session keeps its route")

        XCTAssertTrue(controller.setOutputSelection(OutputSelection()), "an explicit local choice keeps authority")
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection())
        receiver.callbacks.onOutputSelection(OutputSelection())
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection())
        controller.stop()
    }
}
