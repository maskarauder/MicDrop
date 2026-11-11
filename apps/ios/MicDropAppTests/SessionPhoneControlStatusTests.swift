import Foundation
import MicDropCore
import MicDropTransport
import XCTest

@testable import MicDrop

/// Phone settings exchange v1 on the worker's real `/status` wiring (`sendStatus`, `processHostStatus`;
/// `StreamReceiver.kt:687-716`) with an in-memory transport, temporary stores and no audio engine.
final class SessionPhoneControlStatusTests: XCTestCase {
    private enum Failure: Error { case unexpectedNative }

    private final class Transport: ControlTransport, @unchecked Sendable {
        let requests = Locked<[ControlRequest]>([])
        let reply: (ControlRequest) throws -> ControlResponse

        init(_ reply: @escaping (ControlRequest) throws -> ControlResponse) { self.reply = reply }

        func send(_ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws
            -> ControlResponse
        {
            requests.withLock { $0.append(request) }
            onStart(ControlRequestHandle {})
            try Task.checkCancellation()
            return try reply(request)
        }

        func statusRequests() -> [ControlRequest] { requests.value.filter { $0.path == ControlRequest.Path.status } }
    }

    private final class Probe: LocalHostProbing, @unchecked Sendable {
        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool {
            onStart(ControlRequestHandle {})
            return true
        }
    }

    private final class ICE: RemoteIceFetching, @unchecked Sendable {
        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            throw Failure.unexpectedNative
        }
    }

    private static let token = String(repeating: "s", count: 43)
    private static let connected: ControlJSON = ["state": .string("connected")]

    private static func reply(_ fields: ControlJSON = connected) -> ControlResponse {
        ControlResponse(body: Array(fields.encoded()))
    }

