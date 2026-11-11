import MicDropCore
import XCTest

/// Port of `apps/android/app/src/test/java/com/maskarauder/micdrop/SessionLifecycleTest.kt` plus table tests for every
/// phase. `MediaPresentation`, `StopReason.wireFor` and `SessionShutdown` vectors of the same Kotlin file live in
/// `MediaPresentationTests`, `StopReasonTests` and `SessionShutdownTests`.
final class SessionLifecycleTests: XCTestCase {
    private let destination = "Windows: 192.168.1.20:47321"

    // MARK: - SessionLifecycleTest.kt

    func testLateNetworkNoticeCannotReviveStopOrOverwriteANewSession() {
        var session = SessionLifecycle()
        session.begin("first", destination: "host")
        session.update("first", phase: .recovering, networkStatus: "Network: Cellular")
        session.stopping("first")
        XCTAssertFalse(session.update("first", phase: .playing, networkStatus: "Network: Wi-Fi"))
        XCTAssertEqual(session.view.networkStatus, "Network: Cellular")
        session.finish("first", message: "Stopped")
        session.begin("second", destination: "host")
        XCTAssertEqual(session.view.networkStatus, "")
        XCTAssertFalse(session.update("first", networkStatus: "stale"))
    }

    func testDuplexResumeWaitsForTeardownAndStopCancelsAQueuedResume() {
        var session = SessionLifecycle()
        session.begin("duplex", destination: "host")
        session.update("duplex", phase: .playing)
        XCTAssertTrue(session.pause("duplex", automatic: true))
        XCTAssertFalse(session.focusGained())  // Gain before native teardown must wait.
        XCTAssertTrue(session.focusReturned)
        XCTAssertFalse(session.begin("premature", destination: "host"))
        XCTAssertTrue(session.queuePlay("duplex"))
        XCTAssertTrue(session.stopping("duplex"))
        XCTAssertFalse(session.playAfterPause)
        XCTAssertFalse(session.focusGained())
        XCTAssertTrue(session.finish("duplex", message: "Stopped"))
        XCTAssertNil(session.token)
        XCTAssertFalse(session.view.retained)
    }

    func testPermanentLossOrFailureCannotAutomaticallyRestartDuplexAfterTemporaryLoss() {
        var session = SessionLifecycle()
        session.begin("duplex", destination: "host")
        session.update("duplex", phase: .playing)
        session.pause("duplex", automatic: true)
        session.pause("duplex", automatic: false)
        XCTAssertFalse(session.focusGained())
        XCTAssertTrue(session.finish("duplex", message: "Paused"))
        XCTAssertEqual(session.view.phase, .paused)
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertTrue(session.stopping("duplex"))
        XCTAssertTrue(session.finish("duplex", message: "Expired"))
        XCTAssertFalse(session.focusGained())

        session.begin("next", destination: "host")
        session.update("next", phase: .playing)
        session.pause("next", automatic: true)
        XCTAssertTrue(session.finish("next", message: "Failed", failed: true))
        XCTAssertFalse(session.focusGained())
        XCTAssertNil(session.token)
        XCTAssertEqual(session.view.failureId, "next")
    }

    func testRestoringAHeadsetKeepsTheSessionOwnedAndStopRejectsLateSuccess() {
        var session = SessionLifecycle()
        XCTAssertTrue(session.begin("headset", destination: "host"))
        XCTAssertTrue(session.update("headset", phase: .routeRecovering))
        XCTAssertTrue(session.view.active)
        XCTAssertFalse(session.begin("replacement", destination: "other host"))
        XCTAssertTrue(session.stopping("headset"))
        XCTAssertFalse(session.update("headset", phase: .playing, message: "late route acknowledgment"))
        XCTAssertTrue(session.finish("headset", message: "Stopped."))
        XCTAssertEqual(session.view.phase, .ended)
        XCTAssertNil(session.token)
    }

    func testFinalCopyReportIsRetainedAfterStopAndRejectsAnOldWorker() {
        var session = SessionLifecycle()
        session.begin("first", destination: "host")
        session.update("first", diagnostics: "periodic")
        session.stopping("first")
        XCTAssertFalse(session.update("first", diagnostics: "late periodic"))
        XCTAssertTrue(session.finish("first", message: "stopped", diagnostics: "terminal: peer_failed"))
        XCTAssertEqual(session.view.diagnostics, "terminal: peer_failed")
        session.begin("second", destination: "host")
        XCTAssertFalse(session.finish("first", message: "old", diagnostics: "old terminal"))
        XCTAssertNil(session.view.diagnostics)
    }

