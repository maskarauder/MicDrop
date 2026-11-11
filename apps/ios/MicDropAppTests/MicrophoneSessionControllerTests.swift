import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// `MicrophoneSessionController` over a fake worker (Android main `1dcaa7a` parity follow-up): Now Playing follows
/// the worker's actual retained muted capture rather than the keep-alive setting, and the background lease covers
/// microphone-only headset recovery. Creates no audio session, capture or HTTP; the lease backend only counts.
final class MicrophoneSessionControllerTests: XCTestCase {
    private static let usb = AudioPortDescriptor(
        uid: "test-usb", type: MicrophoneKind.PortType.usbAudio, isInput: true)
    private static let headset = AudioPortDescriptor(
        uid: "test-hfp", type: MicrophoneKind.PortType.bluetoothHFP, isInput: true)
    private static let silenced = "Silenced · microphone capture stopped"
    private static let pin = OutputSelection(
        kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "test-bluetooth-output")

    private final class Clock: MonotonicClock, @unchecked Sendable {
        func nowMs() -> Int64 { 1_000 }
    }

    /// Record permission as iOS reports it now; a test may revoke it mid-session (Settings).
    private final class Permission: MicrophonePermissionProviding, @unchecked Sendable {
        var status: MicrophonePermissions.Status = .granted
        /// Permission prompts requested (Windows must never cause one).
        private(set) var requests = 0
        func request() async -> Bool {
            requests += 1
            return status == .granted
        }
    }

    /// The worker side: keeps the callbacks so the test can publish as the session would (on main).
    private final class Receiver: StreamReceiving {
        let callbacks: SessionCallbacks
        private(set) var closes: [StopReason] = []
        private(set) var outputEnabled: [Bool] = []
        private(set) var muteRequests: [Bool] = []
        /// Every output switch forwarded to this worker (`setOutputSelection`, the gated route change).
        private(set) var selections: [OutputSelection] = []
        var desiredMuted = false
        /// Whether a reported output selection belongs to this worker (`matchesOutputSelection`).
        var outputSelectionMatches = false
        init(_ callbacks: SessionCallbacks) { self.callbacks = callbacks }
        func start() {}
        func close(_ reason: StopReason) { closes.append(reason) }
        func setOutputEnabled(_ enabled: Bool) { outputEnabled.append(enabled) }
        func setOutputSelection(_ s: OutputSelection) { selections.append(s) }
        func setOutputFocus(_ p: OutputPause?) {}
        func setMicrophoneMuted(_ muted: Bool) {
            muteRequests.append(muted)
            desiredMuted = muted
        }
        var microphoneMuteRequested: Bool { desiredMuted }
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
        /// Background tasks currently begun through the lease backend.
        var leases = 0
        /// `reloadKeepAlive` calls (one per new connection).
        var keepAliveReloads = 0
        /// `rememberOutput` calls (session route updates and local choices).
        var outputSaves = 0
        /// The controller's audio preferences and remembered devices (a temporary directory).
        var store: AudioPreferencesStore?
    }

