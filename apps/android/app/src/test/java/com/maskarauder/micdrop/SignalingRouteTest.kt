package com.maskarauder.micdrop

import java.io.IOException
import javax.net.ssl.SSLException
import org.junit.Assert.*
import org.junit.Test

class SignalingRouteTest {
    @Test fun freshConnectUsesLanFirstWithoutContactingRendezvous() {
        val route = SignalingRoute(true)
        val calls = mutableListOf<String>()
        route.initial { calls += "probe"; true }
        assertEquals(1, route.exchange("/offer", { calls += "lan"; 1 },
            { fail("rendezvous before LAN"); 0 }, { fail("second probe"); false }, { false }))
        assertEquals(listOf("probe", "lan"), calls)
        assertFalse(route.needsRemoteIce(false))
        route.upgrade { fail("already local"); false }
        route.recover()
        route.exchange("/recover-offer", { fail("LAN before rendezvous"); 0 },
            { calls += "remote"; 1 }, { false }, { false })
        assertEquals(listOf("probe", "lan", "remote"), calls)
    }

    @Test fun initialLanUnavailableThenRendezvousUnavailableDoesNotLoop() {
        val route = SignalingRoute(true)
        route.initial { false }
        assertThrows(SignalingRoutesUnavailable::class.java) {
            route.exchange("/offer", { fail("unavailable LAN retried"); 0 }, { throw IOException() },
                { fail("repeated initial probe"); false }, { false })
        }
    }

    @Test fun ambiguousInitialLanOfferNeedsCancellationOnRendezvous() {
        val route = SignalingRoute(true)
        route.initial { true }
        assertThrows(OfferFallbackRequired::class.java) {
            route.exchange("/offer", { throw IOException() }, { fail("offer replayed without cancellation"); 0 },
                { false }, { false })
        }
        assertFalse(route.direct)
        assertTrue(route.needsRemoteIce(false))
    }

    @Test fun rendezvousFirstThenOneHealthyProbeAndRendezvousFirstAfterHandoff() {
        val route = SignalingRoute(true)
        val calls = mutableListOf<String>()
        fun request() = route.exchange("/status", { calls += "lan"; 1 },
            { calls += "remote"; 1 }, { calls += "probe"; true }, { false })
        request()
        assertEquals(listOf("remote"), calls)
        assertTrue(route.needsRemoteIce(false))
        route.upgrade { calls += "probe"; true }
        request()
        route.upgrade { fail("repeated healthy probe"); false }
        assertEquals(listOf("remote", "probe", "lan"), calls)
        assertFalse(route.needsRemoteIce(false))
        assertTrue(route.needsRemoteIce(true)) // Forced relay remains explicit.
        route.recover(); request()
        assertEquals("remote", calls.last())
        assertTrue(route.needsRemoteIce(false))
        route.upgrade { calls += "probe"; true }
        assertEquals("direct LAN", route.label)
    }

    @Test fun failedRendezvousGetsOneVerifiedLanFallbackThenStops() {
        for (reachable in listOf(false, true)) {
            val route = SignalingRoute(true)
            val calls = mutableListOf<String>()
            assertThrows(SignalingRoutesUnavailable::class.java) {
                route.exchange("/status", { calls += "lan"; throw IOException() },
                    { calls += "remote"; throw IOException() }, { calls += "probe"; reachable }, { false })
            }
            assertEquals(if (reachable) listOf("remote", "probe", "lan") else listOf("remote", "probe"), calls)
        }
        assertFalse(ConnectionFailure.retryableStatus(SignalingRoutesUnavailable()))
    }

    @Test fun lostLanTriesRendezvousBeforeCheckingLanAgain() {
        val route = SignalingRoute(true)
        route.upgrade { true }
        val calls = mutableListOf<String>()
        assertThrows(SignalingRoutesUnavailable::class.java) {
            route.exchange("/recover-offer", { calls += "lan"; throw IOException() },
                { calls += "remote"; throw IOException() }, { calls += "probe"; false }, { false })
        }
        assertEquals(listOf("lan", "remote", "probe"), calls)
    }

    @Test fun ambiguousOfferRequiresCancellationButUnsentOfferCanFallBack() {
        val route = SignalingRoute(true)
        var offers = 0
        assertThrows(OfferFallbackRequired::class.java) {
            route.exchange("/offer", { offers++; 1 }, { throw IOException() }, { true }, { false })
        }
        assertEquals(0, offers)
        assertTrue(route.direct)
        val fresh = SignalingRoute(true)
        assertEquals(1, fresh.exchange("/offer", { offers++; 1 },
            { throw SignalingRequestNotSent(IOException()) }, { true }, { false }))
        assertEquals(1, offers)
    }

    @Test fun authorizationTlsCancellationAndAmbiguousAnswerCannotBeReplayed() {
        for (error in listOf(HttpFailure(403), HttpFailure(500), HttpFailure(503), SSLException("test"), IOException())) {
            val route = SignalingRoute(true)
            assertThrows(IOException::class.java) {
                route.exchange("/status", { fail("unauthorized fallback"); 0 }, { throw error },
                    { fail("unexpected probe"); false }, { error !is HttpFailure && error !is SSLException })
            }
        }
        assertThrows(IOException::class.java) {
            SignalingRoute(true).exchange("/answer", { fail("ambiguous answer replay"); 0 },
                { throw IOException() }, { fail("unexpected probe"); false }, { false })
        }
    }

    @Test fun plainLanNeverUsesRendezvousOrProbes() {
        val route = SignalingRoute(false)
        route.recover(); route.upgrade { fail("LAN probe"); false }
        assertEquals(1, route.exchange("/offer", { 1 }, { fail("rendezvous"); 0 }, { false }, { false }))
        assertFalse(route.needsRemoteIce(true))
    }

    @Test fun onlyAcknowledgedCancellationCanReplaceAnOfferNonce() {
        val attempt = OfferAttempt(true).also { it.begin() }
        val old = attempt.header("/offer")
        assertThrows(IllegalStateException::class.java) { attempt.cancelledForFallback(false) }
        assertEquals(old, attempt.header("/cancel-offer"))
        attempt.cancelledForFallback(true)
        assertFalse(attempt.needsCancellation(null))
        attempt.begin()
        assertNotEquals(old, attempt.header("/offer"))
        assertEquals(attempt.header("/offer"), attempt.header("/cancel-offer"))
    }
}
