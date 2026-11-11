package com.maskarauder.micdrop

import java.io.IOException
import javax.net.ssl.SSLException
import org.junit.Assert.*
import org.junit.Test

class SignalingHandoffTest {
    @Test fun cancelledLanHeartbeatDoesNotSpendRendezvousAttemptBetweenNetworkCallbacks() {
        val route = SignalingRoute(true).apply { initial { true }; upgrade { false } }
        val handoff = NetworkHandoff().apply { arm() }
        val recovery = LanRecovery(true).apply { observe(true, 0) }
        val calls = mutableListOf<String>()
        val error = assertThrows(SignalingNetworkChanged::class.java) {
            route.exchange("/status", {
                calls += "lan"; handoff.changed(100); throw SignalingStreamEnded()
            }, {
                // Previously, the mobile-available callback cancelled this
                // fallback and made a normal handoff terminal in under 300 ms.
                calls += "remote"; handoff.changed(234); throw IOException()
            }, { calls += "probe"; false }, { false }, handoff::waiting)
        }
        assertTrue(ConnectionFailure.retryableStatus(error))
        assertEquals(listOf("lan"), calls)
        recovery.networkChanged(100)
        handoff.changed(234)
        assertFalse(handoff.take(533)); assertTrue(handoff.take(534))
        route.recover()
        val result = recovery.exchangeStatus({ 534 }, {}, {
            route.exchange("/recover-offer", { fail("LAN before rendezvous"); 0 },
                { calls += "remote recovery"; 1 }, { fail("unneeded probe"); false }, { false }, handoff::waiting)
            recovery.answer = "prepared answer"; recovery.accepted(534)
        }, { "connected" })
        assertEquals("connected", result)
        assertEquals(listOf("lan", "remote recovery"), calls)
        assertEquals(1L, recovery.generation)
        assertTrue(recovery.observe(true, 600))
    }

    @Test fun unsettledNetworkDefersOnlyEstablishedSessionOperations() {
        val handoff = NetworkHandoff().apply { arm(); changed(100) }
        for (path in listOf("/status", "/microphone", "/recover-offer", "/recover-answer")) {
            assertThrows(SignalingNetworkChanged::class.java) {
                SignalingRoute(true).exchange(path, { fail("LAN during handoff"); 0 },
                    { fail("rendezvous during handoff"); 0 }, { fail("probe during handoff"); false },
                    { false }, handoff::waiting)
            }
        }
        for (path in listOf("/stop", "/cancel-offer")) {
            val route = SignalingRoute(true).apply { initial { true }; upgrade { false } }
            assertEquals(1, route.exchange(path, { throw IOException() }, { 1 }, { false }, { false }, handoff::waiting))
        }
        assertEquals(1, SignalingRoute(false).exchange("/status", { 1 }, { fail(); 0 },
            { false }, { false }, handoff::waiting))
        val initial = SignalingRoute(true).apply { initial { true } }
        assertThrows(OfferFallbackRequired::class.java) {
            initial.exchange("/offer", { throw IOException() }, { fail("offer replay"); 0 },
                { false }, { false }, handoff::waiting)
        }
        assertThrows(IOException::class.java) {
            initial.exchange("/answer", { fail("answer replay"); 0 }, { throw IOException() },
                { fail("answer probe"); false }, { false }, handoff::waiting)
        }
    }

    @Test fun interruptedRendezvousPreservesPendingAnswerAndOriginalDeadline() {
        val route = SignalingRoute(true).apply { recover() }
        val handoff = NetworkHandoff().apply { arm() }
        val recovery = LanRecovery(true).apply {
            observe(true, 0); networkChanged(100); begin(100); answer = "same answer"
        }
        assertThrows(SignalingNetworkChanged::class.java) {
            recovery.exchangeStatus({ 200 }, { fail("new generation") }, {
                route.exchange("/recover-answer", { fail("LAN replay"); 0 }, {
                    handoff.changed(200); throw SignalingRequestNotSent(IOException())
                }, { fail("probe during handoff"); false }, { false }, handoff::waiting)
            }, { fail("confirmation before answer"); 0 })
        }
        assertTrue(handoff.take(500)); route.recover(); recovery.networkChanged(500)
        assertEquals("same answer", recovery.answer)
        assertEquals(1L, recovery.generation)
        assertEquals(29_600L, recovery.remaining(500))
        // No new callback: genuine failure of both routes is still terminal.
        assertThrows(SignalingRoutesUnavailable::class.java) {
            route.exchange("/recover-answer", { fail(); 0 }, { throw IOException() },
                { false }, { false }, handoff::waiting)
        }
        assertFalse(ConnectionFailure.retryableStatus(SignalingRoutesUnavailable()))
        assertTrue(recovery.expired(30_100))
    }

    @Test fun callbackDuringFallbackProbeOrRequestCannotExhaustTheNewNetwork() {
        for (duringProbe in listOf(true, false)) {
            val handoff = NetworkHandoff().apply { arm() }
            assertThrows(SignalingNetworkChanged::class.java) {
                SignalingRoute(true).exchange("/status", {
                    assertFalse(duringProbe); handoff.changed(100); throw IOException()
                }, { throw IOException() }, {
                    if (duringProbe) handoff.changed(100)
                    !duringProbe
                }, { false }, handoff::waiting)
            }
        }
    }

    @Test fun handoffCannotHideAuthenticatedRejectionTlsFailureOrStopCancellation() {
        for (failure in listOf(HttpFailure(403), HttpFailure(503), SSLException("test"), IOException())) {
            val handoff = NetworkHandoff().apply { arm() }
            var stopped = false
            val actual = assertThrows(IOException::class.java) {
                SignalingRoute(true).exchange("/status", { fail(); 0 }, {
                    handoff.changed(100)
                    stopped = failure !is HttpFailure && failure !is SSLException
                    throw failure
                }, { fail("unauthorized fallback"); false }, { stopped }, handoff::waiting)
            }
            assertSame(failure, actual)
        }
    }
}
