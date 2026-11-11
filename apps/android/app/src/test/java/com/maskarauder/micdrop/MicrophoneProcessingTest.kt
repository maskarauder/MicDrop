package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class MicrophoneProcessingTest {
    private val requested = MicrophoneProcessing(true, true)
    @Test fun playbackNeverEnablesVoiceProcessing() {
        assertEquals(MicrophoneProcessing(), requested.effective(StreamMode.PLAYBACK, MicrophoneKind.BUILT_IN))
    }
    @Test fun microphoneOnlyHasNoEchoReference() {
        assertEquals(MicrophoneProcessing(false, true), requested.effective(StreamMode.MICROPHONE, MicrophoneKind.BUILT_IN))
    }
    @Test fun bluetoothKeepsAndroidAndHeadsetProcessingPolicy() {
        for (kind in listOf(MicrophoneKind.SCO, MicrophoneKind.LE))
            assertEquals(MicrophoneProcessing(), requested.effective(StreamMode.DUPLEX, kind))
    }
    @Test fun duplexVoiceOptionsNeverEnableGainOrChangeDesktopProcessing() {
        val effective = requested.effective(StreamMode.DUPLEX, MicrophoneKind.BUILT_IN)
        assertTrue(effective.echoCancellation); assertTrue(effective.noiseReduction)
        assertEquals("false", effective.constraints()["googAutoGainControl"])
        assertEquals("false", effective.constraints()["googHighpassFilter"])
        assertEquals("true", effective.constraints()["googEchoCancellation"])
    }
    @Test fun existingAndMalformedPreferencesKeepProcessingOff() {
        assertFalse(AudioPreferences.from(emptyMap<String, Any>()).echoCancellation)
        assertFalse(AudioPreferences.from(mapOf("echoCancellation" to "true", "noiseReduction" to 1)).noiseReduction)
        val saved = AudioPreferences(echoCancellation = true, noiseReduction = true)
        assertEquals(saved, AudioPreferences.from(saved.fields()))
    }
}
