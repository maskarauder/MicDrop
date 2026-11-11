package com.maskarauder.micdrop

import java.util.Locale

// Only these numeric counters and fixed labels leave this calculator. IDs and
// untrusted member strings are used for lookups, never included in a report.
internal data class RtcSample(val id: String, val type: String, val timestampUs: Double,
                              val members: Map<String, Any>)

internal data class PlaybackSnapshot(val codec: String, val path: String,
                                     val values: Map<String, Double?>,
                                     val transport: MediaTransportSnapshot = MediaTransportSnapshot()) {
    fun text(): String {
        fun number(key: String, unit: String = "", decimals: Int = 1): String =
            values[key]?.let { String.format(Locale.US, "%.${decimals}f%s", it, unit) } ?: "unavailable"
        return """
            Codec: $codec · Media path: $path
            Network RTT: ${number("rtt_ms", " ms")} · RTP jitter: ${number("jitter_ms", " ms")}
            Recent window: ${number("window_seconds", " s")}
            Jitter buffer — actual: ${number("buffer_ms", " ms")}, target: ${number("buffer_target_ms", " ms")}, minimum: ${number("buffer_minimum_ms", " ms")}
            Incoming payload: ${number("payload_kbps", " kb/s")}
            Recent packets — received: ${number("received_packets", decimals = 0)}, net loss change: ${number("lost_packets", decimals = 0)}, discarded: ${number("discarded_packets", decimals = 0)}
            Recent concealed samples: ${number("concealed_samples", decimals = 0)} (${number("concealed_percent", "%")})
            Recent time stretching — inserted: ${number("inserted_samples", decimals = 0)}, removed: ${number("removed_samples", decimals = 0)} samples
            Total received: ${number("bytes_total", " bytes", 0)}
            RTT and jitter-buffer statistics are not speaker latency.
        """.trimIndent()
    }
}

// Each direction has its own counter history. An outbound reset must not erase
// valid playback jitter/buffer measurements, or overwrite its receive window.
internal class SessionMetrics(private val mode: StreamMode) {
    private val incoming = PlaybackMetrics()
    private val outgoing = PlaybackMetrics(true)
    fun update(samples: Map<String, RtcSample>): PlaybackSnapshot = when (mode) {
        StreamMode.PLAYBACK -> incoming.update(samples)
        StreamMode.MICROPHONE -> outgoing.update(samples)
        StreamMode.DUPLEX -> {
            val received = incoming.update(samples)
            val sent = outgoing.update(samples)
            received.copy(values = received.values + sent.values.filterKeys { it.startsWith("sent_") })
        }
    }
}

internal class PlaybackMetrics(private val outgoing: Boolean = false) {
    private var previous: RtcSample? = null

    fun update(samples: Map<String, RtcSample>): PlaybackSnapshot {
        val incoming = samples.values.firstOrNull { it.type == (if (outgoing) "outbound-rtp" else "inbound-rtp") && it.members["kind"] == "audio" }
        val old = previous
        previous = incoming
        val values = linkedMapOf<String, Double?>()
        fun current(key: String): Double? = incoming?.members?.number(key)
        val seconds = if (incoming != null && old?.id == incoming.id)
            ((incoming.timestampUs - old.timestampUs) / 1e6).takeIf { it.isFinite() && it > 0 && it <= 10 }
            else null
        val reset = cumulative.any { key ->
            val now = current(key); val before = old?.members?.number(key)
            now != null && before != null && now < before
        }
        val window = seconds?.takeUnless { reset }
        fun delta(key: String, signed: Boolean = false): Double? {
            if (window == null) return null
            val now = incoming?.members?.number(key, signed) ?: return null
            val before = old?.members?.number(key, signed) ?: return null
            return (now - before).takeIf { it.isFinite() && (signed || it >= 0) }
        }
        val emitted = delta("jitterBufferEmittedCount")?.takeIf { it > 0 }
        fun mean(key: String) = emitted?.let { count -> delta(key)?.let { 1000 * it / count } }
        values["window_seconds"] = window
        values["buffer_ms"] = mean("jitterBufferDelay")
        values["buffer_target_ms"] = mean("jitterBufferTargetDelay")
        values["buffer_minimum_ms"] = mean("jitterBufferMinimumDelay")
        values["jitter_ms"] = current("jitter")?.times(1000)
        values["bytes_total"] = current("bytesReceived")
        values["payload_kbps"] = window?.let { secondsInWindow -> delta("bytesReceived")?.let { it * 8 / secondsInWindow / 1000 } }
        values["received_packets"] = delta("packetsReceived")
        // RTCP's cumulative loss estimate can decrease after late arrivals.
        values["lost_packets"] = delta("packetsLost", true)
        values["discarded_packets"] = delta("packetsDiscarded")
        values["concealed_samples"] = delta("concealedSamples")
        val totalSamples = delta("totalSamplesReceived")?.takeIf { it > 0 }
        values["concealed_percent"] = totalSamples?.let { total -> delta("concealedSamples")?.let { 100 * it / total } }?.takeIf { it in 0.0..100.0 }
        values["inserted_samples"] = delta("insertedSamplesForDeceleration")
        values["removed_samples"] = delta("removedSamplesForAcceleration")
        if (outgoing) {
            values["sent_bytes_total"] = current("bytesSent")
            values["sent_packets"] = delta("packetsSent")
            values["sent_payload_kbps"] = window?.let { delta("bytesSent")?.let { bytes -> bytes * 8 / it / 1000 } }
        }

        fun linked(sample: RtcSample?, key: String, type: String): RtcSample? =
            (sample?.members?.get(key) as? String)?.let { samples[it] }?.takeIf { it.type == type }
        val transport = linked(incoming, "transportId", "transport")
        val pair = linked(transport, "selectedCandidatePairId", "candidate-pair")
            // Keepalive pings put an established selected pair in-progress.
            // Selection identifies the path; it does not prove live audio.
            ?.takeIf { it.members["state"] in setOf("succeeded", "in-progress") }
        values["rtt_ms"] = pair?.members?.number("currentRoundTripTime")?.times(1000)
        val local = linked(pair, "localCandidateId", "local-candidate")
        val remote = linked(pair, "remoteCandidateId", "remote-candidate")
        val selected = MediaTransportSnapshot.selected(local, remote)
        val codec = linked(incoming, "codecId", "codec")?.members?.get("mimeType")
        return PlaybackSnapshot(if (codec == "audio/opus") "Opus" else "unavailable",
            selected.legacyPath,
            values.mapValues { (_, value) -> value?.takeIf { it.isFinite() } }, selected)
    }

    private fun Map<String, Any>.number(key: String, signed: Boolean = false): Double? =
        (get(key) as? Number)?.toDouble()?.takeIf { it.isFinite() && (signed || it >= 0) }

    companion object {
        private val cumulative = listOf("bytesReceived", "packetsReceived", "bytesSent", "packetsSent", "packetsDiscarded",
            "jitterBufferEmittedCount", "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferMinimumDelay",
            "totalSamplesReceived", "concealedSamples", "insertedSamplesForDeceleration", "removedSamplesForAcceleration")
    }
}
