package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class PlaybackMetricsTest {
    private fun sample(seconds: Int, overrides: Map<String, Any> = emptyMap(), id: String = "audio"): RtcSample =
        RtcSample(id, "inbound-rtp", seconds * 1e6, mapOf<String, Any>("kind" to "audio",
            "bytesReceived" to seconds * 16000, "packetsReceived" to seconds * 100,
            "packetsLost" to seconds, "jitterBufferEmittedCount" to seconds * 48000,
            "jitterBufferDelay" to seconds * 48000 * 0.03,
            "jitterBufferTargetDelay" to seconds * 48000 * 0.04,
            "jitterBufferMinimumDelay" to seconds * 48000 * 0.01,
            "totalSamplesReceived" to seconds * 48000, "concealedSamples" to seconds * 480,
            "jitter" to 0.005) + overrides)
    private fun update(metrics: PlaybackMetrics, sample: RtcSample) = metrics.update(mapOf(sample.id to sample))

    @Test fun usesCounterDeltasForRecentDelayAndRates() {
        val metrics = PlaybackMetrics()
        assertNull(update(metrics, sample(10)).values["buffer_ms"])
        val next = update(metrics, sample(12, mapOf("jitterBufferDelay" to 24000.0)))
        // Old cumulative delay was 14400. New interval is 9600 / 96000 = 100 ms,
        // while the lifetime mean would misleadingly report about 41.7 ms.
        assertEquals(100.0, next.values["buffer_ms"]!!, 0.0001)
        assertEquals(40.0, next.values["buffer_target_ms"]!!, 0.0001)
        assertEquals(128.0, next.values["payload_kbps"]!!, 0.0001)
        assertEquals(1.0, next.values["concealed_percent"]!!, 0.0001)
    }

    @Test fun resetsOnCounterResetStreamChangeOrBadTime() {
        for (next in listOf(sample(12, mapOf("bytesReceived" to 0)), sample(12, id = "new"), sample(10), sample(30))) {
            val metrics = PlaybackMetrics(); update(metrics, sample(10))
            assertNull(update(metrics, next).values["buffer_ms"])
        }
    }

    @Test fun absentAndIdleMetricsRemainUnavailable() {
        val metrics = PlaybackMetrics()
        val first = sample(10)
        update(metrics, first)
        val idle = update(metrics, first.copy(timestampUs = 12e6))
        assertNull(idle.values["buffer_ms"])
        assertNull(idle.values["rtt_ms"])
        assertNull(idle.values["discarded_packets"])
        val absent = update(metrics, RtcSample("audio", "inbound-rtp", 14e6, mapOf("kind" to "audio")))
        assertNull(absent.values["jitter_ms"])
        assertTrue(absent.text().contains("unavailable"))
    }

    @Test fun netLossCanDecreaseAndNonfiniteNumbersAreRejected() {
        val metrics = PlaybackMetrics(); update(metrics, sample(10, mapOf("packetsLost" to 5)))
        val next = update(metrics, sample(12, mapOf("packetsLost" to 3, "jitter" to Double.NaN)))
        assertEquals(-2.0, next.values["lost_packets"]!!, 0.0)
        assertNull(next.values["jitter_ms"])
    }

    @Test fun followsSelectedTransportAndNeverPrintsIdentifiers() {
        val incoming = sample(10, mapOf("transportId" to "secret-transport", "codecId" to "codec"))
        val samples = mapOf(incoming.id to incoming,
            "secret-transport" to RtcSample("secret-transport", "transport", 1.0, mapOf("selectedCandidatePairId" to "selected")),
            "selected" to RtcSample("selected", "candidate-pair", 1.0, mapOf("state" to "succeeded",
                "currentRoundTripTime" to 0.008, "localCandidateId" to "local", "remoteCandidateId" to "remote")),
            "other" to RtcSample("other", "candidate-pair", 1.0, mapOf("state" to "succeeded", "currentRoundTripTime" to 9)),
            "local" to RtcSample("local", "local-candidate", 1.0, mapOf("candidateType" to "host", "protocol" to "udp", "address" to "secret-ip")),
            "remote" to RtcSample("remote", "remote-candidate", 1.0, mapOf("candidateType" to "host", "address" to "secret-peer")),
            "codec" to RtcSample("codec", "codec", 1.0, mapOf("mimeType" to "audio/opus", "sdpFmtpLine" to "secret-sdp")))
        val result = PlaybackMetrics().update(samples)
        assertEquals(8.0, result.values["rtt_ms"]!!, 0.0)
        assertEquals("direct / udp", result.path)
        assertEquals("Opus", result.codec)
        assertFalse(result.text().contains("secret"))
    }

    @Test fun duplexKeepsSeparateCounterHistoriesForBothDirections() {
        fun outgoing(seconds: Int, bytes: Int = seconds * 8000) = RtcSample("sending", "outbound-rtp", seconds * 1e6,
            mapOf("kind" to "audio", "bytesSent" to bytes, "packetsSent" to seconds * 100))
        val metrics = SessionMetrics(StreamMode.DUPLEX)
        fun both(seconds: Int, bytes: Int = seconds * 8000) = metrics.update(mapOf("audio" to sample(seconds), "sending" to outgoing(seconds, bytes)))
        both(10)
        val running = both(12)
        assertEquals(64.0, running.values["sent_payload_kbps"]!!, 0.0)
        assertNotNull(running.values["bytes_total"])
        assertNotNull(running.values["buffer_ms"])
        val reset = both(14, 0)
        assertNull(reset.values["sent_payload_kbps"])
        assertNotNull(reset.values["buffer_ms"])
        assertEquals(2.0, reset.values["window_seconds"]!!, 0.0)
        assertFalse(SessionMetrics(StreamMode.PLAYBACK).update(mapOf("sending" to outgoing(10))).values.containsKey("sent_bytes_total"))
    }

    @Test fun microphoneCountersUseOutboundStreamAndRejectResets() {
        fun outgoing(seconds: Int, overrides: Map<String, Any> = emptyMap(), id: String = "sending") =
            RtcSample(id, "outbound-rtp", seconds * 1e6, mapOf<String, Any>("kind" to "audio",
                "bytesSent" to seconds * 8000, "packetsSent" to seconds * 100) + overrides)
        val metrics = PlaybackMetrics(true)
        val first = metrics.update(mapOf("sending" to outgoing(10), "audio" to sample(10)))
        assertEquals(80000.0, first.values["sent_bytes_total"]!!, 0.0)
        assertNull(first.values["bytes_total"])
        assertNull(first.values["sent_payload_kbps"])
        val second = metrics.update(mapOf("sending" to outgoing(12), "audio" to sample(12)))
        assertEquals(64.0, second.values["sent_payload_kbps"]!!, 0.0)
        assertEquals(200.0, second.values["sent_packets"]!!, 0.0)
        assertNull(second.values["buffer_ms"])
        for (next in listOf(outgoing(14, mapOf("bytesSent" to 0)), outgoing(14, id = "new"),
            outgoing(12), outgoing(30))) {
            val reset = PlaybackMetrics(true)
            reset.update(mapOf("sending" to outgoing(12)))
            assertNull(reset.update(mapOf(next.id to next)).values["sent_payload_kbps"])
        }
        assertFalse(PlaybackMetrics().update(mapOf("sending" to outgoing(12))).values.containsKey("sent_packets"))
    }
}