    func testPlayDuringManualPauseWaitsForCleanupAndCannotOverlapPeers() {
        var session = SessionLifecycle()
        session.begin("s", destination: "host")
        session.update("s", phase: .playing)
        session.pause("s", automatic: false)
        XCTAssertFalse(session.queuePlay("stale"))
        XCTAssertTrue(session.queuePlay("s"))
        XCTAssertTrue(session.queuePlay("s"))
        XCTAssertFalse(session.begin("overlap", destination: "host"))
        session.finish("s", message: "closed")
        XCTAssertEqual(session.view.phase, .paused)
        XCTAssertTrue(session.playAfterPause)
        XCTAssertTrue(session.begin("next", destination: "host"))
        XCTAssertFalse(session.playAfterPause)
        XCTAssertFalse(session.finish("s", message: "late callback"))
    }

    func testPauseStopAndFailureEachCancelQueuedPlay() {
        for cancel in ["pause", "stop", "failure"] {
            var session = SessionLifecycle()
            session.begin("s", destination: "host")
            session.pause("s", automatic: false)
            session.queuePlay("s")
            switch cancel {
            case "pause":
                session.pause("s", automatic: false)
            case "stop":
                session.stopping("s")
            default:
                session.finish("s", message: "failed", failed: true)
            }
            XCTAssertFalse(session.playAfterPause, "Queued Play survived \(cancel)")
            XCTAssertFalse(session.focusGained())
        }
    }

    func testExplicitPlayDuringInterruptedCleanupReplacesAutomaticIntent() {
        var session = SessionLifecycle()
        session.begin("s", destination: "host")
        session.pause("s", automatic: true)
        session.focusGained()
        session.queuePlay("s")
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertFalse(session.focusReturned)
        session.finish("s", message: "closed")
        XCTAssertEqual(session.view.phase, .paused)
        XCTAssertTrue(session.playAfterPause)
    }

    func testTransientGainDuringTeardownWaitsForNativeRelease() {
        var session = SessionLifecycle()
        session.begin("first", destination: "host")
        session.update("first", phase: .playing, diagnostics: "report")
        XCTAssertTrue(session.pause("first", automatic: true))
        XCTAssertFalse(session.focusGained())
        XCTAssertTrue(session.focusReturned)
        XCTAssertFalse(session.begin("too soon", destination: "host"))
        XCTAssertFalse(session.update("first", phase: .playing))
        XCTAssertTrue(session.finish("first", message: "paused"))
        XCTAssertEqual(session.view.phase, .interrupted)
        XCTAssertEqual(session.view.diagnostics, "report")
        XCTAssertTrue(session.focusReturned)
        XCTAssertTrue(session.begin("second", destination: "host"))
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertFalse(session.finish("first", message: "late end"))
    }

    func testAnotherLossCancelsGainReceivedDuringTeardown() {
        var session = SessionLifecycle()
        session.begin("s", destination: "host")
        session.pause("s", automatic: true)
        session.focusGained()
        session.pause("s", automatic: true)
        session.finish("s", message: "paused")
        XCTAssertFalse(session.focusReturned)
        XCTAssertTrue(session.resumeOnFocus)
        XCTAssertTrue(session.focusGained())
    }

    func testTerminalWorkerFailureWinsOverAConcurrentPauseAndQueuedGain() {
        var session = SessionLifecycle()
        session.begin("s", destination: "host")
        session.pause("s", automatic: true)
        session.focusGained()
        session.finish("s", message: "Authentication failed", failed: true)
        XCTAssertEqual(session.view.phase, .ended)
        XCTAssertEqual(session.view.message, "Authentication failed")
        XCTAssertFalse(session.focusGained())
        XCTAssertNil(session.token)
    }

    func testExplicitPauseAndPermanentLossCancelAutomaticResume() {
        for gainBeforePause in [false, true] {
            var session = SessionLifecycle()
            session.begin("s", destination: "host")
            session.pause("s", automatic: true)
            if gainBeforePause { session.focusGained() }
            XCTAssertTrue(session.pause("s", automatic: false))
            XCTAssertFalse(session.focusGained())
            // A delayed transient-loss callback cannot re-arm it.
            session.pause("s", automatic: true)
            session.finish("s", message: "paused")
            XCTAssertEqual(session.view.phase, .paused, "gainBeforePause=\(gainBeforePause)")
            XCTAssertFalse(session.resumeOnFocus)
            XCTAssertFalse(session.view.busy)
            XCTAssertTrue(session.view.retained)
        }
    }

