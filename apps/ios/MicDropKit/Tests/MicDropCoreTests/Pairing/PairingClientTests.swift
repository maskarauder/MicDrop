import Foundation
import XCTest

@testable import MicDropCore

final class PairingClientTests: XCTestCase {
    private static let key = String(repeating: "b", count: 64)
    private static let approved = ControlResponse(
        body: Array(
            "{\"version\":1,\"state\":\"approved\",\"request_id\":\"\"}".utf8))
    private static let pending = ControlResponse(
        body: Array(
            "{\"version\":1,\"state\":\"pending\",\"request_id\":\"012345abcdef\"}".utf8))

    private struct Transport: ControlTransport {
        let operation: @Sendable (ControlRequest, Int, ControlRequestHandle) async throws -> ControlResponse

        func send(
            _ request: ControlRequest, timeoutMs: Int, onStart: (ControlRequestHandle) -> Void
        ) async throws -> ControlResponse {
            let handle = ControlRequestHandle {}
            onStart(handle)
            return try await operation(request, timeoutMs, handle)
        }
    }

    private struct Probe: LocalHostProbing {
        let operation: @Sendable (Int) async throws -> Bool

        func reachable(timeoutMs: Int, onStart: (ControlRequestHandle) -> Void) async throws -> Bool {
            onStart(ControlRequestHandle {})
            return try await operation(timeoutMs)
        }
    }

    private final class Clock: @unchecked Sendable {
        let milliseconds = Locked<Int64>(0)
        let sleeps = Locked<[Int64]>([])
        var timing: PairingClient.Timing {
            PairingClient.Timing(
                monotonicNowMs: { self.milliseconds.value },
                wallNowSeconds: { 1_000 + self.milliseconds.value / 1_000 },
                sleepMs: { delay in
                    self.sleeps.withLock { $0.append(delay) }
                    self.milliseconds.withLock { $0 += delay }
                })
        }
    }

    private func invitation(expiry: Int64 = 1_300, remote: Bool = false) throws -> PairingInvitation {
        let route =
            remote
            ? try RemoteRoute(url: "https://relay.example", token: String(repeating: "A", count: 43), forceRelay: false)
            : nil
        return try PairingInvitation(
            endpoint: LANEndpoint(host: "192.168.1.2", port: 41_001), hostKey: String(repeating: "a", count: 64),
            secret: String(repeating: "C", count: 43), expiresAt: expiry, remote: route)
    }

    /// Records `probe <ms>`, `lan <ms>` (direct route) and `link <ms>` (the link's own transport:
    /// rendezvous for remote links) in call order; `lan` receives its 1-based call index.
    private func lanFirstClient(
        clock: Clock, events: Locked<[String]>,
        probe: @escaping @Sendable () throws -> Bool,
        lan: @escaping @Sendable (Int) throws -> ControlResponse,
        link: @escaping @Sendable () throws -> ControlResponse = { PairingClientTests.approved }
    ) -> PairingClient {
        let lanCalls = Locked(0)
        return PairingClient(
            makeTransport: { _ in
                Transport { _, timeout, _ in
                    events.withLock { $0.append("link \(timeout)") }
                    return try link()
                }
            },
            timing: clock.timing,
            makeLocalRoute: { _ in
                PairingClient.LocalRoute(
                    probe: Probe { timeout in
                        events.withLock { $0.append("probe \(timeout)") }
                        return try probe()
                    },
                    transport: Transport { _, timeout, _ in
                        events.withLock { $0.append("lan \(timeout)") }
                        let call = lanCalls.withLock {
                            $0 += 1
                            return $0
                        }
                        return try lan(call)
                    })
            })
    }

