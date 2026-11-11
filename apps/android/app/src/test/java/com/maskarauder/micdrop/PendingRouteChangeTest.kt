package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class PendingRouteChangeTest {
    @Test fun aReplacementRequiresTheOldWorkerAndCannotConsumeAnotherGeneration() {
        val change = PendingRouteChange<MicrophoneSelection>()
        val target = MicrophoneSelection(MicrophoneKind.SCO, 40)
        assertTrue(change.begin("old", target, 1000))
        assertFalse(change.begin("other", MicrophoneSelection(), 1001))
        assertNull(change.take("other", 2000))
        assertEquals(target, change.take("old", 2000))
        assertNull(change.take("old", 2001))
    }

    @Test fun stopFocusCancellationAndDelayedCleanupCannotStartAReplacement() {
        val change = PendingRouteChange<String>(20000)
        change.begin("old", "target", 1000)
        change.cancel()
        assertNull(change.take("old", 1001))
        assertTrue(change.begin("new", "next", 2000))
        assertNull(change.take("old", 2001))
        assertFalse(change.expired(21999))
        assertTrue(change.expired(22000))
        assertNull(change.take("new", 3600000))
    }

    @Test fun stopAndOldCallbacksCannotReviveASwitchedLifecycle() {
        val life = SessionLifecycle()
        life.begin("old", "synthetic host")
        life.update("old", phase = SessionPhase.PLAYING)
        assertTrue(life.switchRoute("old"))
        assertFalse(life.switchRoute("old"))
        assertFalse(life.switchRoute("different"))
        assertTrue(life.view.busy)
        assertTrue(MediaPresentation.of(life.view.phase, false, false).buffering)
        assertTrue(life.stopping("old"))
        assertFalse(life.switchRoute("old"))
        assertFalse(life.update("old", phase = SessionPhase.PLAYING))
        assertTrue(life.finish("old", "Stopped"))
        assertTrue(life.begin("new", "synthetic host"))
        assertFalse(life.finish("old", "old completion"))
        assertFalse(life.update("old", phase = SessionPhase.PLAYING))
    }

    @Test fun aPreviousNotificationCanOnlyStopOrMuteItsOwnInFlightReplacement() {
        // A new worker may reach network/headset recovery before its first
        // Playing callback clears the replacement's notification scope.
        for (phase in listOf(SessionPhase.SWITCHING, SessionPhase.CONNECTING,
                SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)) {
            assertTrue(RouteActionScope.accepts("new", "old", "old", phase, true))
            assertFalse(RouteActionScope.accepts("new", "old", "old", phase, false))
            assertFalse(RouteActionScope.accepts("new", "unrelated", "old", phase, true))
        }
        assertFalse(RouteActionScope.accepts("new", "old", "old", SessionPhase.PLAYING, true))
        assertFalse(RouteActionScope.accepts("new", "old", null, SessionPhase.CONNECTING, true))
        assertFalse(RouteActionScope.accepts(null, "old", "old", SessionPhase.CONNECTING, true))
        assertTrue(RouteActionScope.accepts("new", "new", null, SessionPhase.PLAYING, false))
    }
}
