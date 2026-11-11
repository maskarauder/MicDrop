import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Advanced "Keep microphone active while muted in background" and the configurable Bluetooth route recovery
/// window, driven through `MicrophoneControl` with fake ports, a fake capture engine and a fake host gate; no
/// audio unit or HTTP is created. Background survival on physical iPhone hardware requires device testing.
/// Retained muted capture (`captureRetainedWhileMuted`, matching Android `microphoneCaptureRetained`)
/// is recorded from `Hooks.onCaptureRetainedWhileMuted`.
final class MicrophoneBackgroundKeepAliveTests: XCTestCase {
    private static let usb = AudioPortDescriptor(
        uid: "test-usb", type: MicrophoneKind.PortType.usbAudio, isInput: true)
    private static let headset = AudioPortDescriptor(
        uid: "test-hfp", type: MicrophoneKind.PortType.bluetoothHFP, isInput: true)
    /// The headset's HFP output (same uid), so the communication route matches during restoration.
    private static let headsetOutput = AudioPortDescriptor(
        uid: "test-hfp", type: MicrophoneKind.PortType.bluetoothHFP, isInput: false)
    private static let silenced = "Silenced · microphone capture stopped"

    private final class Session: MicrophoneRouting.SessionControl {
        let port: AudioPortDescriptor
        var available: [AudioPortDescriptor]
        /// `currentRoute.outputs` and the category options; `headsetRoute()` makes HFP restoration possible.
        var outputs: [AudioPortDescriptor] = []
        var options: UInt = 0
        init(_ port: AudioPortDescriptor) {
            self.port = port
            available = [port]
        }
        func availableInputs() -> [AudioPortDescriptor]? { available }
        func currentInputs() -> [AudioPortDescriptor] { [port] }
        func currentOutputs() -> [AudioPortDescriptor] { outputs }
        var sampleRate: Double { 48_000 }
        var outputNumberOfChannels: Int { 2 }
        var isActive: Bool { true }
        var categoryRawValue: String { AudioSessionPlan.Category.playAndRecord.rawValue }
        var modeRawValue: String { AudioSessionPlan.Mode.default.rawValue }
        var categoryOptionsRawValue: UInt { options }
        func setPreferredInput(uid: String?) throws {}
        func reactivate() throws {}
    }

    private final class Calls: MicrophoneRouting.CallActivity {
        var hasActiveCall: Bool { false }
    }

    private final class Host: MicrophoneControl.HostGate {
        var muted: [Bool] = []
        var timeouts: [Int?] = []
        /// The local sample gate when each `/microphone` request was sent (set by `fixture`).
        var sampleGate: (() -> Bool)?
        var gateOpenWhenSent: [Bool] = []
        var onRequest: (() -> Void)?
        func setHostMicrophoneGate(token: String, muted: Bool, timeoutMs: Int?) throws {
            self.muted.append(muted)
            timeouts.append(timeoutMs)
            gateOpenWhenSent.append(sampleGate?() ?? false)
            onRequest?()
        }
    }

    /// Records ADM input starts/stops and track gates; `onStart` runs inside a start, like a Stop, a return to
    /// the foreground or a saved preference racing the native call. `startResult` < 0 is iOS refusing the start.
    private final class Engine: MicrophoneCapture.Engine {
        var running: [Bool] = []
        var gates: [Bool] = []
        var onStart: (() -> Void)?
        var startResult = 0
        func setMicrophoneSampleGate(open: Bool) { gates.append(open) }
        func setCaptureRunning(_ running: Bool) -> Int {
            self.running.append(running)
            guard running else { return 0 }
            onStart?()
            return startResult
        }
    }

    private final class Hooks: MicrophoneControl.Hooks {
        var closed = false
        var networkHeld = false
        var now: Int64 = 1_000
        var desiredMuted = true
        var appliedMuted: Bool?
        var controlDirty = false
        var applicationActive = true
        /// The setting the tests assign. With `keepAliveStore` set, the value is read as in production instead:
        /// `AppEnvironment.keepMicrophoneActiveWhileMuted`, the store's live keep-alive.
        var keepAliveSetting = true
        var keepAliveStore: AdvancedAudioPreferencesStore?
        var keepMicrophoneActiveWhileMuted: Bool {
            get { keepAliveStore.map { AppEnvironment.keepMicrophoneActiveWhileMuted($0) } ?? keepAliveSetting }
            set { keepAliveSetting = newValue }
        }
        var failureCodes: [SessionFailure] = []
        var failureMessages: [String] = []
        var statuses: [String] = []
        var phases: [SessionPhase] = []
        var reportedMuted: [Bool] = []
        /// Every `onCaptureRetainedWhileMuted` value, and a probe run at each one (e.g. the sample gate then).
        var retained: [Bool] = []
        var onRetained: ((Bool) -> Void)?
        var captureEnabledCount = 0
        var onEnabled: (() -> Void)?
        var audioLockDepth = 0
        func withAudioLock<T>(_ body: () -> T) -> T {
            audioLockDepth += 1
            defer { audioLockDepth -= 1 }
            return body()
        }
        func fail(_ message: String, _ code: SessionFailure) {
            failureMessages.append(message)
            failureCodes.append(code)
        }
        func onPhase(_ p: SessionPhase) { phases.append(p) }
        func onStatus(_ s: String) { statuses.append(s) }
        func onMicrophoneState(_ muted: Bool, pending: Bool) { if !pending { reportedMuted.append(muted) } }
        func onMicrophoneSelection(_ s: MicrophoneSelection) {}
        func holdOutputForHeadset() {}
        func verifyOutputForHeadset() {}
        func checkpoint() throws {}
        func sleep(ms: Int) throws {}
        func nowMs() -> Int64 { now }
        func notifyControl() {}
        func onCaptureRetainedWhileMuted(_ retained: Bool) {
            self.retained.append(retained)
            onRetained?(retained)
        }
        func onCaptureEnabled() {
            captureEnabledCount += 1
            onEnabled?()
        }
    }

