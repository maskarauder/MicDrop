package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class AudioPreferencesTest {
    @Test fun temporarySpeakerRemembersDefaultWithoutPersistingItsActiveOverride() {
        val temporary = OutputSelection.fallbackSpeaker()
        assertEquals(OutputKind.PHONE, temporary.kind)
        assertEquals(OutputKind.DEFAULT, temporary.preferenceKind)
        val preferences = AudioPreferences(preferredOutputKind = temporary.preferenceKind)
        assertFalse(preferences.needsOutputSelection(temporary))
        val cold = OutputSelection.restored(AudioPreferences.from(preferences.fields()).preferredOutputKind)
        assertEquals(OutputSelection(), cold)
        assertFalse(cold.temporarySpeaker)
        assertTrue(preferences.needsOutputSelection(OutputSelection.restored(OutputKind.PHONE)))
    }

    @Test fun theNextExplicitConnectionUsesCurrentToggles() {
        val saved = AudioPreferences(outputEnabled = false, microphoneEnabled = true)
        assertEquals(StreamMode.MICROPHONE, saved.connectionMode)
        assertEquals(StreamMode.DUPLEX, saved.copy(outputEnabled = true).connectionMode)
        assertEquals(StreamMode.PLAYBACK, saved.copy(outputEnabled = true, microphoneEnabled = false).connectionMode)
        val silent = saved.copy(microphoneEnabled = false)
        assertEquals(StreamMode.PLAYBACK, silent.connectionMode)
        assertFalse(silent.outputEnabled)
        assertFalse(silent.connectionMode.microphone)
    }

    @Test fun rememberedSettingsContainNoDeviceIdentityOrCaptureTicket() {
        val original = AudioPreferences(false, true, false, false, MicrophoneKind.SCO, OutputKind.BLUETOOTH)
        assertEquals(original, AudioPreferences.from(original.fields()))
        assertEquals(setOf("outputEnabled", "microphoneEnabled", "fastRecovery", "leStereo", "preferredInputKind", "preferredOutputKind", "echoCancellation", "noiseReduction", "keepMicrophoneActive"),
            original.fields().keys)
        assertFalse(AudioPreferences().microphoneEnabled)
        assertEquals(StreamMode.PLAYBACK, AudioPreferences.from(emptyMap<String, Any>()).connectionMode)
    }

    @Test fun anExternalOutputPreferenceCannotBecomeAndroidDefaultAfterProcessDeath() {
        val saved = AudioPreferences(preferredOutputKind = OutputKind.BLUETOOTH)
        val cold = OutputSelection.restored(saved.preferredOutputKind)
        assertTrue(saved.needsOutputSelection(cold))
        val phone = saved.copy(preferredOutputKind = OutputKind.PHONE)
        assertFalse(phone.needsOutputSelection(OutputSelection.restored(phone.preferredOutputKind)))
        assertFalse(AudioPreferences.from(emptyMap<String, Any>()).needsOutputSelection(OutputSelection()))
        val malformed = AudioPreferences.from(mapOf("preferredOutputKind" to "unknown"))
        assertTrue(malformed.needsOutputSelection(OutputSelection()))
    }

    @Test fun aRememberedHeadsetKindCannotSilentlyChooseThePhoneMicrophone() {
        val saved = AudioPreferences(microphoneEnabled = true, preferredInputKind = MicrophoneKind.SCO)
        assertTrue(saved.needsInputSelection(MicrophoneSelection()))
        assertFalse(saved.copy(microphoneEnabled = false).needsInputSelection(MicrophoneSelection()))
        assertFalse(saved.needsInputSelection(MicrophoneSelection(MicrophoneKind.SCO)))
        assertTrue(saved.needsInputSelection(MicrophoneSelection(MicrophoneKind.LE)))
        assertFalse(saved.copy(preferredInputKind = MicrophoneKind.BUILT_IN).needsInputSelection(MicrophoneSelection()))
    }

    @Test fun malformedSettingsNeverEnableMicrophoneByCoercion() {
        val restored = AudioPreferences.from(mapOf("microphoneEnabled" to "true", "outputEnabled" to 0,
            "preferredInputKind" to "unknown"))
        assertFalse(restored.microphoneEnabled)
        assertTrue(restored.outputEnabled)
        assertNull(restored.preferredInputKind)
        assertTrue(restored.copy(microphoneEnabled = true).needsInputSelection(MicrophoneSelection()))
        assertEquals(restored, AudioPreferences.from(restored.fields()))
    }

    @Test fun windowsUnmuteAndPlayDesktopAudioLastOnlyForTheRunningSession() {
        // The phone muted, then Windows unmuted: the next Connect stays playback-only.
        val muted = AudioPreferences(outputEnabled = true, microphoneEnabled = false)
        assertEquals(muted, muted.afterMute(false, fromWindows = true))
        assertEquals(StreamMode.PLAYBACK, muted.afterMute(false, fromWindows = true).connectionMode)
        // Windows output edits never change the next Connect's mode.
        val duplex = AudioPreferences(outputEnabled = true, microphoneEnabled = true)
        assertEquals(StreamMode.DUPLEX, duplex.afterOutput(false, fromWindows = true).connectionMode)
        val microphone = duplex.copy(outputEnabled = false)
        assertEquals(StreamMode.MICROPHONE, microphone.afterOutput(true, fromWindows = true).connectionMode)
        val silent = AudioPreferences(outputEnabled = false, microphoneEnabled = false)
        assertEquals(silent, silent.afterOutput(true, fromWindows = true))
        assertFalse(silent.afterOutput(true, fromWindows = true).afterMute(false, fromWindows = true).microphoneEnabled)
    }

    @Test fun aWindowsMuteIsSavedLikeThePhonesOwnMute() {
        val duplex = AudioPreferences(outputEnabled = true, microphoneEnabled = true, keepMicrophoneActive = true)
        assertEquals(duplex.afterMute(true, fromWindows = false), duplex.afterMute(true, fromWindows = true))
        assertEquals(duplex.copy(microphoneEnabled = false), duplex.afterMute(true, fromWindows = true))
        assertEquals(StreamMode.PLAYBACK, duplex.afterMute(true, fromWindows = true).connectionMode)
        // A later Windows Unmute leaves the microphone off for the next Connect.
        assertFalse(duplex.afterMute(true, fromWindows = true).afterMute(false, fromWindows = true).microphoneEnabled)
    }

    @Test fun phoneTogglesAreStillRememberedForTheNextExplicitConnect() {
        val saved = AudioPreferences(outputEnabled = false, microphoneEnabled = false, echoCancellation = true,
            preferredOutputKind = OutputKind.PHONE)
        assertEquals(saved.copy(microphoneEnabled = true), saved.afterMute(false, fromWindows = false))
        assertEquals(saved.copy(outputEnabled = true), saved.afterOutput(true, fromWindows = false))
        assertEquals(StreamMode.DUPLEX, saved.afterMute(false, fromWindows = false).afterOutput(true, fromWindows = false).connectionMode)
        val duplex = saved.copy(outputEnabled = true, microphoneEnabled = true)
        assertEquals(saved.copy(outputEnabled = true), duplex.afterMute(true, fromWindows = false))
        assertEquals(StreamMode.MICROPHONE, duplex.afterOutput(false, fromWindows = false).connectionMode)
    }

    @Test fun captureRetentionIsOptInAndCannotEnableMicrophoneOrGrantConsent() {
        assertFalse(AudioPreferences.from(emptyMap<String, Any>()).keepMicrophoneActive)
        assertFalse(AudioPreferences.from(mapOf("keepMicrophoneActive" to "true")).keepMicrophoneActive)
        val saved = AudioPreferences(keepMicrophoneActive = true)
        val restored = AudioPreferences.from(saved.fields())
        assertEquals(saved, restored)
        assertFalse(restored.microphoneEnabled)
        assertEquals(StreamMode.PLAYBACK, restored.connectionMode)
    }
}
