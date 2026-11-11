package com.maskarauder.micdrop

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class SessionStopRetryTest {
    @Test fun lostStopDuringRecoveryIsRetriedBeforeAnotherOfferAndOnlyOnceAcknowledged() {
        val retry = SessionStopRetry()
        val old = retry.remember("host-and-phone", "old-session", "user_stop", 1000)
        val events = mutableListOf<String>()
        fun connect(now: Long, reachable: Boolean) {
            val previous = retry.beforeOffer("host-and-phone", now) { stop ->
                assertSame(old, stop)
                events.add("stop:${stop.token}:${stop.reason}")
                if (!reachable) throw IOException("network changing")
            }
            // Even Connect with an entered link must allow native release
            // after Stop; it need not have come from the saved Resume action.
            assertTrue(BusyOfferRetry(previous, now).allow(423, now + 1))
            events.add("offer")
        }
        assertThrows(IOException::class.java) { connect(2000, false) }
        assertFalse(old.acknowledged)
        assertEquals(listOf("stop:old-session:user_stop"), events)
        connect(4000, true)
        connect(4500, true) // Explicit busy response, never an ambiguous offer replay.
        assertEquals(listOf("stop:old-session:user_stop", "stop:old-session:user_stop", "offer", "offer"), events)
        retry.accepted("host-and-phone")
        assertFalse(retry.beforeOffer("host-and-phone", 5000) { fail("old Stop reached successor") })
    }

    @Test fun acknowledgedStopWaitsForNativeReleaseWithoutResendingIt() {
        val retry = SessionStopRetry()
        retry.acknowledge(retry.remember("host", "old-session", "user_pause", 1000))
        assertTrue(retry.beforeOffer("host", 1100) { fail("unnecessary Stop") })
    }

    @Test fun oldSessionGoneIsSafeButAuthorizationAndTransportFailuresBlockTheNewOffer() {
        for (status in listOf(401, 410)) {
            val retry = SessionStopRetry()
            val old = retry.remember("host", "old-session", "user_stop", 1000)
            assertTrue(retry.beforeOffer("host", 1500) { throw HttpFailure(status) })
            assertTrue(old.acknowledged)
        }
        for (status in listOf(400, 403, 404, 423, 429, 500, 503)) {
            val retry = SessionStopRetry()
            val old = retry.remember("host", "old-session", "user_stop", 1000)
            assertEquals(status, assertThrows(HttpFailure::class.java) {
                retry.beforeOffer("host", 1500) { throw HttpFailure(status) }
            }.status)
            assertFalse(old.acknowledged)
        }
    }

    @Test fun retryRemainsScopedExpiresAndCannotAcknowledgeAReplacement() {
        val retry = SessionStopRetry()
        val old = retry.remember("first-host-and-phone", "old-session", "user_stop", 1000)
        assertFalse(retry.beforeOffer("other-host-or-phone", 1500) { fail("credential sent to another destination") })
        retry.accepted("other-host-or-phone")
        assertTrue(retry.beforeOffer("first-host-and-phone", 2000) { assertSame(old, it) })
        val next = retry.remember("first-host-and-phone", "next-session", "user_stop", 3000)
        retry.acknowledge(old)
        assertFalse(next.acknowledged)
        assertFalse(retry.beforeOffer("first-host-and-phone", 123000) { fail("expired credential reused") })
        assertFalse(retry.beforeOffer("first-host-and-phone", 123001) { fail("expired record retained") })
    }

    @Test fun stoppingTheRetryPreservesCleanupForTheNextConnect() {
        val retry = SessionStopRetry()
        val old = retry.remember("host", "old-session", "user_stop", 1000)
        assertThrows(InterruptedException::class.java) {
            retry.beforeOffer("host", 1500) { throw InterruptedException() }
        }
        assertFalse(old.acknowledged)
        assertTrue(retry.beforeOffer("host", 2000) { assertSame(old, it) })
    }
}
