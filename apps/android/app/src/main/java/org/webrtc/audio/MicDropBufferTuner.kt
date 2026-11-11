package org.webrtc.audio

import android.media.AudioTrack

// Reuse the pinned WebRTC buffer policy in the standalone local output test.
// Keep this in Kotlin: the pinned AAR's class version is newer than JDK 17's
// javac accepts, but Kotlin and Android's D8 already support it for this app.
internal class MicDropBufferTuner {
    private val manager = LowLatencyAudioBufferManager()
    fun adjust(track: AudioTrack) = manager.maybeAdjustBufferSize(track)
}
