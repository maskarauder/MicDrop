package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.TimeoutException
import javax.net.ssl.SSLException

class SessionEvidenceTest {
    @Test fun initialGatheringSurvivesSetupFailureAndIsNegotiatedSeparately() {
        val gathering = IceGathering.initial("", false, true, true, 15001, 1 to 701)
        val terminal = TerminalEvidence("2026-10-09T00:00:00Z", 10000, SessionFailure.STAGE_TIMEOUT,
            ConnectionStage.ROUTES, 9990, ConnectionSnapshot("failed", "failed", "unavailable", null), emptyList(), 0,
            iceGathering = gathering)
        assertFalse(terminal.fields().containsKey("ice_gathering"))
        assertEquals(gathering.fields(), terminal.fields(includeIceGathering = true)["ice_gathering"])
        assertTrue(terminal.text().contains("Initial Android ICE gathering: timed_out"))
        assertTrue(terminal.text().contains("Last code: 701"))
    }

    @Test fun callbackTailIsBoundedOrderedAndIndependentOfLaterCleanup() {
        val trace = SessionEvidence()
        for (i in 0..99) trace.observe(EvidenceKind.ICE, if (i % 2 == 0) "connected" else "disconnected", i.toLong())
        val tail = trace.tail(100)
        assertEquals(24, tail.size)
        assertEquals(76L, trace.omitted(100))
        trace.observe(EvidenceKind.ICE, "disconnected", 100) // Duplicate is not an event.
        assertEquals(76L, trace.omitted(100))
        trace.observe(EvidenceKind.PEER, "connected", 50) // Late callback cannot regress receipt time.
        assertEquals(99L, trace.tail(100).last().uptimeMs)
        trace.observe(EvidenceKind.PEER, "closed", 101)
        assertEquals("disconnected", tail.last().value)
        assertEquals(24, tail.size)
        assertFalse(trace.tail(100).any { it.value == "closed" })
    }

    @Test fun unknownPermissionPowerAndNetworkObservationsStayUnknown() {
        val runtime = RuntimeSnapshot(null, null, null, null, null, null, "unknown", null, null, null, 0)
        val trace = SessionEvidence()
        val connection = trace.connection(runtime, 100)
        assertNull(runtime.fields()["microphone_permission"])
        assertNull(runtime.fields()["device_idle"])
        assertEquals("unknown", runtime.fields()["default_network"])
        assertTrue(runtime.text().contains("unknown"))
        assertEquals("connecting", connection.peer)
        assertEquals("new", connection.ice)
        assertEquals("unavailable", connection.host)
        trace.connection(runtime, 200)
        assertEquals(12, trace.tail(200).size) // Initial flags, not repeated each heartbeat.
    }

    @Test fun connectionExtensionRequiresHostCapabilityAndContainsNoIdentifiers() {
        val runtime = RuntimeSnapshot(false, false, false, true, true, true, "wifi", false, false, false, 2)
        val connection = ConnectionSnapshot("disconnected", "disconnected", "connected", runtime)
        val report = PlaybackReport(1, "2026-10-01T00:00:00Z", 10000, null, "Disconnected", "running",
            PlaybackSnapshot("Opus", "unavailable", emptyMap()), connection = connection)
        assertFalse(report.fields().containsKey("connection"))
        assertEquals(connection.fields(), report.fields(includeConnection = true)["connection"])
        assertEquals(setOf("peer", "ice", "host", "runtime"), connection.fields().keys)
        assertFalse(runtime.text().contains("internet required"))
    }

    @Test fun failuresAreClassifiedByTypeWithoutPrivateExceptionText() {
        val secret = "micdrop://private-invitation"
        for ((error, code) in listOf(
            IOException(secret) to SessionFailure.NETWORK_IO,
            SSLException(secret) to SessionFailure.TLS_FAILURE,
            TimeoutException(secret) to SessionFailure.STAGE_TIMEOUT,
            SecurityException(secret) to SessionFailure.PERMISSION_DENIED,
            HttpFailure(403) to SessionFailure.HTTP_REJECTED,
            UnsatisfiedLinkError(secret) to SessionFailure.NATIVE_LOAD,
            IllegalStateException(secret) to SessionFailure.SESSION_EXCEPTION)) {
            assertEquals(code, SessionFailure.from(error))
        }
        val terminal = TerminalEvidence("2026-10-01T00:00:00Z", 10000, SessionFailure.PEER_FAILED,
            ConnectionStage.MICROPHONE, 9990, ConnectionSnapshot("failed", "failed", "disconnected", null), emptyList(), 0)
        assertEquals("peer_failed", terminal.fields()["code"])
        assertEquals("microphone", terminal.fields()["stage"])
        assertFalse(terminal.fields().toString().contains(secret))
        assertTrue(terminal.text().contains("peer_failed"))
    }
}
