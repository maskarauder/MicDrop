package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class TerminalLabelsTest {
    @Test fun beforeAnOfferReplyTerminalDiagnosticsWereNotSent() {
        for (includeConnection in listOf(false, true))
            assertEquals("not sent; no Windows offer reply", TerminalLabels.delivery(OfferReply.NONE, includeConnection))
    }

    @Test fun aRejectedOfferReplyIsNotReportedAsMissingOrUnrequested() {
        for (includeConnection in listOf(false, true))
            assertEquals("not sent; Windows offer reply rejected", TerminalLabels.delivery(OfferReply.REJECTED, includeConnection))
    }

    @Test fun afterAnOfferReplyTheLabelSaysWhetherWindowsRequestedDiagnostics() {
        assertEquals("not confirmed", TerminalLabels.delivery(OfferReply.ACCEPTED, true))
        assertEquals("not confirmed", TerminalLabels.NOT_CONFIRMED)
        // Logging off or no phone control also omits the request on current hosts.
        assertEquals("not requested by Windows (older Windows or logging off)", TerminalLabels.delivery(OfferReply.ACCEPTED, false))
    }

    @Test fun beforeAnOfferReplyMediaRecoveryWasNotNegotiated() {
        for (recovery in listOf(LanRecovery(false), LanRecovery(true), LanRecovery(true).apply { observe(false, 0) }))
            assertEquals("Media recovery: not negotiated (no Windows offer reply)", TerminalLabels.mediaRecovery(OfferReply.NONE, recovery, 1000))
    }

    @Test fun aRejectedOfferReplyDoesNotReportTheDefaultRecoveryWindow() {
        for (recovery in listOf(LanRecovery(false), LanRecovery(true), LanRecovery(true).apply { observe(false, 0) }))
            assertEquals("Media recovery: not negotiated (Windows offer reply rejected)",
                TerminalLabels.mediaRecovery(OfferReply.REJECTED, recovery, 1000))
    }

    @Test fun afterAnOfferReplyMediaRecoveryKeepsTheTerminalStateAndRemainingTime() {
        assertEquals("Media recovery: settled · ICE restarts requested: 0 · Window: 10 seconds\nRecovery time remaining: 10000 ms",
            TerminalLabels.mediaRecovery(OfferReply.ACCEPTED, LanRecovery(false), 0))
        val recovery = LanRecovery(true, 90000, 2000, 10000, 6).apply { observe(true, 0); observe(false, 1000); begin(3000) }
        assertEquals("Media recovery: recovering · ICE restarts requested: 1 · Window: 90 seconds\nRecovery time remaining: 85000 ms",
            TerminalLabels.mediaRecovery(OfferReply.ACCEPTED, recovery, 6000))
    }
}