    /// One control over fakes; `engine` is retained here because `MicrophoneCapture` holds it weakly.
    private struct Fixture {
        let control: MicrophoneControl
        let capture: MicrophoneCapture
        let engine: Engine
        let hooks: Hooks
        let host: Host
        let session: Session
        let recovery: HeadsetRecovery
    }

    private func fixture(
        mode: StreamMode = .microphone, port: AudioPortDescriptor = MicrophoneBackgroundKeepAliveTests.usb,
        windowMs: Int64 = HeadsetRecovery.windowMs
    ) throws -> Fixture {
        let selection = try XCTUnwrap(MicrophoneSelection(port: port))
        let session = Session(port)
        let routing = MicrophoneRouting(
            selection: selection, session: session, calls: Calls(), clock: SystemMonotonicClock(),
            lost: {}, monitor: nil)
        addTeardownBlock {
            try? routing.close()
            MicrophoneCapture.setApplicationInputMuted(false)
        }
        let capture = MicrophoneCapture(input: MicrophoneCapture.InputInitialization())
        capture.input.complete(nil)
        let engine = Engine()
        capture.attach(engine)
        let recovery = HeadsetRecovery(limitMs: windowMs)
        let hooks = Hooks()
        let host = Host()
        host.sampleGate = { [capture] in capture.sampleGateOpen }
        let control = MicrophoneControl(
            mode: mode, selection: selection, routing: routing, capture: capture, recovery: recovery, host: host,
            hooks: hooks)
        return Fixture(
            control: control, capture: capture, engine: engine, hooks: hooks, host: host, session: session,
            recovery: recovery)
    }

    /// A verified, unmuted capture (the state after Unmute), without running the probe loop.
    private func startUnmuted(_ f: Fixture) throws {
        f.hooks.desiredMuted = false
        f.hooks.appliedMuted = false
        try f.capture.resume()
    }

    /// The selected HFP headset as the communication route (input and output, `.allowBluetooth`), activated so
    /// this session owns it (`MicrophoneRouting.activate`, as at stage INPUT_ROUTE): restoration can complete.
    private func headsetRoute(_ f: Fixture) throws {
        f.session.outputs = [Self.headsetOutput]
        f.session.options = AudioSessionPlan.CategoryOptions.allowBluetooth.rawValue
        _ = try f.control.routing.activate(timeoutMs: 0, cancelled: { false })
    }

    /// The muted microphone-only lock-screen line for the published retained state.
    private func detail(_ f: Fixture) throws -> String {
        let view = MicrophoneView(
            session: SessionView(phase: .playing), muted: true, changing: false, mode: .microphone,
            input: try XCTUnwrap(MicrophoneSelection(port: f.session.port)))
        return MicrophoneStatusText.detail(view, keptOpenForBackground: f.hooks.retained.last ?? false)
    }

    /// The report's `microphone` object while muted (`A/MicrophoneInput.kt:49` parity): a capture kept open on
    /// the selected USB route (fixture: 48 kHz) is verified, a paused one is unavailable; the host accepts both
    /// and building it opens no gate.
    private func assertMutedReport(
        _ f: Fixture, keptOpen: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let snapshot = f.control.snapshot(networkHeld: false, processing: nil)
        let expected: MicrophoneSnapshot
        if keptOpen {
            expected = MicrophoneSnapshot(
                state: "muted", route: "USB microphone", sampleRate: 48_000, channels: 1,
                requestedRoute: "USB microphone", routeVerified: true)
        } else {
            expected = MicrophoneSnapshot(
                state: "muted", route: "unavailable", requestedRoute: "USB microphone", routeVerified: false)
        }
        XCTAssertEqual(snapshot, expected, message, file: file, line: line)
        XCTAssertNil(
            snapshot.hostValidationProblem(audioDirection: f.control.duplex ? "duplex" : ""), message,
            file: file, line: line)
        XCTAssertFalse(f.engine.gates.contains(true), "\(message): no gate opened", file: file, line: line)
        XCTAssertFalse(f.capture.sampleGateOpen, message, file: file, line: line)
    }

    // MARK: - Verified capture evidence