    /// A controller whose Advanced keep-alive setting is on (the default) unless `keep` says otherwise. Its
    /// remembered output is the temporary store's (`made.store`), as in production. `keepAlive` is the Advanced
    /// store whose saved keep-alive `reloadKeepAlive` makes live (none: only counted); `permission` is granted unless
    /// the test changes it.
    @MainActor
    private func makeController(
        _ made: Made, keep: Bool = true, keepAlive: AdvancedAudioPreferencesStore? = nil,
        permission: Permission = Permission()
    ) throws -> MicrophoneSessionController {
        let advanced = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: keep)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = AudioPreferencesStore(directory: directory)
        made.store = store
        let lease = BackgroundExecutionLease.Backend(
            begin: { _, _ in
                made.leases += 1
                return made.leases
            }, end: { _ in made.leases -= 1 })
        return MicrophoneSessionController(
            dependencies: MicrophoneSessionController.Dependencies(
                clock: Clock(), permission: permission,
                inputAvailable: { _ in true },
                outputAvailable: { _, _ in true },
                refreshOutput: { selection, _ in selection },
                loadPreferences: { store.load() },
                updatePreferences: { change in _ = store.update(change) },
                activateAudio: { _, completion in completion(.success) },
                deactivateAudio: {},
                makeReceiver: { configuration, callbacks in
                    let receiver = Receiver(callbacks)
                    made.receivers.append(receiver)
                    made.configurations.append(configuration)
                    return receiver
                },
                rememberConnection: { _ in },
                makeLease: { onExpire in BackgroundExecutionLease(name: "test", backend: lease, onExpire: onExpire) },
                observesApplicationState: false,
                restoredOutput: { store.restoredOutputSelection() },
                rememberOutput: { selection in
                    made.outputSaves += 1
                    store.rememberOutput(selection)
                },
                rememberInput: { _ = store.rememberInput($0) },
                advancedAudio: { advanced },
                reloadKeepAlive: {
                    made.keepAliveReloads += 1
                    keepAlive?.reloadLive()
                }))
    }

    private static func pairedLink() throws -> String {
        try ConnectionLink.paired(
            host: "192.168.1.2", port: 8443, hostKey: String(repeating: "ab", count: 32),
            clientKey: String(repeating: "cd", count: 32)
        ).pairedRecord()
    }

    /// Connect, then the worker reports PLAYING with the microphone unmuted.
    @MainActor
    private func connectPlaying(
        _ controller: MicrophoneSessionController, _ made: Made, mode: StreamMode,
        port: AudioPortDescriptor = MicrophoneSessionControllerTests.usb, outputEnabled: Bool = true
    ) throws -> Receiver {
        try controller.connect(
            text: try Self.pairedLink(), mode: mode, input: try XCTUnwrap(MicrophoneSelection(port: port)),
            outputEnabled: outputEnabled, fastRecovery: true, outputSelection: OutputSelection())
        let receiver = try XCTUnwrap(made.receivers.last)
        receiver.callbacks.onPhase(.playing)
        receiver.callbacks.onMicrophoneCaptureEnabled()
        receiver.callbacks.onMicrophoneState(false, false)
        XCTAssertEqual(controller.view.session.phase, .playing)
        XCTAssertFalse(controller.view.muted)
        return receiver
    }

    /// The live settings binding the controller passed to its newest worker.
    private static func binding(_ made: Made) throws -> PhoneControlBinding {
        try XCTUnwrap(made.configurations.last?.phoneControl)
    }

    /// Connect, then the worker reports PLAYING and an applied Mute.
    @MainActor
    private func connectMuted(
        _ controller: MicrophoneSessionController, _ made: Made, mode: StreamMode = .microphone,
        port: AudioPortDescriptor = MicrophoneSessionControllerTests.usb
    ) throws -> Receiver {
        try controller.connect(
            text: try Self.pairedLink(), mode: mode, input: try XCTUnwrap(MicrophoneSelection(port: port)),
            outputEnabled: false, fastRecovery: true, outputSelection: OutputSelection())
        let receiver = try XCTUnwrap(made.receivers.last)
        receiver.callbacks.onPhase(.playing)
        receiver.desiredMuted = true
        receiver.callbacks.onMicrophoneState(true, false)
        XCTAssertEqual(controller.view.session.phase, .playing)
        XCTAssertTrue(controller.view.muted)
        XCTAssertFalse(controller.view.changing)
        return receiver
    }

    /// Connect, the phone's Mute while CONNECTING (before the worker opened capture), then the worker applies it and
    /// reports PLAYING: a live muted session in which the phone never had an unmuted microphone.
    @MainActor
    private func connectMutedBeforeCapture(
        _ controller: MicrophoneSessionController, _ made: Made, mode: StreamMode = .microphone
    ) throws -> Receiver {
        try controller.connect(
            text: try Self.pairedLink(), mode: mode, input: try XCTUnwrap(MicrophoneSelection(port: Self.usb)),
            outputEnabled: true, fastRecovery: true, outputSelection: OutputSelection())
        let receiver = try XCTUnwrap(made.receivers.last)
        XCTAssertEqual(controller.view.session.phase, .connecting)
        controller.setMuted(true)
        XCTAssertEqual(receiver.muteRequests, [true], "the phone's Mute is accepted while connecting")
        receiver.callbacks.onMicrophoneState(true, false)
        receiver.callbacks.onPhase(.playing)
        XCTAssertEqual(controller.view.session.phase, .playing)
        XCTAssertTrue(controller.view.muted)
        XCTAssertFalse(controller.view.changing)
        return receiver
    }

    /// The `live.microphone_muted` value the newest worker's live session advertises now (nil: the field is not
    /// offered); fails unless that session is live.
    @MainActor
    private static func offeredMute(_ made: Made) throws -> Bool? {
        try XCTUnwrap(try binding(made).current(), "a live session").microphoneMuted
    }

    @MainActor
    func testNowPlayingFollowsTheWorkersRetainedCaptureNotTheSetting() throws {
        let made = Made()
        let controller = try makeController(made)
        let first = try connectMuted(controller, made)
        controller.applicationActiveChanged(false)
        XCTAssertFalse(controller.captureRetainedWhileMuted)
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced, "the setting alone never claims an open microphone")

        first.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertTrue(controller.captureRetainedWhileMuted)
        XCTAssertEqual(controller.nowPlayingDetail, MicrophoneStatusText.Messages.mutedKeptOpen)
        first.callbacks.onMicrophoneCaptureRetained(false)
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced, "for example headset recovery paused capture")
        first.callbacks.onMicrophoneCaptureRetained(true)
        controller.applicationActiveChanged(true)
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced, "never claimed in the foreground")
        controller.applicationActiveChanged(false)
        XCTAssertEqual(controller.nowPlayingDetail, MicrophoneStatusText.Messages.mutedKeptOpen)

        controller.stop()
        XCTAssertFalse(controller.captureRetainedWhileMuted, "Stop clears it")
        first.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertFalse(controller.captureRetainedWhileMuted, "a stopping worker is ignored")
        first.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(controller.view.session.phase, .ended)

        let second = try connectMuted(controller, made)
        XCTAssertFalse(controller.captureRetainedWhileMuted, "a new receiver starts at false")
        first.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertFalse(controller.captureRetainedWhileMuted, "a callback from a superseded token is ignored")
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced)
        second.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertEqual(controller.nowPlayingDetail, MicrophoneStatusText.Messages.mutedKeptOpen)
        controller.stop()
        second.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertFalse(controller.captureRetainedWhileMuted)
    }

    @MainActor
    func testTheSettingOffNeverClaimsAKeptOpenMicrophone() throws {
        let made = Made()
        let controller = try makeController(made, keep: false)
        let receiver = try connectMuted(controller, made)
        controller.applicationActiveChanged(false)
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced)
        controller.stop()
        receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
    }

    /// Microphone-only headset recovery pauses capture and has no playout, so ROUTE_RECOVERING holds the lease
    /// (bounded by iOS); duplex keeps playout running silenced and needs it only for an output pause.
    @MainActor
    func testMicrophoneOnlyHeadsetRecoveryHoldsTheBackgroundLease() throws {
        let made = Made()
        let controller = try makeController(made)
        let microphone = try connectMuted(controller, made, port: Self.headset)
        XCTAssertEqual(made.leases, 0, "connected: running audio I/O keeps the app alive")
        microphone.callbacks.onPhase(.routeRecovering)
        XCTAssertEqual(made.leases, 1, "headset recovery: capture paused, no playout")
        microphone.callbacks.onPhase(.playing)
        XCTAssertEqual(made.leases, 0, "released once the headset is restored")
        microphone.callbacks.onPhase(.routeRecovering)
        XCTAssertEqual(made.leases, 1)
        controller.stop()
        microphone.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(made.leases, 0, "Stop ends the lease")

        let duplex = try connectMuted(controller, made, mode: .duplex, port: Self.headset)
        XCTAssertNil(controller.view.session.outputPause)
        XCTAssertEqual(made.leases, 0)
        duplex.callbacks.onPhase(.routeRecovering)
        XCTAssertEqual(made.leases, 0, "duplex headset recovery without an output pause")
        controller.stop()
        duplex.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertEqual(made.leases, 0)
    }

    // MARK: - Phone settings exchange v1 (D046)

    /// Microphone-only advertises only the mute and duplex also "Play desktop audio". The mute field disappears while a
    /// change is in flight, and while muted in the background unless a muted capture is already running; a pausing,
    /// stopping, ended or superseded session advertises nothing.
    @MainActor
    func testLiveFieldsFollowTheModeTheChangeStateAndTheBackgroundRule() throws {
        let made = Made()
        let controller = try makeController(made)
        let microphone = try connectPlaying(controller, made, mode: .microphone)
        let binding = try Self.binding(made)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(microphoneMuted: false))
        controller.applicationActiveChanged(false)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(microphoneMuted: false), "Mute is offered in background")
        controller.setMuted(true)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(), "a mute in flight hides the field")
        microphone.callbacks.onMicrophoneState(true, false)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(), "muted in the background, no capture running")
        microphone.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(microphoneMuted: true), "the muted capture runs")
        microphone.callbacks.onMicrophoneCaptureRetained(false)
        XCTAssertEqual(binding.current(), PhoneLiveSettings())
        controller.applicationActiveChanged(true)
        XCTAssertEqual(binding.current(), PhoneLiveSettings(microphoneMuted: true), "foreground")
        controller.stop()
        XCTAssertNil(binding.current(), "stopping")
        microphone.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertNil(binding.current(), "ended")

        let duplex = try connectPlaying(controller, made, mode: .duplex)
        let duplexBinding = try Self.binding(made)
        XCTAssertEqual(
            duplexBinding.current(),
            PhoneLiveSettings(
                outputEnabled: true, microphoneMuted: false, output: OutputSelection(), outputAppliesLive: true))
        XCTAssertNil(binding.current(), "an earlier session's binding stays empty")
        controller.handleInterruption(began: true, shouldResume: false)
        XCTAssertNil(duplexBinding.current(), "pausing")
        duplex.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .interrupted)
        XCTAssertNil(duplexBinding.current(), "interrupted")
        controller.stop()
    }

    /// Windows Mute and Unmute go through `setMuted` (its guard, the worker's gated flow) and "Play desktop audio"
    /// through `setOutputEnabled`; a field the session does not advertise now is refused with no state change. Only
    /// a Windows Mute is saved (`microphoneEnabled = false`); an unmute and the output change end with the session.
    @MainActor
    func testWindowsLiveChangesUseTheControllersOwnGuardedPaths() throws {
        let made = Made()
        let controller = try makeController(made)
        let duplex = try connectPlaying(controller, made, mode: .duplex)
        let binding = try Self.binding(made)
        let store = try XCTUnwrap(made.store)
        store.update { previous in
            var next = previous
            next.microphoneEnabled = true
            return next
        }

        try binding.apply(PhoneLiveSettings(microphoneMuted: true))
        XCTAssertTrue(controller.view.muted)
        XCTAssertTrue(controller.view.changing)
        XCTAssertEqual(duplex.muteRequests, [true])
        XCTAssertFalse(store.load().microphoneEnabled, "a Windows Mute is saved like the phone's own")
        duplex.callbacks.onMicrophoneState(true, false)
        try binding.apply(PhoneLiveSettings(microphoneMuted: false))
        XCTAssertEqual(duplex.muteRequests, [true, false], "the worker verifies and reopens the authorized capture")
        XCTAssertFalse(controller.view.muted)
        XCTAssertFalse(store.load().microphoneEnabled, "a Windows unmute is never saved")
        duplex.callbacks.onMicrophoneState(false, false)

        try binding.apply(PhoneLiveSettings(outputEnabled: false))
        XCTAssertFalse(controller.view.session.outputEnabled)
        XCTAssertEqual(duplex.outputEnabled, [false])
        XCTAssertTrue(store.load().outputEnabled, "a Windows output edit is never saved")

        controller.setMuted(true)
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(microphoneMuted: false)), "a change in flight")
        XCTAssertEqual(duplex.muteRequests, [true, false, true])
        controller.stop()
        duplex.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(outputEnabled: true)), "an ended session")
        XCTAssertTrue(store.load().outputEnabled)

        let microphone = try connectPlaying(controller, made, mode: .microphone)
        XCTAssertThrowsError(
            try Self.binding(made).apply(PhoneLiveSettings(outputEnabled: true)), "microphone-only has no output")
        XCTAssertTrue(microphone.outputEnabled.isEmpty)
        XCTAssertTrue(store.load().outputEnabled)
        controller.setMuted(true)
        microphone.callbacks.onMicrophoneState(true, false)
        controller.setMuted(false)
        XCTAssertEqual(microphone.muteRequests, [true, false])
        XCTAssertTrue(store.load().microphoneEnabled, "the phone's own Unmute still saves")
        controller.stop()
    }

    /// The phone muted (saved off), Windows unmuted this session: after Stop the saved preference still says off, so
    /// the next Connect is playback-only and no Windows command reaches a new connection's microphone.
    @MainActor
    func testAWindowsUnmuteDoesNotCarryIntoTheNextConnect() throws {
        let made = Made()
        let controller = try makeController(made)
        let store = try XCTUnwrap(made.store)
        store.update { previous in
            var next = previous
            next.microphoneEnabled = true
            return next
        }
        let microphone = try connectPlaying(controller, made, mode: .microphone)
        controller.setMuted(true)
        microphone.callbacks.onMicrophoneState(true, false)
        XCTAssertFalse(store.load().microphoneEnabled, "the phone's Mute is saved")

        try Self.binding(made).apply(PhoneLiveSettings(microphoneMuted: false))
        XCTAssertEqual(microphone.muteRequests, [true, false])
        microphone.callbacks.onMicrophoneState(false, false)
        XCTAssertFalse(controller.view.muted, "this session is unmuted")
        controller.stop()
        microphone.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))

        XCTAssertFalse(store.load().microphoneEnabled)
        XCTAssertEqual(store.load().connectionMode, .playback, "the next Connect starts no microphone")
    }

    /// for "Play desktop audio" in duplex: the phone turned it off (saved, so the next Connect would be
    /// microphone-only), Windows turns it on for this session, and a duplex focus resume keeps the Windows ON. After
    /// Stop the saved preferences still pick microphone-only, so the Windows edit changed no later Connect's mode.
    @MainActor
    func testAWindowsPlayDesktopAudioOnLeavesTheNextConnectionModeUnchanged() throws {
        let made = Made()
        let controller = try makeController(made)
        let store = try XCTUnwrap(made.store)
        store.update { previous in
            var next = previous
            next.microphoneEnabled = true
            return next
        }
        XCTAssertEqual(store.load().connectionMode, .duplex)
        let duplex = try connectPlaying(controller, made, mode: .duplex)
        controller.setOutputEnabled(false)
        XCTAssertEqual(duplex.outputEnabled, [false])
        XCTAssertEqual(store.load().connectionMode, .microphone, "the phone's own toggle is saved")

        try Self.binding(made).apply(PhoneLiveSettings(outputEnabled: true))
        XCTAssertTrue(controller.view.session.outputEnabled)
        XCTAssertEqual(duplex.outputEnabled, [false, true])
        XCTAssertFalse(store.load().outputEnabled, "a Windows ON is not saved")

        controller.handleInterruption(began: true, shouldResume: false)
        duplex.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .interrupted)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(made.configurations.map(\.resuming), [false, true], "the duplex focus resume")
        XCTAssertEqual(made.configurations.last?.initiallyOutputEnabled, true, "the session keeps the Windows ON")
        let resumed = try XCTUnwrap(made.receivers.last)
        resumed.callbacks.onPhase(.playing)
        XCTAssertEqual(try Self.binding(made).current()?.outputEnabled, true)
        controller.stop()
        resumed.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))

        XCTAssertFalse(store.load().outputEnabled)
        XCTAssertTrue(store.load().microphoneEnabled)
        XCTAssertEqual(store.load().connectionMode, .microphone, "the next Connect is the phone's choice")
    }

    /// Initial remote/trickle setup suspends network audio before the first microphone control. That path publishes the
    /// user's unmuted request with `pending: false` even though capture never ran (`suspendForNetwork`). A Mute before
    /// media becomes ready must therefore still leave Windows unable to start the first capture.
    @MainActor
    func testANetworkHoldBeforeCaptureDoesNotAuthorizeWindowsUnmute() throws {
        for mode in [StreamMode.microphone, .duplex] {
            let made = Made()
            let controller = try makeController(made)
            try controller.connect(
                text: try Self.pairedLink(), mode: mode, input: .builtIn,
                outputEnabled: true, fastRecovery: true, outputSelection: OutputSelection())
            let receiver = try XCTUnwrap(made.receivers.last)
            receiver.callbacks.onMicrophoneState(false, false)
            controller.setMuted(true)
            receiver.callbacks.onMicrophoneState(true, false)
            receiver.callbacks.onPhase(.playing)

            XCTAssertNil(try Self.offeredMute(made), "\(mode): a desired-state report is not capture evidence")
            XCTAssertThrowsError(try Self.binding(made).apply(PhoneLiveSettings(microphoneMuted: false)))
            XCTAssertEqual(receiver.muteRequests, [true], "Windows must not start the first capture")
            XCTAssertTrue(controller.view.muted)
            controller.stop()
            receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        }
    }

    /// a Mute tapped while connecting lets the session reach PLAYING without ever opening capture, so Windows is
    /// offered no Unmute, even in the foreground, and an unmute command is refused with no mute request and nothing
    /// saved. Once the phone itself unmutes, the field appears and stays after the phone mutes again.
    @MainActor
    func testWindowsGetsNoUnmuteUntilThePhoneItselfOpenedCapture() throws {
        for mode in [StreamMode.microphone, .duplex] {
            let made = Made()
            let controller = try makeController(made)
            let store = try XCTUnwrap(made.store)
            let receiver = try connectMutedBeforeCapture(controller, made, mode: mode)
            let binding = try Self.binding(made)
            XCTAssertNil(try Self.offeredMute(made), "\(mode): the phone never opened capture")
            XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(microphoneMuted: false)), "\(mode)")
            XCTAssertEqual(receiver.muteRequests, [true], "\(mode): no mute request reached the worker")
            XCTAssertTrue(controller.view.muted)
            XCTAssertFalse(store.load().microphoneEnabled, "\(mode): only the phone's Mute was saved")

            controller.setMuted(false)
            XCTAssertNil(try Self.offeredMute(made), "\(mode): the phone's unmute is in flight")
            receiver.callbacks.onMicrophoneCaptureEnabled()
            receiver.callbacks.onMicrophoneState(false, false)
            XCTAssertEqual(try Self.offeredMute(made), false, "\(mode): the phone opened capture")
            controller.setMuted(true)
            receiver.callbacks.onMicrophoneState(true, false)
            XCTAssertEqual(try Self.offeredMute(made), true, "\(mode): Windows may now unmute this session")
            try binding.apply(PhoneLiveSettings(microphoneMuted: false))
            XCTAssertEqual(receiver.muteRequests, [true, false, true, false])
            XCTAssertFalse(controller.view.muted)
            controller.stop()
            receiver.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        }
    }

    /// A verified capture may finish on the worker just before the phone mutes on main. Its queued evidence still
    /// belongs to this session; neither desired-state reports nor retained muted capture can supply that evidence.
    @MainActor
    func testVerifiedCaptureEvidenceSurvivesALaterLocalMuteButNotStopOrANewSession() throws {
        let made = Made()
        let controller = try makeController(made)
        let first = try connectMutedBeforeCapture(controller, made)
        first.callbacks.onMicrophoneCaptureRetained(true)
        XCTAssertNil(try Self.offeredMute(made), "muted keep-alive is not a phone-enabled microphone")

        controller.setMuted(false)
        // Route recovery allows a safety Mute while Unmute is pending. The worker opened capture, then the
        // phone muted before main dequeued its success notification.
        first.callbacks.onPhase(.routeRecovering)
        controller.setMuted(true)
        first.callbacks.onMicrophoneCaptureEnabled()
        first.callbacks.onMicrophoneState(true, false)
        XCTAssertEqual(try Self.offeredMute(made), true, "actual capture history survives a later local Mute")
        controller.stop()
        first.callbacks.onMicrophoneCaptureEnabled()
        XCTAssertNil(try Self.binding(made).current(), "a stopping session cannot publish authorization")
        first.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))

        let next = try connectMutedBeforeCapture(controller, made)
        first.callbacks.onMicrophoneCaptureEnabled()
        XCTAssertNil(try Self.offeredMute(made), "an older receiver cannot authorize the new session")
        XCTAssertThrowsError(try Self.binding(made).apply(PhoneLiveSettings(microphoneMuted: false)))
        XCTAssertEqual(next.muteRequests, [true])
        controller.stop()
        next.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
    }

    /// The phone-enabled capture belongs to the authorized session: it survives the input-switch replacement and a
    /// duplex focus resume, whose new workers start muted and never report an unmuted microphone themselves, and it
    /// ends with Stop, so after the next Connect a Mute tapped while connecting again leaves Windows no Unmute.
    @MainActor
    func testThePhoneEnabledCaptureSurvivesTheSessionsReplacementsButNotStop() throws {
        let made = Made()
        let controller = try makeController(made)
        let first = try connectPlaying(controller, made, mode: .microphone)
        controller.setMuted(true)
        first.callbacks.onMicrophoneState(true, false)
        XCTAssertEqual(try Self.offeredMute(made), true)

        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token))
        first.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 2, "the replacement connection started")
        XCTAssertEqual(made.configurations.last?.initiallyMicrophoneMuted, true)
        let replacement = try XCTUnwrap(made.receivers.last)
        replacement.desiredMuted = true
        replacement.callbacks.onMicrophoneState(true, false)
        replacement.callbacks.onPhase(.playing)
        XCTAssertEqual(try Self.offeredMute(made), true, "input switch: the same authorized session")
        try Self.binding(made).apply(PhoneLiveSettings(microphoneMuted: false))
        XCTAssertEqual(replacement.muteRequests, [false], "the replacement reopens the authorized capture")
        controller.stop()
        replacement.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))

        let duplex = try connectPlaying(controller, made, mode: .duplex)
        controller.setMuted(true)
        duplex.callbacks.onMicrophoneState(true, false)
        controller.handleInterruption(began: true, shouldResume: false)
        duplex.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .interrupted)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(made.configurations.last?.resuming, true, "focus resume")
        XCTAssertEqual(made.configurations.last?.initiallyMicrophoneMuted, true)
        let resumed = try XCTUnwrap(made.receivers.last)
        resumed.desiredMuted = true
        resumed.callbacks.onMicrophoneState(true, false)
        resumed.callbacks.onPhase(.playing)
        XCTAssertEqual(try Self.offeredMute(made), true, "duplex resume: the same authorized session")
        controller.stop()
        resumed.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))

        let next = try connectMutedBeforeCapture(controller, made, mode: .duplex)
        XCTAssertNil(try Self.offeredMute(made), "Stop ended the session's authorization")
        XCTAssertThrowsError(try Self.binding(made).apply(PhoneLiveSettings(microphoneMuted: false)))
        XCTAssertEqual(next.muteRequests, [true])
        controller.stop()
    }

    /// Capture authorization reads permission at every snapshot and apply, not only at Connect. With record permission
    /// revoked during a session (Settings), Mute is still offered and applied while the microphone is on, but the muted
    /// session offers Windows no Unmute and an unmute command is refused with no mute request.
    @MainActor
    func testRevokedPermissionWithdrawsTheWindowsUnmute() throws {
        let made = Made()
        let permission = Permission()
        let controller = try makeController(made, permission: permission)
        let duplex = try connectPlaying(controller, made, mode: .duplex)
        let binding = try Self.binding(made)
        permission.status = .denied
        XCTAssertEqual(try Self.offeredMute(made), false, "the Mute direction is unchanged")
        try binding.apply(PhoneLiveSettings(microphoneMuted: true))
        XCTAssertEqual(duplex.muteRequests, [true])
        duplex.callbacks.onMicrophoneState(true, false)
        XCTAssertNil(try Self.offeredMute(made), "no Unmute without permission")
        XCTAssertThrowsError(try binding.apply(PhoneLiveSettings(microphoneMuted: false)))
        XCTAssertEqual(duplex.muteRequests, [true], "nothing reached the worker")
        XCTAssertTrue(controller.view.muted)
        permission.status = .undetermined
        XCTAssertNil(try Self.offeredMute(made), "only a granted permission counts")
        permission.status = .granted
        XCTAssertEqual(try Self.offeredMute(made), true, "read live, not cached")
        controller.stop()
    }

    /// With in a muted microphone-only session whose **Keep microphone active while muted in background** is off: in
    /// the background its worker releases capture (`MicrophoneBackgroundKeepAliveTests`), so no audio I/O runs and iOS
    /// may suspend MicDrop, which then stops sending `/status` and Windows' row goes stale. Phone control does nothing
    /// to stay alive or reopen the microphone: the Windows snapshot withdraws `live.microphone_muted` as soon as
    /// MicDrop leaves the foreground, an unmute naming it (current or stale editor) is rejected, and no mute request,
    /// capture start, permission prompt, background task or reconnect follows. Back in the foreground the Unmute is
    /// offered again.
    @MainActor
    func testABackgroundMutedSessionWithoutKeepAliveWithdrawsTheWindowsUnmute() throws {
        let fixture = try PhoneControlFixture(self)
        let made = Made()
        let permission = Permission()
        let controller = try makeController(made, keep: false, permission: permission)
        let microphone = try connectPlaying(controller, made, mode: .microphone)
        controller.setMuted(true)
        microphone.callbacks.onMicrophoneState(true, false)
        let adapter = fixture.adapter(binding: try Self.binding(made))
        func mute(_ snapshot: PhoneSettingsSnapshot) -> PhoneSetting? {
            snapshot.settings.first { $0.key == PhoneControlKeys.microphoneMuted }
        }
        let foreground = adapter.current()
        XCTAssertEqual(mute(foreground)?.value, .bool(true), "foreground: Windows may unmute")

        controller.applicationActiveChanged(false)
        microphone.callbacks.onMicrophoneCaptureRetained(false)
        XCTAssertFalse(controller.captureRetainedWhileMuted)
        XCTAssertEqual(controller.nowPlayingDetail, Self.silenced)
        let background = adapter.current()
        XCTAssertTrue(background.enabled, "the session is still live")
        XCTAssertNil(mute(background), "withdrawn in the background")
        XCTAssertNotEqual(background.revision, foreground.revision, "a stale editor must reload")
        XCTAssertNil(background.hostValidationError())
        let unmute: [(String, ControlJSON.Value)] = [(PhoneControlKeys.microphoneMuted, .bool(false))]
        adapter.receiveOnMain(PhoneControlFixture.command(1, base: background.revision, unmute))
        XCTAssertEqual(adapter.acknowledgment?.status, .rejected)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.invalidValueText)
        adapter.receiveOnMain(PhoneControlFixture.command(2, base: foreground.revision, unmute))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.staleText)
        XCTAssertEqual(microphone.muteRequests, [true], "no request reached the worker: no capture start")
        XCTAssertTrue(controller.view.muted)
        XCTAssertEqual(permission.requests, 0, "no permission prompt")
        XCTAssertEqual(made.leases, 0, "no background task of its own")
        XCTAssertEqual(made.configurations.count, 1, "no reconnect")

        controller.applicationActiveChanged(true)
        XCTAssertEqual(mute(adapter.current())?.value, .bool(true), "foreground again")
        controller.stop()
    }

    /// The resume hint (`SessionConfiguration.resume`) marks duplex resumes (`focusRegain` for focus return, `manual`
    /// for Resume from PAUSED and a Resume queued during PAUSING, `MicrophoneService.kt:389`) and the input-switch
    /// replacement (`automatic`, `:483`); an explicit Connect sends none. Only an explicit Connect makes the saved
    /// keep-alive live; resumes and the replacement keep the session's.
    @MainActor
    func testOnlyDuplexResumesCarryTheResumeHint() throws {
        let made = Made()
        let controller = try makeController(made)
        let first = try connectPlaying(controller, made, mode: .duplex)
        XCTAssertEqual(made.configurations.map(\.resume), [nil], "Connect")

        controller.handleInterruption(began: true, shouldResume: false)
        first.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .interrupted)
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .focusRegain], "focus return")

        let second = try XCTUnwrap(made.receivers.last)
        second.callbacks.onPhase(.playing)
        controller.handleInterruption(began: true, shouldResume: false)
        controller.handleInterruption(began: false, shouldResume: false)
        second.callbacks.onEnded(StreamEnd(reason: .focusPermanent, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .paused)
        controller.resume()
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .focusRegain, .manual], "Resume from PAUSED")

        let third = try XCTUnwrap(made.receivers.last)
        third.callbacks.onPhase(.playing)
        controller.handleInterruption(began: true, shouldResume: false)
        controller.resume()
        XCTAssertEqual(made.configurations.count, 3, "queued until the worker ended")
        third.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(made.configurations.map(\.resume), [nil, .focusRegain, .manual, .manual], "queued Resume")

        let fourth = try XCTUnwrap(made.receivers.last)
        fourth.callbacks.onPhase(.playing)
        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token))
        XCTAssertNil(try Self.binding(made).current(), "a worker superseded by the input switch changes nothing")
        fourth.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(
            made.configurations.map(\.resume), [nil, .focusRegain, .manual, .manual, .automatic], "input switch")
        XCTAssertEqual(made.keepAliveReloads, 1, "the first Connect only")

        let fifth = try XCTUnwrap(made.receivers.last)
        controller.stop()
        fifth.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        _ = try connectPlaying(controller, made, mode: .duplex)
        XCTAssertNil(made.configurations.last?.resume, "Connect after Stop")
        XCTAssertEqual(made.keepAliveReloads, 2)
        controller.stop()
    }

    /// A Windows keep-alive edit made during a microphone-only session stays held through the user's input switch,
    /// whose replacement connection belongs to the same session, and becomes live only at the next explicit Connect, so
    /// the switch cannot turn on a muted background capture.
    @MainActor
    func testAWindowsKeepAliveEditWaitsForTheNextConnectNotAnInputSwitch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let advanced = AdvancedAudioPreferencesStore(directory: directory)
        try advanced.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false))
        let made = Made()
        let controller = try makeController(made, keepAlive: advanced)
        let first = try connectPlaying(controller, made, mode: .microphone)
        XCTAssertEqual(made.keepAliveReloads, 1)

        try advanced.saveForNextConnection(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true))
        XCTAssertFalse(advanced.liveKeepMicrophoneActive())
        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token))
        first.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 2, "the replacement connection started")
        XCTAssertFalse(advanced.liveKeepMicrophoneActive(), "an input switch is not the next Connect")
        XCTAssertEqual(made.keepAliveReloads, 1)

        let second = try XCTUnwrap(made.receivers.last)
        controller.stop()
        second.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        _ = try connectPlaying(controller, made, mode: .microphone)
        XCTAssertTrue(advanced.liveKeepMicrophoneActive(), "the next Connect adopts the Windows edit")
        XCTAssertEqual(made.keepAliveReloads, 2)
        controller.stop()
    }

    /// with, through the adapter and this controller's real binding: one Windows command saves
    /// `audio.keep_microphone_active` for the next connection and switches the duplex session's output now. The output
    /// change is the in-session switch, never a Connect, so the held keep-alive edit stays held through it, a duplex
    /// focus resume and an input switch (`keepAliveReloads` stays 1), and becomes live only at the next explicit
    /// Connect (here microphone-only, the mode the keep-alive serves).
    @MainActor
    func testAWindowsOutputChangeNeverMakesAHeldKeepAliveEditLive() throws {
        let fixture = try PhoneControlFixture(self)
        try fixture.advanced.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false))
        fixture.route.value = [PhoneControlFixture.speaker, PhoneControlFixture.bluetooth]
        let made = Made()
        let controller = try makeController(made, keepAlive: fixture.advanced)
        let duplex = try connectPlaying(controller, made, mode: .duplex)
        XCTAssertEqual(made.keepAliveReloads, 1)
        let adapter = fixture.adapter(binding: try Self.binding(made))
        let snapshot = adapter.current()
        let output = try XCTUnwrap(snapshot.settings.first { $0.key == PhoneControlKeys.output })
        XCTAssertEqual(output.effect, .live)
        let bluetooth = try XCTUnwrap(output.choices.last)
        XCTAssertEqual(bluetooth.label, "Bluetooth media output 1 · Synthetic output")
        let changes: [(String, ControlJSON.Value)] = [
            (PhoneControlKeys.keepMicrophoneActive, .bool(true)), (PhoneControlKeys.output, .string(bluetooth.value)),
        ]
        adapter.receiveOnMain(PhoneControlFixture.command(1, base: snapshot.revision, changes))
        XCTAssertEqual(adapter.acknowledgment?.status, .applied)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.savedText)
        XCTAssertEqual(duplex.selections, [PhoneControlFixture.bluetoothPin], "the output switched now")
        XCTAssertEqual(controller.view.session.outputSelection, PhoneControlFixture.bluetoothPin)
        XCTAssertTrue(fixture.advanced.load().keepMicrophoneActiveWhileMuted, "saved for the next connection")
        XCTAssertFalse(fixture.advanced.liveKeepMicrophoneActive(), "the running session keeps its keep-alive")
        XCTAssertEqual(made.keepAliveReloads, 1)
        XCTAssertEqual(made.configurations.count, 1, "no reconnect")

        controller.handleInterruption(began: true, shouldResume: false)
        duplex.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        controller.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(made.configurations.map(\.resuming), [false, true], "the duplex focus resume")
        XCTAssertEqual(made.configurations.last?.outputSelection, PhoneControlFixture.bluetoothPin)
        let resumed = try XCTUnwrap(made.receivers.last)
        resumed.callbacks.onPhase(.playing)
        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token))
        resumed.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 3, "the input-switch replacement started")
        XCTAssertFalse(fixture.advanced.liveKeepMicrophoneActive())
        XCTAssertEqual(made.keepAliveReloads, 1, "neither the output change, the resume nor the switch reloaded it")

        let replacement = try XCTUnwrap(made.receivers.last)
        controller.stop()
        replacement.callbacks.onEnded(StreamEnd(reason: .user, message: "Stopped."))
        _ = try connectPlaying(controller, made, mode: .microphone)
        XCTAssertEqual(made.keepAliveReloads, 2)
        XCTAssertTrue(fixture.advanced.liveKeepMicrophoneActive(), "the next Connect adopts the Windows edit")
        controller.stop()
    }

    /// in duplex with a phone, wired or USB microphone: a Windows output choice takes the phone's own
    /// `setOutputSelection` and the worker switches now. Mute, the change state, "Play desktop audio", permission and
    /// the keep-alive are untouched, nothing reconnects, and the choice is saved like a local one, so a duplex resume
    /// and an input switch pass their output preflight (a choice that was only saved failed the resume with
    /// `duplexResumeFailed` and refused the switch). CONNECTING and a superseded, switching worker refuse it.
    @MainActor
    func testAWindowsOutputChoiceSwitchesANonBluetoothDuplexSessionLive() throws {
        let made = Made()
        let permission = Permission()
        let controller = try makeController(made, permission: permission)
        let store = try XCTUnwrap(made.store)
        try controller.connect(
            text: try Self.pairedLink(), mode: .duplex, input: try XCTUnwrap(MicrophoneSelection(port: Self.usb)),
            outputEnabled: true, fastRecovery: true, outputSelection: OutputSelection())
        XCTAssertThrowsError(try Self.binding(made).applyOutput(Self.pin), "CONNECTING")
        let duplex = try XCTUnwrap(made.receivers.last)
        duplex.callbacks.onPhase(.playing)
        duplex.callbacks.onMicrophoneState(false, false)
        let binding = try Self.binding(made)
        XCTAssertEqual(binding.current()?.output, OutputSelection())
        XCTAssertEqual(binding.current()?.outputAppliesLive, true)

        try binding.applyOutput(Self.pin)
        XCTAssertEqual(duplex.selections, [Self.pin], "the worker's gated, verified switch")
        XCTAssertEqual(controller.view.session.outputSelection, Self.pin)
        XCTAssertEqual(binding.current()?.output, Self.pin)
        XCTAssertEqual(store.restoredOutputSelection(), Self.pin, "saved like a local choice")
        XCTAssertEqual(store.selectionGeneration, 0, "not a next-connection save")
        XCTAssertFalse(controller.view.muted)
        XCTAssertFalse(controller.view.changing)
        XCTAssertTrue(duplex.muteRequests.isEmpty)
        XCTAssertTrue(duplex.outputEnabled.isEmpty)
        XCTAssertEqual(made.configurations.count, 1, "no reconnect")

        controller.handleInterruption(began: true, shouldResume: false)
        duplex.callbacks.onEnded(StreamEnd(reason: .focusTransient, message: "Paused."))
        XCTAssertEqual(controller.view.session.phase, .interrupted)
        XCTAssertThrowsError(try binding.applyOutput(OutputSelection()), "INTERRUPTED: no live binding")
        controller.resume()
        XCTAssertEqual(made.configurations.count, 2)
        XCTAssertEqual(controller.view.session.phase, .connecting, "the duplex resume passed the output preflight")
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin)

        let resumed = try XCTUnwrap(made.receivers.last)
        resumed.callbacks.onPhase(.playing)
        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token), "the input switch is allowed")
        XCTAssertEqual(controller.view.session.phase, .switching)
        XCTAssertThrowsError(try Self.binding(made).applyOutput(OutputSelection()), "SWITCHING")
        resumed.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 3, "the replacement connection started")
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin)
        XCTAssertEqual(resumed.selections, [], "the refused choice reached no worker")
        XCTAssertEqual(made.keepAliveReloads, 1, "only the Connect reloaded the keep-alive (E2)")
        XCTAssertEqual(permission.requests, 0, "no permission prompt")
        controller.stop()
    }

    /// A duplex session with a Bluetooth headset microphone keeps its coupled headset route: a Windows output choice
    /// is stored and saved like the phone's "Media output after headset mic" but not forwarded (`next_connection`),
    /// and the next switch to a phone, wired or USB microphone uses it.
    @MainActor
    func testABluetoothHeadsetDuplexHoldsAWindowsOutputForTheNextNonBluetoothInput() throws {
        let made = Made()
        let controller = try makeController(made)
        let store = try XCTUnwrap(made.store)
        let headset = try connectPlaying(controller, made, mode: .duplex, port: Self.headset)
        let binding = try Self.binding(made)
        XCTAssertEqual(binding.current()?.output, OutputSelection())
        XCTAssertEqual(binding.current()?.outputAppliesLive, false)

        try binding.applyOutput(Self.pin)
        XCTAssertTrue(headset.selections.isEmpty, "the headset route is unchanged")
        XCTAssertEqual(controller.view.session.outputSelection, Self.pin)
        XCTAssertEqual(store.restoredOutputSelection(), Self.pin)
        XCTAssertFalse(controller.view.muted)

        let token = try XCTUnwrap(controller.inputActionToken())
        XCTAssertTrue(controller.switchInput(.builtIn, expectedToken: token))
        headset.callbacks.onEnded(StreamEnd(reason: .pause, message: "Paused."))
        XCTAssertEqual(made.configurations.count, 2)
        XCTAssertEqual(made.configurations.last?.microphoneSelection.kind, .builtIn)
        XCTAssertEqual(made.configurations.last?.outputSelection, Self.pin, "the held choice applies now")
        XCTAssertEqual(try Self.binding(made).current()?.outputAppliesLive, true)
        XCTAssertEqual(made.keepAliveReloads, 1)
        controller.stop()
    }

    /// Microphone-only has no output: the binding reports none and refuses an output, so the adapter saves a Windows
    /// choice for the next connection instead (`PhoneControlAdapterTests`).
    @MainActor
    func testMicrophoneOnlyHasNoOutputForWindowsToSwitch() throws {
        let made = Made()
        let controller = try makeController(made)
        let microphone = try connectPlaying(controller, made, mode: .microphone)
        let binding = try Self.binding(made)
        XCTAssertNil(binding.current()?.output)
        XCTAssertEqual(binding.current()?.outputAppliesLive, false)
        XCTAssertThrowsError(try binding.applyOutput(Self.pin))
        XCTAssertTrue(microphone.selections.isEmpty)
        XCTAssertEqual(made.outputSaves, 0)
        controller.stop()
    }

    /// An automatic output update of the session is saved only while the saved output is the session's previous or new
    /// endpoint (`MicrophoneService.kt:216-221`), so an output saved for the next connection outside this session
    /// (modelled with the Windows next-connection save, which applies only to microphone-only sessions) survives.
    @MainActor
    func testAnAutomaticOutputUpdateNeverOverwritesAnOutputSavedOutsideTheSession() throws {
        let made = Made()
        let controller = try makeController(made)
        let store = try XCTUnwrap(made.store)
        let duplex = try connectPlaying(controller, made, mode: .duplex)
        duplex.outputSelectionMatches = true
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection(), "the session follows the saved output")
        duplex.callbacks.onOutputSelection(OutputSelection())
        XCTAssertEqual(made.outputSaves, 1, "the saved output is the session's: the update is saved")

        let speaker = OutputSelection.restored(.phone)
        store.saveOutputForNextConnection(speaker)
        duplex.callbacks.onOutputSelection(OutputSelection())
        XCTAssertEqual(made.outputSaves, 1, "the other choice is neither of the session's endpoints")
        XCTAssertEqual(store.restoredOutputSelection(), speaker)
        XCTAssertEqual(controller.view.session.outputSelection, OutputSelection(), "the session keeps its route")

        XCTAssertTrue(controller.setOutputSelection(OutputSelection()), "an explicit local choice keeps authority")
        XCTAssertEqual(made.outputSaves, 2)
        XCTAssertEqual(store.restoredOutputSelection(), OutputSelection())
        controller.stop()
    }
}
