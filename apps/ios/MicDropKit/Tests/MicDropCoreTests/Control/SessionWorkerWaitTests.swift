import Foundation
import XCTest

@testable import MicDropCore

/// Port of `SessionWorkerWaitTest.kt` plus the iOS bridge contract: Stop wakes only a registered wait, never interrupts
/// in-flight native work, a wait that completes after Stop throws, and a late Stop cannot reach cleanup.
final class SessionWorkerWaitTests: XCTestCase {
    typealias Worker = ControlTestSupport.Worker
    typealias PendingReply = ControlTestSupport.PendingReply

    private static let session = String(repeating: "a", count: 43)

    /// Blocks the calling thread (kept out of async closures, where blocking APIs are `noasync`).
    private static func block(on semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// `runAsync` whose operation registers `handle` and waits for `reply`.
    private static func exchange(
        _ waits: SessionWorkerWait, timeoutMs: Int?, stopping: Bool = false, handle: ControlRequestHandle,
        reply: PendingReply
    ) throws -> ControlResponse {
        let response: ControlResponse = try waits.runAsync(timeoutMs: timeoutMs, stopping: stopping) { register in
            register(handle)
            return try await reply.wait()
        }
        return response
    }

    // MARK: Android scenarios

    func testStopBeforeTheOwnerStartsCannotCreateNativeResources() {
        let creations = Locked(0)
        let owner = Worker { worker in
            try worker.waits.checkpoint()
            creations.withLock { $0 += 1 }
        }
        owner.stop()
        owner.start()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertEqual(creations.value, 0)
    }

    func testStopDuringInFlightCreationDoesNotInterruptItAndTheResourceIsStillDisposed() {
        let creating = DispatchSemaphore(value: 0)
        let completeCreation = DispatchSemaphore(value: 0)
        let disposed = Locked(0)
        let nextSetup = Locked(0)
        let waitingDuringCreation = Locked(true)
        let owner = Worker { worker in
            var owned = false
            defer { if owned { disposed.withLock { $0 += 1 } } }
            try worker.waits.checkpoint()
            creating.signal()
            // In-flight native creation, outside any registered wait: Stop cannot interrupt it.
            SessionWorkerWaitTests.block(on: completeCreation)
            waitingDuringCreation.value = worker.waits.isWaiting
            owned = true
            try worker.waits.checkpoint()
            nextSetup.withLock { $0 += 1 }
        }
        owner.start()
        XCTAssertEqual(creating.wait(timeout: .now() + 5), .success)
        owner.stop()
        completeCreation.signal()
        XCTAssertTrue(owner.finish())
        XCTAssertFalse(waitingDuringCreation.value)
        XCTAssertTrue(owner.stopped)
        XCTAssertEqual(nextSetup.value, 0)
        XCTAssertEqual(disposed.value, 1)
    }

    func testStopWakesABlockedWaitWithoutLeavingAnInterruptForCleanup() {
        let cleanupResult = Locked<String?>(nil)
        let owner = Worker { worker in
            defer {
                // Cleanup: a stopping exchange after the interrupted wait completes normally.
                let acknowledged: String? = try? worker.waits.runAsync(timeoutMs: 1_000, stopping: true) { _ in
                    "acknowledged"
                }
                cleanupResult.value = acknowledged
            }
            try worker.waits.awaitCompletion(timeoutMs: nil) { (_: SessionWorkerWait.Completion<Void>) in }
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        owner.stop()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertEqual(cleanupResult.value, "acknowledged")
        XCTAssertFalse(owner.waits.isWaiting)
    }

    func testACompletedWaitAfterStopCannotContinueSetup() {
        let nextSetup = Locked(0)
        let owner = Worker { worker in
            let _: String = try worker.waits.awaitCompletion(timeoutMs: 1_000) { completion in
                worker.stop()
                completion.succeed("late SDP success")
            }
            nextSetup.withLock { $0 += 1 }
        }
        owner.start()
        XCTAssertTrue(owner.finish())
        XCTAssertEqual(nextSetup.value, 0)
        XCTAssertTrue(owner.stopped)
    }

    func testACompletionDeliveredWhileTheWorkerSleepsIsCheckedAgainAfterWaking() {
        let gate = DispatchSemaphore(value: 0)
        let owner = Worker { worker in
            let _: String = try worker.waits.awaitCompletion(timeoutMs: 5_000) { completion in
                DispatchQueue.global().async {
                    SessionWorkerWaitTests.block(on: gate)
                    worker.closed.value = true
                    completion.succeed("answer")
                }
            }
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        gate.signal()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped, "a success that arrives after Stop cannot authorize more setup")
    }

    func testStopAfterAcquiringTheAudioPermitReturnsItForTheNextConnection() {
        let audio = AudioSessionOwner()
        XCTAssertTrue(audio.tryAcquire())  // a previous holder
        let continued = Locked(false)
        let owner = Worker { worker in
            try audio.acquire(worker.waits)
            continued.value = true
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        // Stop lands exactly when the permit is handed over: the worker wakes with the grant, its
        // post-wait checkpoint fails and the permit is returned.
        owner.closed.value = true
        audio.release()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertFalse(continued.value, "a stopped session continued setup")
        XCTAssertFalse(audio.isHeld)

        let next = Worker { worker in
            try audio.acquire(worker.waits)
            audio.release()
        }
        next.start()
        XCTAssertTrue(next.finish())
        XCTAssertNil(next.failure.value)
        XCTAssertFalse(audio.isHeld)
    }

    func testCancellingAQueuedAudioOwnerDoesNotReleaseAnotherSessionsPermit() {
        let audio = AudioSessionOwner()
        XCTAssertTrue(audio.tryAcquire())  // another session owns audio
        let owner = Worker { worker in
            try audio.acquire(worker.waits)
            audio.release()
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        owner.stop()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertTrue(audio.isHeld, "the other session's permit must survive")
        audio.release()
        XCTAssertFalse(audio.isHeld, "the cancelled waiter must not receive the permit")
        XCTAssertTrue(audio.tryAcquire())
        audio.release()
    }

    func testLateAndRepeatedStopCannotInterruptOwnerCleanup() {
        let cleaning = DispatchSemaphore(value: 0)
        let completeCleanup = DispatchSemaphore(value: 0)
        let ready = Locked<String?>(nil)
        let cleanup = Locked<String?>(nil)
        let owner = Worker { worker in
            let value: String = try worker.waits.awaitCompletion(timeoutMs: 1_000) { $0.succeed("ready") }
            ready.value = value
            cleaning.signal()
            SessionWorkerWaitTests.block(on: completeCleanup)
            let acknowledged: String = try worker.waits.runAsync(timeoutMs: 1_000, stopping: true) { _ in
                "stop acknowledged"
            }
            cleanup.value = acknowledged
        }
        owner.start()
        XCTAssertEqual(cleaning.wait(timeout: .now() + 5), .success)
        for _ in 0..<20 { owner.stop() }
        completeCleanup.signal()
        XCTAssertTrue(owner.finish())
        XCTAssertNil(owner.failure.value)
        XCTAssertEqual(ready.value, "ready")
        XCTAssertEqual(cleanup.value, "stop acknowledged")
    }

    // MARK: Bounded waits

    func testCheckpointThrowsOnlyAfterClose() {
        let closed = Locked(false)
        let waits = SessionWorkerWait(isCancelled: { closed.value })
        XCTAssertNoThrow(try waits.checkpoint())
        closed.value = true
        XCTAssertThrowsError(try waits.checkpoint()) { XCTAssertTrue($0 is SessionStopped) }
    }

    func testCompletionFromAnotherThreadReturnsTheValue() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let value: Int = try waits.awaitCompletion(timeoutMs: 5_000) { completion in
            DispatchQueue.global().async { completion.succeed(42) }
        }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(waits.isWaiting)
    }

    func testOnlyTheFirstCompletionCounts() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        var kept: SessionWorkerWait.Completion<String>?
        let value: String = try waits.awaitCompletion(timeoutMs: 1_000) { completion in
            kept = completion
            completion.succeed("first")
            completion.fail(ControlTestSupport.Unclassified())
            completion.succeed("second")
        }
        XCTAssertEqual(value, "first")
        XCTAssertEqual(kept?.isCompleted, true)
    }

    func testAFailedCompletionRethrowsItsError() {
        let waits = SessionWorkerWait(isCancelled: { false })
        XCTAssertThrowsError(
            try waits.awaitCompletion(timeoutMs: 1_000) { (completion: SessionWorkerWait.Completion<Int>) in
                completion.fail(HTTPFailure(410))
            }
        ) { XCTAssertEqual($0 as? HTTPFailure, HTTPFailure(410)) }
    }

    func testAnExpiredWaitIsAStageTimeoutThatIsNotRetryable() {
        let waits = SessionWorkerWait(isCancelled: { false })
        XCTAssertThrowsError(
            try waits.awaitCompletion(timeoutMs: 20) { (_: SessionWorkerWait.Completion<Int>) in }
        ) { error in
            XCTAssertTrue(error is StageTimeoutError)
            XCTAssertFalse(ConnectionFailure.retryableStatus(error))
            XCTAssertEqual(SessionFailure.from(error), .stageTimeout)
        }
        XCTAssertFalse(waits.isWaiting)
    }

    func testZeroTimeoutStillReturnsASynchronousCompletion() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let value: String = try waits.awaitCompletion(timeoutMs: 0) { $0.succeed("ready") }
        XCTAssertEqual(value, "ready")
    }

    func testOrElseReturnsTheFallbackOnTimeout() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let started = Date()
        let notified: Bool = try waits.awaitCompletion(timeoutMs: 30, orElse: false) { _ in }
        XCTAssertFalse(notified)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.025)
        let early: Bool = try waits.awaitCompletion(timeoutMs: 1_000, orElse: false) { $0.succeed(true) }
        XCTAssertTrue(early)
    }

    func testOrElseAfterStopStillThrows() {
        let owner = Worker { worker in
            let _: Bool = try worker.waits.awaitCompletion(timeoutMs: 20, orElse: false) { _ in
                worker.closed.value = true
            }
        }
        owner.start()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
    }

    func testCallbackSpellingCompletesFromAnyThreadAndTimesOut() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let sdp: String = try waits.await(timeoutMs: 5_000) { complete in
            let box = SessionWorkerWaitTests.CallbackBox(complete)
            DispatchQueue.global().async { box.call(.success("v=0")) }
        }
        XCTAssertEqual(sdp, "v=0")
        XCTAssertThrowsError(try Self.callbackNeverCompleting(waits, timeoutMs: 20)) {
            XCTAssertTrue($0 is StageTimeoutError)
        }
        XCTAssertThrowsError(try Self.callbackFailing(waits)) {
            XCTAssertEqual($0 as? ControlResponseError, ControlResponseError(.invalidReply))
        }
    }

    /// Hands a completion callback to another thread.
    private final class CallbackBox: @unchecked Sendable {
        private let complete: (Result<String, Error>) -> Void

        init(_ complete: @escaping (Result<String, Error>) -> Void) {
            self.complete = complete
        }

        func call(_ result: Result<String, Error>) {
            complete(result)
        }
    }

    private static func callbackNeverCompleting(_ waits: SessionWorkerWait, timeoutMs: Int) throws -> String {
        let value: String = try waits.await(timeoutMs: timeoutMs) { _ in }
        return value
    }

    private static func callbackFailing(_ waits: SessionWorkerWait) throws -> String {
        let value: String = try waits.await(timeoutMs: 1_000) { complete in
            complete(.failure(ControlResponseError(.invalidReply)))
        }
        return value
    }

    func testAThrowingStartPropagatesWithoutRegisteringAWait() {
        let waits = SessionWorkerWait(isCancelled: { false })
        XCTAssertThrowsError(
            try waits.awaitCompletion(timeoutMs: 1_000) { (_: SessionWorkerWait.Completion<Int>) in
                throw ControlResponseError(.invalidJSON)
            }
        ) { XCTAssertEqual($0 as? ControlResponseError, ControlResponseError(.invalidJSON)) }
        XCTAssertFalse(waits.isWaiting)
    }

    func testCancelOutsideAWaitIsANoOp() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        waits.cancel()
        waits.cancel()
        let value: String = try waits.awaitCompletion(timeoutMs: 5_000) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion.succeed("kept") }
        }
        XCTAssertEqual(value, "kept")
    }

    func testCancelInterruptsTheRegisteredWait() {
        // Kotlin interrupts a registered wait on any cancel(); the woken wait reports Stop.
        let owner = Worker { worker in
            let _: Int = try worker.waits.awaitCompletion(timeoutMs: nil) { _ in }
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        owner.waits.cancel()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
    }

    func testSleepWaitsAndStopInterruptsIt() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let started = Date()
        try waits.sleep(ms: 30)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.025)
        try waits.sleep(ms: 0)
        try waits.sleep(ms: -5)

        let owner = Worker { worker in try worker.waits.sleep(ms: 60_000) }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        let stoppedAt = Date()
        owner.stop()
        XCTAssertTrue(owner.finish(timeout: 2))
        XCTAssertTrue(owner.stopped)
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1.0)
    }

    // MARK: Async bridge

    func testRunAsyncReturnsTheTaskResult() throws {
        let waits = SessionWorkerWait(isCancelled: { false })
        let value: String = try waits.runAsync(timeoutMs: 5_000) { _ in "offer" }
        XCTAssertEqual(value, "offer")
        let unbounded: Int = try waits.runAsync(timeoutMs: nil) { _ in 7 }
        XCTAssertEqual(unbounded, 7)
    }

    func testRunAsyncRethrowsTheTaskError() {
        let waits = SessionWorkerWait(isCancelled: { false })
        XCTAssertThrowsError(try Self.failingRun(waits)) { XCTAssertEqual($0 as? HTTPFailure, HTTPFailure(423)) }
    }

    private static func failingRun(_ waits: SessionWorkerWait) throws -> Int {
        let value: Int = try waits.runAsync(timeoutMs: 5_000) { _ in throw HTTPFailure(423) }
        return value
    }

    func testRunAsyncTimeoutCancelsTheRegisteredHandleAndIsARetryableTimeout() {
        let waits = SessionWorkerWait(isCancelled: { false })
        let reply = PendingReply()
        let handle = ControlRequestHandle { reply.finish(.failure(SessionStopped())) }
        XCTAssertThrowsError(try Self.exchange(waits, timeoutMs: 30, handle: handle, reply: reply)) { error in
            XCTAssertEqual(error as? ControlIOError, ControlIOError(.timedOut))
            XCTAssertTrue(ConnectionFailure.retryableStatus(error))
        }
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(reply.isFinished)
    }

    func testStopCancelsTheRegisteredRequestAndThrowsSessionStopped() {
        let reply = PendingReply()
        let handle = ControlRequestHandle { reply.finish(.failure(ControlIOError(.transportClosed))) }
        let owner = Worker { worker in
            _ = try SessionWorkerWaitTests.exchange(worker.waits, timeoutMs: 60_000, handle: handle, reply: reply)
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        owner.stop()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertTrue(handle.isCancelled)
    }

    func testAHandleRegisteredAfterStopIsCancelledImmediately() {
        let gate = DispatchSemaphore(value: 0)
        let registered = DispatchSemaphore(value: 0)
        let late = ControlRequestHandle {}
        let owner = Worker { worker in
            let _: Int = try worker.waits.runAsync(timeoutMs: 60_000) { register in
                SessionWorkerWaitTests.block(on: gate)
                register(late)
                registered.signal()
                return 1
            }
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        owner.stop()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        gate.signal()
        XCTAssertEqual(registered.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(late.isCancelled)
    }

    func testAFailureAfterStopIsReportedAsSessionStopped() {
        let owner = Worker { worker in
            let _: Int = try worker.waits.runAsync(timeoutMs: 5_000) { _ in
                worker.closed.value = true
                throw ControlIOError(.transportClosed)
            }
        }
        owner.start()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
    }

    func testStoppingRequestsIgnoreStopAndSkipCheckpoints() {
        let reply = PendingReply()
        let handle = ControlRequestHandle { reply.finish(.failure(SessionStopped())) }
        let result = Locked<String?>(nil)
        let owner = Worker { worker in
            worker.closed.value = true  // cleanup runs after `closed` is set
            let response = try SessionWorkerWaitTests.exchange(
                worker.waits, timeoutMs: 5_000, stopping: true, handle: handle, reply: reply)
            result.value = String(decoding: response.body, as: UTF8.self)
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting })
        for _ in 0..<5 { owner.waits.cancel() }
        XCTAssertFalse(handle.isCancelled, "a stopping request is never cancelled by Stop")
        reply.finish(.success(ControlResponse(body: Array("{\"ok\":true}".utf8))))
        XCTAssertTrue(owner.finish())
        XCTAssertNil(owner.failure.value)
        XCTAssertEqual(result.value, "{\"ok\":true}")
    }

    func testStoppingRequestStillHonoursItsTimeout() {
        let waits = SessionWorkerWait(isCancelled: { true })
        let reply = PendingReply()
        let handle = ControlRequestHandle { reply.finish(.failure(SessionStopped())) }
        XCTAssertThrowsError(try Self.exchange(waits, timeoutMs: 30, stopping: true, handle: handle, reply: reply)) {
            XCTAssertEqual($0 as? ControlIOError, ControlIOError(.timedOut))
        }
        XCTAssertTrue(handle.isCancelled)
    }

    func testOrdinaryRequestAfterCloseIsRefusedBeforeAnyIO() {
        let transport = ControlTestSupport.ScriptedTransport(body: "{}")
        let waits = SessionWorkerWait(isCancelled: { true })
        let request = ControlRequest.status(session: Self.session, body: nil)
        XCTAssertThrowsError(try waits.send(request, over: transport, timeoutMs: 2_000)) {
            XCTAssertTrue($0 is SessionStopped)
        }
        XCTAssertTrue(transport.requests.value.isEmpty)
    }

    // MARK: send / sendJSON over a ControlTransport

    func testSendPassesTheRequestTimeoutAndHandle() throws {
        let transport = ControlTestSupport.ScriptedTransport(body: "{\"ok\":true,\"muted\":true}\n")
        let waits = SessionWorkerWait(isCancelled: { false })
        let observed = Locked<[ControlRequestHandle]>([])
        let request = ControlRequest.microphone(session: Self.session, muted: true)
        let reply = try waits.sendJSON(request, over: transport, timeoutMs: 8_000) { handle in
            observed.withLock { $0.append(handle) }
        }
        XCTAssertNoThrow(try reply.requireMicrophoneAck(muted: true))
        XCTAssertEqual(transport.requests.value, [request])
        XCTAssertEqual(transport.timeouts.value, [8_000])
        XCTAssertEqual(observed.value.count, 1)
        XCTAssertTrue(observed.value.first === transport.handles.value.first)
    }

    func testSendJSONRejectsANonObjectBody() {
        let transport = ControlTestSupport.ScriptedTransport(body: "[1,2]")
        let waits = SessionWorkerWait(isCancelled: { false })
        let request = ControlRequest.status(session: Self.session, body: nil)
        XCTAssertThrowsError(try waits.sendJSON(request, over: transport, timeoutMs: 2_000)) { error in
            XCTAssertEqual(error as? ControlResponseError, ControlResponseError(.invalidJSON))
            XCTAssertFalse(ConnectionFailure.retryableStatus(error))
        }
    }

    func testSendPropagatesTransportErrorsUnchanged() {
        let errors: [Error] = [HTTPFailure(503), SignalingStreamEnded(), ControlIOError(.unreachable)]
        for error in errors {
            let transport = ControlTestSupport.ScriptedTransport(.fail(error))
            let waits = SessionWorkerWait(isCancelled: { false })
            let request = ControlRequest.status(session: Self.session, body: nil)
            XCTAssertThrowsError(try waits.send(request, over: transport, timeoutMs: 2_000)) { thrown in
                XCTAssertEqual(String(describing: thrown), String(describing: error))
            }
        }
    }

    func testStopAbortsAnInFlightSend() {
        let transport = ControlTestSupport.ScriptedTransport(.block)
        let request = ControlRequest.status(session: Self.session, body: nil)
        let owner = Worker { worker in
            _ = try worker.waits.send(request, over: transport, timeoutMs: 60_000)
        }
        owner.start()
        XCTAssertTrue(ControlTestSupport.eventually { owner.waits.isWaiting && !transport.handles.value.isEmpty })
        owner.stop()
        XCTAssertTrue(owner.finish())
        XCTAssertTrue(owner.stopped)
        XCTAssertEqual(transport.handles.value.first?.isCancelled, true)
    }

    func testTransportGraceIsFiveSeconds() {
        XCTAssertEqual(SessionWorkerWait.transportGraceMs, 5_000)
    }
}
