import Foundation
import MicDropCore
import MicDropTransport
import XCTest

@testable import MicDrop

/// Established-session signaling retries (`retrySignaling`, `StreamReceiver.kt:1589-1599`) through the worker's real
/// request wiring, with in-memory transports and no audio engine.
final class SessionSignalingRetryTests: XCTestCase {
    private enum Failure: Error { case unexpectedNative }

    private final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
        func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
    }

    private final class Transport: ControlTransport, @unchecked Sendable {
        let cancellations = Locked(0)
        let reply: (ControlRequest) throws -> ControlResponse

        init(_ reply: @escaping (ControlRequest) throws -> ControlResponse) { self.reply = reply }

        func send(_ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws
            -> ControlResponse
        {
            onStart(ControlRequestHandle { [self] in cancellations.withLock { $0 += 1 } })
            try Task.checkCancellation()
            return try reply(request)
        }
    }

    private final class Probe: LocalHostProbing, @unchecked Sendable {
        let timeouts = Locked<[Int]>([])
        var didStart: (() -> Void)?
        let reply: () -> Bool
        init(_ reply: @escaping () -> Bool = { false }) { self.reply = reply }
        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool {
            timeouts.withLock { $0.append(timeoutMs) }
            onStart(ControlRequestHandle {})
            didStart?()
            return reply()
        }
    }

    /// `/v1/ice`: the first `failures` fetches find no network; later ones return TURN credentials.
    private final class ICE: RemoteIceFetching, @unchecked Sendable {
        let calls = Locked(0)
        let failures: Int
        init(failures: Int = 0) { self.failures = failures }
        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if call <= failures { throw ControlIOError(.iceServiceUnavailable) }
            let expiry = Int64(Date().timeIntervalSince1970) + 600
            let turn = "\"turn:relay.example:3478?transport=udp\""
            let server = "{\"urls\":[\(turn)],\"username\":\"u\",\"credential\":\"p\"}"
            return (200, Data("{\"version\":1,\"expires_at\":\(expiry),\"ice_servers\":[\(server)]}".utf8))
        }
    }

    private static let token = String(repeating: "s", count: 43)

    private static func response(_ fields: ControlJSON = ["ok": .bool(true)]) -> ControlResponse {
        ControlResponse(body: Array(fields.encoded()))
    }

    private static var healthy: SessionController.StatusExchange {
        let response: ControlJSON = ["state": .string("connected")]
        return SessionController.StatusExchange(
            response: response, host: HostStatus(response), uploaded: nil,
            sentReport: false, sentTrickle: false, sentContinuous: false)
    }

    private func session(
        local: Transport, remote: Transport, probe: Probe = Probe(), clock: Clock = Clock(), ice: ICE = ICE(),
        mode: StreamMode = .playback, forceRelay: Bool = false,
        bluetoothRecoveryMs: Int64 = OutputRouteChange.bluetoothRecoveryMs,
        keepMicrophoneActiveWhileMuted: @escaping @Sendable () -> Bool = { true }
    ) throws -> SessionController {
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: "",
            pin: Array(repeating: 1, count: 32), expiresAt: 0, clientKey: String(repeating: "a", count: 64),
            remote: RemoteRoute(
                url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: forceRelay))
        let processing = MicrophoneProcessing()
        let configuration = SessionConfiguration(
            link: link, linkText: "test-only", mode: mode, reconnect: false, fastRecovery: true, baseline: nil,
            initiallyOutputEnabled: true, outputSelection: OutputSelection(), protectedDefaultSpeaker: false,
            microphoneSelection: .builtIn, initiallyMicrophoneMuted: true, processing: processing,
            plan: AudioSessionPlan.make(mode: mode, input: .builtIn, processing: processing),
            bluetoothRecoveryMs: bluetoothRecoveryMs)
        let owner = AudioSessionOwner()
        let dependencies = SessionDependencies(
            transport: remote, localTransport: { _ in local }, localProbe: { _ in probe },
            tls: { _ in throw Failure.unexpectedNative }, iceService: RemoteICEService(fetcher: ice),
            engineFactory: { _, _, _ in
                XCTFail("test created native media")
                throw Failure.unexpectedNative
            },
            arbiter: AudioSessionArbiter(owner: owner), owner: owner, clock: clock, journalSave: { _ in },
            runtime: { SessionRuntime() }, keepMicrophoneActiveWhileMuted: keepMicrophoneActiveWhileMuted)
        return SessionController(configuration, callbacks: .none, dependencies: dependencies)
    }

    private func established(_ controller: SessionController) {
        controller.lanRecovery = LanRecovery(supported: true)
        controller.lanRecovery.observe(healthy: true, now: controller.nowMs())
    }

    func testRetryAfterExhaustedRoutesReopensTheICECredentialCooldown() throws {
        for forceRelay in [false, true] {
            let fake = Transport { _ in throw ControlIOError(.transportClosed) }
            let ice = ICE(failures: 1)
            let controller = try session(local: fake, remote: fake, ice: ice, forceRelay: forceRelay)
            established(controller)
            var failure: Error?
            XCTAssertThrowsError(try controller.fetchRemoteICEConfiguration()) { failure = $0 }
            let error = try XCTUnwrap(failure)
            if forceRelay {
                XCTAssertEqual(error as? ControlIOError, ControlIOError(.iceServiceUnavailable))
            } else {
                XCTAssertTrue(error is SignalingRoutesUnavailable, "no verified LAN on the replacement network")
            }
            controller.controlSignal.notify()  // Skips the real 500 ms retry wait.
            XCTAssertTrue(try controller.handleStatusFailure(error, attemptedAt: controller.nowMs()))
            let refreshed = try controller.fetchRemoteICEConfiguration()
            XCTAssertEqual(ice.calls.value, 2, "the next round fetches instead of waiting out the 30 s cooldown")
            XCTAssertEqual(refreshed?.hasTURN, true)
        }
    }

    func testHandoffDuringFallbackProbeStillReopensTheICECredentialCooldown() throws {
        let clock = Clock()
        let fake = Transport { _ in throw ControlIOError(.transportClosed) }
        let probe = Probe()
        let ice = ICE(failures: 1)
        let controller = try session(local: fake, remote: fake, probe: probe, clock: clock, ice: ice)
        established(controller)
        controller.networkHandoff.arm()
        probe.didStart = { [weak controller] in _ = controller?.networkHandoff.changed(now: clock.nowMs()) }
        let attemptedAt = clock.nowMs()
        var failure: Error?
        XCTAssertThrowsError(try controller.fetchRemoteICEConfiguration()) { failure = $0 }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error is SignalingNetworkChanged, "cellular became the default during the LAN probe")
        probe.didStart = nil
        XCTAssertTrue(try controller.handleStatusFailure(error, attemptedAt: attemptedAt))
        clock.advance(NetworkHandoff.quietPeriodMs)
        XCTAssertTrue(controller.networkHandoff.take(now: clock.nowMs()))
        _ = try controller.fetchRemoteICEConfiguration()
        XCTAssertEqual(ice.calls.value, 2, "the first fetch on the replacement network is not throttled")
    }

    func testRetryAfterFailedLANFallbackStartsWithRendezvousAgain() throws {
        for path in ["/recover-offer", "/status", "/microphone"] {
            let calls = Locked<[String]>([])
            let local = Transport { _ in
                calls.withLock { $0.append("LAN") }
                throw ControlIOError(.transportClosed)
            }
            let remote = Transport { _ in
                let first = calls.withLock { value -> Bool in
                    value.append("rendezvous")
                    return value.filter { $0 == "rendezvous" }.count == 1
                }
                if first { throw ControlIOError(.transportClosed) }
                return Self.response()
            }
            let probe = Probe {
                calls.withLock { $0.append("probe") }
                return true
            }
            let controller = try session(local: local, remote: remote, probe: probe)
            established(controller)
            let attempt = { _ = try controller.request(path, token: Self.token) }
            if path == "/microphone" {
                XCTAssertNoThrow(try controller.runMicrophoneControl(attempt))
            } else {
                var failure: Error?
                XCTAssertThrowsError(try attempt()) { failure = $0 }
                let error = try XCTUnwrap(failure)
                XCTAssertTrue(error is SignalingRoutesUnavailable, path)
                controller.controlSignal.notify()
                XCTAssertTrue(try controller.handleStatusFailure(error, attemptedAt: controller.nowMs()))
            }
            XCTAssertTrue(controller.networkHeld, path)
            XCTAssertFalse(controller.signalingRoute.direct, "every retry restores rendezvous-first priority")
            try attempt()
            XCTAssertEqual(calls.value, ["rendezvous", "probe", "LAN", "rendezvous"], path)
        }
    }

    func testHandoffCancelledStatusIsChargedToTheWindowFromItsStart() throws {
        let clock = Clock()
        let owner = Locked<SessionController?>(nil)
        let local = Transport { _ in
            XCTFail("LAN fallback while a handoff is pending")
            return Self.response()
        }
        let remote = Transport { _ in
            clock.advance(6_000)
            owner.value?.defaultNetworkChanged()
            throw SessionStopped()  // Transports report their cancelled handle as Stop.
        }
        let controller = try session(local: local, remote: remote, clock: clock)
        owner.value = controller
        defer { owner.value = nil }
        established(controller)
        controller.networkHandoff.arm()
        let attemptedAt = clock.nowMs()
        var failure: Error?
        XCTAssertThrowsError(try controller.request("/status", token: Self.token)) { failure = $0 }
        let error = try XCTUnwrap(failure)
        XCTAssertTrue(error is SignalingNetworkChanged)
        XCTAssertEqual(remote.cancellations.value, 1)
        XCTAssertTrue(try controller.handleStatusFailure(error, attemptedAt: attemptedAt))
        controller.lanRecovery.networkChanged(clock.nowMs())
        let recovery = controller.lanRecovery
        XCTAssertEqual(recovery.remaining(clock.nowMs()), recovery.limitMs - 6_000, "not a fresh window")
        let entry =
            "7000 ms · route=rendezvous · request=status · phase=rendezvous_connect · category=cancelled"
            + " · elapsed=6000 ms"
        XCTAssertEqual(controller.signalingRequestFailures.entries, [entry])
    }

    func testMicrophoneControlFailureIsChargedFromTheStepStart() throws {
        let clock = Clock()
        let fake = Transport { _ in Self.response() }
        let controller = try session(local: fake, remote: fake, clock: clock)
        established(controller)
        try controller.runMicrophoneControl {
            clock.advance(17_000)  // LAN 8 s, rendezvous 8 s and a probe before both routes failed.
            throw SignalingRoutesUnavailable()
        }
        XCTAssertTrue(controller.networkHeld)
        let recovery = controller.lanRecovery
        XCTAssertEqual(recovery.remaining(clock.nowMs()), recovery.limitMs - 17_000)
        XCTAssertThrowsError(try controller.runMicrophoneControl { throw HTTPFailure(403) }) {
            XCTAssertEqual($0 as? HTTPFailure, HTTPFailure(403))
        }
    }

    func testHealthyLANCheckWaitsForMicrophoneControlAndSkipsHeldRecovery() throws {
        let fake = Transport { _ in Self.response() }
        let probe = Probe { true }
        let microphone = try session(local: fake, remote: fake, probe: probe, mode: .microphone)
        microphone.peerStateStorage.value = "Connected"
        microphone.iceConnectedFlag.value = true
        XCTAssertEqual(try microphone.processHostStatus(Self.healthy, attemptedAt: microphone.nowMs()), .proceed)
        XCTAssertTrue(probe.timeouts.value.isEmpty, "no LAN probe before the first applied /microphone")
        microphone.microphoneAppliedMuted.value = true
        XCTAssertEqual(try microphone.processHostStatus(Self.healthy, attemptedAt: microphone.nowMs()), .proceed)
        XCTAssertEqual(probe.timeouts.value.count, 1)
        XCTAssertTrue(microphone.signalingRoute.direct)

        let held = Probe {
            XCTFail("LAN probe while a requested restart holds audio")
            return true
        }
        let clock = Clock()
        let playback = try session(local: fake, remote: fake, probe: held, clock: clock)
        playback.peerStateStorage.value = "Connected"
        playback.iceConnectedFlag.value = true
        playback.playoutActiveFlag.value = true
        let recovery = LanRecovery(supported: true)
        recovery.observe(healthy: true, now: clock.nowMs())
        recovery.networkChanged(clock.nowMs())
        try recovery.begin(clock.nowMs())
        try recovery.accepted(clock.nowMs())
        recovery.observe(healthy: true, now: clock.nowMs())
        clock.advance(1_000)
        recovery.networkChanged(clock.nowMs())  // Within 5 s of the last accepted answer.
        XCTAssertTrue(recovery.restartRequested)
        XCTAssertFalse(recovery.restartDue(clock.nowMs()))
        playback.lanRecovery = recovery
        XCTAssertEqual(try playback.processHostStatus(Self.healthy, attemptedAt: clock.nowMs()), .proceed)
        XCTAssertTrue(playback.networkHeld)
        XCTAssertFalse(playback.signalingRoute.direct)
        XCTAssertTrue(held.timeouts.value.isEmpty)
    }

    func testTerminalReportAfterSetupFailureCarriesSignalingDeadlinesAndRequestFailures() throws {
        let clock = Clock()
        let local = Transport { _ in
            XCTFail("LAN after an unavailable Connect probe")
            return Self.response()
        }
        let remote = Transport { _ in
            clock.advance(8_000)
            throw ControlIOError(.timedOut)
        }
        let controller = try session(local: local, remote: remote, clock: clock)
        try controller.signalingRoute.initial { false }
        XCTAssertThrowsError(try controller.request("/offer", token: "")) {
            XCTAssertTrue($0 is SignalingRoutesUnavailable)
        }
        XCTAssertThrowsError(try controller.request("/stop", token: Self.token, timeoutMs: 5_000, stopping: true))
        XCTAssertEqual(controller.signalingRequestFailures.entries.count, 1, "stopping requests are never recorded")
        XCTAssertTrue(controller.lastDiagnostics.isEmpty)
        XCTAssertEqual(controller.offerReply, .none)
        controller.finalSnapshot = controller.refreshedFinalSnapshot()
        controller.terminalDelivery = ReportText.TerminalDelivery.delivery(
            reply: controller.offerReply, connectionNegotiated: controller.includeConnection)
        let lines = controller.terminalReport().components(separatedBy: "\n")
        let failure =
            "route=rendezvous · request=offer · phase=rendezvous_connect · category=timeout"
            + " · elapsed=8000 ms"
        let expected = [
            "Recent signaling request failures (phone uptime):", "9000 ms · " + failure,
            "Media recovery: not negotiated (no Windows offer reply)",
            "Signaling: HTTPS rendezvous · Local probe: unavailable · Fallback: LAN unavailable",
            "Cellular media candidates: allowed · Force TURN relay: false",
            "Signaling history: Connect: LAN unavailable → Request: rendezvous",
            "Connection deadlines — requested recovery: 30000 ms · requested setup: 45000 ms · not negotiated (no Windows offer reply)",
            "Windows terminal diagnostics: not sent; no Windows offer reply",
        ]
        for line in expected { XCTAssertTrue(lines.contains(line), line) }
        XCTAssertFalse(lines.contains(where: { $0.hasPrefix("Recovery time remaining:") }))
        XCTAssertFalse(lines.contains(where: { $0.contains("legacy Windows limits") }))
        XCTAssertFalse(lines.contains(where: { $0.contains("unavailable on this Windows build") }))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("Connection order — initial: LAN → rendezvous") }))
        XCTAssertEqual(lines.filter { $0.hasPrefix("Signaling history:") }.count, 1)
        XCTAssertTrue(lines.contains("Bluetooth route recovery: 20 s (default)"))
    }

    func testAdvancedAudioSettingsReachTheSessionAndItsReport() throws {
        let fake = Transport { _ in throw ControlIOError(.transportClosed) }
        let keep = SessionController.Guarded(false)
        let controller = try session(
            local: fake, remote: fake, mode: .microphone, bluetoothRecoveryMs: 45_000,
            keepMicrophoneActiveWhileMuted: { keep.value })
        XCTAssertEqual(controller.headsetRecovery.limitMs, 45_000, "headset microphone recovery")
        XCTAssertEqual(controller.outputController.bluetoothRecoveryLimitMs, 45_000, "selected Bluetooth output")
        XCTAssertFalse(controller.keepMicrophoneActiveWhileMuted)
        XCTAssertFalse(controller.microphoneHooks.keepMicrophoneActiveWhileMuted)
        XCTAssertTrue(
            controller.signalingText().hasSuffix(
                "\nBluetooth route recovery: 45 s · Keep microphone active while muted in background: off"))
        keep.value = true  // A saved change is read live by the running session.
        XCTAssertTrue(controller.microphoneHooks.keepMicrophoneActiveWhileMuted)
        XCTAssertTrue(controller.signalingText().hasSuffix("while muted in background: on"))
        let playback = try session(local: fake, remote: fake)
        XCTAssertEqual(playback.headsetRecovery.limitMs, HeadsetRecovery.windowMs)
        XCTAssertEqual(playback.outputController.bluetoothRecoveryLimitMs, OutputRouteChange.bluetoothRecoveryMs)
        XCTAssertTrue(playback.signalingText().hasSuffix("\nBluetooth route recovery: 20 s (default)"))
    }

    /// The worker reads the store's live keep-alive (`AppEnvironment.sessionDependencies`): a Windows edit (phone
    /// settings exchange v1, `saveForNextConnection`) never reaches the running session, so its background policy keeps
    /// the old value and starts no muted capture; a local Save does.
    func testAWindowsKeepAliveEditNeverReachesTheRunningSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = AdvancedAudioPreferencesStore(directory: directory)
        try store.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false))
        let fake = Transport { _ in throw ControlIOError(.transportClosed) }
        let controller = try session(
            local: fake, remote: fake, mode: .microphone,
            keepMicrophoneActiveWhileMuted: { store.liveKeepMicrophoneActive() })
        XCTAssertFalse(controller.microphoneHooks.keepMicrophoneActiveWhileMuted)

        try store.saveForNextConnection(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true))
        XCTAssertTrue(store.load().keepMicrophoneActiveWhileMuted)
        XCTAssertFalse(controller.microphoneHooks.keepMicrophoneActiveWhileMuted, "held for the next connection")
        XCTAssertTrue(controller.signalingText().hasSuffix("while muted in background: off"))

        try store.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true))
        XCTAssertTrue(controller.microphoneHooks.keepMicrophoneActiveWhileMuted, "a local Save applies at once")
    }
}
