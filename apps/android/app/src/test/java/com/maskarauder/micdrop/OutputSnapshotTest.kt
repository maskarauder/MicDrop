package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class OutputSnapshotTest {
    private val output = OutputSnapshot("webrtc_audiotrack", 1000, "phone speaker", 1, 0,
        48000, 2, 960, 4800, 0, "low latency", null, null)

    @Test fun queueEstimateUsesFramePositionAndMonotonicPresentationTime() {
        // 100 ms of frames beyond the timestamp, whose frame was presented 20 ms ago.
        assertEquals(80.0, OutputTiming.queueMs(9600, 4800, 1000000000, 1020000000, 48000, 0)!!, 0.001)
        // Some routes timestamp a frame committed to future presentation.
        assertEquals(120.0, OutputTiming.queueMs(9600, 4800, 1020000000, 1000000000, 48000, 0)!!, 0.001)
    }

    @Test fun unknownStaleResetAndInconsistentClocksDoNotProduceLatency() {
        assertNull(OutputTiming.queueMs(null, 0, 1000000000, 1000000000, 48000, 0))
        assertNull(OutputTiming.queueMs(9600, 4800, 1000000000, 2100000000, 48000, 0))
        assertNull(OutputTiming.queueMs(0, 4800, 1000000000, 1000000000, 48000, 0))
        assertNull(OutputTiming.queueMs(9600, 4800, 1000000000, 1000000000, 48000, 1000000001))
        assertNull(OutputTiming.queueMs(9600, 4800, 1000000000, 1200000000, 48000, 0))
        assertNull(OutputTiming.queueMs(9600, 4800, 1000000000, 1000000000, 0, 0))
    }

    @Test fun recoveryRequiresConsecutiveGoodWindowsAndRestartsAfterRouteChange() {
        val monitor = RecoveryMonitor(true)
        assertEquals("waiting", monitor.update(0, false, null, null, null).phase)
        assertEquals("settling", monitor.update(1000, true, output, 800.0, 40.0).phase)
        monitor.update(3000, true, output, 60.0, 40.0)
        monitor.update(5000, true, output, 60.0, 40.0)
        assertEquals("settling", monitor.update(7000, true, output, null, 40.0).phase)
        monitor.update(9000, true, output, 60.0, 40.0)
        monitor.update(11000, true, output, 60.0, 40.0)
        val settled = monitor.update(13000, true, output, 60.0, 40.0)
        assertEquals("settled", settled.phase)
        assertEquals(12000L, settled.settledAfterMs)
        assertEquals(800.0, settled.peakBufferMs!!, 0.0)
        val changed = monitor.update(15000, true, output.copy(routeChanges = 1), 500.0, 40.0)
        assertEquals("settling", changed.phase); assertEquals(0L, changed.episodeMs)
        assertNull(changed.settledAfterMs)
        assertEquals(500.0, changed.peakBufferMs!!, 0.0)
    }

    @Test fun trackReplacementAndMissingOutputDoNotConfuseRecovery() {
        val monitor = RecoveryMonitor(false)
        monitor.update(1000, true, output, 60.0, 40.0)
        monitor.update(3000, true, null, 60.0, 40.0)
        assertEquals("settled", monitor.update(5000, true, output, 60.0, 40.0).phase)
        assertEquals("settling", monitor.update(7000, true, output.copy(trackGeneration = 2), 60.0, 40.0).phase)
        assertEquals("waiting", monitor.update(9000, false, null, 60.0, 40.0).phase)
    }

    @Test fun optionalWireExtensionPreservesLegacyUploadsAndTypedBaseline() {
        val report = PlaybackReport(1, "2026-09-29T00:00:00Z", 10000, null, "Connected", "running",
            PlaybackSnapshot("Opus", "direct / udp", emptyMap()), output,
            RecoverySnapshot(true, "settling", 2000, null, 800.0),
            output.copy(backend = "local_audiotrack"))
        assertFalse(report.fields().containsKey("output"))
        assertEquals(output.fields(), report.fields(true)["output"])
        assertNotNull(report.fields(true)["local_output_baseline"])
        assertTrue(output.text().contains("not queue occupancy"))
        assertTrue(output.text().contains("unavailable"))
    }
}
