package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class OfferAttemptTest {
    @Test fun stopBeforeOfferDoesNotContactWindows() {
        val attempt = OfferAttempt(true)
        assertFalse(attempt.needsCancellation(null))
        assertNull(attempt.header("/offer"))
    }

    @Test fun cancelledLostResponseUsesTheOriginalNonceAndReconnectUsesAnother() {
        val attempt = OfferAttempt(true)
        attempt.begin()
        val sent = requireNotNull(attempt.header("/offer"))
        assertEquals(32, java.util.Base64.getUrlDecoder().decode(sent).size)
        assertEquals(43, sent.length)
        attempt.begin() // An explicit busy retry is still this attempt.
        assertEquals(sent, attempt.header("/offer"))
        assertTrue(attempt.needsCancellation(null))
        assertEquals(sent, attempt.header("/cancel-offer"))
        val reconnect = OfferAttempt(true).also { it.begin() }
        assertNotEquals(sent, reconnect.header("/offer"))
        assertEquals(sent, attempt.header("/cancel-offer"))
    }

    @Test fun knownSessionsUseNormalStopAndNonceNeverEntersStatusOrAnswer() {
        val attempt = OfferAttempt(true).also { it.begin() }
        assertFalse(attempt.needsCancellation("session-token"))
        for (path in listOf("/stop", "/status", "/answer", "/recover-offer", "/pair"))
            assertNull(attempt.header(path))
    }

    @Test fun legacySingleUseHostDoesNotUseTheExtension() {
        val attempt = OfferAttempt(false).also { it.begin() }
        assertFalse(attempt.needsCancellation(null))
        assertNull(attempt.header("/offer"))
        assertNull(attempt.header("/cancel-offer"))
    }
}