    func testTimeoutOrKeepPausedReleasesTheInterruptionState() {
        var session = SessionLifecycle()
        session.begin("s", destination: "host")
        session.pause("s", automatic: true)
        session.finish("s", message: "paused")
        XCTAssertTrue(session.view.busy)
        session.pause("s", automatic: false)
        XCTAssertEqual(session.view.phase, .paused)
        XCTAssertFalse(session.focusGained())
    }

    func testStopOrOutputLossWinsAtEveryPauseStage() {
        for complete in [false, true] {
            var session = SessionLifecycle()
            session.begin("s", destination: "host")
            session.pause("s", automatic: true)
            if complete { session.finish("s", message: "paused") }
            XCTAssertTrue(session.stopping("s"))
            XCTAssertFalse(session.focusGained())
            XCTAssertFalse(session.pause("s", automatic: true))
            session.finish("s", message: "stopped")
            XCTAssertEqual(session.view.phase, .ended, "complete=\(complete)")
            XCTAssertNil(session.token)
        }
    }

    func testRestoredPausedStateStaysSilentAndOldActionsCannotStopNewPlayback() {
        var session = SessionLifecycle()
        session.restorePause("paused")
        XCTAssertEqual(session.view.phase, .paused)
        XCTAssertFalse(session.focusGained())
        XCTAssertFalse(session.update("paused", phase: .playing))
        session.begin("new", destination: "host")
        XCTAssertFalse(session.stopping("paused"))
        session.restorePause("stale")
        XCTAssertEqual(session.token, "new")
    }

    func testStopCannotBeUndoneByLateWorkerCallbacks() {
        var session = SessionLifecycle()
        XCTAssertTrue(session.begin("first", destination: "host"))
        XCTAssertFalse(session.begin("duplicate", destination: "other"))
        XCTAssertTrue(session.update("first", phase: .playing, diagnostics: "last report"))
        XCTAssertTrue(session.stopping("first"))
        XCTAssertFalse(session.stopping("first"))
        XCTAssertFalse(session.update("first", phase: .playing, message: "late success"))
        XCTAssertEqual(session.view.phase, .stopping)
        XCTAssertTrue(session.finish("first", message: "Windows acknowledged Stop."))
        XCTAssertFalse(session.view.active)
        XCTAssertEqual(session.view.diagnostics, "last report")
        XCTAssertNil(session.token)
    }

    func testOldControlsAndCallbacksCannotAffectNextSession() {
        var session = SessionLifecycle()
        session.begin("old", destination: "host")
        session.finish("old", message: "ended")
        XCTAssertTrue(session.begin("new", destination: "host"))
        XCTAssertFalse(session.stopping("old"))
        XCTAssertFalse(session.finish("old", message: "late end"))
        XCTAssertFalse(session.update("old", phase: .playing, diagnostics: "old report"))
        XCTAssertEqual(session.view.phase, .connecting)
        XCTAssertNil(session.view.diagnostics)
    }

    // MARK: - Initial state, begin and update

    func testInitialStateIsIdleWithoutTokenOrIntent() {
        let session = SessionLifecycle()
        XCTAssertEqual(session.view, SessionView())
        XCTAssertNil(session.token)
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertFalse(session.focusReturned)
        XCTAssertFalse(session.playAfterPause)
        XCTAssertEqual(SessionLifecycle(initial: SessionView(phase: .paused)).view.phase, .paused)
    }

    func testBeginReplacesTheViewWithAFreshConnectingView() {
        let old = SessionView(
            phase: .ended, message: "Connection ended. Use Reconnect when ready.", diagnostics: "terminal",
            destination: "Windows: 10.0.0.1:1", failureId: "old", outputEnabled: false,
            outputSelection: .restored(.phone), outputPause: .route, networkStatus: "Network: Wi-Fi")
        var session = SessionLifecycle(initial: old)
        XCTAssertTrue(session.begin("id", destination: destination))
        XCTAssertEqual(session.token, "id")
        XCTAssertEqual(
            session.view,
            SessionView(phase: .connecting, message: "Connecting securely to Windows…", destination: destination))
        XCTAssertEqual(session.view.message, SessionLifecycle.Messages.connecting)
    }

