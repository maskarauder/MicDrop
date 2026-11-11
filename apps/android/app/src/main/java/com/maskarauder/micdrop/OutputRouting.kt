package com.maskarauder.micdrop

import android.media.AudioTrack
import android.media.AudioRouting
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.webrtc.audio.JavaAudioDeviceModule

// Pinned app-library fields expose this app's own track. Never write fields,
// release the track, or call hidden Android APIs. Routing invokes only public
// AudioTrack methods from the owning session worker, while PCM is gated.
internal object WebRtcOutputAccess {
    private val output = runCatching {
        JavaAudioDeviceModule::class.java.getDeclaredField("audioOutput").apply { isAccessible = true }
    }.getOrNull()
    private val track = runCatching {
        Class.forName("org.webrtc.audio.WebRtcAudioTrack").getDeclaredField("audioTrack").apply { isAccessible = true }
    }.getOrNull()
    fun track(module: JavaAudioDeviceModule?): AudioTrack? = runCatching {
        module?.let { output?.get(it) }?.let { track?.get(it) as? AudioTrack }
    }.getOrNull()
}

internal class WebRtcOutputRouting {
    @Volatile private var bound: AudioTrack? = null
    @Volatile private var boundTicket: Long? = null
    private var listener: AudioRouting.OnRoutingChangedListener? = null
    fun bind(module: JavaAudioDeviceModule, ticket: Long, selection: OutputSelection,
        context: android.content.Context, changed: () -> Unit): Boolean? {
        val track = WebRtcOutputAccess.track(module) ?: return null
        if (track === bound && boundTicket == ticket) return true
        clear()
        val device = if (selection.explicit) OutputDevices.resolve(context, selection) ?: return false else null
        if (!track.setPreferredDevice(device)) return false
        val callback = AudioRouting.OnRoutingChangedListener { changed() }
        track.addOnRoutingChangedListener(callback, Handler(Looper.getMainLooper()))
        bound = track; boundTicket = ticket; listener = callback
        return true
    }
    fun verifies(module: JavaAudioDeviceModule, ticket: Long, selection: OutputSelection,
        context: android.content.Context): Boolean {
        return devices(module, ticket, context)?.let(selection::verifies) == true
    }
    fun devices(module: JavaAudioDeviceModule, ticket: Long, context: android.content.Context): List<OutputDevice>? {
        val track = WebRtcOutputAccess.track(module) ?: return null
        if (track !== bound || ticket != boundTicket || track.playState != AudioTrack.PLAYSTATE_PLAYING) return null
        val devices = if (Build.VERSION.SDK_INT >= 36) track.routedDevices
            else listOfNotNull(track.routedDevice)
        return OutputDevices.describe(context, devices)
    }
    fun clear() {
        val track = bound; val callback = listener
        bound = null; listener = null; boundTicket = null
        if (track != null && callback != null) runCatching { track.removeOnRoutingChangedListener(callback) }
    }
}
