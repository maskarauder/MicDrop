import XCTest

@testable import MicDropCore

final class SessionRequestRegistrationTests: XCTestCase {
    func testHandoffCancelsInflightStatusAndRemainsRetryable() {
        let registration = SessionRequestRegistration()
        let handle = ControlRequestHandle {}
        registration.attach(handle)
        registration.cancelForHandoff()
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(ConnectionFailure.retryableStatus(registration.failure(SessionStopped(), sessionClosed: false)))
    }

    func testUserStopWinsAfterHandoff() {
        let registration = SessionRequestRegistration()
        registration.cancelForHandoff()
        let failure = registration.failure(SessionStopped(), sessionClosed: true)
        XCTAssertTrue(failure is SessionStopped)
        XCTAssertFalse(ConnectionFailure.retryableStatus(failure))
    }

    func testOrdinaryCancellationStaysTerminal() {
        let registration = SessionRequestRegistration()
        registration.cancel()
        registration.cancelForHandoff()
        XCTAssertTrue(registration.failure(SessionStopped(), sessionClosed: false) is SessionStopped)
    }

    func testLateHandleIsCancelledAfterStopOrRequestRetirement() {
        for cancelled in [false, true] {
            let old = SessionRequestRegistration()
            if cancelled { old.cancel() } else { old.finish() }
            let current = SessionRequestRegistration()
            let currentHandle = ControlRequestHandle {}
            current.attach(currentHandle)
            let lateHandle = ControlRequestHandle {}
            old.attach(lateHandle)
            XCTAssertTrue(lateHandle.isCancelled)
            XCTAssertFalse(currentHandle.isCancelled)
        }
    }

    func testHandoffDoesNotMakeTLSFailureRetryable() {
        let registration = SessionRequestRegistration()
        registration.cancelForHandoff()
        let failure = registration.failure(SignalingTLSFailure(.windows, .identity), sessionClosed: false)
        XCTAssertTrue(failure is SignalingTLSFailure)
        XCTAssertFalse(ConnectionFailure.retryableStatus(failure))
    }
}
