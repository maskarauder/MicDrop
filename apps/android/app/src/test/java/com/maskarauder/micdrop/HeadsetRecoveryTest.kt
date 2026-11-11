package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class HeadsetRecoveryTest {
    @Test fun customWindowKeepsOneDeadlineAndStopRejectsLateRestoration() {
        val recovery = HeadsetRecovery(60500)
        recovery.request(1000)
        val first = requireNotNull(recovery.current())
        recovery.request(60000)
        assertFalse(recovery.complete(first, 60001))
        assertEquals(1L, recovery.remaining(61499))
        assertEquals(0L, recovery.remaining(61500))
        assertFalse(recovery.complete(requireNotNull(recovery.current()), 61500))
        assertTrue(recovery.text().contains("Window: 60500 ms"))
        recovery.cancel()
        assertFalse(recovery.request(62000))
    }

    @Test fun furtherRouteChangesInvalidateAnAcknowledgmentWithoutRenewingTheDeadline() {
        val recovery = HeadsetRecovery()
        assertTrue(recovery.request(1000))
        val first = requireNotNull(recovery.current())
        assertEquals(15000L, recovery.remaining(6000)) // Still eligible after the old five-second cutoff.
        assertTrue(recovery.request(19000))
        val current = requireNotNull(recovery.current())
        assertEquals(first.episode, current.episode)
        assertFalse(recovery.complete(first, 19001))
        assertEquals(1999L, recovery.remaining(19001))
        assertTrue(recovery.complete(current, 20999))
        assertFalse(recovery.pending())
        assertFalse(recovery.complete(current, 20999))
        assertTrue(recovery.text().contains("Completed: 1"))
    }

    @Test fun callbackStormsAndSlowAcknowledgmentsCannotKeepRecoveryAliveIndefinitely() {
        val recovery = HeadsetRecovery()
        recovery.request(1000)
        for (time in 1001L..21000L step 100) recovery.request(time)
        val last = requireNotNull(recovery.current())
        assertEquals(0L, recovery.remaining(21000))
        assertFalse(recovery.complete(last, 21000))
        assertFalse(recovery.reselectionDue(21000))
        assertFalse(recovery.profileRequestDue(21000))
        assertTrue(recovery.pending()) // The owning worker must end this episode.
    }

    @Test fun reselectionRequestsAreBoundedAndANewEpisodeGetsItsOwnBudget() {
        val recovery = HeadsetRecovery()
        recovery.request(1000)
        assertTrue(recovery.reselectionDue(1000))
        assertFalse(recovery.reselectionDue(1499))
        assertTrue(recovery.reselectionDue(1500))
        assertTrue(recovery.reselectionDue(2000))
        assertFalse(recovery.reselectionDue(3000))
        assertFalse(recovery.reselectionDue(20000)) // More time does not reset the retry budget.
        val first = requireNotNull(recovery.current())
        assertTrue(recovery.complete(first, 20000))
        recovery.request(21000)
        val second = requireNotNull(recovery.current())
        assertNotEquals(first.episode, second.episode)
        assertFalse(recovery.complete(first, 21001))
        assertTrue(recovery.reselectionDue(21001))
        assertTrue(recovery.complete(second, 21002))
        assertTrue(recovery.text().contains("Completed: 2"))
        assertTrue(recovery.text().contains("Reselection requests: 4"))
    }

    @Test fun waitingForAnEndpointPreservesTheBudgetButCannotRenewTheWindow() {
        val recovery = HeadsetRecovery()
        recovery.request(1000)
        for (time in 1000L..19000L step 100) assertFalse(recovery.reselectionDue(time, false))
        assertTrue(recovery.text().contains("Reselection requests: 0"))
        assertEquals(1000L, recovery.remaining(20000))
        assertTrue(recovery.reselectionDue(20000, true))
        recovery.request(20500) // Endpoint callbacks cannot grant another twenty seconds.
        assertTrue(recovery.reselectionDue(20500, true))
        assertFalse(recovery.reselectionDue(21000, true))
        assertFalse(recovery.complete(requireNotNull(recovery.current()), 21000))
        assertTrue(recovery.text().contains("Reselection requests: 2"))
    }

    @Test fun stopWinsWhenAnAcknowledgmentIsAlreadyInFlight() {
        val recovery = HeadsetRecovery()
        recovery.request(1000)
        val ticket = requireNotNull(recovery.current())
        val waiting = CountDownLatch(1)
        val acknowledgment = CountDownLatch(1)
        val resumed = AtomicBoolean(true)
        val worker = Thread {
            waiting.countDown()
            if (acknowledgment.await(2, TimeUnit.SECONDS)) resumed.set(recovery.complete(ticket, 16001))
        }
        worker.start()
        try {
            assertTrue(waiting.await(2, TimeUnit.SECONDS))
            recovery.cancel()
            acknowledgment.countDown()
            worker.join(2000)
            assertFalse(worker.isAlive)
            assertFalse(resumed.get())
            assertFalse(recovery.request(16002))
            assertFalse(recovery.pending())
            assertTrue(recovery.text().contains("Completed: 0"))
            assertTrue(recovery.text().contains("recovery: stopped"))
        } finally { acknowledgment.countDown(); worker.interrupt(); worker.join(2000) }
    }

    @Test fun releasingAnUnavailableRouteIsOncePerEpisodeAndKeepsTheDeadline() {
        val recovery = HeadsetRecovery()
        recovery.request(1000)
        assertFalse(recovery.routeReleaseDue(1000, true))
        assertTrue(recovery.routeReleaseDue(1001, false))
        recovery.observe("selected audio profile unavailable")
        for (time in 1002L..20000L step 100) {
            recovery.request(time)
            assertFalse(recovery.routeReleaseDue(time, false))
        }
        assertEquals(1000L, recovery.remaining(20000))
        assertTrue(recovery.text().contains("Route releases: 1"))
        assertTrue(recovery.text().contains("Reselection requests: 0"))
        assertTrue(recovery.text().contains("Last check: selected audio profile unavailable"))
        assertTrue(recovery.reselectionDue(20000, true))
        assertTrue(recovery.complete(requireNotNull(recovery.current()), 20001))
        recovery.request(21000)
        assertTrue(recovery.routeReleaseDue(21001, false))
        assertTrue(recovery.text().contains("Route releases: 2"))
    }

    @Test fun stopOrExpiryPreventsARouteReleaseAndPreservesTheLastCheck() {
        val stopped = HeadsetRecovery()
        stopped.request(1000); stopped.observe("original headset identity unavailable")
        stopped.cancel()
        assertFalse(stopped.routeReleaseDue(1001, false))
        stopped.observe("late callback")
        assertTrue(stopped.text().contains("Last check: original headset identity unavailable"))
        val expired = HeadsetRecovery()
        expired.request(1000)
        assertFalse(expired.routeReleaseDue(21000, false))
    }
}
