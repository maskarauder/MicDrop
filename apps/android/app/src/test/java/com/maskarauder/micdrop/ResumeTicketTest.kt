package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class ResumeTicketTest {
    @Test fun aControlCannotResumeAReplacedConnection() {
        val link = "micdrop://v2/original-opaque-credential"
        val ticket = ResumeTicket("random-action-id", ResumeTicket.fingerprint(link), true)
        assertTrue(ticket.matches("  $link\n"))
        assertFalse(ticket.matches("micdrop://v2/different-credential"))
        assertEquals(64, ticket.digest.length)
        assertFalse(ticket.digest.contains("credential"))
    }

    @Test fun onlyAnExplicitBusyRejectionCanBeRetriedForFiveSeconds() {
        val retry = BusyOfferRetry(true, 1000)
        assertTrue(retry.allow(423, 1000)); assertTrue(retry.allow(423, 5999))
        assertFalse(retry.allow(423, 6000)); assertFalse(retry.allow(423, 999))
        for (status in listOf(200, 400, 401, 403, 410, 429, 500, 503)) assertFalse(retry.allow(status, 2000))
        assertFalse(BusyOfferRetry(false, 1000).allow(423, 2000))
    }
}