    func testBeginIsAcceptedFromEveryPhaseWithoutAWorker() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let active = session.view.active
            let accepted = session.begin("next", destination: destination)
            XCTAssertEqual(accepted, !active, "\(phase)")
            if accepted {
                XCTAssertEqual(session.token, "next")
                XCTAssertEqual(session.view.phase, .connecting)
                XCTAssertFalse(session.resumeOnFocus)
                XCTAssertFalse(session.focusReturned)
                XCTAssertFalse(session.playAfterPause)
            } else {
                XCTAssertEqual(session.token, "s", "\(phase)")
                XCTAssertEqual(session.view.phase, phase)
            }
        }
    }

    func testBeginFromInterruptedClearsAPendingAutomaticResume() {
        var session = lifecycle(in: .interrupted)
        session.focusGained()
        XCTAssertTrue(session.focusReturned)
        XCTAssertTrue(session.begin("resume", destination: destination))
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertFalse(session.focusReturned)
    }

    func testUpdateCopiesOnlyTheGivenFields() {
        var session = SessionLifecycle()
        session.begin("s", destination: destination)
        XCTAssertTrue(session.update("s", phase: .playing))
        XCTAssertEqual(session.view.message, SessionLifecycle.Messages.connecting)
        XCTAssertTrue(session.update("s", message: "LAN snapshot: rtt 4 ms"))
        XCTAssertEqual(session.view.phase, .playing)
        XCTAssertTrue(session.update("s", diagnostics: "report 1"))
        XCTAssertTrue(session.update("s", networkStatus: "Network: Wi-Fi"))
        XCTAssertTrue(session.update("s"))
        XCTAssertEqual(session.view.phase, .playing)
        XCTAssertEqual(session.view.message, "LAN snapshot: rtt 4 ms")
        XCTAssertEqual(session.view.diagnostics, "report 1")
        XCTAssertEqual(session.view.networkStatus, "Network: Wi-Fi")
        XCTAssertEqual(session.view.destination, destination)
    }

    func testUpdateIsAcceptedOnlyWhileAWorkerOwnsTheLiveSession() {
        let accepting: Set<SessionPhase> = [.connecting, .playing, .recovering, .routeRecovering, .switching]
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let before = session.view
            let accepted = session.update("s", phase: .recovering, message: "update")
            XCTAssertEqual(accepted, accepting.contains(phase), "\(phase)")
            if !accepted { XCTAssertEqual(session.view, before, "\(phase)") }
        }
        var session = lifecycle(in: .playing)
        XCTAssertFalse(session.update("other", phase: .recovering))
        XCTAssertEqual(session.view.phase, .playing)
    }

    func testSetDestinationRequiresTheCurrentToken() {
        var session = SessionLifecycle()
        session.begin("a", destination: "")
        session.setDestination("b", "Windows: 10.0.0.9:1")
        XCTAssertEqual(session.view.destination, "")
        session.setDestination("a", destination)
        XCTAssertEqual(session.view.destination, destination)
        session.finish("a", message: "Stopped.")
        session.setDestination("a", "Windows: 10.0.0.9:1")
        XCTAssertEqual(session.view.destination, destination)
    }

    // MARK: - switchRoute, stopping, finish

    func testSwitchRouteFromLivePhasesOnly() {
        let accepting: Set<SessionPhase> = [.playing, .recovering, .routeRecovering]
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let accepted = session.switchRoute("s")
            XCTAssertEqual(accepted, accepting.contains(phase), "\(phase)")
            if accepted {
                XCTAssertEqual(session.view.phase, .switching)
                XCTAssertEqual(
                    session.view.message, "Changing microphone. Finishing the current stream before reconnecting…")
                XCTAssertTrue(session.view.active)
            }
        }
        var session = lifecycle(in: .playing)
        XCTAssertFalse(session.switchRoute("other"))
        XCTAssertTrue(session.switchRoute("s"))
        XCTAssertTrue(session.finish("s", message: "Changing microphone…"))
        XCTAssertEqual(session.view.phase, .ended)
        XCTAssertNil(session.token)
    }

    func testStoppingAcceptsEveryRetainedPhaseOnce() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let expected = session.view.retained && phase != .stopping
            XCTAssertEqual(session.stopping("s"), expected, "\(phase)")
            if expected {
                XCTAssertEqual(session.view.phase, .stopping)
                XCTAssertEqual(session.view.message, "Stopping locally and notifying Windows…")
                XCTAssertFalse(session.resumeOnFocus)
                XCTAssertFalse(session.focusReturned)
                XCTAssertFalse(session.playAfterPause)
                XCTAssertTrue(session.finish("s", message: StopReason.user.message))
                XCTAssertEqual(session.view.phase, .ended)
            }
        }
    }

    func testFinishRequiresAnActivePhaseAndTheToken() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let active = session.view.active
            XCTAssertFalse(session.finish("other", message: "late"), "\(phase)")
            XCTAssertEqual(session.finish("s", message: "done"), active, "\(phase)")
            if active {
                XCTAssertEqual(session.view.phase, phase == .pausing ? .paused : .ended, "\(phase)")
                XCTAssertEqual(session.view.message, "done")
            } else {
                XCTAssertEqual(session.view.phase, phase)
            }
        }
    }

    func testFailedFinishDuringPausingEndsTheSession() {
        var session = lifecycle(in: .pausing)
        XCTAssertTrue(session.finish("s", message: "Connection ended. Use Reconnect when ready.", failed: true))
        XCTAssertEqual(session.view.phase, .ended)
        XCTAssertEqual(session.view.failureId, "s")
        XCTAssertNil(session.token)
        XCTAssertFalse(session.view.retained)
    }

    func testPausingFinishKeepsTheTokenAndReplacesTheMessage() {
        // PlaybackService.finish: a pausing end shows the pause text plus the worker's confirmation lines.
        var manual = lifecycle(in: .pausing)
        let shown = manual.view.message + SessionLifecycle.confirmationSuffix("Paused.\nWindows acknowledged Stop.")
        XCTAssertTrue(manual.finish("s", message: shown, diagnostics: "terminal"))
        XCTAssertEqual(manual.view.phase, .paused)
        XCTAssertEqual(manual.view.message, "Paused. Play reconnects to live audio.\nWindows acknowledged Stop.")
        XCTAssertEqual(manual.view.diagnostics, "terminal")
        XCTAssertEqual(manual.token, "s")
        XCTAssertNil(manual.view.failureId)

        var automatic = lifecycle(in: .playing)
        automatic.pause("s", automatic: true)
        let armedMessage = automatic.view.message
        XCTAssertTrue(automatic.finish("s", message: armedMessage))
        XCTAssertEqual(automatic.view.phase, .interrupted)
        XCTAssertEqual(automatic.token, "s")
        XCTAssertTrue(automatic.resumeOnFocus)
        XCTAssertTrue(automatic.view.busy)
    }

    func testFailureIdMarksOnlyFailedEnds() {
        var session = SessionLifecycle()
        session.begin("a", destination: destination)
        session.finish("a", message: "Connection ended. Use Reconnect when ready.", failed: true)
        XCTAssertEqual(session.view.failureId, "a")
        session.begin("b", destination: destination)
        XCTAssertNil(session.view.failureId)
        session.finish("b", message: "Stopped.")
        XCTAssertNil(session.view.failureId)
    }

    // MARK: - pause, focusGained, restorePause, queuePlay

    func testPauseFromEveryPhase() {
        let live: Set<SessionPhase> = [.connecting, .playing, .recovering, .routeRecovering, .switching]
        for phase in SessionPhase.allCases {
            for automatic in [false, true] {
                var session = lifecycle(in: phase)
                let wasArmed = session.resumeOnFocus
                let accepted = session.pause("s", automatic: automatic)
                let label = "\(phase) automatic=\(automatic)"
                switch phase {
                case _ where live.contains(phase):
                    XCTAssertTrue(accepted, label)
                    XCTAssertEqual(session.view.phase, .pausing, label)
                    XCTAssertEqual(session.resumeOnFocus, automatic, label)
                case .pausing:
                    // Manual pausing: a repeated loss can never re-arm automatic resume.
                    XCTAssertTrue(accepted, label)
                    XCTAssertEqual(session.view.phase, .pausing, label)
                    XCTAssertFalse(session.resumeOnFocus, label)
                case .interrupted:
                    XCTAssertTrue(accepted, label)
                    XCTAssertEqual(session.view.phase, automatic ? .interrupted : .paused, label)
                    XCTAssertEqual(session.resumeOnFocus, wasArmed && automatic, label)
                default:
                    XCTAssertFalse(accepted, label)
                    XCTAssertEqual(session.view.phase, phase, label)
                }
                XCTAssertFalse(session.playAfterPause, label)
                XCTAssertFalse(session.focusReturned, label)
            }
        }
        var session = lifecycle(in: .playing)
        XCTAssertFalse(session.pause("other", automatic: true))
        XCTAssertEqual(session.view.phase, .playing)
    }

    func testPauseMessagesUseTheIOSInterruptionText() {
        var automatic = lifecycle(in: .playing)
        automatic.pause("s", automatic: true)
        XCTAssertEqual(
            automatic.view.message,
            "Interrupted. Will resume when iOS ends the audio interruption (up to 5 minutes).")
        XCTAssertEqual(automatic.view.message, SessionLifecycle.Messages.automaticPause)
        automatic.finish("s", message: SessionLifecycle.Messages.automaticPause)
        automatic.pause("s", automatic: true)
        XCTAssertEqual(automatic.view.phase, .interrupted)
        XCTAssertEqual(automatic.view.message, SessionLifecycle.Messages.automaticPause)
        automatic.pause("s", automatic: false)
        XCTAssertEqual(automatic.view.phase, .paused)
        XCTAssertEqual(automatic.view.message, "Paused. Play reconnects to live audio.")

        var manual = lifecycle(in: .recovering)
        manual.pause("s", automatic: false)
        XCTAssertEqual(manual.view.message, SessionLifecycle.Messages.paused)
    }

    func testFocusGainedWithoutArmedResumeChangesNothing() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            guard !session.resumeOnFocus else { continue }
            let before = session
            XCTAssertFalse(session.focusGained(), "\(phase)")
            XCTAssertEqual(session, before, "\(phase)")
        }
    }

    func testFocusGainedReturnsTrueOnlyOnceTheOldWorkerEnded() {
        var session = lifecycle(in: .playing)
        session.pause("s", automatic: true)
        XCTAssertFalse(session.focusGained())
        XCTAssertTrue(session.focusReturned)
        session.finish("s", message: "paused")
        XCTAssertEqual(session.view.phase, .interrupted)
        XCTAssertTrue(session.focusGained())
        XCTAssertTrue(session.focusReturned)
    }

    func testRestorePauseIsIgnoredWhileBusy() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let before = session
            session.restorePause("ticket")
            if before.view.busy {
                XCTAssertEqual(session, before, "\(phase)")
            } else {
                XCTAssertEqual(session.token, "ticket", "\(phase)")
                XCTAssertEqual(session.view.phase, .paused)
                XCTAssertEqual(session.view.message, "Paused. Play reconnects to live audio.")
                XCTAssertNil(session.view.failureId)
                XCTAssertFalse(session.resumeOnFocus)
                XCTAssertFalse(session.focusReturned)
                XCTAssertFalse(session.playAfterPause)
            }
        }
    }

    func testRestorePauseKeepsTheRetainedCardFields() {
        var session = SessionLifecycle()
        session.begin("a", destination: destination)
        session.update("a", diagnostics: "report")
        session.finish("a", message: "Connection ended. Use Reconnect when ready.", failed: true)
        XCTAssertEqual(session.view.failureId, "a")
        session.restorePause("ticket")
        XCTAssertNil(session.view.failureId)
        XCTAssertEqual(session.view.destination, destination)
        XCTAssertEqual(session.view.diagnostics, "report")
    }

    func testQueuePlayOnlyWhilePausing() {
        for phase in SessionPhase.allCases {
            var session = lifecycle(in: phase)
            let accepted = session.queuePlay("s")
            XCTAssertEqual(accepted, phase == .pausing, "\(phase)")
            XCTAssertEqual(session.playAfterPause, phase == .pausing, "\(phase)")
        }
        var session = lifecycle(in: .playing)
        session.pause("s", automatic: true)
        XCTAssertTrue(session.queuePlay("s"))
        XCTAssertEqual(session.view.phase, .pausing)
        XCTAssertEqual(session.view.message, "Play requested. Finishing the previous stream before reconnecting…")
        XCTAssertFalse(session.resumeOnFocus)
        XCTAssertFalse(session.queuePlay("other"))
    }

    // MARK: - Confirmation suffix and strings

    func testConfirmationSuffixKeepsEverythingAfterTheFirstNewline() {
        let cases: [(String, String)] = [
            ("", ""),
            ("Paused.", ""),
            ("Paused.\n", ""),
            ("Paused.\nWindows acknowledged Stop.", "\nWindows acknowledged Stop."),
            ("a\nb\nc", "\nb\nc"),
            ("\nleading", "\nleading"),
            (
                "Paused.\nStopped locally; Windows Stop was not confirmed. Its watchdog will end the session.",
                "\nStopped locally; Windows Stop was not confirmed. Its watchdog will end the session."
            ),
        ]
        for (message, suffix) in cases {
            XCTAssertEqual(SessionLifecycle.confirmationSuffix(message), suffix, message)
        }
    }

    func testLifecycleMessagesAreTheSpecifiedStrings() {
        typealias M = SessionLifecycle.Messages
        XCTAssertEqual(M.connecting, "Connecting securely to Windows…")
        XCTAssertEqual(M.stopping, "Stopping locally and notifying Windows…")
        XCTAssertEqual(
            M.automaticPause, "Interrupted. Will resume when iOS ends the audio interruption (up to 5 minutes).")
        XCTAssertEqual(M.paused, "Paused. Play reconnects to live audio.")
        XCTAssertEqual(M.queuedPlay, "Play requested. Finishing the previous stream before reconnecting…")
        XCTAssertEqual(M.switchingMicrophone, "Changing microphone. Finishing the current stream before reconnecting…")
        XCTAssertEqual(M.linkUnavailable, "The Windows connection is unavailable or expired. Paste its current link.")
        XCTAssertEqual(M.playbackStartFailed, "Playback could not start. Open MicDrop and check the Windows link.")
        XCTAssertEqual(M.backgroundStartDenied, "iOS could not start background playback. Open MicDrop and try Play.")
        XCTAssertEqual(M.startTimeout, "iOS did not make playback ready. Open MicDrop and try Reconnect.")
        XCTAssertEqual(M.audioBusy, "Audio is busy. Try again after other playback stops.")
        XCTAssertEqual(
            M.outputReselect,
            "The selected media output is unavailable. Reconnect it or choose another output. "
                + "If iOS is hiding a connected device, use AirPlay & Bluetooth output… to make it the iPhone "
                + "output (tap Stop first if a session is running or paused), then choose it.")
        XCTAssertEqual(Strings.outputReselect, M.outputReselect)
        XCTAssertEqual(M.serviceEnded, "Playback service ended. Use Reconnect after Windows finishes the stream.")
        XCTAssertEqual(
            M.backgroundSetupExpired,
            "iOS paused MicDrop in the background before audio started. Open MicDrop and tap Reconnect.")
        XCTAssertEqual(M.savedConnectionUnavailable, "Saved connection could not be loaded.")
        XCTAssertEqual(M.duplexPauseExpired, "Duplex pause ended after 5 minutes. Tap Connect to start again.")
        XCTAssertEqual(
            M.duplexResumeFailed,
            "Duplex could not resume. Check microphone permission and the selected input, then tap Connect again.")
        XCTAssertEqual(
            M.duplexPaused(automatic: true),
            "Duplex paused for phone audio. Will resume when the interruption ends (up to 5 minutes).")
        XCTAssertEqual(
            M.duplexPaused(automatic: false),
            "Duplex paused for phone audio. Tap Resume duplex when ready (within 5 minutes).")
    }

    // MARK: - Helpers

    /// A lifecycle owned by token `"s"` in `phase` (`.idle` and `.ended` have no token).
    private func lifecycle(in phase: SessionPhase) -> SessionLifecycle {
        var session = SessionLifecycle()
        switch phase {
        case .idle:
            break
        case .connecting:
            session.begin("s", destination: destination)
        case .playing, .recovering, .routeRecovering, .switching:
            session.begin("s", destination: destination)
            session.update("s", phase: phase)
        case .pausing:
            session.begin("s", destination: destination)
            session.update("s", phase: .playing)
            session.pause("s", automatic: false)
        case .paused:
            session.restorePause("s")
        case .interrupted:
            session.begin("s", destination: destination)
            session.update("s", phase: .playing)
            session.pause("s", automatic: true)
            session.finish("s", message: SessionLifecycle.Messages.automaticPause)
        case .stopping:
            session.begin("s", destination: destination)
            session.stopping("s")
        case .ended:
            session.begin("s", destination: destination)
            session.finish("s", message: StopReason.user.message)
        }
        XCTAssertEqual(session.view.phase, phase, "fixture for \(phase)")
        return session
    }
}