    func testOnlyAVerifiedUnmutedGateOpeningReportsCaptureEnabled() throws {
        let f = try fixture()
        f.hooks.desiredMuted = false
        f.hooks.networkHeld = true
        f.control.suspendForNetwork()
        XCTAssertEqual(f.hooks.reportedMuted, [false], "a hold reports desired Unmute before any capture")
        XCTAssertFalse(f.capture.captureActive)
        XCTAssertEqual(f.hooks.captureEnabledCount, 0)

        f.control.setMicrophoneMuted(true)
        f.hooks.networkHeld = false
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertTrue(f.capture.captureActive, "muted keep-alive actually runs capture")
        XCTAssertFalse(f.capture.sampleGateOpen)
        XCTAssertEqual(f.hooks.captureEnabledCount, 0, "gated keep-alive does not authorize a first Windows Unmute")

        f.hooks.onEnabled = {
            XCTAssertTrue(f.capture.captureActive)
            XCTAssertTrue(f.capture.sampleGateOpen)
            XCTAssertEqual(f.host.muted.last, false, "the host already acknowledged Unmute")
            XCTAssertEqual(f.hooks.audioLockDepth, 0, "notifications run outside the audio lock")
        }
        f.control.setMicrophoneMuted(false)
        try f.control.apply(token: "test-token")
        XCTAssertEqual(f.hooks.captureEnabledCount, 1)
        XCTAssertTrue(f.hooks.failureCodes.isEmpty)
    }

    func testFailedOrSupersededUnmuteNeverReportsCaptureEnabled() throws {
        for interruption in ["start-failure", "network-hold", "mute", "stop"] {
            let f = try fixture()
            f.hooks.desiredMuted = false
            if interruption == "start-failure" { f.engine.startResult = -1 }
            f.host.onRequest = {
                switch interruption {
                case "network-hold": f.hooks.networkHeld = true
                case "mute": f.control.setMicrophoneMuted(true)
                case "stop": f.hooks.closed = true
                default: break
                }
            }
            try f.control.apply(token: "test-token")
            XCTAssertEqual(f.hooks.captureEnabledCount, 0, interruption)
            XCTAssertFalse(f.capture.sampleGateOpen, interruption)
        }
    }

    func testHeadsetRecoveryReportsCaptureEnabledOnlyAfterVerifiedUnmute() throws {
        let f = try fixture(port: Self.headset)
        try headsetRoute(f)
        f.hooks.appliedMuted = true
        f.hooks.desiredMuted = false
        f.session.available = []
        f.control.inputRouteLost()
        try f.control.restoreHeadset(token: "test-token")
        XCTAssertEqual(f.hooks.reportedMuted, [false], "early recovery only reports the desired state")
        XCTAssertFalse(f.capture.captureActive)
        XCTAssertEqual(f.hooks.captureEnabledCount, 0)

        f.hooks.onEnabled = {
            XCTAssertTrue(f.capture.captureActive)
            XCTAssertTrue(f.capture.sampleGateOpen)
            XCTAssertEqual(f.host.muted, [true, false])
            XCTAssertEqual(f.hooks.audioLockDepth, 0)
        }
        f.session.available = [Self.headset]
        try f.control.restoreHeadset(token: "test-token")
        XCTAssertFalse(f.recovery.pending())
        XCTAssertEqual(f.hooks.captureEnabledCount, 1)
    }

    // MARK: - Keep-alive preference

