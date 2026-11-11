package com.maskarauder.micdrop

import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.AudioDeviceInfo
import android.media.AudioRouting
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.SystemClock
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.atomic.AtomicLong

// Optional read-only access to the pinned AAR's app-owned Java fields. There is
// no public output observer in this version. Never mutate/release this track or
// invoke hidden Android APIs. A dependency change or access failure simply
// makes optional timing diagnostics unavailable. Explicit Bluetooth duplex uses
// the same public route observation as a required gate before enabling output;
// an unverified headset output ends that session instead of playing elsewhere.
internal class WebRtcOutputDiagnostics {
    private val reader = OutputDiagnostics("webrtc_audiotrack")
    private var watched: AudioTrack? = null
    private var listener: AudioRouting.OnRoutingChangedListener? = null
    private val routeGeneration = AtomicLong()

    private fun track(module: JavaAudioDeviceModule?): AudioTrack? = WebRtcOutputAccess.track(module)
    fun routedDevice(module: JavaAudioDeviceModule): AudioDeviceInfo? = runCatching { track(module)?.routedDevice }.getOrNull()
    fun matches(module: JavaAudioDeviceModule, routing: MicrophoneRouting): Boolean = runCatching {
        val current = track(module) ?: return@runCatching false
        routing.matchesOutput(current.routedDevice) && routing.acceptsOutputChannels(current.channelCount)
    }.getOrDefault(false)
    fun watchRoute(module: JavaAudioDeviceModule, routing: MicrophoneRouting, invalid: () -> Unit): Boolean {
        clearRouteWatch()
        val track = track(module) ?: return false
        val current = routeGeneration.get()
        val callback = AudioRouting.OnRoutingChangedListener {
            if (current == routeGeneration.get() && !matches(module, routing)) invalid()
        }
        return runCatching {
            track.addOnRoutingChangedListener(callback, Handler(Looper.getMainLooper()))
            watched = track; listener = callback
            true
        }.getOrDefault(false)
    }
    fun clearRouteWatch() {
        routeGeneration.incrementAndGet()
        val old = watched; val callback = listener
        watched = null; listener = null
        if (old != null && callback != null) runCatching { old.removeOnRoutingChangedListener(callback) }
    }

    fun snapshot(module: JavaAudioDeviceModule?): OutputSnapshot? = try {
        track(module)?.let { reader.snapshot(it) }
    } catch (_: Exception) { null }
}

internal class OutputDiagnostics(private val backend: String) {
    private var lastTrack: AudioTrack? = null
    private var lastRouteId: Int? = null // Used only for comparisons, never logged.
    private var generation = 0
    private var routeChanges = 0
    private var epochNs = 0L
    private var lastFrame: Long? = null
    private var lastTimestampNs: Long? = null
    private var positionReset = false
    private val writtenFrames = if (Build.VERSION.SDK_INT >= 37) runCatching {
        // Public API 37 method, discovered reflectively to retain compile SDK 36
        // and compatibility with API 31–36. No hidden-API access.
        AudioTrack::class.java.getMethod("getWrittenFramesCount")
    }.getOrNull() else null

    fun snapshot(track: AudioTrack, knownWrittenFrames: Long? = null): OutputSnapshot? = try {
        val now = System.nanoTime()
        val route = track.routedDevice
        if (track !== lastTrack) {
            lastTrack = track; lastRouteId = route?.id; generation++; epochNs = now
            lastFrame = null; lastTimestampNs = null; positionReset = false
        } else if (route?.id != lastRouteId) {
            routeChanges++; lastRouteId = route?.id; epochNs = now
        }
        val stamp = AudioTimestamp()
        val timestampValid = track.playState == AudioTrack.PLAYSTATE_PLAYING && track.getTimestamp(stamp)
        if (timestampValid) {
            // Written frames and timestamp positions may use different origins
            // after a device discontinuity. Do not fabricate a large queue.
            if ((lastFrame?.let { stamp.framePosition < it } == true) ||
                (lastTimestampNs?.let { stamp.nanoTime < it } == true)) positionReset = true
            lastFrame = stamp.framePosition; lastTimestampNs = stamp.nanoTime
        }
        val written = knownWrittenFrames ?: runCatching { writtenFrames?.invoke(track) as? Long }.getOrNull()
        val sampledAt = System.nanoTime()
        val age = if (timestampValid && stamp.nanoTime >= epochNs)
            ((sampledAt - stamp.nanoTime) / 1e6).takeIf { it in -1000.0..1000.0 } else null
        OutputSnapshot(backend, SystemClock.elapsedRealtime(), route?.let { PlaybackEnvironment.type(it.type) },
            generation, routeChanges, track.sampleRate, track.channelCount,
            track.bufferSizeInFrames, track.bufferCapacityInFrames, track.underrunCount,
            when (track.performanceMode) {
                AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "low latency"
                AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "power saving"
                else -> "none"
            }, age, if (age != null && !positionReset) OutputTiming.queueMs(written, stamp.framePosition, stamp.nanoTime,
                sampledAt, track.sampleRate, epochNs) else null)
    } catch (_: RuntimeException) { null }
}
