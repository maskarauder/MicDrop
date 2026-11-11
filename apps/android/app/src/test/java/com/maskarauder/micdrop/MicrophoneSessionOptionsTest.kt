package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class MicrophoneSessionOptionsTest {
    @Test fun keepAliveIsCapturedAtTheExplicitConnect() {
        assertFalse(MicrophoneSessionOptions().keepMicrophoneActive)
        assertFalse(MicrophoneSessionOptions.forConnect(AudioPreferences()).keepMicrophoneActive)
        assertTrue(MicrophoneSessionOptions.forConnect(AudioPreferences(keepMicrophoneActive = true)).keepMicrophoneActive)
        // Other preferences, including the microphone toggle, are not session options.
        assertEquals(MicrophoneSessionOptions(), MicrophoneSessionOptions.forConnect(
            AudioPreferences(outputEnabled = false, microphoneEnabled = true, echoCancellation = true)))
    }

    @Test fun anEditDuringTheSessionWaitsForTheNextExplicitConnect() {
        for (initial in listOf(true, false)) {
            var saved = AudioPreferences(microphoneEnabled = true, keepMicrophoneActive = initial)
            // Input-switch replacements and duplex resumes reuse the Connect's options.
            val session = MicrophoneSessionOptions.forConnect(saved)
            saved = saved.copy(keepMicrophoneActive = !initial) // A Windows edit while connected.
            assertEquals(initial, session.keepMicrophoneActive)
            assertEquals(!initial, MicrophoneSessionOptions.forConnect(saved).keepMicrophoneActive)
        }
    }
}