    func testRemoteLinkPollsVerifiedLANHostWithoutRendezvous() async throws {
        let clock = Clock()
        let events = Locked<[String]>([])
        let client = lanFirstClient(
            clock: clock, events: events, probe: { true },
            lan: { call in call == 1 ? Self.pending : Self.approved },
            link: { throw ControlIOError(.rendezvousFailed) })
        let offered = try invitation(remote: true)
        let result = try await client.enroll(
            offered, clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(), progress: { _ in })
        XCTAssertEqual(events.value, ["probe 1500", "lan 5000", "lan 5000"])
        XCTAssertEqual(clock.sleeps.value, [3_000])
        XCTAssertEqual(result.remote, offered.remote)
    }

    func testLANFailureAfterVerifiedProbeRetriesThroughRendezvousImmediately() async throws {
        // `.timedOut` is also the LAN transport's absolute request deadline.
        for failure in [ControlIOError(.unreachable), ControlIOError(.timedOut)] {
            let clock = Clock()
            let events = Locked<[String]>([])
            let texts = Locked<[String]>([])
            let client = lanFirstClient(clock: clock, events: events, probe: { true }, lan: { _ in throw failure })
            let offered = try invitation(remote: true)
            let result = try await client.enroll(
                offered, clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(),
                progress: { text in texts.withLock { $0.append(text) } })
            XCTAssertEqual(events.value, ["probe 1500", "lan 5000", "link 15000"])
            XCTAssertEqual(clock.sleeps.value, [])
            XCTAssertEqual(texts.value, [PairingClient.retryText])
            XCTAssertEqual(result.remote, offered.remote)
        }
    }

    func testUnavailableLANProbeGoesStraightToRendezvous() async throws {
        let verdicts: [@Sendable () throws -> Bool] = [{ false }, { throw ControlIOError(.timedOut) }]
        for verdict in verdicts {
            let events = Locked<[String]>([])
            let client = lanFirstClient(
                clock: Clock(), events: events, probe: verdict,
                lan: { _ in
                    XCTFail("An unverified LAN host must not receive the invitation secret")
                    return Self.approved
                })
            _ = try await client.enroll(
                invitation(remote: true), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(),
                progress: { _ in })
            XCTAssertEqual(events.value, ["probe 1500", "link 15000"])
        }
    }

    func testLANRejectionAndTLSFailureAreNotRetriedThroughRendezvous() async throws {
        let errors: [Error] = [HTTPFailure(403), SignalingTLSFailure(.windows, .identity)]
        for expected in errors {
            let events = Locked<[String]>([])
            let client = lanFirstClient(
                clock: Clock(), events: events, probe: { true }, lan: { _ in throw expected })
            do {
                _ = try await client.enroll(
                    invitation(remote: true), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(),
                    progress: { _ in })
                XCTFail("Authenticated LAN failure must escape")
            } catch { XCTAssertEqual(String(reflecting: error), String(reflecting: expected)) }
            XCTAssertEqual(events.value, ["probe 1500", "lan 5000"])
        }
    }

    func testLANLinkNeverProbesAndCancelledProbeSendsNothing() async throws {
        let events = Locked<[String]>([])
        let lanClient = lanFirstClient(clock: Clock(), events: events, probe: { true }, lan: { _ in Self.approved })
        _ = try await lanClient.enroll(
            invitation(), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(), progress: { _ in })
        XCTAssertEqual(events.value, ["link 5000"])

        let attempt = PairingAttempt()
        let cancelled = Locked<[String]>([])
        let client = lanFirstClient(
            clock: Clock(), events: cancelled,
            probe: {
                attempt.cancel()
                return true
            }, lan: { _ in Self.approved })
        do {
            _ = try await client.enroll(
                invitation(remote: true), clientKey: Self.key, label: "iPhone", attempt: attempt, progress: { _ in })
            XCTFail("Stop during the LAN probe must cancel enrollment")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelled.value, ["probe 1500"])
    }

