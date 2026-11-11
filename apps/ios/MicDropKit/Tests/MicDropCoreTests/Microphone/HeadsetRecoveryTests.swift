import Dispatch
import Foundation
import MicDropCore
import XCTest

/// `T/HeadsetRecoveryTest.kt` (all eight tests, same numbers) plus the iOS copy text, the constants and the
/// locking/arithmetic edges.
final class HeadsetRecoveryTests: XCTestCase {
    func testCustomWindowKeepsOneDeadlineAndStopRejectsLateRestoration() throws {
        let recovery = HeadsetRecovery(limitMs: 60_500)
        recovery.request(nowMs: 1000)
        let first = try XCTUnwrap(recovery.current())
        recovery.request(nowMs: 60000)
        XCTAssertFalse(recovery.complete(first, nowMs: 60001))
        XCTAssertEqual(recovery.remaining(nowMs: 61499), 1)
        XCTAssertEqual(recovery.remaining(nowMs: 61500), 0)
        XCTAssertFalse(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 61500))
        XCTAssertTrue(recovery.text().contains("Window: 60500 ms"))
        recovery.cancel()
        XCTAssertFalse(recovery.request(nowMs: 62000))
    }

    func testFurtherRouteChangesInvalidateAnAcknowledgmentWithoutRenewingTheDeadline() throws {
        let recovery = HeadsetRecovery()
        XCTAssertTrue(recovery.request(nowMs: 1000))
        let first = try XCTUnwrap(recovery.current())
        XCTAssertEqual(recovery.remaining(nowMs: 6000), 15000)  // Still eligible after the old five-second cutoff.
        XCTAssertTrue(recovery.request(nowMs: 19000))
        let current = try XCTUnwrap(recovery.current())
        XCTAssertEqual(first.episode, current.episode)
        XCTAssertFalse(recovery.complete(first, nowMs: 19001))
        XCTAssertEqual(recovery.remaining(nowMs: 19001), 1999)
        XCTAssertTrue(recovery.complete(current, nowMs: 20999))
        XCTAssertFalse(recovery.pending())
        XCTAssertFalse(recovery.complete(current, nowMs: 20999))
        XCTAssertTrue(recovery.text().contains("Completed: 1"))
    }

    func testCallbackStormsAndSlowAcknowledgmentsCannotKeepRecoveryAliveIndefinitely() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 1000)
        for time in stride(from: Int64(1001), through: 21000, by: 100) { recovery.request(nowMs: time) }
        let last = try XCTUnwrap(recovery.current())
        XCTAssertEqual(recovery.remaining(nowMs: 21000), 0)
        XCTAssertFalse(recovery.complete(last, nowMs: 21000))
        XCTAssertFalse(recovery.reselectionDue(nowMs: 21000))
        XCTAssertFalse(recovery.profileRequestDue(nowMs: 21000))
        XCTAssertTrue(recovery.pending())  // The owning worker must end this episode.
    }

    func testReselectionRequestsAreBoundedAndANewEpisodeGetsItsOwnBudget() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 1000)
        XCTAssertTrue(recovery.reselectionDue(nowMs: 1000))
        XCTAssertFalse(recovery.reselectionDue(nowMs: 1499))
        XCTAssertTrue(recovery.reselectionDue(nowMs: 1500))
        XCTAssertTrue(recovery.reselectionDue(nowMs: 2000))
        XCTAssertFalse(recovery.reselectionDue(nowMs: 3000))
        XCTAssertFalse(recovery.reselectionDue(nowMs: 20000))  // More time does not reset the retry budget.
        let first = try XCTUnwrap(recovery.current())
        XCTAssertTrue(recovery.complete(first, nowMs: 20000))
        recovery.request(nowMs: 21000)
        let second = try XCTUnwrap(recovery.current())
        XCTAssertNotEqual(first.episode, second.episode)
        XCTAssertFalse(recovery.complete(first, nowMs: 21001))
        XCTAssertTrue(recovery.reselectionDue(nowMs: 21001))
        XCTAssertTrue(recovery.complete(second, nowMs: 21002))
        XCTAssertTrue(recovery.text().contains("Completed: 2"))
        XCTAssertTrue(recovery.text().contains("Reselection requests: 4"))
    }

    func testWaitingForAnEndpointPreservesTheBudgetButCannotRenewTheWindow() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 1000)
        for time in stride(from: Int64(1000), through: 19000, by: 100) {
            XCTAssertFalse(recovery.reselectionDue(nowMs: time, endpointAvailable: false))
        }
        XCTAssertTrue(recovery.text().contains("Reselection requests: 0"))
        XCTAssertEqual(recovery.remaining(nowMs: 20000), 1000)
        XCTAssertTrue(recovery.reselectionDue(nowMs: 20000, endpointAvailable: true))
        recovery.request(nowMs: 20500)  // Endpoint callbacks cannot grant another twenty seconds.
        XCTAssertTrue(recovery.reselectionDue(nowMs: 20500, endpointAvailable: true))
        XCTAssertFalse(recovery.reselectionDue(nowMs: 21000, endpointAvailable: true))
        XCTAssertFalse(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 21000))
        XCTAssertTrue(recovery.text().contains("Reselection requests: 2"))
    }

    func testStopWinsWhenAnAcknowledgmentIsAlreadyInFlight() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 1000)
        let ticket = try XCTUnwrap(recovery.current())
        let waiting = DispatchSemaphore(value: 0)
        let acknowledgment = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let resumed = ResultBox()
        DispatchQueue.global().async {
            waiting.signal()
            if acknowledgment.wait(timeout: .now() + 1) == .success {
                resumed.set(recovery.complete(ticket, nowMs: 16001))
            }
            finished.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 1), .success)
        recovery.cancel()
        acknowledgment.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(resumed.get(), false)
        XCTAssertFalse(recovery.request(nowMs: 16002))
        XCTAssertFalse(recovery.pending())
        XCTAssertNil(recovery.current())
        XCTAssertTrue(recovery.text().contains("Completed: 0"))
        XCTAssertTrue(recovery.text().contains("recovery: stopped"))
    }

    func testReleasingAnUnavailableRouteIsOncePerEpisodeAndKeepsTheDeadline() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 1000)
        XCTAssertFalse(recovery.routeReleaseDue(nowMs: 1000, endpointAvailable: true))
        XCTAssertTrue(recovery.routeReleaseDue(nowMs: 1001, endpointAvailable: false))
        recovery.observe("selected audio profile unavailable")
        for time in stride(from: Int64(1002), through: 20000, by: 100) {
            recovery.request(nowMs: time)
            XCTAssertFalse(recovery.routeReleaseDue(nowMs: time, endpointAvailable: false))
        }
        XCTAssertEqual(recovery.remaining(nowMs: 20000), 1000)
        XCTAssertTrue(recovery.text().contains("Route releases: 1"))
        XCTAssertTrue(recovery.text().contains("Reselection requests: 0"))
        XCTAssertTrue(recovery.text().contains("Last check: selected audio profile unavailable"))
        XCTAssertTrue(recovery.reselectionDue(nowMs: 20000, endpointAvailable: true))
        XCTAssertTrue(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 20001))
        recovery.request(nowMs: 21000)
        XCTAssertTrue(recovery.routeReleaseDue(nowMs: 21001, endpointAvailable: false))
        XCTAssertTrue(recovery.text().contains("Route releases: 2"))
    }

    func testStopOrExpiryPreventsARouteReleaseAndPreservesTheLastCheck() {
        let stopped = HeadsetRecovery()
        stopped.request(nowMs: 1000)
        stopped.observe("original headset identity unavailable")
        stopped.cancel()
        XCTAssertFalse(stopped.routeReleaseDue(nowMs: 1001, endpointAvailable: false))
        stopped.observe("late callback")
        XCTAssertTrue(stopped.text().contains("Last check: original headset identity unavailable"))
        let expired = HeadsetRecovery()
        expired.request(nowMs: 1000)
        XCTAssertFalse(expired.routeReleaseDue(nowMs: 21000, endpointAvailable: false))
    }

    // MARK: - Profile requests (same budget shape; never called on iOS)

    func testProfileRequestsHaveTheirOwnBoundedBudget() throws {
        let recovery = HeadsetRecovery()
        XCTAssertFalse(recovery.profileRequestDue(nowMs: 1000))  // Not pending.
        recovery.request(nowMs: 1000)
        XCTAssertTrue(recovery.reselectionDue(nowMs: 1000))
        XCTAssertTrue(recovery.profileRequestDue(nowMs: 1000))
        XCTAssertFalse(recovery.profileRequestDue(nowMs: 1499))
        XCTAssertTrue(recovery.profileRequestDue(nowMs: 1500))
        XCTAssertTrue(recovery.profileRequestDue(nowMs: 2000))
        XCTAssertFalse(recovery.profileRequestDue(nowMs: 3000))
        XCTAssertTrue(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 3000))
        recovery.request(nowMs: 4000)
        XCTAssertTrue(recovery.profileRequestDue(nowMs: 4000))
        XCTAssertEqual(
            recovery.text(platformNotes: false),
            "Selected headset recovery: restoring · Window: 20000 ms · Completed: 1 · Reselection requests: 1 · "
                + "Route releases: 0 · SCO profile requests: 4 · Last check: checking selected headset")
    }

    // MARK: - States, observation and text

    func testInitialStateAndObservationOnlyWhilePending() {
        let recovery = HeadsetRecovery()
        XCTAssertNil(recovery.current())
        XCTAssertFalse(recovery.pending())
        XCTAssertEqual(recovery.remaining(nowMs: 5000), 0)
        XCTAssertFalse(recovery.reselectionDue(nowMs: 5000))
        XCTAssertFalse(recovery.routeReleaseDue(nowMs: 5000, endpointAvailable: false))
        XCTAssertFalse(recovery.complete(HeadsetRecovery.Ticket(episode: 0, revision: 0), nowMs: 5000))
        recovery.observe("ignored")
        XCTAssertEqual(
            recovery.text(platformNotes: false),
            "Selected headset recovery: settled · Window: 20000 ms · Completed: 0 · Reselection requests: 0 · "
                + "Route releases: 0 · SCO profile requests: 0 · Last check: not started")
        recovery.request(nowMs: 5000)
        XCTAssertEqual(recovery.current(), HeadsetRecovery.Ticket(episode: 1, revision: 1))
        XCTAssertTrue(recovery.text().contains("Last check: checking selected headset"))
        recovery.observe(HeadsetEndpoint.State.identityMissing.text)
        XCTAssertTrue(recovery.text().contains("Last check: original headset identity unavailable"))
        recovery.request(nowMs: 6000)
        XCTAssertEqual(recovery.current(), HeadsetRecovery.Ticket(episode: 1, revision: 2))
        // A repeated request inside the episode keeps "Last check".
        XCTAssertTrue(recovery.text().contains("Last check: original headset identity unavailable"))
    }

    func testANewEpisodeResetsLastCheckAndPerEpisodeBudgetsButKeepsTotals() throws {
        let recovery = HeadsetRecovery()
        recovery.request(nowMs: 0)
        XCTAssertTrue(recovery.routeReleaseDue(nowMs: 0, endpointAvailable: false))
        recovery.observe(HeadsetRecovery.Check.waitingMicrophoneSource)
        XCTAssertTrue(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 10))
        // Settled: observation is ignored and the last label is kept.
        recovery.observe(HeadsetRecovery.Check.portAvailable)
        XCTAssertTrue(recovery.text().contains("settled"))
        XCTAssertTrue(recovery.text().contains("Last check: waiting for original microphone source"))
        recovery.request(nowMs: 100)
        XCTAssertEqual(recovery.current()?.episode, 2)
        XCTAssertTrue(recovery.text().contains("Last check: checking selected headset"))
        XCTAssertTrue(recovery.routeReleaseDue(nowMs: 100, endpointAvailable: false))
        XCTAssertTrue(recovery.text().contains("Route releases: 2"))
    }

    func testIOSCopyTextMarksTheCountersThatIOSCannotUse() {
        let recovery = HeadsetRecovery()
        XCTAssertEqual(
            recovery.text(),
            "Selected headset recovery: settled · Window: 20000 ms · Completed: 0 · Reselection requests: 0 · "
                + "Route releases: 0 (not available on iOS) · SCO profile requests: 0 (not available on iOS) · "
                + "Last check: not started")
        XCTAssertEqual(recovery.text(), recovery.text(platformNotes: true))
        recovery.request(nowMs: 0)
        XCTAssertTrue(recovery.routeReleaseDue(nowMs: 0, endpointAvailable: false))
        XCTAssertTrue(recovery.text().contains("Route releases: 1 · SCO profile requests: 0 (not available on iOS)"))
        XCTAssertTrue(recovery.text().hasPrefix(HeadsetRecovery.textPrefix + " "))
        XCTAssertEqual(HeadsetRecovery.textPrefix, "Selected headset recovery:")
    }

    func testConstantsAndLabels() {
        XCTAssertEqual(HeadsetRecovery.windowMs, 20_000)
        XCTAssertEqual(HeadsetRecovery.windowSeconds, 20)
        XCTAssertEqual(HeadsetRecovery.counterLimit, (Int64(1) << 53) - 1)
        XCTAssertEqual(HeadsetRecovery.requestsPerEpisode, 3)
        XCTAssertEqual(HeadsetRecovery.requestSpacingMs, 500)
        XCTAssertEqual(HeadsetRecovery.Check.notStarted, "not started")
        XCTAssertEqual(HeadsetRecovery.Check.checking, "checking selected headset")
        XCTAssertEqual(HeadsetRecovery.Check.portUnavailable, "selected port unavailable")
        XCTAssertEqual(HeadsetRecovery.Check.portAvailable, "selected port available")
        XCTAssertEqual(HeadsetRecovery.Check.selectionRejected, "iOS rejected headset selection")
        XCTAssertEqual(HeadsetRecovery.Check.waitingCommunicationRoute, "waiting for original communication route")
        XCTAssertEqual(HeadsetRecovery.Check.waitingMicrophoneSource, "waiting for original microphone source")
        XCTAssertEqual(HeadsetRecovery.Check.waitingVerifiedMicrophone, "waiting for verified original microphone")
        XCTAssertEqual(
            HeadsetRecovery.Check.waitingVerifiedOutput, "waiting for verified original output and channel count")
        let alias: HeadsetRecoveryTicket = HeadsetRecovery.Ticket(episode: 2, revision: 3)
        XCTAssertEqual(alias.episode, 2)
        XCTAssertEqual(alias.revision, 3)
    }

    func testACustomWindowEndsAtItsLimit() throws {
        let recovery = HeadsetRecovery(limitMs: 1000)
        recovery.request(nowMs: 0)
        XCTAssertEqual(recovery.remaining(nowMs: 500), 500)
        XCTAssertEqual(recovery.remaining(nowMs: 999), 1)
        XCTAssertEqual(recovery.remaining(nowMs: 1000), 0)
        XCTAssertFalse(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 1000))
        XCTAssertTrue(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: 999))
    }

    func testExtremeClockValuesNeverTrap() throws {
        let recovery = HeadsetRecovery()
        XCTAssertTrue(recovery.request(nowMs: .max))
        for now in [Int64.min, -1, 0, .max] {
            let remaining = recovery.remaining(nowMs: now)
            XCTAssertTrue((0...HeadsetRecovery.windowMs).contains(remaining), "\(now) → \(remaining)")
            _ = recovery.reselectionDue(nowMs: now)
            _ = recovery.profileRequestDue(nowMs: now)
            _ = recovery.routeReleaseDue(nowMs: now, endpointAvailable: false)
        }
        XCTAssertEqual(recovery.remaining(nowMs: .max), HeadsetRecovery.windowMs)
        XCTAssertTrue(recovery.complete(try XCTUnwrap(recovery.current()), nowMs: .max))
        XCTAssertTrue(recovery.request(nowMs: .min))
        XCTAssertEqual(recovery.remaining(nowMs: .min), HeadsetRecovery.windowMs)
    }

    func testConcurrentCallbacksAreSerialized() throws {
        let recovery = HeadsetRecovery()
        let iterations = 500
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            recovery.request(nowMs: 1000 + Int64(index % 7))
            recovery.observe(HeadsetRecovery.Check.checking)
            _ = recovery.current()
            _ = recovery.text()
            _ = recovery.reselectionDue(nowMs: 1000 + Int64(index))
        }
        let ticket = try XCTUnwrap(recovery.current())
        XCTAssertEqual(ticket.episode, 1)
        XCTAssertEqual(ticket.revision, Int64(iterations))
        // Every attempt falls within 500 ms of the first accepted one, so exactly one is accepted.
        XCTAssertTrue(recovery.text().contains("Reselection requests: 1 ·"), recovery.text())
    }
}

/// Cross-thread result holder for the in-flight acknowledgment test.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
