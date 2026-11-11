package com.maskarauder.micdrop

import android.media.AudioRecord
import android.media.AudioRouting
import android.os.Handler
import android.os.Looper
import org.webrtc.audio.JavaAudioDeviceModule
import java.util.concurrent.atomic.AtomicLong

internal data class MicrophoneSnapshot(val state: String, val route: String,
    val sampleRate: Int = 0, val channels: Int = 0,
    val requestedRoute: String? = null, val routeVerified: Boolean? = null) {
    fun fields(): Map<String, Any> = linkedMapOf("state" to state, "route" to route,
        "sample_rate_hz" to sampleRate, "channels" to channels).apply {
        requestedRoute?.let { put("requested_route", it) }; routeVerified?.let { put("route_verified", it) }
    }
    fun text() = "Microphone: $state · Input: $route · $sampleRate Hz / $channels channels" +
        (requestedRoute?.let { "\nSelected input: $it · Route verified: ${routeVerified == true}" } ?: "")
}

// Read only app-owned Java fields in the pinned AAR, then use public AudioRecord
// routing APIs. Failure closes microphone return rather than guessing an input.
// Never read/retain PCM, release the record, or use hidden Android APIs here.
internal class MicrophoneInput {
    private val inputField = runCatching {
        JavaAudioDeviceModule::class.java.getDeclaredField("audioInput").apply { isAccessible = true }
    }.getOrNull()
    private val recordField = runCatching {
        Class.forName("org.webrtc.audio.WebRtcAudioRecord").getDeclaredField("audioRecord").apply { isAccessible = true }
    }.getOrNull()
    private var watched: AudioRecord? = null
    private var listener: AudioRouting.OnRoutingChangedListener? = null
    private val generation = AtomicLong()
    private fun record(module: JavaAudioDeviceModule): AudioRecord? = runCatching {
        inputField?.get(module)?.let { recordField?.get(it) as? AudioRecord }
    }.getOrNull()

    fun matches(module: JavaAudioDeviceModule, routing: MicrophoneRouting): Boolean = runCatching {
        routing.matchesInput(record(module)?.routedDevice)
    }.getOrDefault(false)

    fun snapshot(module: JavaAudioDeviceModule, state: String, selection: MicrophoneSelection,
        routing: MicrophoneRouting, captureRunning: Boolean = state == "running"): MicrophoneSnapshot {
        val unknownState = if (state == "running") "waiting" else state
        val record = record(module) ?: return MicrophoneSnapshot(unknownState, "unavailable",
            requestedRoute = selection.kind.label, routeVerified = false)
        return runCatching {
            val device = record.routedDevice
            val verified = captureRunning && state in listOf("running", "muted") && routing.matchesInput(device)
            MicrophoneSnapshot(if (state == "running" && !verified) "waiting" else state,
                device?.let { MicrophoneKind.forType(it.type)?.label } ?: "unavailable",
                record.sampleRate, record.channelCount, selection.kind.label, verified)
        }.getOrElse { MicrophoneSnapshot(unknownState, "unavailable", requestedRoute = selection.kind.label, routeVerified = false) }
    }
    fun watch(module: JavaAudioDeviceModule, routing: MicrophoneRouting, invalid: () -> Unit): Boolean {
        clear()
        val record = record(module) ?: return false
        val current = generation.get()
        val changed = AudioRouting.OnRoutingChangedListener {
            if (generation.get() == current && !matches(module, routing)) invalid()
        }
        return runCatching {
            record.addOnRoutingChangedListener(changed, Handler(Looper.getMainLooper()))
            watched = record; listener = changed
            true
        }.getOrDefault(false)
    }
    fun clear() {
        generation.incrementAndGet() // Ignore callbacks queued before mute/teardown.
        val old = watched; val callback = listener
        watched = null; listener = null
        if (old != null && callback != null) runCatching { old.removeOnRoutingChangedListener(callback) }
    }
}
