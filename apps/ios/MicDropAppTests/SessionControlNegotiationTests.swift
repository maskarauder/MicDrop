import Foundation
import MicDropCore
import MicDropTransport
import XCTest

@testable import MicDrop

/// The phone-control negotiation, the session-resume hint and the negotiated `/status` body budget through the
/// worker's real request wiring (`transportRequest`), with in-memory transports and no audio engine. Ports the
/// app side of `PhoneControlTest`/`SessionResumeTest` and Android's `offerHeader` call sites
/// (`StreamReceiver.kt:1888-1893`, `RemoteHttp.kt:70-76`).
final class SessionControlNegotiationTests: XCTestCase {
    private enum Failure: Error { case unexpectedNative }

    private final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
    }

    private final class Transport: ControlTransport, @unchecked Sendable {
        let requests = Locked<[ControlRequest]>([])
        let reply: (ControlRequest, Int) throws -> ControlResponse

        init(_ reply: @escaping (ControlRequest, Int) throws -> ControlResponse) { self.reply = reply }

        func send(_ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws
            -> ControlResponse
        {
            let index = requests.withLock { list -> Int in
                list.append(request)
                return list.count - 1
            }
            onStart(ControlRequestHandle {})
            try Task.checkCancellation()
            return try reply(request, index)
        }

        func offers() -> [ControlRequest] { requests.value.filter { $0.path == ControlRequest.Path.offer } }
    }

    private final class Probe: LocalHostProbing, @unchecked Sendable {
        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool {
            onStart(ControlRequestHandle {})
            return true
        }
    }

    private final class ICE: RemoteIceFetching, @unchecked Sendable {
        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            let expiry = Int64(Date().timeIntervalSince1970) + 600
            return (200, Data("{\"version\":1,\"expires_at\":\(expiry),\"ice_servers\":[]}".utf8))
        }
    }

    private static let token = String(repeating: "s", count: 43)

    private static func response(_ fields: ControlJSON = ["ok": .bool(true)]) -> ControlResponse {
        ControlResponse(body: Array(fields.encoded()))
    }

    private static func offerReply(version: Int = 3) -> ControlResponse {
        response(["version": .int(version), "session": .string(token)])
    }

    private static func link(version: LinkVersion = .paired, remote: Bool = false) throws -> ConnectionLink {
        let endpoint = try LANEndpoint(host: "192.168.1.2", port: 8443)
        let pin = [UInt8](repeating: 1, count: 32)
        guard version == .paired else {
            return try ConnectionLink(
                version: version, endpoint: endpoint, token: token, pin: pin,
                expiresAt: version == .v2 ? 253_402_300_799 : 0, clientKey: "", remote: nil)
        }
        let route =
            remote
            ? try RemoteRoute(url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: false)
            : nil
        return try ConnectionLink(
            version: .paired, endpoint: endpoint, token: "", pin: pin, expiresAt: 0,
            clientKey: String(repeating: "a", count: 64), remote: route)
    }

    /// `phoneControl` passes that fixture's controller binding and stores, so the session owns a settings adapter.
    private func session(
        local: Transport, remote: Transport, link: ConnectionLink, resume: SessionResume.Reason? = nil,
        reconnect: Bool = false, phoneControl: PhoneControlFixture? = nil
    ) -> SessionController {
        let configuration = SessionConfiguration(
            link: link, linkText: "test-only", mode: .playback, reconnect: reconnect, fastRecovery: true,
            baseline: nil, initiallyOutputEnabled: true, outputSelection: OutputSelection(),
            protectedDefaultSpeaker: false, microphoneSelection: .builtIn, initiallyMicrophoneMuted: true,
            processing: MicrophoneProcessing(), plan: .playback(), resume: resume,
            phoneControl: phoneControl?.binding)
        let owner = AudioSessionOwner()
        let dependencies = SessionDependencies(
            transport: remote, localTransport: { _ in local }, localProbe: { _ in Probe() },
            tls: { _ in throw Failure.unexpectedNative }, iceService: RemoteICEService(fetcher: ICE()),
            engineFactory: { _, _, _ in
                XCTFail("test created native media")
                throw Failure.unexpectedNative
            },
            arbiter: AudioSessionArbiter(owner: owner), owner: owner, clock: Clock(), journalSave: { _ in },
            runtime: { SessionRuntime() }, phoneControl: phoneControl?.environment)
        return SessionController(configuration, callbacks: .none, dependencies: dependencies)
    }

    private static func assertEncodable(
        _ requests: [ControlRequest], file: StaticString = #filePath, line: UInt = #line
    ) {
        for request in requests {
            XCTAssertNoThrow(try ControlRequestEncoder.validate(request), request.path, file: file, line: line)
        }
    }

    /// Every v3 `/offer`, including the 423 busy retry, asks for phone control whatever the local opt-in says, and
    /// carries the resume hint and reason only for a resuming worker.
    func testEveryPairedOfferNegotiatesAndOnlyAResumeCarriesTheHint() throws {
        let cases: [SessionResume.Reason?] = [nil] + SessionResume.Reason.allCases
        for resume in cases {
            let offered = Locked(0)
            let local = Transport { request, _ in
                // A previous test's unacknowledged Stop to the same destination may be resent first.
                guard request.path == ControlRequest.Path.offer else { return Self.response() }
                let first = offered.withLock { count -> Bool in
                    count += 1
                    return count == 1
                }
                if first { throw HTTPFailure(423) }
                return Self.offerReply()
            }
            let remote = Transport { _, _ in
                XCTFail("a LAN-only link contacted rendezvous")
                throw Failure.unexpectedNative
            }
            let controller = session(
                local: local, remote: remote, link: try Self.link(), resume: resume, reconnect: true)
            _ = try controller.obtainOffer()
            let offers = local.offers()
            XCTAssertEqual(offers.count, 2, "the busy offer was retried")
            XCTAssertEqual(offers.map(\.phoneControlOffer), [true, true])
            XCTAssertEqual(offers.map(\.sessionResume), [resume != nil, resume != nil])
            XCTAssertEqual(offers.map(\.sessionResumeReason), [resume, resume])
            XCTAssertEqual(offers.map(\.phoneControlNegotiated), [false, false])
            Self.assertEncodable(local.requests.value)
        }
    }

    /// The offer re-sent through rendezvous after the `/cancel-offer` fallback carries all three lines; the
    /// cancellation itself carries none (the host answers any of them outside `/offer` with 400).
    func testFallbackReofferKeepsTheHintsAndCancelOfferHasNone() throws {
        let local = Transport { _, _ in throw ControlIOError(.transportClosed) }
        let remote = Transport { request, _ in
            guard request.path == ControlRequest.Path.cancelOffer else { return Self.offerReply() }
            return Self.response(["offer_cancelled": .bool(true)])
        }
        let controller = session(
            local: local, remote: remote, link: try Self.link(remote: true), resume: .focusRegain)
        try controller.signalingRoute.initial { true }
        _ = try controller.obtainOffer()
        // A previous test's unacknowledged Stop to the same destination may be resent first.
        let paths = { (transport: Transport) in transport.requests.value.map(\.path).filter { $0 != "/stop" } }
        XCTAssertEqual(paths(local), ["/offer"])
        XCTAssertEqual(paths(remote), ["/cancel-offer", "/offer"])
        for request in local.requests.value + remote.requests.value {
            let offer = request.path == ControlRequest.Path.offer
            XCTAssertEqual(request.phoneControlOffer, offer, request.path)
            XCTAssertEqual(request.sessionResume, offer, request.path)
            XCTAssertEqual(request.sessionResumeReason, offer ? .focusRegain : nil, request.path)
        }
        Self.assertEncodable(local.requests.value + remote.requests.value)
    }

    /// v1/v2 hosts would answer either header with 400 before allocating anything, so legacy links send neither.
    func testLegacyLinksSendNeitherHint() throws {
        for version in [LinkVersion.v1, .v2] {
            let local = Transport { _, _ in Self.offerReply(version: version.rawValue) }
            let remote = Transport { _, _ in throw Failure.unexpectedNative }
            let link = try Self.link(version: version)
            let controller = session(local: local, remote: remote, link: link, resume: .manual)
            _ = try controller.obtainOffer()
            let offer = try XCTUnwrap(local.offers().first, "\(version)")
            XCTAssertFalse(offer.phoneControlOffer, "\(version)")
            XCTAssertFalse(offer.sessionResume, "\(version)")
            XCTAssertNil(offer.sessionResumeReason, "\(version)")
            Self.assertEncodable(local.requests.value)
        }
    }

    /// Ordinary requests never carry the hints; only a negotiated session's `/status` gets the 160 KiB budget.
    func testOnlyANegotiatedStatusGetsTheLargerBudget() throws {
        let local = Transport { _, _ in Self.response() }
        let remote = Transport { _, _ in throw Failure.unexpectedNative }
        let controller = session(local: local, remote: remote, link: try Self.link(), resume: .manual)
        let paths = ["/status", "/answer", "/microphone", "/stop"]
        for path in paths { _ = try controller.request(path, token: Self.token, body: Data("{}".utf8)) }
        controller.phoneControlEnabled = true
        for path in paths { _ = try controller.request(path, token: Self.token, body: Data("{}".utf8)) }
        _ = try controller.request("/status", token: Self.token)
        let requests = local.requests.value
        XCTAssertEqual(requests.map(\.path), paths + paths + ["/status"])
        XCTAssertFalse(
            requests.contains { $0.phoneControlOffer || $0.sessionResume || $0.sessionResumeReason != nil })
        XCTAssertEqual(
            requests.map(\.maxResponseBytes),
            [98_304, 98_304, 98_304, 98_304, 163_840, 98_304, 98_304, 98_304, 163_840])
        XCTAssertEqual(requests.map(\.bodyBudget), requests.map(\.maxResponseBytes))
        Self.assertEncodable(requests)
    }

    /// `acceptOffer` takes the negotiation from this session's reply only, and only with the controller's binding
    /// (`StreamReceiver.kt:397`): without one there is no adapter, no snapshot and no larger budget.
    @MainActor
    func testAcceptOfferReadsTheNegotiatedVersion() throws {
        let fake = Transport { _, _ in Self.response() }
        let base: ControlJSON = ["version": .int(3), "session": .string(Self.token), "sdp": .string("v=0\r\n")]
        let cases: [(ControlJSON.Value?, Bool)] = [
            (.int(1), true), (.string("1"), true), (nil, false), (.int(2), false), (.bool(true), false),
        ]
        let fixture = try PhoneControlFixture(self)
        for (version, negotiated) in cases {
            let extra = version.map { [ControlJSON.Member("phone_control_version", $0)] } ?? []
            let bound = session(local: fake, remote: fake, link: try Self.link(), phoneControl: fixture)
            XCTAssertNotNil(bound.phoneControl)
            XCTAssertTrue(try bound.acceptOffer(ControlJSON(members: base.members + extra)))
            XCTAssertEqual(bound.phoneControlEnabled, negotiated, String(describing: version))
            let unbound = session(local: fake, remote: fake, link: try Self.link())
            XCTAssertNil(unbound.phoneControl)
            XCTAssertTrue(try unbound.acceptOffer(ControlJSON(members: base.members + extra)))
            XCTAssertFalse(unbound.phoneControlEnabled, String(describing: version))
        }
        XCTAssertFalse(
            session(local: fake, remote: fake, link: try Self.link(), phoneControl: fixture).phoneControlEnabled)
        XCTAssertEqual(fixture.liveReads.value, 0, "negotiation alone reads no phone settings")
    }

    /// The resume hint is configuration, never persisted: a fresh configuration defaults to an explicit Connect.
    func testResumingDefaultsToAnExplicitConnect() throws {
        let configuration = SessionConfiguration(
            link: try Self.link(), linkText: "test-only", mode: .playback, reconnect: true, fastRecovery: true,
            baseline: nil, initiallyOutputEnabled: true, outputSelection: OutputSelection(),
            protectedDefaultSpeaker: false, microphoneSelection: .builtIn, initiallyMicrophoneMuted: false,
            processing: MicrophoneProcessing(), plan: .playback())
        XCTAssertNil(configuration.resume)
        XCTAssertFalse(configuration.resuming)
    }
}
