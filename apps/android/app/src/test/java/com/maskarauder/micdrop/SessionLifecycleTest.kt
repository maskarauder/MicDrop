package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class SessionLifecycleTest {
    @Test fun lateNetworkNoticeCannotReviveStopOrOverwriteANewSession() {
        val session = SessionLifecycle()
        session.begin("first", "host")
        session.update("first", SessionPhase.RECOVERING, networkStatus = "Network: Mobile data")
        session.stopping("first")
        assertFalse(session.update("first", SessionPhase.PLAYING, networkStatus = "Network: Wi-Fi"))
        session.finish("first", "Stopped")
        session.begin("second", "host")
        assertEquals("", session.view.networkStatus)
        assertFalse(session.update("first", networkStatus = "stale"))
    }
    @Test fun duplexResumeWaitsForTeardownAndStopCancelsAQueuedResume() {
        val session = SessionLifecycle()
        session.begin("duplex", "host")
        session.update("duplex", SessionPhase.PLAYING)
        assertTrue(session.pause("duplex", true))
        assertFalse(session.focusGained()) // Gain before native teardown must wait.
        assertTrue(session.focusReturned)
        assertFalse(session.begin("premature", "host"))
        assertTrue(session.queuePlay("duplex"))
        assertTrue(session.stopping("duplex"))
        assertFalse(session.playAfterPause)
        assertFalse(session.focusGained())
        assertTrue(session.finish("duplex", "Stopped"))
        assertNull(session.token)
        assertFalse(session.view.retained)
    }

    @Test fun permanentLossOrFailureCannotAutomaticallyRestartDuplexAfterTemporaryLoss() {
        val session = SessionLifecycle()
        session.begin("duplex", "host")
        session.update("duplex", SessionPhase.PLAYING)
        session.pause("duplex", true)
        session.pause("duplex", false)
        assertFalse(session.focusGained())
        assertTrue(session.finish("duplex", "Paused"))
        assertEquals(SessionPhase.PAUSED, session.view.phase)
        assertFalse(session.resumeOnFocus)
        assertTrue(session.stopping("duplex"))
        assertTrue(session.finish("duplex", "Expired"))
        assertFalse(session.focusGained())

        session.begin("next", "host")
        session.update("next", SessionPhase.PLAYING)
        session.pause("next", true)
        assertTrue(session.finish("next", "Failed", failed = true))
        assertFalse(session.focusGained())
        assertNull(session.token)
    }

    @Test fun restoringAHeadsetKeepsTheSessionOwnedAndStopRejectsLateSuccess() {
        val session = SessionLifecycle()
        assertTrue(session.begin("headset", "host"))
        assertTrue(session.update("headset", SessionPhase.ROUTE_RECOVERING))
        assertTrue(session.view.active)
        assertFalse(session.begin("replacement", "other host"))
        assertTrue(session.stopping("headset"))
        assertFalse(session.update("headset", SessionPhase.PLAYING, message = "late route acknowledgment"))
        assertTrue(session.finish("headset", "Stopped."))
        assertEquals(SessionPhase.ENDED, session.view.phase)
        assertNull(session.token)
    }

    @Test fun finalCopyReportIsRetainedAfterStopAndRejectsAnOldWorker() {
        val session = SessionLifecycle()
        session.begin("first", "host"); session.update("first", diagnostics = "periodic")
        session.stopping("first")
        assertFalse(session.update("first", diagnostics = "late periodic"))
        assertTrue(session.finish("first", "stopped", diagnostics = "terminal: peer_failed"))
        assertEquals("terminal: peer_failed", session.view.diagnostics)
        session.begin("second", "host")
        assertFalse(session.finish("first", "old", diagnostics = "old terminal"))
        assertNull(session.view.diagnostics)
    }

    @Test fun playDuringManualPauseWaitsForCleanupAndCannotOverlapPeers() {
        val session = SessionLifecycle()
        session.begin("s", "host"); session.update("s", SessionPhase.PLAYING)
        session.pause("s", false)
        assertFalse(session.queuePlay("stale"))
        assertTrue(session.queuePlay("s"))
        assertTrue(session.queuePlay("s"))
        assertFalse(session.begin("overlap", "host"))
        session.finish("s", "closed")
        assertEquals(SessionPhase.PAUSED, session.view.phase)
        assertTrue(session.playAfterPause)
        assertTrue(session.begin("next", "host"))
        assertFalse(session.playAfterPause)
        assertFalse(session.finish("s", "late callback"))
    }

    @Test fun pauseStopAndFailureEachCancelQueuedPlay() {
        for (cancel in listOf("pause", "stop", "failure")) {
            val session = SessionLifecycle()
            session.begin("s", "host"); session.pause("s", false); session.queuePlay("s")
            when (cancel) {
                "pause" -> session.pause("s", false)
                "stop" -> session.stopping("s")
                else -> session.finish("s", "failed", failed = true)
            }
            assertFalse("Queued Play survived $cancel", session.playAfterPause)
            assertFalse(session.focusGained())
        }
    }

    @Test fun explicitPlayDuringInterruptedCleanupReplacesAutomaticIntent() {
        val session = SessionLifecycle()
        session.begin("s", "host"); session.pause("s", true); session.focusGained()
        session.queuePlay("s")
        assertFalse(session.resumeOnFocus)
        assertFalse(session.focusReturned)
        session.finish("s", "closed")
        assertEquals(SessionPhase.PAUSED, session.view.phase)
        assertTrue(session.playAfterPause)
    }

    @Test fun mediaCardShowsPlayBeforeCleanupAndKeepsTransientIntentCancellable() {
        for (phase in listOf(SessionPhase.PAUSING, SessionPhase.PAUSED)) {
            assertEquals(MediaPresentation(true, false, false, false), MediaPresentation.of(phase, false, false))
        }
        assertEquals(MediaPresentation(true, true, true, false), MediaPresentation.of(SessionPhase.PAUSING, false, true))
        for (phase in listOf(SessionPhase.PAUSING, SessionPhase.INTERRUPTED)) {
            assertEquals(MediaPresentation(true, true, false, true), MediaPresentation.of(phase, true, false))
        }
        for (phase in listOf(SessionPhase.IDLE, SessionPhase.STOPPING, SessionPhase.ENDED)) {
            assertEquals(MediaPresentation(false, false, false, false), MediaPresentation.of(phase, false, false))
        }
    }

    @Test fun preciseReasonsFallBackForPreviouslyReleasedHosts() {
        assertEquals("user_stop", StopReason.PAUSE.wireFor(1))
        assertEquals("user_pause", StopReason.PAUSE.wireFor(2))
        for (reason in listOf(StopReason.FOCUS_TRANSIENT, StopReason.FOCUS_PERMANENT)) {
            assertEquals("focus_loss", reason.wireFor(1))
            assertEquals(reason.wire, reason.wireFor(2))
        }
        assertEquals("output_lost", StopReason.OUTPUT.wireFor(1))
    }

    @Test fun transientGainDuringTeardownWaitsForNativeRelease() {
        val session = SessionLifecycle()
        session.begin("first", "host"); session.update("first", SessionPhase.PLAYING, diagnostics = "report")
        assertTrue(session.pause("first", true))
        assertFalse(session.focusGained())
        assertTrue(session.focusReturned)
        assertFalse(session.begin("too soon", "host"))
        assertFalse(session.update("first", SessionPhase.PLAYING))
        assertTrue(session.finish("first", "paused"))
        assertEquals(SessionPhase.INTERRUPTED, session.view.phase)
        assertEquals("report", session.view.diagnostics)
        assertTrue(session.focusReturned)
        assertTrue(session.begin("second", "host"))
        assertFalse(session.resumeOnFocus)
        assertFalse(session.finish("first", "late end"))
    }

    @Test fun anotherLossCancelsGainReceivedDuringTeardown() {
        val session = SessionLifecycle()
        session.begin("s", "host"); session.pause("s", true); session.focusGained()
        session.pause("s", true); session.finish("s", "paused")
        assertFalse(session.focusReturned)
        assertTrue(session.resumeOnFocus)
        assertTrue(session.focusGained())
    }

    @Test fun terminalWorkerFailureWinsOverAConcurrentPauseAndQueuedGain() {
        val session = SessionLifecycle()
        session.begin("s", "host"); session.pause("s", true); session.focusGained()
        session.finish("s", "Authentication failed", failed = true)
        assertEquals(SessionPhase.ENDED, session.view.phase)
        assertEquals("Authentication failed", session.view.message)
        assertFalse(session.focusGained())
        assertNull(session.token)
    }

    @Test fun explicitPauseAndPermanentLossCancelAutomaticResume() {
        for (gainBeforePause in listOf(false, true)) {
            val session = SessionLifecycle()
            session.begin("s", "host"); session.pause("s", true)
            if (gainBeforePause) session.focusGained()
            assertTrue(session.pause("s", false))
            assertFalse(session.focusGained())
            // A delayed transient-loss callback cannot re-arm it.
            session.pause("s", true)
            session.finish("s", "paused")
            assertEquals(SessionPhase.PAUSED, session.view.phase)
            assertFalse(session.resumeOnFocus)
            assertFalse(session.view.busy)
            assertTrue(session.view.retained)
        }
    }

    @Test fun timeoutOrKeepPausedReleasesTheInterruptionState() {
        val session = SessionLifecycle()
        session.begin("s", "host"); session.pause("s", true); session.finish("s", "paused")
        assertTrue(session.view.busy)
        session.pause("s", false)
        assertEquals(SessionPhase.PAUSED, session.view.phase)
        assertFalse(session.focusGained())
    }

    @Test fun stopOrOutputLossWinsAtEveryPauseStage() {
        for (complete in listOf(false, true)) {
            val session = SessionLifecycle()
            session.begin("s", "host"); session.pause("s", true)
            if (complete) session.finish("s", "paused")
            assertTrue(session.stopping("s"))
            assertFalse(session.focusGained())
            assertFalse(session.pause("s", true))
            session.finish("s", "stopped")
            assertEquals(SessionPhase.ENDED, session.view.phase)
            assertNull(session.token)
        }
    }

    @Test fun restoredPausedStateStaysSilentAndOldActionsCannotStopNewPlayback() {
        val session = SessionLifecycle()
        session.restorePause("paused")
        assertEquals(SessionPhase.PAUSED, session.view.phase)
        assertFalse(session.focusGained())
        assertFalse(session.update("paused", SessionPhase.PLAYING))
        session.begin("new", "host")
        assertFalse(session.stopping("paused"))
        session.restorePause("stale")
        assertEquals("new", session.token)
    }

    @Test fun stopCannotBeUndoneByLateWorkerCallbacks() {
        val session = SessionLifecycle()
        assertTrue(session.begin("first", "host"))
        assertFalse(session.begin("duplicate", "other"))
        assertTrue(session.update("first", SessionPhase.PLAYING, diagnostics = "last report"))
        assertTrue(session.stopping("first"))
        assertFalse(session.stopping("first"))
        assertFalse(session.update("first", SessionPhase.PLAYING, message = "late success"))
        assertEquals(SessionPhase.STOPPING, session.view.phase)
        assertTrue(session.finish("first", "Windows acknowledged Stop."))
        assertFalse(session.view.active)
        assertEquals("last report", session.view.diagnostics)
        assertNull(session.token)
    }

    @Test fun oldControlsAndCallbacksCannotAffectNextSession() {
        val session = SessionLifecycle()
        session.begin("old", "host"); session.finish("old", "ended")
        assertTrue(session.begin("new", "host"))
        assertFalse(session.stopping("old"))
        assertFalse(session.finish("old", "late end"))
        assertFalse(session.update("old", SessionPhase.PLAYING, diagnostics = "old report"))
        assertEquals(SessionPhase.CONNECTING, session.view.phase)
        assertNull(session.view.diagnostics)
    }

    @Test fun notifyPrecedesMediaDestructionAndFailureStillReleases() {
        val events = mutableListOf<String>()
        assertTrue(SessionShutdown.complete({ events.add("stop"); true }, { events.add("dispose") }))
        assertEquals(listOf("stop", "dispose"), events)
        events.clear()
        assertFalse(SessionShutdown.complete({ events.add("unreachable"); throw java.io.IOException() }, { events.add("dispose") }))
        assertEquals(listOf("unreachable", "dispose"), events)
    }
}