    func testPendingRetryAndApprovalPreserveRequestContractAndEndEveryLease() async throws {
        let clock = Clock()
        let requests = Locked<[ControlRequest]>([])
        let timeouts = Locked<[Int]>([])
        let texts = Locked<[String]>([])
        let leases = Locked((started: 0, ended: 0))
        let transport = Transport { request, timeout, _ in
            let call = requests.withLock {
                $0.append(request)
                return $0.count
            }
            timeouts.withLock { $0.append(timeout) }
            if call == 1 { return Self.pending }
            if call == 2 { throw HTTPFailure(503) }
            return Self.approved
        }
        let client = PairingClient(
            makeTransport: { _ in transport }, timing: clock.timing,
            iterationLease: {
                leases.withLock { $0.started += 1 }
                return { leases.withLock { $0.ended += 1 } }
            })
        let result = try await client.enroll(
            invitation(), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(),
            progress: { text in texts.withLock { $0.append(text) } })
        XCTAssertEqual(result.version, .paired)
        XCTAssertEqual(result.clientKey, Self.key)
        XCTAssertEqual(timeouts.value, [5_000, 5_000, 5_000])
        XCTAssertEqual(clock.sleeps.value, [3_000, 3_000])
        XCTAssertEqual(texts.value, [PairingClient.pendingText("012345abcdef"), PairingClient.retryText])
        XCTAssertEqual(leases.value.started, 3)
        XCTAssertEqual(leases.value.ended, 3)
        for request in requests.value {
            XCTAssertEqual(request.path, "/pair")
            XCTAssertNil(request.bearer)
            XCTAssertNil(request.offerAttempt)
            XCTAssertFalse(request.trickleHeaders)
            XCTAssertEqual(request.maxResponseBytes, 1_024)
            let json = try StrictJSONObject(data: XCTUnwrap(request.body))
            XCTAssertEqual(json.keys, ["version", "secret", "label"])
            XCTAssertEqual(json.value("version"), .integer(1))
            XCTAssertEqual(json.value("label"), .string("iPhone"))
        }
    }

    func testRemoteTimeoutAndReturnedRoute() async throws {
        let observed = Locked<Int?>(nil)
        let transport = Transport { _, timeout, _ in
            observed.value = timeout
            return Self.approved
        }
        let client = PairingClient(makeTransport: { _ in transport }, timing: Clock().timing)
        let offered = try invitation(remote: true)
        let result = try await client.enroll(
            offered, clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(), progress: { _ in })
        XCTAssertEqual(observed.value, 15_000)
        XCTAssertEqual(result.remote, offered.remote)
    }

    func testExpiryBoundsRequestsAndRetainsLocalNetworkDenial() async throws {
        for denied in [false, true] {
            let clock = Clock()
            let requests = Locked(0)
            let transport = Transport { _, timeout, _ in
                requests.withLock { $0 += 1 }
                XCTAssertEqual(timeout, 1_000)
                if denied { throw ControlIOError(.localNetworkDenied) }
                return Self.pending
            }
            let client = PairingClient(makeTransport: { _ in transport }, timing: clock.timing)
            do {
                _ = try await client.enroll(
                    invitation(expiry: 1_001), clientKey: Self.key, label: "iPhone",
                    attempt: PairingAttempt(), progress: { _ in })
                XCTFail("Expired approval window must fail")
            } catch {
                if denied {
                    XCTAssertTrue(PairingFailureText.isLocalNetworkDenied(error))
                } else {
                    XCTAssertEqual(error as? HTTPFailure, HTTPFailure(410))
                }
            }
            XCTAssertEqual(requests.value, 1)
            XCTAssertEqual(clock.sleeps.value, [1_000])
        }
    }

    func testExpiredInvitationNeverCreatesTransport() async throws {
        let created = Locked(false)
        let client = PairingClient(
            makeTransport: { _ in
                created.value = true
                return Transport { _, _, _ in Self.approved }
            }, timing: Clock().timing)
        do {
            _ = try await client.enroll(
                invitation(expiry: 1_000), clientKey: Self.key, label: "iPhone",
                attempt: PairingAttempt(), progress: { _ in })
            XCTFail("Expired invitation must fail")
        } catch { XCTAssertEqual(error as? PairingClient.Failure, .invitationExpired) }
        XCTAssertFalse(created.value)
    }

