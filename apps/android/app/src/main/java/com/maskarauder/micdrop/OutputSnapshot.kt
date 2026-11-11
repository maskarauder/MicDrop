package com.maskarauder.micdrop

import java.util.Locale

internal data class OutputSnapshot(
    val backend: String, val capturedUptimeMs: Long, val route: String?,
    val trackGeneration: Int, val routeChanges: Int,
    val sampleRateHz: Int, val channels: Int, val bufferFrames: Int, val capacityFrames: Int,
    val underruns: Int, val performanceMode: String,
    val timestampAgeMs: Double?, val estimatedQueueMs: Double?
) : java.io.Serializable {
    fun fields(): Map<String, Any?> = linkedMapOf(
        "backend" to backend, "captured_uptime_ms" to capturedUptimeMs, "route" to route,
        "track_generation" to trackGeneration, "route_changes" to routeChanges,
        "sample_rate_hz" to sampleRateHz, "channels" to channels,
        "buffer_frames" to bufferFrames, "capacity_frames" to capacityFrames,
        "underruns" to underruns, "performance_mode" to performanceMode,
        "timestamp_age_ms" to timestampAgeMs, "estimated_queue_ms" to estimatedQueueMs)

    fun text(): String {
        fun ms(value: Double?) = value?.let { String.format(Locale.US, "%.1f ms", it) } ?: "unavailable"
        return """
            Actual AudioTrack route: ${route ?: "unavailable"}
            Output: $sampleRateHz Hz / $channels channels · Performance: $performanceMode
            Buffer size: ${ms(bufferFrames * 1000.0 / sampleRateHz)} · Capacity: ${ms(capacityFrames * 1000.0 / sampleRateHz)} (not queue occupancy)
            Output underruns: $underruns · Track generation: $trackGeneration · Observed route changes: $routeChanges
            Estimated queued output: ${ms(estimatedQueueMs)} · Timestamp age: ${ms(timestampAgeMs)}
            Output timing is an OS estimate; headset rendering and physical latency remain unmeasured.
        """.trimIndent()
    }
}

internal object OutputTiming {
    // Use System.nanoTime with AudioTimestamp's MONOTONIC timebase, never
    // elapsedRealtime (which includes deep sleep). Only a current, coherent
    // frame/time pair is useful. Future committed timestamps are legitimate.
    fun queueMs(written: Long?, presented: Long, timestampNs: Long, nowNs: Long,
                sampleRate: Int, epochNs: Long): Double? {
        if (written == null || written < 0 || presented < 0 || presented > written ||
            sampleRate <= 0 || timestampNs < epochNs) return null
        val ageMs = (nowNs - timestampNs) / 1e6
        if (ageMs !in -1000.0..1000.0) return null
        return ((written - presented) * 1000.0 / sampleRate - ageMs)
            .takeIf { it.isFinite() && it in 0.0..60000.0 }
    }
}

internal data class RecoverySnapshot(val fastAccelerate: Boolean, val phase: String,
    val episodeMs: Long, val settledAfterMs: Long?, val peakBufferMs: Double?) {
    fun fields(): Map<String, Any?> = linkedMapOf("fast_accelerate" to fastAccelerate,
        "phase" to phase, "episode_ms" to episodeMs, "settled_after_ms" to settledAfterMs,
        "peak_buffer_ms" to peakBufferMs)
    fun text() = "Buffer recovery: $phase · Fast recovery: $fastAccelerate · " +
        "Settled after: ${settledAfterMs?.let { "$it ms" } ?: "unavailable"}"
}

// Observes recovery; never flushes audio or restarts a peer. 'Settled' means
// three consecutive valid windows at <= max(80 ms, target + 20 ms).
internal class RecoveryMonitor(private val fastAccelerate: Boolean) {
    private var started: Long? = null
    private var routeEpoch: Pair<Int, Int>? = null
    private var stable = 0
    private var settled: Long? = null
    private var peak: Double? = null

    fun update(nowMs: Long, running: Boolean, output: OutputSnapshot?, bufferMs: Double?,
               targetMs: Double?): RecoverySnapshot {
        val epoch = output?.let { it.trackGeneration to it.routeChanges }
        if (!running) {
            started = null; stable = 0; settled = null; peak = null; routeEpoch = epoch
            return RecoverySnapshot(fastAccelerate, "waiting", 0, null, null)
        }
        if (started == null || (epoch != null && routeEpoch != null && epoch != routeEpoch)) {
            started = nowMs; stable = 0; settled = null; peak = null
        }
        if (epoch != null) routeEpoch = epoch
        val elapsed = (nowMs - requireNotNull(started)).coerceAtLeast(0)
        val buffer = bufferMs?.takeIf { it.isFinite() && it >= 0 }
        if (buffer != null) peak = maxOf(peak ?: 0.0, buffer)
        val target = targetMs?.takeIf { it.isFinite() && it >= 0 } ?: 0.0
        if (buffer != null && buffer <= maxOf(80.0, target + 20.0)) stable = minOf(stable + 1, 3) else {
            stable = 0; settled = null
        }
        if (stable >= 3 && settled == null) settled = elapsed
        return RecoverySnapshot(fastAccelerate, if (settled != null) "settled" else "settling",
            elapsed, settled, peak)
    }
}
