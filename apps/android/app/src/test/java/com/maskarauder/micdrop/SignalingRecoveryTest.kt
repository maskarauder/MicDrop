package com.maskarauder.micdrop

import java.io.IOException
import java.net.SocketTimeoutException
import java.security.cert.CertificateExpiredException
import java.util.concurrent.ExecutionException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.*
import org.junit.Test

class SignalingRecoveryTest {
    @Test fun fadedWifiWithoutCallbackCanRecoverTheSameSessionOnRendezvous() {
        val route = SignalingRoute(true).apply { initial { true }; upgrade { false } }
        val recovery = LanRecovery(true).apply { observe(true, 0) }
        val calls = mutableListOf<String>()
        var now = 100L
        val attemptedAt = now
        val error = assertThrows(SignalingRoutesUnavailable::class.java) {
            route.exchange("/status", { calls += "lan"; now += 2000; throw SocketTimeoutException() },
                { calls += "rendezvous"; now += 8000; throw SocketTimeoutException() },
                { calls += "probe"; now += 1500; false }, { false })
        }
        assertTrue(recovery.signalingFailed(error, attemptedAt))
        assertEquals(18_500L, recovery.remaining(now))
        route.recover()
        val result = recovery.exchangeStatus({ now }, { route.recover() }, {
            route.exchange("/recover-offer", { fail("LAN before rendezvous"); 0 },
                { calls += "recover"; 1 }, { false }, { false })
            recovery.answer = "same session answer"
            recovery.accepted(now)
        }, { "connected" })
        assertEquals("connected", result)
        assertEquals(listOf("lan", "rendezvous", "probe", "recover"), calls)
        assertEquals(1L, recovery.generation)
        assertTrue(recovery.observe(true, now))
        assertFalse(recovery.active)
    }

    @Test fun repeatedRouteFailuresAndLateCallbackCannotExtendTheDeadline() {
        val recovery = LanRecovery(true).apply { observe(true, 0) }
        assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 100))
        recovery.begin(1100); recovery.answer = "prepared"
        assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 15000))
        recovery.networkChanged(25000)
        assertEquals(5100L, recovery.remaining(25000))
        assertEquals(1L, recovery.generation)
        assertEquals("prepared", recovery.answer)
        assertThrows(SocketTimeoutException::class.java) {
            recovery.exchangeStatus({ 30100 }, { fail("new offer after deadline") },
                { fail("answer after deadline") }, { fail("status after deadline") })
        }
        assertFalse(recovery.observe(true, 30100))
    }

    @Test fun failedLanFallbackRetriesRendezvousWithThePreparedAnswer() {
        val route = SignalingRoute(true).apply { recover() }
        val recovery = LanRecovery(true).apply {
            observe(true, 0); networkChanged(100); begin(100); answer = "unchanged answer"
        }
        val calls = mutableListOf<String>()
        val error = assertThrows(SignalingRoutesUnavailable::class.java) {
            recovery.exchangeStatus({ 200 }, { fail("new generation") }, {
                route.exchange("/recover-answer", { calls += "lan"; throw IOException() },
                    { calls += "rendezvous"; throw IOException() }, { true }, { false })
            }, { fail("unacknowledged answer") })
        }
        assertTrue(route.direct)
        assertTrue(recovery.signalingFailed(error, 200))
        route.recover()
        recovery.exchangeStatus({ 700 }, { fail("new generation") }, {
            assertEquals("unchanged answer", recovery.answer)
            route.exchange("/recover-answer", { fail("sticky LAN fallback"); 0 },
                { calls += "retry rendezvous"; 1 }, { false }, { false })
            recovery.accepted(700)
        }, { calls += "confirm" })
        assertEquals(listOf("rendezvous", "lan", "retry rendezvous", "confirm"), calls)
        assertEquals(1L, recovery.generation)
    }

    @Test fun startupStopAndSecurityFailuresNeverEnterThisRecovery() {
        val startup = LanRecovery(true)
        assertFalse(startup.signalingFailed(SignalingRoutesUnavailable(), 0))
        assertFalse(startup.active)
        val recovery = LanRecovery(true).apply { observe(true, 0) }
        for (error in listOf(SignalingRoutesUnavailable(), IOException())) {
            assertFalse(recovery.signalingFailed(error, 1, stopped = true))
        }
        for (error in listOf(HttpFailure(401), HttpFailure(403), HttpFailure(409), HttpFailure(410),
            HttpFailure(423), SSLHandshakeException("private"), ExecutionException(CertificateExpiredException()),
            OfferFallbackRequired(), IOException(InterruptedException()))) {
            assertFalse(recovery.signalingFailed(error, 1))
        }
        assertFalse(recovery.active)
        assertTrue(recovery.signalingFailed(ExecutionException(SignalingRoutesUnavailable()), 1))
    }

    @Test fun ordinaryCellularControlFailureDoesNotRequireAnIceDisconnect() {
        val recovery = LanRecovery(true).apply { observe(true, 0) }
        assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 100))
        assertTrue(recovery.active)
        assertTrue(recovery.restartDue(1100))
        // No successful control response: the last connected ICE snapshot alone
        // never invokes observe(true), so retries cannot silently reset the clock.
        repeat(5) { assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 1000L + it * 4000)) }
        assertEquals(10_100L, recovery.remaining(20000))
    }
}