    func testTLSHTTPAndMalformedReplyAreNotRetried() async throws {
        let errors: [Error] = [
            SignalingTLSFailure(.windows, .identity), HTTPFailure(403), HTTPFailure(409), HTTPFailure(500),
            PairingClient.Failure.malformedReply,
        ]
        for expected in errors {
            let count = Locked(0)
            let ended = Locked(0)
            let transport = Transport { _, _, _ in
                count.withLock { $0 += 1 }
                throw expected
            }
            let client = PairingClient(
                makeTransport: { _ in transport }, timing: Clock().timing,
                iterationLease: { { ended.withLock { $0 += 1 } } })
            do {
                _ = try await client.enroll(
                    invitation(), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(), progress: { _ in })
                XCTFail("Fatal failure must escape")
            } catch { XCTAssertEqual(String(reflecting: error), String(reflecting: expected)) }
            XCTAssertEqual(count.value, 1)
            XCTAssertEqual(ended.value, 1)
        }
    }

    func testCancellationWinsOverApprovalAndBalancesLease() async throws {
        let attempt = PairingAttempt()
        let ended = Locked(false)
        let transport = Transport { _, _, _ in
            attempt.cancel()
            return Self.approved
        }
        let client = PairingClient(
            makeTransport: { _ in transport }, timing: Clock().timing,
            iterationLease: { { ended.value = true } })
        do {
            _ = try await client.enroll(
                invitation(), clientKey: Self.key, label: "iPhone", attempt: attempt, progress: { _ in })
            XCTFail("Stop must prevent approval from being returned")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(ended.value)
    }

    func testTaskCancellationClosesTheRegisteredRequestWithoutExplicitBinding() async throws {
        let started = expectation(description: "Request started")
        let handle = Locked<ControlRequestHandle?>(nil)
        let transport = Transport { _, _, active in
            handle.value = active
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return Self.approved
        }
        let client = PairingClient(makeTransport: { _ in transport }, timing: Clock().timing)
        let offered = try invitation()
        let task = Task {
            try await client.enroll(
                offered, clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(), progress: { _ in })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled task must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(handle.value?.isCancelled, true)
    }

    func testLANRequestEndsWithTheApprovalWindowAndIgnoresALateReply() async throws {
        // 3 s of approval time left; the LAN transport alone would allow min(3000, 8000) + 3000 ms.
        let clock = Clock()
        let handle = Locked<ControlRequestHandle?>(nil)
        let deadlines = Locked<[Int64]>([])
        let texts = Locked<[String]>([])
        let pendingReply = Locked<CheckedContinuation<Void, Never>?>(nil)
        let (started, start) = AsyncStream<Void>.makeStream()
        let delivered = expectation(description: "Late reply delivered")
        let transport = Transport { _, timeout, active in
            XCTAssertEqual(timeout, 3_000)
            handle.value = active
            // A reply that keeps trickling in: it ignores the cancel and completes only after the window.
            await withCheckedContinuation { continuation in
                pendingReply.value = continuation
                start.yield()
            }
            delivered.fulfill()
            return Self.approved
        }
        let base = clock.timing
        let timing = PairingClient.Timing(
            monotonicNowMs: base.monotonicNowMs, wallNowSeconds: base.wallNowSeconds, sleepMs: base.sleepMs,
            awaitDeadlineMs: { delay in
                // The approval window elapses while the request is in flight.
                for await _ in started { break }
                deadlines.withLock { $0.append(delay) }
                clock.milliseconds.withLock { $0 += delay }
            })
        let client = PairingClient(makeTransport: { _ in transport }, timing: timing)
        do {
            _ = try await client.enroll(
                invitation(expiry: 1_003), clientKey: Self.key, label: "iPhone", attempt: PairingAttempt(),
                progress: { text in texts.withLock { $0.append(text) } })
            XCTFail("The end of the approval window must end the request")
        } catch { XCTAssertEqual(error as? HTTPFailure, HTTPFailure(410)) }
        XCTAssertEqual(clock.milliseconds.value, 3_000, "ended with the window, not at the transport's 6 s")
        XCTAssertEqual(deadlines.value, [3_000])
        XCTAssertEqual(clock.sleeps.value, [], "no poll after the window")
        XCTAssertEqual(texts.value, [PairingClient.retryText])
        XCTAssertEqual(handle.value?.isCancelled, true, "expiry cancels the in-flight request")

        // The late reply, an approval, arrives after enrollment ended and changes nothing.
        pendingReply.value?.resume()
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testStopEndsAWindowedLANRequestAtOnceWhenTheTransportIgnoresTheCancel() async throws {
        let handle = Locked<ControlRequestHandle?>(nil)
        let pendingReply = Locked<CheckedContinuation<Void, Never>?>(nil)
        let started = expectation(description: "Request started")
        let transport = Transport { _, _, active in
            handle.value = active
            await withCheckedContinuation { continuation in
                pendingReply.value = continuation
                started.fulfill()
            }
            return Self.approved
        }
        let client = PairingClient(makeTransport: { _ in transport }, timing: Clock().timing)
        let offered = try invitation()
        let attempt = PairingAttempt()
        let task = Task {
            try await client.enroll(offered, clientKey: Self.key, label: "iPhone", attempt: attempt, progress: { _ in })
        }
        await fulfillment(of: [started], timeout: 2)
        attempt.cancel()
        do {
            _ = try await task.value
            XCTFail("Stop must end enrollment")
        } catch { XCTAssertTrue(error is CancellationError, "Stop is reported as cancellation, not a timeout") }
        XCTAssertEqual(handle.value?.isCancelled, true)
        pendingReply.value?.resume()
    }

    func testAttemptCancellationInterruptsPollingSleep() async throws {
        let sleeping = expectation(description: "Polling sleep started")
        let timing = PairingClient.Timing(
            monotonicNowMs: { 0 }, wallNowSeconds: { 1_000 },
            sleepMs: { _ in
                sleeping.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            })
        let client = PairingClient(makeTransport: { _ in Transport { _, _, _ in Self.pending } }, timing: timing)
        let offered = try invitation()
        let attempt = PairingAttempt()
        let task = Task {
            try await client.enroll(offered, clientKey: Self.key, label: "iPhone", attempt: attempt, progress: { _ in })
        }
        await fulfillment(of: [sleeping], timeout: 2)
        attempt.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled delay must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReplyDecodingRejectsAmbiguousOrOversizedInput() {
        for text in [
            "{\"version\":1,\"state\":\"pending\",\"request_id\":\"ABCDEF012345\"}",
            "{\"version\":1,\"state\":\"unknown\",\"request_id\":\"\"}",
            "{\"version\":1.0,\"state\":\"approved\",\"request_id\":\"\"}",
            "{\"version\":1,\"version\":1,\"state\":\"approved\",\"request_id\":\"\"}",
            "{\"version\":1,\"state\":\"approved\"}",
        ] { XCTAssertThrowsError(try PairingClient.decodeReply(Array(text.utf8))) }
        XCTAssertThrowsError(try PairingClient.decodeReply(Array(repeating: 32, count: 1_025)))
        XCTAssertEqual(try PairingClient.decodeReply(Self.approved.body), .approved)
    }

    func testWindowClampsWithoutIntegerOverflow() {
        XCTAssertEqual(PairingClient.windowMs(expiresAt: .max, wallNowSeconds: .min), 300_000)
        XCTAssertEqual(PairingClient.windowMs(expiresAt: .min, wallNowSeconds: .max), 0)
        XCTAssertEqual(PairingClient.windowMs(expiresAt: 1_001, wallNowSeconds: 1_000), 1_000)
    }
}
