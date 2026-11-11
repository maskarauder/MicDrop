import Foundation
import MicDropCore
import MicDropTransport
import WebRTC
import XCTest

@testable import MicDrop

/// Exercises the worker's actual request wiring using in-memory transports; creates no audio engine.
final class SessionRoutingTests: XCTestCase {
    private enum Failure: Error { case unexpectedNative }

    private final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
        func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
    }

    private final class Transport: ControlTransport, @unchecked Sendable {
        let requests = Locked<[ControlRequest]>([])
        let timeouts = Locked<[Int]>([])
        let cancellations = Locked(0)
        var didStart: ((ControlRequest) -> Void)?
        let reply: (ControlRequest, Int) throws -> ControlResponse

        init(_ reply: @escaping (ControlRequest, Int) throws -> ControlResponse) { self.reply = reply }

        func send(_ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws
            -> ControlResponse
        {
            requests.withLock { $0.append(request) }
            timeouts.withLock { $0.append(timeoutMs) }
            onStart(ControlRequestHandle { [self] in cancellations.withLock { $0 += 1 } })
            didStart?(request)
            try Task.checkCancellation()
            return try reply(request, timeoutMs)
        }
    }

    private final class Probe: LocalHostProbing, @unchecked Sendable {
        let timeouts = Locked<[Int]>([])
        let cancellations = Locked(0)
        var didStart: (() -> Void)?
        let reply: (Int) throws -> Bool
        init(_ reply: @escaping (Int) throws -> Bool = { _ in true }) { self.reply = reply }
        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool {
            timeouts.withLock { $0.append(timeoutMs) }
            onStart(ControlRequestHandle { [self] in cancellations.withLock { $0 += 1 } })
            didStart?()
            return try reply(timeoutMs)
        }
    }

    private final class ICE: RemoteIceFetching, @unchecked Sendable {
        let calls = Locked(0)
        let timeouts = Locked<[Int]>([])
        var didFetch: (() -> Void)?
        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            calls.withLock { $0 += 1 }
            didFetch?()
            let expiry = Int64(Date().timeIntervalSince1970) + 600
            return (200, Data("{\"version\":1,\"expires_at\":\(expiry),\"ice_servers\":[]}".utf8))
        }
        func fetchICE(url: URL, authorization: String, timeoutMs: Int) async throws -> (status: Int, body: Data) {
            timeouts.withLock { $0.append(timeoutMs) }
            return try await fetchICE(url: url, authorization: authorization)
        }
    }

    private typealias EngineFactory =
        (MediaEngineConfiguration, any MediaEngineEvents, @escaping () throws -> Void) throws -> MediaEngine

    private static let token = String(repeating: "s", count: 43)
    private static func response(_ fields: ControlJSON = ["ok": .bool(true)]) -> ControlResponse {
        ControlResponse(body: Array(fields.encoded()))
    }

    /// A playback `/offer` reply the session accepts, plus `extra` capability members.
    private static func offer(_ extra: [ControlJSON.Member] = []) -> ControlJSON {
        let base: ControlJSON = ["version": .int(3), "session": .string(token), "sdp": .string("v=0\r\n")]
        return ControlJSON(members: base.members + extra)
    }

    private static func noNativeMedia(
        _ configuration: MediaEngineConfiguration, _ events: any MediaEngineEvents,
        _ checkpoint: @escaping () throws -> Void
    ) throws -> MediaEngine {
        XCTFail("test created native media")
        throw Failure.unexpectedNative
    }

    /// The default fixture: a paired v3 link with a rendezvous route.
    private static func remoteLink() throws -> ConnectionLink {
        try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: "",
            pin: Array(repeating: 1, count: 32), expiresAt: 0, clientKey: String(repeating: "a", count: 64),
            remote: RemoteRoute(
                url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: false))
    }

    private func session(
        local: Transport, remote: Transport, probe: Probe = Probe(), clock: Clock = Clock(), ice: ICE = ICE(),
        preferences: ConnectionPreferences = ConnectionPreferences(), link: ConnectionLink? = nil,
        engineFactory: @escaping EngineFactory = SessionRoutingTests.noNativeMedia
    ) throws -> SessionController {
        let link = try link ?? Self.remoteLink()
        let configuration = SessionConfiguration(
            link: link, linkText: "test-only", mode: .playback, reconnect: false, fastRecovery: true, baseline: nil,
            initiallyOutputEnabled: true, outputSelection: OutputSelection(), protectedDefaultSpeaker: false,
            microphoneSelection: .builtIn, initiallyMicrophoneMuted: true, processing: MicrophoneProcessing(),
            plan: .playback(), connectionPreferences: preferences)
        let owner = AudioSessionOwner()
        let dependencies = SessionDependencies(
            transport: remote, localTransport: { _ in local }, localProbe: { _ in probe },
            tls: { _ in throw Failure.unexpectedNative }, iceService: RemoteICEService(fetcher: ice),
            engineFactory: engineFactory,
            arbiter: AudioSessionArbiter(owner: owner), owner: owner, clock: clock, journalSave: { _ in },
            runtime: { SessionRuntime() })
        return SessionController(configuration, callbacks: .none, dependencies: dependencies)
    }

    func testVerifiedLANOfferDoesNotFetchPublicICEOrContactRendezvous() throws {
        let local = Transport { _, _ in Self.response(["version": .int(3), "session": .string(Self.token)]) }
        let remote = Transport { _, _ in
            XCTFail("rendezvous contacted before verified LAN")
            throw Failure.unexpectedNative
        }
        let ice = ICE()
        let controller = try session(local: local, remote: remote, ice: ice)
        try controller.signalingRoute.initial { true }
        let offer = try controller.obtainOffer()
        XCTAssertEqual(offer.string("session"), Self.token)
        XCTAssertEqual(local.requests.value.map(\.path), ["/offer"])
        XCTAssertEqual(ice.calls.value, 0)
        XCTAssertEqual(controller.iceConfiguration, .empty)
        XCTAssertTrue(remote.requests.value.isEmpty)
        XCTAssertEqual(local.requests.value.first?.connectionPreferences, ConnectionPreferences())
    }

    /// The deadline headers ride only on a v3 `/offer` (`transportRequest`: `protocolVersion == 3 && path ==
    /// "/offer"`), on LAN and through rendezvous alike. The Windows host answers them on any other request with 400
    /// "Invalid connection timeouts" (`internal/session/connection_timeouts.go:29-31`), and the encoder refuses them
    /// before any I/O, so every recorded request must also pass `ControlRequestEncoder.validate`.
    func testRendezvousV3OfferCarriesPreferencesAndOtherRequestsDoNot() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 90_000, .setup: 60_000])
        let local = Transport { _, _ in throw ControlIOError(.transportClosed) }
        let remote = Transport { request, _ in
            if request.path == "/cancel-offer" { return Self.response(["offer_cancelled": .bool(true)]) }
            return Self.response(["version": .int(3), "session": .string(Self.token)])
        }
        let controller = try session(local: local, remote: remote, preferences: preferences)
        try controller.signalingRoute.initial { true }
        _ = try controller.obtainOffer()
        XCTAssertFalse(controller.signalingRoute.direct, "the successor offer went through rendezvous")
        _ = try controller.request("/status", token: Self.token)
        XCTAssertEqual(local.requests.value.map(\.path), ["/offer"])
        XCTAssertEqual(local.requests.value.map(\.connectionPreferences), [preferences])
        XCTAssertEqual(remote.requests.value.map(\.path), ["/cancel-offer", "/offer", "/status"])
        XCTAssertEqual(remote.requests.value.map(\.connectionPreferences), [nil, preferences, nil])
        XCTAssertEqual(remote.requests.value.map(\.trickleHeaders), [false, true, false])
        for request in local.requests.value + remote.requests.value {
            XCTAssertNoThrow(try ControlRequestEncoder.validate(request), request.path)
        }
    }

    /// A v1/v2 host predates the deadline negotiation, so its `/offer` carries no deadline headers even when
    /// custom windows are saved (`legacy` limits then apply).
    func testLegacyLinkOfferCarriesNoTimeoutPreferences() throws {
        let preferences = try ConnectionPreferences(timeouts: [.recovery: 90_000, .setup: 60_000])
        for (version, expiresAt) in [(LinkVersion.v1, Int64(0)), (LinkVersion.v2, Int64(253_402_300_799))] {
            let link = try ConnectionLink(
                version: version, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: Self.token,
                pin: Array(repeating: 1, count: 32), expiresAt: expiresAt, clientKey: "", remote: nil)
            let local = Transport { _, _ in
                Self.response(["version": .int(version.rawValue), "session": .string(Self.token)])
            }
            let remote = Transport { _, _ in
                XCTFail("a LAN-only link contacted rendezvous")
                throw Failure.unexpectedNative
            }
            let controller = try session(local: local, remote: remote, preferences: preferences, link: link)
            _ = try controller.obtainOffer()
            XCTAssertEqual(local.requests.value.map(\.path), ["/offer"], "\(version)")
            let offer = try XCTUnwrap(local.requests.value.first)
            XCTAssertNil(offer.connectionPreferences, "\(version)")
            XCTAssertFalse(offer.trickleHeaders, "\(version)")
            XCTAssertEqual(offer.bearer, Self.token, "\(version)")
            XCTAssertNoThrow(try ControlRequestEncoder.validate(offer), "\(version)")
        }
    }

    func testAmbiguousOfferIsCancelledBeforeFreshNonceAndRemoteICE() throws {
        let calls = Locked<[String]>([])
        let local = Transport { request, _ in
            calls.withLock { $0.append("LAN \(request.path)") }
            throw ControlIOError(.transportClosed)
        }
        let remote = Transport { request, _ in
            calls.withLock { $0.append("remote \(request.path)") }
            if request.path == "/cancel-offer" { return Self.response(["offer_cancelled": .bool(true)]) }
            return Self.response(["version": .int(3), "session": .string(Self.token)])
        }
        let ice = ICE()
        ice.didFetch = { calls.withLock { $0.append("ICE") } }
        let controller = try session(local: local, remote: remote, ice: ice)
        try controller.signalingRoute.initial { true }
        _ = try controller.obtainOffer()
        XCTAssertEqual(calls.value, ["LAN /offer", "remote /cancel-offer", "ICE", "remote /offer"])
        let old = try XCTUnwrap(local.requests.value.first?.offerAttempt)
        XCTAssertEqual(remote.requests.value[0].offerAttempt, old)
        XCTAssertNotEqual(remote.requests.value[1].offerAttempt, old)
    }

    func testUnacknowledgedOfferCancellationCannotAllocateSuccessor() throws {
        let local = Transport { _, _ in throw ControlIOError(.transportClosed) }
        let remote = Transport { _, _ in Self.response(["offer_cancelled": .bool(false)]) }
        let controller = try session(local: local, remote: remote)
        try controller.signalingRoute.initial { true }
        XCTAssertThrowsError(try controller.obtainOffer())
        XCTAssertEqual(remote.requests.value.map(\.path), ["/cancel-offer"])
        XCTAssertEqual(local.requests.value.first?.offerAttempt, controller.offerAttempt.header(for: "/cancel-offer"))
    }

    func testStopDuringProbeCancelsHandleAndCannotAuthorizeARequest() throws {
        let local = Transport { _, _ in
            XCTFail("LAN request after Stop")
            return Self.response()
        }
        let remote = Transport { _, _ in throw ControlIOError(.transportClosed) }
        let probe = Probe()
        let controller = try session(local: local, remote: remote, probe: probe)
        probe.didStart = { [weak controller] in controller?.close(.user) }
        XCTAssertThrowsError(try controller.request("/status", token: Self.token)) {
            XCTAssertTrue(ConnectionFailure.isCancellation($0))
        }
        XCTAssertEqual(probe.cancellations.value, 1)
        XCTAssertTrue(local.requests.value.isEmpty)
    }

    func testPendingHandoffDefersRequestsAndPreservesRecoveryBudget() throws {
        let local = Transport { _, _ in
            XCTFail("LAN during handoff")
            return Self.response()
        }
        let remote = Transport { _, _ in
            XCTFail("rendezvous during handoff")
            return Self.response()
        }
        let controller = try session(local: local, remote: remote)
        controller.lanRecovery = LanRecovery(supported: true)
        controller.lanRecovery.observe(healthy: true, now: 1_000)
        controller.networkHandoff.arm()
        controller.networkHandoff.changed(now: 1_000)
        XCTAssertThrowsError(try controller.request("/status", token: Self.token)) {
            XCTAssertTrue($0 is SignalingNetworkChanged)
        }
        XCTAssertTrue(local.requests.value.isEmpty)
        XCTAssertTrue(remote.requests.value.isEmpty)
    }

    func testFallbackUsesOnlyRemainingSetupBudget() throws {
        let clock = Clock()
        let local = Transport { _, _ in
            clock.advance(800)
            throw ControlIOError(.transportClosed)
        }
        let remote = Transport { _, _ in Self.response() }
        let controller = try session(local: local, remote: remote, clock: clock)
        try controller.signalingRoute.initial { true }
        controller.setupStartedMs = 1_000
        controller.connectionDeadlines = ConnectionPreferences().legacy(restartSupported: true)
        clock.advance(44_000)
        _ = try controller.request("/status", token: Self.token)
        XCTAssertEqual(local.timeouts.value, [1_000])
        XCTAssertEqual(remote.timeouts.value, [200])
    }

    func testMicrophoneGateUsesConfiguredRequestBudgetsUnlessRestorationClamps() throws {
        let preferences = try ConnectionPreferences(timeouts: [.lanRequest: 20_000, .remoteRequest: 3_000])
        let acknowledgment = Self.response(["ok": .bool(true), "muted": .bool(true)])
        let local = Transport { _, _ in throw ControlIOError(.transportClosed) }
        let remote = Transport { _, _ in acknowledgment }
        let controller = try session(local: local, remote: remote, preferences: preferences)
        try controller.signalingRoute.initial { true }
        try controller.microphoneHooks.setHostMicrophoneGate(token: Self.token, muted: true, timeoutMs: nil)
        XCTAssertEqual(local.requests.value.map(\.path), ["/microphone"])
        XCTAssertEqual(local.timeouts.value, [20_000], "ordinary /microphone uses LAN_REQUEST on LAN")
        XCTAssertEqual(remote.requests.value.map(\.path), ["/microphone"])
        XCTAssertEqual(remote.timeouts.value, [3_000], "and REMOTE_REQUEST on rendezvous, not a fixed 8 s")

        let lan = Transport { _, _ in acknowledgment }
        let restoring = try session(local: lan, remote: remote, preferences: preferences)
        try restoring.signalingRoute.initial { true }
        try restoring.microphoneHooks.setHostMicrophoneGate(token: Self.token, muted: true, timeoutMs: 1_500)
        try restoring.setHostMicrophoneGate(token: Self.token, muted: true)
        XCTAssertEqual(lan.timeouts.value, [1_500, 20_000], "only headset restoration passes its clamp")
    }

    func testStopCanUseBothRoutesWithinOneAbsoluteBudgetAfterClose() throws {
        let clock = Clock()
        let local = Transport { _, _ in Self.response() }
        let remote = Transport { _, _ in
            clock.advance(3_000)
            throw ControlIOError(.transportClosed)
        }
        let probe = Probe { _ in
            clock.advance(500)
            return true
        }
        let controller = try session(local: local, remote: remote, probe: probe, clock: clock)
        controller.close(.user)
        _ = try controller.request("/stop", token: Self.token, timeoutMs: 5_000, stopping: true)
        XCTAssertEqual(remote.timeouts.value, [3_000])
        XCTAssertEqual(probe.timeouts.value, [750])
        XCTAssertEqual(local.timeouts.value, [1_500])
    }

    func testRejectedDeadlineNegotiationStillRetainsTokenForStop() throws {
        let local = Transport { _, _ in Self.response() }
        let remote = Transport { _, _ in Self.response() }
        let controller = try session(local: local, remote: remote)
        let offer: ControlJSON = [
            "version": .int(3), "session": .string(Self.token),
            "connection_timeouts_version": .int(1), "recovery_window_ms": .int(1),
        ]
        XCTAssertThrowsError(try controller.acceptOffer(offer))
        XCTAssertEqual(controller.sessionToken, Self.token)
        XCTAssertTrue(try controller.notifyRemoteStop(reason: .user))
        XCTAssertEqual(remote.requests.value.map(\.path), ["/stop"])
        XCTAssertEqual(remote.requests.value.first?.bearer, Self.token)
    }

    func testICERequestHonorsConfiguredAndRemainingSetupTimeout() throws {
        let local = Transport { _, _ in Self.response() }
        let remote = Transport { _, _ in Self.response() }
        let preferences = try ConnectionPreferences(timeouts: [.iceService: 30_000])
        let ice = ICE()
        let clock = Clock()
        let controller = try session(local: local, remote: remote, clock: clock, ice: ice, preferences: preferences)
        controller.setupStartedMs = 1_000
        clock.advance(44_750)
        _ = try controller.fetchRemoteICEConfiguration()
        XCTAssertEqual(ice.timeouts.value, [250])
        let request = URLSessionRemoteIceFetcher.makeRequest(
            url: URL(string: "https://relay.example/v1/ice")!, authorization: "Bearer test", timeoutMs: 1_234)
        XCTAssertEqual(request.timeoutInterval, 1.234, accuracy: 0.001)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    @MainActor
    func testConfiguredConnectTimeoutsReachProductionTransports() throws {
        let fake = Transport { _, _ in Self.response() }
        let preferences = try ConnectionPreferences(timeouts: [.lanRequest: 15_000, .remoteRequest: 30_000])
        let controller = try session(local: fake, remote: fake, preferences: preferences)
        let dependencies = try AppEnvironment.sessionDependencies(for: controller.configuration)
        let local = try XCTUnwrap(dependencies.localTransport(controller.lanRoute) as? LanControlTransport)
        let remote = try XCTUnwrap(dependencies.transport as? RemoteControlTransport)
        XCTAssertEqual(local.connectTimeoutMs, 15_000)
        XCTAssertEqual(remote.connectTimeoutMs, 30_000)
    }

    func testCopyReportIncludesCapturedPhoneFactsWhileLegacyUploadKeepsEnvironmentNull() throws {
        let fake = Transport { _, _ in Self.response() }
        let controller = try session(local: fake, remote: fake)
        let build = BuildInfo(versionName: "test-build", revision: "0123456789ab")
        let environment = try XCTUnwrap(PlaybackEnvironment.snapshot(build: build))
        XCTAssertEqual(environment.manufacturer, "Apple")
        XCTAssertFalse(environment.model.isEmpty)
        XCTAssertFalse(environment.osRelease.isEmpty)
        let snapshot = controller.metrics.update([:])
        let connection = controller.evidence.connection(runtime: nil, uptimeMs: 1_000)
        let routes = RouteSelectionSnapshot(local: false, remote: false, generation: 0, switches: 0)
        let capturedAt = "2026-10-17T00:00:00Z"
        let report = PlaybackReport(
            sequence: 1, capturedAt: capturedAt, uptimeMs: 1_000, environment: environment,
            state: "Connected", mediaOutput: "waiting", snapshot: snapshot, recovery: nil,
            microphone: nil, microphoneProcessing: nil, mode: .playback, connection: connection,
            lanRecovery: nil, outputControl: nil, iceGathering: nil, mediaTransport: nil, routeSelection: nil)
        controller.pendingReport = report
        let response: ControlJSON = ["state": .string("connected")]
        let exchange = SessionController.StatusExchange(
            response: response, host: HostStatus(response), uploaded: nil,
            sentReport: false, sentTrickle: false, sentContinuous: false)
        let text = controller.periodicDiagnosticsText(
            exchange, snapshot: snapshot, routes: routes, connection: connection,
            tlsTrust: controller.turnTLSTrust.snapshot(), capturedAt: capturedAt)
        XCTAssertTrue(text.contains(build.reportHeader))
        XCTAssertTrue(text.contains("Phone: Apple \(environment.model) · iOS \(environment.osRelease)"))
        XCTAssertTrue(text.contains("Current iOS output route:"))
        XCTAssertFalse(text.contains("Phone route/environment: unavailable"))
        // The trust lines are copied even though this host negotiated no report member.
        XCTAssertTrue(text.contains("iPhone TURN/TLS trust fallback: checks=0 · failures=0 · last=not_checked"), text)
        let encoded = try report.json(includeOutput: false, includeConnection: false, platformEnvironment: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded.encoded()) as? [String: Any])
        XCTAssertTrue(object["environment"] is NSNull)
    }

    func testReportCarriesTLSCountersOnlyWhenTheHostAdvertisedThem() throws {
        let fake = Transport { _, _ in Self.response() }
        let advertised = ControlJSON.Member("tls_certificate_diagnostics_version", .int(1))
        for (offer, negotiated) in [(Self.offer(), false), (Self.offer([advertised]), true)] {
            let controller = try session(local: fake, remote: fake)
            XCTAssertTrue(try controller.acceptOffer(offer))
            XCTAssertEqual(controller.includeTlsVerification, negotiated)
            let report = PlaybackReport(
                sequence: 1, capturedAt: "2026-10-25T00:00:00Z", uptimeMs: 1_000, environment: nil,
                state: "Connected", mediaOutput: "waiting", snapshot: controller.metrics.update([:]), recovery: nil,
                microphone: nil, microphoneProcessing: nil, mode: .playback, connection: nil, lanRecovery: nil,
                outputControl: nil, iceGathering: nil, mediaTransport: nil, routeSelection: nil,
                tlsVerification: controller.reportedTLSVerification(controller.turnTLSTrust.snapshot()))
            let json = try report.json(includeOutput: false, includeConnection: false, platformEnvironment: false)
            guard negotiated else {
                XCTAssertNil(json["tls_certificate_verification"])
                continue
            }
            let member = try XCTUnwrap(json["tls_certificate_verification"])
            XCTAssertEqual(
                String(decoding: member.encoded(), as: UTF8.self),
                #"{"version":1,"checks":0,"failures":0,"last_result":"not_checked"}"#)
        }
    }

    func testEveryPeerReceivesTheSessionTURNTLSCounters() throws {
        let fake = Transport { _, _ in Self.response() }
        let captured = Locked<MediaEngineConfiguration?>(nil)
        let controller = try session(
            local: fake, remote: fake,
            engineFactory: { configuration, _, _ in
                captured.value = configuration
                throw Failure.unexpectedNative
            })
        XCTAssertTrue(try controller.acceptOffer(Self.offer()))
        XCTAssertThrowsError(try controller.setUpMedia(preferredInput: nil))
        let configuration = try XCTUnwrap(captured.value)
        XCTAssertTrue(configuration.turnTLSTrust === controller.turnTLSTrust)
    }

    func testTURNServersKeepTheSecureCertificatePolicyWithoutAHostnameOverride() {
        let servers = ICEPeerConfiguration.iceServers([
            RemoteICEServer(url: "turn:relay.example:3478?transport=udp", username: "user", credential: "test"),
            RemoteICEServer(url: "turns:relay.example:5349?transport=tcp", username: "user", credential: "test"),
        ])
        XCTAssertEqual(servers.count, 2)
        for server in servers {
            XCTAssertEqual(server.tlsCertPolicy, .secure)
            XCTAssertNil(server.hostname)
        }
    }
}