    /// A paired LAN session after `acceptOffer`, negotiated when the reply carries `phone_control_version: 1`.
    @MainActor
    private func session(
        _ fixture: PhoneControlFixture, transport: Transport, negotiated: Bool, binding: Bool = true,
        reports: Bool = false
    ) throws -> SessionController {
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: "",
            pin: Array(repeating: 1, count: 32), expiresAt: 0, clientKey: String(repeating: "a", count: 64),
            remote: nil)
        let configuration = SessionConfiguration(
            link: link, linkText: "test-only", mode: .playback, reconnect: false, fastRecovery: true,
            baseline: nil, initiallyOutputEnabled: true, outputSelection: OutputSelection(),
            protectedDefaultSpeaker: false, microphoneSelection: .builtIn, initiallyMicrophoneMuted: true,
            processing: MicrophoneProcessing(), plan: .playback(),
            phoneControl: binding ? fixture.binding : nil)
        let owner = AudioSessionOwner()
        let dependencies = SessionDependencies(
            transport: transport, localTransport: { _ in transport }, localProbe: { _ in Probe() },
            tls: { _ in throw Failure.unexpectedNative }, iceService: RemoteICEService(fetcher: ICE()),
            engineFactory: { _, _, _ in
                XCTFail("test created native media")
                throw Failure.unexpectedNative
            },
            arbiter: AudioSessionArbiter(owner: owner), owner: owner, clock: fixture.clock, journalSave: { _ in },
            runtime: { SessionRuntime() }, phoneControl: fixture.environment)
        let controller = SessionController(configuration, callbacks: .none, dependencies: dependencies)
        var members: [ControlJSON.Member] = [
            ControlJSON.Member("version", .int(3)), ControlJSON.Member("session", .string(Self.token)),
            ControlJSON.Member("sdp", .string("v=0\r\n")),
        ]
        if negotiated { members.append(ControlJSON.Member("phone_control_version", .int(1))) }
        if reports { members.append(ControlJSON.Member("diagnostics_version", .int(1))) }
        XCTAssertTrue(try controller.acceptOffer(ControlJSON(members: members)))
        return controller
    }

    /// A connected status reply with `phone_control_command`.
    private static func statusReply(carrying command: ControlJSON.Value) -> ControlJSON {
        ControlJSON(members: connected.members + [ControlJSON.Member("phone_control_command", command)])
    }

    private static func exchange(_ response: ControlJSON) -> SessionController.StatusExchange {
        SessionController.StatusExchange(
            response: response, host: HostStatus(response), uploaded: nil, sentReport: false, sentTrickle: false,
            sentContinuous: false)
    }

    private static func body(_ request: ControlRequest?) throws -> ControlJSON {
        try ControlJSON(data: try XCTUnwrap(request?.body, "a POST"))
    }

    /// Runs `body` on a background thread (the session worker's role) while the main run loop keeps serving.
    private func onWorker<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Locked<Result<T, Error>?>(nil)
        let done = expectation(description: "worker")
        Thread {
            result.value = Result { try body() }
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result.value).get()
    }

    /// Without the host's `phone_control_version: 1`, or without the controller's binding, `/status` stays exactly
    /// as before (a GET heartbeat, 96 KiB) and a command in a reply is ignored: the host would answer the member
    /// with 400.
    @MainActor
    func testUnnegotiatedSessionsSendNoSnapshotAndIgnoreCommands() throws {
        for (negotiated, binding) in [(false, true), (true, false)] {
            let fixture = try PhoneControlFixture(self)
            let transport = Transport { _ in Self.reply() }
            let controller = try session(fixture, transport: transport, negotiated: negotiated, binding: binding)
            XCTAssertFalse(controller.phoneControlEnabled)
            _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
            let status = try XCTUnwrap(transport.statusRequests().last)
            XCTAssertNil(status.body, "a body-less GET")
            XCTAssertEqual(status.maxResponseBytes, ControlRequest.maxBodyBytes)
            let command = PhoneControlFixture.command(
                1, base: String(repeating: "0", count: 64), [(PhoneControlAdapter.Key.fastRecovery, .bool(false))])
            let reply = Self.statusReply(carrying: command.value)
            XCTAssertEqual(
                try onWorker { try controller.processHostStatus(Self.exchange(reply), attemptedAt: 0) }, .proceed)
            XCTAssertEqual(fixture.liveReads.value, 0, "\(negotiated) \(binding)")
            XCTAssertEqual(fixture.changes.value, 0)
        }
    }

    /// A negotiated session sends the snapshot alone as a POST within the 160 KiB budget, valid under the host
    /// rules, and repeats it only after a change, a command or 5 s.
    @MainActor
    func testANegotiatedSnapshotRidesAloneAndPassesTheHostRules() throws {
        let fixture = try PhoneControlFixture(self)
        let transport = Transport { _ in Self.reply() }
        let controller = try session(fixture, transport: transport, negotiated: true)
        XCTAssertTrue(controller.phoneControlEnabled)
        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        let first = try XCTUnwrap(transport.statusRequests().last)
        XCTAssertEqual(first.maxResponseBytes, ControlRequest.phoneControlBodyBytes)
        XCTAssertNoThrow(try ControlRequestEncoder.validate(first))
        let body = try Self.body(first)
        XCTAssertEqual(body.keys, ["version", "phone_control"])
        let snapshot = try XCTUnwrap(body.object("phone_control"))
        XCTAssertNil(PhoneControl.hostValidationError(snapshot))
        XCTAssertEqual(snapshot["enabled"], .bool(true))

        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        XCTAssertNil(transport.statusRequests().last?.body, "unchanged within 5 s: a GET")
        fixture.clock.advance(PhoneControlAdapter.refreshMs)
        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        XCTAssertEqual(try Self.body(transport.statusRequests().last).keys, ["version", "phone_control"])
    }

    /// A command is processed from any 200 (here a GET's), applied once however often the host repeats it, and
    /// acknowledged in the next snapshot; a `phone_control_command` that is not an object is ignored.
    @MainActor
    func testCommandsFromAnyStatusReplyApplyOnceAndNonObjectsAreIgnored() throws {
        let fixture = try PhoneControlFixture(self)
        let transport = Transport { _ in Self.reply() }
        let controller = try session(fixture, transport: transport, negotiated: true)
        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        let revision = try XCTUnwrap(try Self.body(transport.statusRequests().last).object("phone_control"))
            .string("revision")

        for ignored in [ControlJSON.Value.string("x"), .array([]), .null, .number("1")] {
            let reply = Self.statusReply(carrying: ignored)
            XCTAssertEqual(
                try onWorker { try controller.processHostStatus(Self.exchange(reply), attemptedAt: 0) }, .proceed)
        }
        XCTAssertEqual(fixture.changes.value, 0)

        let command = PhoneControlFixture.command(
            1, base: revision, [(PhoneControlAdapter.Key.fastRecovery, .bool(false))])
        let reply = Self.statusReply(carrying: command.value)
        for _ in 0..<3 {
            XCTAssertEqual(
                try onWorker { try controller.processHostStatus(Self.exchange(reply), attemptedAt: 0) }, .proceed)
        }
        XCTAssertFalse(fixture.audio.load().fastRecovery)
        XCTAssertEqual(fixture.writes.value, ["audio"], "a repeated command applies once")
        XCTAssertEqual(fixture.changes.value, 3)

        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        let ack = try XCTUnwrap(try Self.body(transport.statusRequests().last).object("phone_control")?.object("ack"))
        XCTAssertEqual(ack.string("id"), PhoneControlFixture.id(1))
        XCTAssertEqual(ack.string("status"), "applied")
        XCTAssertEqual(ack.string("message"), PhoneControlSession.savedText)
    }

    /// The report-less retry after a rejected report keeps the snapshot (`diagnosticsFallbackPreservesTheSettings
    /// Snapshot`).
    @MainActor
    func testTheReportFallbackKeepsTheSnapshot() throws {
        let fixture = try PhoneControlFixture(self)
        let transport = Transport { request in
            if let body = request.body, try ControlJSON(data: body).contains(StatusBody.reportKey) {
                throw HTTPFailure(400)
            }
            return Self.reply()
        }
        let controller = try session(fixture, transport: transport, negotiated: true, reports: true)
        XCTAssertEqual(controller.delivery?.enabled, true)
        let report: DiagnosticJSON = .object([(key: "sequence", value: .int(1))])
        _ = try onWorker { try controller.sendStatus(report: report, ice: nil, continuousICE: nil) }
        let bodies = try transport.statusRequests().map { try Self.body($0) }
        XCTAssertEqual(bodies.map(\.keys), [["version", "phone_control", "android"], ["version", "phone_control"]])
        XCTAssertEqual(bodies[0]["phone_control"], bodies[1]["phone_control"], "the same snapshot, never rebuilt")
        XCTAssertEqual(controller.delivery?.enabled, false)
    }

    /// Settings snapshots, commands, tokens and device labels never reach the copy report.
    @MainActor
    func testTheCopyReportCarriesNoPhoneControlText() throws {
        let fixture = try PhoneControlFixture(self)
        let transport = Transport { _ in Self.reply() }
        let controller = try session(fixture, transport: transport, negotiated: true)
        _ = try onWorker { try controller.sendStatus(report: nil, ice: nil, continuousICE: nil) }
        let snapshot = try XCTUnwrap(try Self.body(transport.statusRequests().last).object("phone_control"))
        let command = PhoneControlFixture.command(
            42, base: snapshot.string("revision"), [(PhoneControlAdapter.Key.noiseReduction, .bool(true))])
        let reply = Self.statusReply(carrying: command.value)
        XCTAssertEqual(
            try onWorker { try controller.processHostStatus(Self.exchange(reply), attemptedAt: 0) }, .proceed)
        XCTAssertTrue(fixture.audio.load().noiseReduction)

        let routes = RouteSelectionSnapshot(local: false, remote: false, generation: 0, switches: 0)
        let text = controller.periodicDiagnosticsText(
            Self.exchange(reply), snapshot: controller.metrics.update([:]), routes: routes,
            connection: controller.evidence.connection(runtime: nil, uptimeMs: 1_000),
            tlsTrust: controller.turnTLSTrust.snapshot(), capturedAt: "2026-10-25T00:00:00Z")
        let report = text + "\n" + controller.terminalReport()
        let tokens = (snapshot.array("fields") ?? []).flatMap { field -> [String] in
            guard case .object(let members) = field,
                case .array(let choices)? = ControlJSON(members: members)["choices"]
            else { return [] }
            return choices.compactMap { choice in
                guard case .object(let members) = choice else { return nil }
                return ControlJSON(members: members).string("value")
            }
        }
        XCTAssertFalse(tokens.isEmpty)
        for secret in tokens + [PhoneControlFixture.id(42), snapshot.string("revision")] {
            XCTAssertFalse(report.contains(secret))
        }
        for word in ["phone_control", "Synthetic", "Allow Windows", "Saved. Next-connection", "(saved"] {
            XCTAssertFalse(report.contains(word), word)
        }
    }
}
