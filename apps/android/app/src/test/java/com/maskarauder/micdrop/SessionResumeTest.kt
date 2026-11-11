package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class SessionResumeTest {
    @Test fun pairedResumeIsDistinctFromExplicitConnect() {
        for (reason in SessionResume.Reason.entries) assertEquals("1", SessionResume.offerHeader(3, "/offer", reason))
        assertNull(SessionResume.offerHeader(3, "/offer", null))
        assertNull(SessionResume.reasonHeader(3, "/offer", null))
        assertTrue(SessionResume.offerHeaders(3, "/offer", null).isEmpty())
    }

    @Test fun reasonsUseTheHostsFixedLabels() {
        assertEquals("X-MicDrop-Session-Resume-Reason", SessionResume.REASON_HEADER)
        assertEquals(listOf("manual", "automatic", "focus_regain"), SessionResume.Reason.entries.map { it.wire })
        for (reason in SessionResume.Reason.entries) {
            assertEquals(reason.wire, SessionResume.reasonHeader(3, "/offer", reason))
            assertTrue(reason.wire.matches(Regex("[a-z_]{1,32}")))
        }
    }

    @Test fun theReasonFollowsTheResumeHintExactlyOnce() {
        for (reason in SessionResume.Reason.entries)
            assertEquals(listOf(SessionResume.HEADER to "1", SessionResume.REASON_HEADER to reason.wire),
                SessionResume.offerHeaders(3, "/offer", reason))
    }

    @Test fun resumeNeverEntersLegacyOrOrdinaryControlRequests() {
        for (reason in SessionResume.Reason.entries) {
            for (version in listOf(1, 2)) {
                assertNull(SessionResume.offerHeader(version, "/offer", reason))
                assertNull(SessionResume.reasonHeader(version, "/offer", reason))
                assertTrue(SessionResume.offerHeaders(version, "/offer", reason).isEmpty())
            }
            for (path in listOf("/status", "/stop", "/answer", "/cancel-offer", "/recover-offer", "/recover-answer", "/microphone", "/pair")) {
                assertNull(SessionResume.offerHeader(3, path, reason))
                assertNull(SessionResume.reasonHeader(3, path, reason))
                assertTrue(SessionResume.offerHeaders(3, path, reason).isEmpty())
            }
        }
    }

    @Test fun entryPointsReportDistinctCauses() {
        // Play, Resume duplex, notification Resume and a queued Play are manual.
        assertEquals(SessionResume.Reason.MANUAL, SessionResume.resumed(userRequested = true))
        assertEquals(SessionResume.Reason.FOCUS_REGAIN, SessionResume.resumed(userRequested = false))
        // F1: the input-switch replacement has neither a Play command nor a focus signal.
        assertEquals(SessionResume.Reason.AUTOMATIC, SessionResume.INPUT_SWITCH)
    }
}