    func testBothSettingsKeepEveryGateClosedAcrossBackgroundAndForeground() throws {
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try f.control.apply(token: "test-token")
            XCTAssertEqual(f.host.muted, [true])
            XCTAssertFalse(f.capture.captureActive, "foreground Mute stops capture in both settings")

            f.hooks.applicationActive = false
            f.control.applyBackgroundPolicy()
            XCTAssertEqual(f.capture.captureActive, keep, "keep=\(keep)")
            XCTAssertEqual(f.control.keepsCaptureOpenForBackground, keep)
            XCTAssertEqual(f.hooks.statuses.contains(MicrophoneStatusText.Messages.mutedKeptOpen), keep)
            XCTAssertEqual(f.control.reportState(networkHeld: false), "muted", "never running while gated")
            assertMutedReport(f, keptOpen: keep, "keep=\(keep)")
            XCTAssertEqual(f.host.muted, [true], "keep=\(keep)")
            f.control.applyBackgroundPolicy()
            XCTAssertEqual(f.engine.running, keep ? [true] : [], "one start per background transition")
            XCTAssertEqual(f.control.captureRetainedWhileMuted, keep, "keep=\(keep)")
            XCTAssertEqual(f.hooks.retained, keep ? [true] : [], "published once, de-duplicated")

            f.hooks.applicationActive = true
            f.control.applyBackgroundPolicy()
            XCTAssertFalse(f.capture.captureActive)
            XCTAssertFalse(f.control.keepsCaptureOpenForBackground)
            XCTAssertEqual(f.engine.running, keep ? [true, false] : [])
            XCTAssertFalse(f.control.captureRetainedWhileMuted)
            XCTAssertEqual(f.hooks.retained, keep ? [true, false] : [], "the foreground withdraws it")

            XCTAssertFalse(f.engine.gates.contains(true), "the sample gate never opened while muted")
            XCTAssertFalse(f.capture.sampleGateOpen)
            XCTAssertEqual(f.host.muted, [true], "no /microphone traffic for the keep-alive")
            XCTAssertEqual(f.hooks.appliedMuted, true)
            XCTAssertTrue(f.hooks.failureCodes.isEmpty)
        }
    }

    /// Phone settings exchange v1: a running session reads the keep-alive only through
    /// `AppEnvironment.keepMicrophoneActiveWhileMuted`, the store's live value, so turning it on from Windows
    /// (`saveForNextConnection`) starts no muted background capture in this session. The next Connect (`reloadLive`)
    /// adopts it, and only then does the policy start the gated keep-alive.
    func testAWindowsKeepAliveEditStartsNoCaptureUntilTheNextConnect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropKeepAlive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = AdvancedAudioPreferencesStore(directory: directory)
        try store.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false))
        let f = try fixture()
        f.hooks.keepAliveStore = store
        try f.control.apply(token: "test-token")
        XCTAssertEqual(f.host.muted, [true])
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertFalse(f.capture.captureActive, "muted, microphone-only, in the background, keep-alive off")

        try store.saveForNextConnection(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true))
        XCTAssertTrue(store.load().keepMicrophoneActiveWhileMuted, "saved for the next connection")
        XCTAssertFalse(AppEnvironment.keepMicrophoneActiveWhileMuted(store), "the session reads the live value")
        for _ in 0..<3 { f.control.applyBackgroundPolicy() }
        XCTAssertTrue(f.engine.running.isEmpty, "capture.resume() never ran in this session")
        XCTAssertFalse(f.capture.captureActive)
        XCTAssertFalse(f.control.keepsCaptureOpenForBackground)
        XCTAssertTrue(f.hooks.retained.isEmpty)

        store.reloadLive()
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true], "the next Connect's policy starts the gated keep-alive")
        XCTAssertTrue(f.control.keepsCaptureOpenForBackground)
        XCTAssertFalse(f.engine.gates.contains(true), "every gate stays closed")
        XCTAssertFalse(f.capture.sampleGateOpen)
        XCTAssertEqual(f.host.muted, [true], "no /microphone traffic")
    }

    func testMuteWhileInTheBackgroundFollowsThePreference() throws {
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try startUnmuted(f)
            f.hooks.applicationActive = false
            f.control.setMicrophoneMuted(true)
            XCTAssertFalse(f.capture.sampleGateOpen, "Mute closes the local gate before the worker runs")
            try f.control.apply(token: "test-token")
            XCTAssertEqual(f.capture.captureActive, keep, "keep=\(keep)")
            XCTAssertEqual(f.control.keepsCaptureOpenForBackground, keep)
            f.control.applyBackgroundPolicy()
            XCTAssertEqual(f.capture.captureActive, keep)
            XCTAssertEqual(f.engine.running, keep ? [true] : [true, false])
            XCTAssertEqual(f.host.muted, [true], "Windows muted the cable in both settings")
            XCTAssertFalse(f.engine.gates.contains(true))
            assertMutedReport(f, keptOpen: keep, "keep=\(keep)")
            XCTAssertEqual(f.host.muted, [true], "keep=\(keep)")
        }
    }

    func testUnmuteAfterBackgroundFollowsBothSettings() throws {
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try f.control.apply(token: "test-token")
            f.hooks.applicationActive = false
            f.control.applyBackgroundPolicy()
            f.hooks.applicationActive = true
            f.control.applyBackgroundPolicy()

            // Unmute after the background stay: one capture start, verified, then the host, then the gate.
            f.control.setMicrophoneMuted(false)
            XCTAssertFalse(f.capture.sampleGateOpen, "keep=\(keep)")
            try f.control.apply(token: "test-token")
            XCTAssertEqual(f.host.muted, [true, false], "keep=\(keep)")
            XCTAssertEqual(f.host.gateOpenWhenSent, [false, false], "the gate opens only after the host unmuted")
            XCTAssertTrue(f.capture.sampleGateOpen, "keep=\(keep)")
            XCTAssertTrue(f.capture.captureActive, "keep=\(keep)")
            XCTAssertEqual(f.hooks.appliedMuted, false, "keep=\(keep)")
            XCTAssertFalse(f.control.keepsCaptureOpenForBackground, "keep=\(keep)")
            XCTAssertEqual(f.engine.running, keep ? [true, false, true] : [true], "keep=\(keep)")
            XCTAssertEqual(f.engine.gates.filter { $0 }.count, 1, "keep=\(keep)")
            XCTAssertTrue(f.hooks.failureCodes.isEmpty, "keep=\(keep)")
        }
    }

    func testUnmuteWhileStillInTheBackgroundReusesTheKeptOpenCapture() throws {
        let f = try fixture()
        try f.control.apply(token: "test-token")
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertTrue(f.control.keepsCaptureOpenForBackground)

        XCTAssertEqual(f.hooks.retained, [true])
        var gateOpenWhenWithdrawn: [Bool] = []
        f.hooks.onRetained = { [capture = f.capture] _ in gateOpenWhenWithdrawn.append(capture.sampleGateOpen) }

        f.control.setMicrophoneMuted(false)
        try f.control.apply(token: "test-token")
        XCTAssertEqual(f.hooks.retained, [true, false])
        XCTAssertEqual(gateOpenWhenWithdrawn, [false], "kept open is withdrawn before any gate opens")
        XCTAssertFalse(f.control.captureRetainedWhileMuted, "an unmuted capture is not retained while muted")
        XCTAssertEqual(f.engine.running, [true], "no second start for the kept-open capture")
        XCTAssertEqual(f.host.muted, [true, false])
        XCTAssertEqual(f.host.gateOpenWhenSent, [false, false], "every gate stayed closed until the host unmuted")
        XCTAssertTrue(f.capture.sampleGateOpen)
        XCTAssertEqual(f.hooks.appliedMuted, false)
        XCTAssertFalse(f.control.keepsCaptureOpenForBackground, "an unmuted capture is no longer a keep-alive")
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true], "the policy leaves an unmuted capture alone")
        XCTAssertTrue(f.hooks.failureCodes.isEmpty)
    }

    func testTurningThePreferenceOffStopsKeptOpenCaptureUntilTheNextTransition() throws {
        let f = try fixture()
        try f.control.apply(token: "test-token")
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertTrue(f.capture.captureActive)

        f.hooks.keepMicrophoneActiveWhileMuted = false
        f.control.applyBackgroundPolicy()
        XCTAssertFalse(f.capture.captureActive, "off stops muted background capture at the next step")
        XCTAssertFalse(f.control.keepsCaptureOpenForBackground)
        XCTAssertEqual(f.hooks.retained, [true, false], "turning it off publishes false")
        f.control.applyBackgroundPolicy()
        f.hooks.keepMicrophoneActiveWhileMuted = true
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true, false], "no restart loop within one background stay")

        // Turned on again: it applies from the next time MicDrop leaves the foreground.
        f.hooks.applicationActive = true
        f.control.applyBackgroundPolicy()
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true, false, true])
        XCTAssertFalse(f.engine.gates.contains(true))
    }

    func testStopForegroundOrPreferenceChangeDuringTheBackgroundStartLeavesNoLateCapture() throws {
        for interruption in ["stop", "foreground", "preference off"] {
            let f = try fixture()
            try f.control.apply(token: "test-token")
            f.hooks.applicationActive = false
            let hooks = f.hooks
            f.engine.onStart = {
                switch interruption {
                case "stop": hooks.closed = true
                case "foreground": hooks.applicationActive = true
                default: hooks.keepMicrophoneActiveWhileMuted = false
                }
            }
            f.control.applyBackgroundPolicy()
            XCTAssertFalse(f.capture.captureActive, interruption)
            XCTAssertEqual(f.engine.running, [true, false], interruption)
            XCTAssertFalse(f.control.keepsCaptureOpenForBackground, interruption)
            XCTAssertTrue(f.hooks.retained.isEmpty, "\(interruption): a start undone at once is never shown")
            XCTAssertFalse(f.hooks.statuses.contains(MicrophoneStatusText.Messages.mutedKeptOpen), interruption)
            f.engine.onStart = nil
            f.control.applyBackgroundPolicy()
            XCTAssertEqual(f.engine.running, [true, false], "\(interruption): no later restart")
            XCTAssertFalse(f.engine.gates.contains(true), interruption)
        }
    }

    func testStopAndTeardownNeverAllowALaterRestart() throws {
        for keptOpen in [false, true] {
            let f = try fixture()
            try f.control.apply(token: "test-token")
            if keptOpen {
                f.hooks.applicationActive = false
                f.control.applyBackgroundPolicy()
                XCTAssertTrue(f.capture.captureActive)
            }
            // Stop / cancellation: the session closes, then the worker's teardown stops recording.
            f.hooks.closed = true
            f.control.stopRecording()
            XCTAssertEqual(f.hooks.retained, keptOpen ? [true, false] : [], "stopRecording publishes false")
            f.capture.detach()
            XCTAssertFalse(f.capture.captureActive)
            for active in [false, true, false] {
                f.hooks.applicationActive = active
                f.control.applyBackgroundPolicy()
            }
            f.control.suspendForNetwork()
            XCTAssertFalse(f.capture.captureActive, "keptOpen=\(keptOpen)")
            XCTAssertEqual(f.engine.running, keptOpen ? [true, false] : [])
            XCTAssertEqual(f.hooks.retained, keptOpen ? [true, false] : [], "no later true")
            XCTAssertThrowsError(try f.capture.resume(), "a detached capture can never restart")
        }
    }

    func testNetworkHoldKeepsAnUnmutedCaptureButHonorsTheMutePreference() throws {
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try startUnmuted(f)
            f.hooks.applicationActive = false
            f.hooks.networkHeld = true
            f.control.suspendForNetwork()
            XCTAssertTrue(f.capture.captureActive, "an unmuted user keeps the unit running for recovery")
            XCTAssertFalse(f.capture.sampleGateOpen)
            XCTAssertEqual(f.hooks.appliedMuted, true)
            let held = f.control.snapshot(networkHeld: true, processing: nil)
            XCTAssertEqual(held.state, "waiting", "keep=\(keep)")
            XCTAssertEqual(held.routeVerified, false, "a held capture is never verified")
            XCTAssertNil(held.hostValidationProblem(audioDirection: ""))

            XCTAssertTrue(f.hooks.retained.isEmpty, "an unmuted capture kept through a hold is not muted capture")

            f.control.setMicrophoneMuted(true)
            f.control.applyBackgroundPolicy()  // The status loop's held step.
            XCTAssertEqual(f.capture.captureActive, keep, "keep=\(keep)")
            f.control.applyBackgroundPolicy()
            XCTAssertEqual(f.engine.running, keep ? [true] : [true, false], "a held step never starts capture")
            XCTAssertTrue(f.host.muted.isEmpty, "no /microphone request while held")
            XCTAssertEqual(f.hooks.retained, keep ? [true] : [], "a muted hold shows the capture it keeps")
        }
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try f.capture.resume()
            f.hooks.applicationActive = false
            f.hooks.networkHeld = true
            f.control.suspendForNetwork()
            XCTAssertEqual(f.capture.captureActive, keep, "a muted hold follows the preference")
        }
    }

    /// The status loop releases the hold (`releaseNetworkAudio`) before it collects that iteration's report;
    /// the next microphone apply comes one iteration later. That one report shows the unmuted user's capture,
    /// kept through the background hold whatever the preference, as muted on its verified route.
    func testReleasedHoldReportsAKeptCaptureAsMutedUntilTheNextApply() throws {
        for keep in [true, false] {
            let f = try fixture()
            f.hooks.keepMicrophoneActiveWhileMuted = keep
            try startUnmuted(f)
            f.hooks.applicationActive = false
            f.hooks.networkHeld = true
            f.control.suspendForNetwork()
            XCTAssertTrue(f.capture.captureActive, "keep=\(keep)")

            f.hooks.networkHeld = false
            f.hooks.controlDirty = true  // `releaseNetworkAudio`; no apply yet.
            assertMutedReport(f, keptOpen: true, "keep=\(keep)")
            XCTAssertEqual(f.hooks.appliedMuted, true, "keep=\(keep)")
            XCTAssertTrue(f.host.muted.isEmpty, "no /microphone request before the next apply")
            XCTAssertTrue(f.hooks.failureCodes.isEmpty, "keep=\(keep)")
        }
    }

    // MARK: - Actual retained capture (report and Now Playing)

    func testARefusedBackgroundStartIsNeverShownAsKeptOpen() throws {
        let f = try fixture()
        try f.control.apply(token: "test-token")
        f.engine.startResult = -1
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true], "one start attempt")
        XCTAssertFalse(f.capture.captureActive)
        f.engine.startResult = 0
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true], "a refusal is recorded once, not retried (08 §8.6)")
        XCTAssertFalse(f.control.captureRetainedWhileMuted)
        XCTAssertTrue(f.hooks.retained.isEmpty, "no true is published")
        XCTAssertFalse(f.hooks.statuses.contains(MicrophoneStatusText.Messages.mutedKeptOpen))
        XCTAssertEqual(try detail(f), Self.silenced, "the setting alone never claims a kept-open microphone")
        XCTAssertEqual(f.host.muted, [true])
        XCTAssertFalse(f.engine.gates.contains(true))
    }

    func testAStartedKeepAliveIsShownOnlyWhileItRuns() throws {
        let f = try fixture()
        try f.control.apply(token: "test-token")
        f.hooks.applicationActive = false
        f.control.applyBackgroundPolicy()
        XCTAssertTrue(f.control.captureRetainedWhileMuted)
        XCTAssertEqual(f.hooks.retained, [true])
        XCTAssertEqual(try detail(f), MicrophoneStatusText.Messages.mutedKeptOpen)
        for _ in 0..<3 { f.control.applyBackgroundPolicy() }
        XCTAssertEqual(f.hooks.retained, [true], "repeated policy steps send nothing new")

        // The unit stopped behind the worker's back (for example an unexpected pause): never reported true.
        f.capture.pause()
        XCTAssertFalse(f.control.captureRetainedWhileMuted, "derived from live capture, not the keep-alive flag")
        f.hooks.applicationActive = true
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.hooks.retained, [true, false])
        XCTAssertEqual(try detail(f), Self.silenced)
    }

    func testANetworkHoldThatBeginsWithCapturePausedNeverPublishesTrue() throws {
        let f = try fixture()
        try f.control.apply(token: "test-token")
        XCTAssertFalse(f.capture.captureActive, "foreground Mute stopped capture")
        f.hooks.applicationActive = false
        f.hooks.networkHeld = true
        f.control.suspendForNetwork()
        for _ in 0..<2 { f.control.applyBackgroundPolicy() }  // The status loop's held steps.
        XCTAssertFalse(f.capture.captureActive, "a held step never starts capture")
        XCTAssertFalse(f.control.captureRetainedWhileMuted)
        XCTAssertTrue(f.hooks.retained.isEmpty)
        XCTAssertTrue(f.engine.running.isEmpty)
        XCTAssertEqual(f.host.muted, [true])
    }

    func testDuplexNeverKeepsAMutedCapture() throws {
        let f = try fixture(mode: .duplex)
        try startUnmuted(f)
        f.hooks.applicationActive = false
        f.control.setMicrophoneMuted(true)
        try f.control.apply(token: "test-token")
        f.control.applyBackgroundPolicy()
        XCTAssertFalse(f.capture.captureActive, "duplex playout keeps the app running instead")
        XCTAssertEqual(f.engine.running, [true, false])
        assertMutedReport(f, keptOpen: false, "duplex")
        XCTAssertFalse(f.control.captureRetainedWhileMuted)
        XCTAssertTrue(f.hooks.retained.isEmpty)
    }

    // MARK: - Configured headset recovery window

    func testHeadsetRecoveryUsesTheConfiguredWindowAndRepeatedLossesDoNotExtendIt() throws {
        let f = try fixture(port: Self.headset, windowMs: 7_500)
        f.hooks.appliedMuted = true
        f.session.available = []
        for now: Int64 in [1_000, 4_000, 8_000] {
            f.hooks.now = now
            f.control.inputRouteLost()
        }
        XCTAssertEqual(f.recovery.remaining(nowMs: 8_000), 500, "the first loss fixed the deadline")

        try f.control.restoreHeadset(token: "test-token")
        XCTAssertEqual(f.hooks.phases, [.routeRecovering])
        XCTAssertEqual(
            f.hooks.statuses,
            ["Restoring the selected headset for up to 7.5 seconds. Microphone temporarily silenced."])
        XCTAssertEqual(f.host.muted, [true])
        XCTAssertEqual(f.host.timeouts, [500], "restoration keeps clamp(remaining, 1, 2000)")
        XCTAssertTrue(f.hooks.failureCodes.isEmpty)

        f.hooks.now = 8_500
        try f.control.restoreHeadset(token: "test-token")
        XCTAssertEqual(f.hooks.failureCodes, [.inputRouteChanged], "bounded termination at the configured window")
        XCTAssertEqual(
            f.hooks.failureMessages,
            [
                "iOS did not restore the selected headset within 7.5 seconds. Microphone return stopped. "
                    + "Choose an available input and tap Connect again."
            ])
        XCTAssertFalse(f.engine.gates.contains(true))
        XCTAssertFalse(f.capture.sampleGateOpen)
    }

    func testMuteAndStopTakePrecedenceDuringHeadsetRecovery() throws {
        let f = try fixture(port: Self.headset, windowMs: 30_000)
        try startUnmuted(f)
        f.session.available = []
        f.control.inputRouteLost()
        XCTAssertTrue(f.recovery.pending())
        XCTAssertFalse(f.capture.sampleGateOpen, "route loss closes the gate at once")
        f.control.setMicrophoneMuted(true)
        f.hooks.now = 2_000
        try f.control.restoreHeadset(token: "test-token")
        XCTAssertEqual(f.host.muted, [true], "Windows is muted while the headset recovers")
        XCTAssertEqual(f.hooks.reportedMuted.last, true, "the user's Mute is reported during recovery")
        XCTAssertFalse(f.capture.captureActive)

        // Stop: `SessionController.close` cancels the recovery; no later step can reopen anything.
        f.hooks.closed = true
        f.recovery.cancel()
        f.hooks.now = 3_000
        f.control.inputRouteLost()
        try f.control.restoreHeadset(token: "test-token")
        XCTAssertFalse(f.recovery.pending())
        XCTAssertEqual(f.host.muted, [true])
        XCTAssertTrue(f.hooks.failureCodes.isEmpty, "Stop is not reported as a recovery timeout")
        XCTAssertFalse(f.engine.gates.contains(true))
    }

    // MARK: - Keep-alive after headset recovery

    /// A muted microphone-only session in the background with the keep-alive running loses its headset: the first
    /// restoration step pauses capture; nothing is sent; the gate stays closed.
    private func keptOpenHeadsetLost(windowMs: Int64 = 7_500, refuseStart: Bool = false) throws -> Fixture {
        let f = try fixture(port: Self.headset, windowMs: windowMs)
        try headsetRoute(f)
        f.hooks.applicationActive = false
        try f.control.apply(token: "test-token")
        if refuseStart { f.engine.startResult = -1 }
        f.control.applyBackgroundPolicy()
        f.engine.startResult = 0
        XCTAssertEqual(f.engine.running, [true])
        XCTAssertEqual(f.capture.captureActive, !refuseStart)

        f.session.available = []
        f.control.inputRouteLost()
        try f.control.loopStep(token: "test-token")
        XCTAssertEqual(f.hooks.phases, [.routeRecovering])
        XCTAssertFalse(f.capture.captureActive, "the first restoration step pauses capture")
        XCTAssertEqual(f.engine.running, refuseStart ? [true] : [true, false])
        XCTAssertEqual(f.hooks.retained, refuseStart ? [] : [true, false], "the first step publishes false")
        XCTAssertFalse(f.control.captureRetainedWhileMuted)
        XCTAssertEqual(f.host.muted, [true, true], "restoration mutes the host gate once")
        return f
    }

    func testTheKeepAliveRestartsOnceAfterAHeadsetRecoveryCompletesMutedInTheBackground() throws {
        let f = try keptOpenHeadsetLost()
        f.hooks.now = 2_000
        try f.control.loopStep(token: "test-token")
        XCTAssertTrue(f.recovery.pending(), "the headset is still missing")
        XCTAssertEqual(f.engine.running, [true, false])

        f.session.available = [Self.headset]
        f.hooks.now = 3_000
        try f.control.loopStep(token: "test-token")
        XCTAssertFalse(f.recovery.pending(), "restored within the window")
        XCTAssertEqual(f.hooks.appliedMuted, true)
        XCTAssertEqual(f.engine.running, [true, false, true], "exactly one new keep-alive start")
        XCTAssertTrue(f.capture.captureActive)
        XCTAssertTrue(f.control.captureRetainedWhileMuted)
        XCTAssertEqual(f.hooks.retained, [true, false, true])
        XCTAssertEqual(f.hooks.statuses.filter { $0 == MicrophoneStatusText.Messages.mutedKeptOpen }.count, 2)
        XCTAssertTrue(f.hooks.statuses.contains(MicrophoneStatusText.Messages.headsetRestored(muted: true)))
        XCTAssertEqual(f.host.muted, [true, true], "no /microphone request for the restart")
        XCTAssertFalse(f.host.muted.contains(false))
        XCTAssertFalse(f.engine.gates.contains(true), "the sample gate stayed closed")
        XCTAssertFalse(f.capture.sampleGateOpen)
        XCTAssertTrue(f.hooks.failureCodes.isEmpty)

        f.hooks.now = 4_000
        try f.control.loopStep(token: "test-token")
        XCTAssertEqual(f.engine.running, [true, false, true], "no further start")
        XCTAssertEqual(f.hooks.retained, [true, false, true])
        XCTAssertEqual(f.hooks.captureEnabledCount, 0, "muted restoration and keep-alive never enabled capture")
    }

    /// History independence: an earlier keep-alive start in this background stay, then a background Unmute, then
    /// the headset is lost and the user mutes during the recovery. The completed muted episode still gets one
    /// gated start, as it would without the earlier start.
    func testTheRestartDoesNotDependOnAnEarlierKeepAliveStartInTheSameBackgroundStay() throws {
        let f = try fixture(port: Self.headset, windowMs: 7_500)
        try headsetRoute(f)
        f.hooks.applicationActive = false
        try f.control.apply(token: "test-token")
        f.control.applyBackgroundPolicy()
        XCTAssertEqual(f.engine.running, [true], "the earlier keep-alive start")
        f.control.setMicrophoneMuted(false)
        try f.control.apply(token: "test-token")
        XCTAssertEqual(f.hooks.appliedMuted, false, "unmuted in the background on the verified headset")
        XCTAssertEqual(f.host.muted, [true, false])
        XCTAssertEqual(f.engine.running, [true], "Unmute reused the running capture")

        f.session.available = []
        f.control.inputRouteLost()
        f.control.setMicrophoneMuted(true)
        try f.control.loopStep(token: "test-token")
        XCTAssertFalse(f.capture.captureActive, "the first restoration step paused the user's capture")
        XCTAssertEqual(f.host.muted, [true, false, true])

        f.session.available = [Self.headset]
        f.hooks.now = 2_000
        try f.control.loopStep(token: "test-token")
        XCTAssertFalse(f.recovery.pending())
        XCTAssertEqual(f.hooks.appliedMuted, true)
        XCTAssertEqual(f.engine.running, [true, false, true], "one gated start after the muted completion")
        XCTAssertTrue(f.control.captureRetainedWhileMuted)
        XCTAssertEqual(f.hooks.retained, [true, false, true])
        XCTAssertEqual(f.host.muted, [true, false, true], "no /microphone request for the restart")
        XCTAssertFalse(f.capture.sampleGateOpen)
        XCTAssertTrue(f.hooks.failureCodes.isEmpty)
    }

    func testNoKeepAliveRestartAfterHeadsetRecoveryInTheForegroundAfterARefusalStopOrExpiry() throws {
        // Completed while MicDrop is in the foreground: foreground Mute stops capture.
        let foreground = try keptOpenHeadsetLost()
        foreground.session.available = [Self.headset]
        foreground.hooks.applicationActive = true
        foreground.hooks.now = 2_000
        try foreground.control.loopStep(token: "test-token")
        XCTAssertFalse(foreground.recovery.pending())
        XCTAssertEqual(foreground.engine.running, [true, false], "foreground")
        XCTAssertEqual(foreground.hooks.retained, [true, false], "foreground")

        // A background start refused before recovery is not retried after it.
        let refused = try keptOpenHeadsetLost(refuseStart: true)
        refused.session.available = [Self.headset]
        refused.hooks.now = 2_000
        try refused.control.loopStep(token: "test-token")
        XCTAssertFalse(refused.recovery.pending())
        XCTAssertEqual(refused.engine.running, [true], "refused before recovery")
        XCTAssertTrue(refused.hooks.retained.isEmpty, "refused before recovery")

        // Stop during recovery: `close` cancels it; the headset returning starts nothing.
        let stopped = try keptOpenHeadsetLost()
        stopped.hooks.closed = true
        stopped.recovery.cancel()
        stopped.session.available = [Self.headset]
        stopped.hooks.now = 2_000
        try stopped.control.loopStep(token: "test-token")
        stopped.control.applyBackgroundPolicy()
        stopped.control.stopRecording()
        XCTAssertEqual(stopped.engine.running, [true, false], "Stop")
        XCTAssertEqual(stopped.hooks.retained, [true, false], "Stop")

        // Expiry: bounded failure, no start.
        let expired = try keptOpenHeadsetLost(windowMs: 7_500)
        expired.hooks.now = 8_500
        try expired.control.loopStep(token: "test-token")
        XCTAssertEqual(expired.hooks.failureCodes, [.inputRouteChanged], "expiry")
        XCTAssertEqual(expired.engine.running, [true, false], "expiry")
        XCTAssertEqual(expired.hooks.retained, [true, false], "expiry")

        for f in [foreground, refused, stopped, expired] {
            XCTAssertFalse(f.engine.gates.contains(true))
            XCTAssertFalse(f.host.muted.contains(false))
        }
    }

    func testSessionMessagesNameTheConfiguredWindow() {
        XCTAssertEqual(
            MicrophoneStatusText.Messages.headsetNotRestored(seconds: "20"),
            "iOS did not restore the selected headset within 20 seconds.")
        XCTAssertEqual(
            SessionController.Messages.headsetNotRestored(seconds: "45"),
            MicrophoneStatusText.Messages.headsetNotRestored(seconds: "45"))
        XCTAssertEqual(
            SessionController.Messages.restoringHeadset(playback: true, seconds: "120"),
            "Restoring the selected headset for up to 120 seconds. Playback and microphone temporarily silenced.")
    }
}
