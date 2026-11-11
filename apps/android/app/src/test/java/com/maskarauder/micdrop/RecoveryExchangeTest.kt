package com.maskarauder.micdrop

import java.io.IOException
import java.net.SocketTimeoutException
import org.junit.Assert.*
import org.junit.Test

class RecoveryExchangeTest {
    @Test fun delayedCellularSignalingRestartsBeforePollingAndConfirmsBeforeDeadline() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0)
        recovery.networkChanged(1000)
        // Model the device trace: signaling usable only ~20 seconds after loss,
        // followed by a 5-second host gather and 2-second answer exchange.
        var now = 21000L
        val order = mutableListOf<String>()
        var trickleActive = true
        val connected = recovery.exchangeStatus({ now }, {
            order += "retire-trickle"; trickleActive = false
        }, {
            order += "restart"; assertTrue(recovery.pending)
            now += 7000; recovery.answer = "same peer answer"; recovery.accepted(now)
        }) {
            order += "status"; assertFalse(trickleActive); assertFalse(recovery.pending)
            now += 1800; true
        }
        assertEquals(listOf("retire-trickle", "restart", "status"), order)
        assertEquals(29800L, now)
        assertTrue(recovery.observe(connected, now))
        assertFalse(recovery.active)
        assertEquals(1L, recovery.generation)
    }

    @Test fun lostAnswerAcknowledgmentRetriesTheSameGenerationBeforeAnyStatus() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.networkChanged(1000)
        var now = 2000L
        var begun = 0; var restores = 0; var polls = 0
        fun exchange(fail: Boolean) = recovery.exchangeStatus({ now }, { begun++ }, {
            restores++
            if (recovery.answer == null) recovery.answer = "prepared once"
            assertEquals("prepared once", recovery.answer)
            now += 8000
            if (fail) throw IOException("lost reply")
            recovery.accepted(now)
        }) { polls++; "connected" }
        assertThrows(IOException::class.java) { exchange(true) }
        assertEquals(0, polls); assertEquals(1L, recovery.generation)
        assertEquals("connected", exchange(false))
        assertEquals(1, begun); assertEquals(2, restores); assertEquals(1, polls)
        assertEquals(13000L, recovery.remaining(now))
    }

    @Test fun expiryDuringRestoreCannotAuthorizeAnotherPollOrExtendRecovery() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.networkChanged(1000)
        var now = 29000L; var polls = 0
        assertThrows(SocketTimeoutException::class.java) {
            recovery.exchangeStatus({ now }, {}, { now = 31000; recovery.accepted(now) }) { polls++ }
        }
        assertEquals(0, polls); assertTrue(recovery.expired(now))
        assertFalse(recovery.observe(true, now))
        assertThrows(SocketTimeoutException::class.java) {
            recovery.exchangeStatus({ now }, { fail("new generation after deadline") }, {}) { polls++ }
        }
    }

    @Test fun stopAndFatalRecoveryErrorsPropagateWithoutPollingOrReplacingSession() {
        for (error in listOf(InterruptedException(), SecurityException("revoked"))) {
            val recovery = LanRecovery(true)
            recovery.observe(true, 0); recovery.networkChanged(1000)
            val caught = assertThrows(error.javaClass) {
                recovery.exchangeStatus({ 2000 }, {}, { throw error }) { fail("polled after stop/revocation") }
            }
            assertSame(error, caught); assertEquals(1L, recovery.generation)
        }
    }

    @Test fun slowAudioSuspensionCannotStartARestartPastTheDeadline() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.networkChanged(1000)
        var now = 30000L
        assertThrows(SocketTimeoutException::class.java) {
            recovery.exchangeStatus({ now }, { now = 31000 }, { fail("late restart") }) { fail("late status") }
        }
        assertEquals(0L, recovery.generation)
    }

    @Test fun healthyStartupAndLegacyPeersKeepOrdinaryPolling() {
        for (supported in listOf(false, true)) for (established in listOf(false, true)) {
            val recovery = LanRecovery(supported)
            if (established) recovery.observe(true, 0)
            assertEquals("status", recovery.exchangeStatus({ 1000 }, { fail("unexpected restart") },
                { fail("unexpected restore") }) { "status" })
            assertEquals(0L, recovery.generation)
        }
    }
}
