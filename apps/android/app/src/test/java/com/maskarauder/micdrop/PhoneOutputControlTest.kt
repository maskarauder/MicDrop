package com.maskarauder.micdrop

import android.Manifest
import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class PhoneOutputControlTest {
    private val usb = OutputSelection(OutputKind.USB, 9, AudioDeviceInfo.TYPE_USB_HEADSET)
    private val saved = OutputSelection(OutputKind.WIRED, -1)
    private val nearby = setOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN)
    private fun settings(mode: StreamMode, input: MicrophoneKind = MicrophoneKind.BUILT_IN) = PhoneLiveSettings(3,
        output = PhoneOutputControl.session(mode, usb), outputLive = PhoneOutputControl.live(mode, input))

    @Test fun playbackAndPhoneWiredOrUsbDuplexChangeTheRunningSessionsOutput() {
        val sessions = listOf(settings(StreamMode.PLAYBACK)) +
            listOf(MicrophoneKind.BUILT_IN, MicrophoneKind.WIRED, MicrophoneKind.USB).map { settings(StreamMode.DUPLEX, it) }
        for (live in sessions) {
            assertEquals("live", PhoneOutputControl.effect(live))
            assertEquals(usb, PhoneOutputControl.value(live, saved))
            // A session output missing from the device list is shown as in use, never as saved.
            assertEquals("USB audio output (in use)", PhoneOutputControl.unlisted(live, usb.kind, true))
            assertEquals("USB audio output (in use)", PhoneOutputControl.unlisted(live, usb.kind, false))
        }
    }

    @Test fun aHeadsetMicrophoneHoldsItsMediaChoiceForALaterInputSwitch() {
        for (input in listOf(MicrophoneKind.SCO, MicrophoneKind.LE)) {
            val live = settings(StreamMode.DUPLEX, input)
            assertEquals("next_connection", PhoneOutputControl.effect(live))
            assertEquals(usb, PhoneOutputControl.value(live, saved))
            assertEquals("USB audio output (after headset mic)", PhoneOutputControl.unlisted(live, usb.kind, true))
        }
    }

    @Test fun microphoneOnlyAndEndedSessionsKeepTheSavedNextConnectionChoice() {
        for (live in listOf(settings(StreamMode.MICROPHONE), settings(StreamMode.MICROPHONE, MicrophoneKind.SCO), null)) {
            assertNull(live?.output)
            assertEquals("next_connection", PhoneOutputControl.effect(live))
            assertEquals(saved, PhoneOutputControl.value(live, saved))
            assertEquals("wired headphones (saved)", PhoneOutputControl.unlisted(live, saved.kind, true))
            assertEquals("wired headphones (saved; unavailable)", PhoneOutputControl.unlisted(live, saved.kind, false))
        }
        assertEquals("next_connection", PhoneOutputControl.effect(PhoneLiveSettings(3, outputLive = true)))
    }

    @Test fun aWindowsOutputChoiceSwitchesARunningSessionAndIsSavedOnlyWithoutOne() {
        // Playback and every duplex input switch now; a headset microphone's switch holds the choice.
        for (live in listOf(settings(StreamMode.PLAYBACK)) + MicrophoneKind.entries.map { settings(StreamMode.DUPLEX, it) }) {
            assertEquals(OutputRoute.LIVE, PhoneOutputControl.route(live, saved))
            // The in-use output is not switched again, and nothing is saved for the next Connect.
            assertEquals(OutputRoute.NONE, PhoneOutputControl.route(live, usb.copy()))
            assertEquals(OutputRoute.NONE, PhoneOutputControl.route(live, null))
        }
        for (input in MicrophoneKind.entries) {
            val live = settings(StreamMode.MICROPHONE, input)
            for (chosen in listOf(saved, usb)) assertEquals(OutputRoute.SAVE, PhoneOutputControl.route(live, chosen))
            assertEquals(OutputRoute.NONE, PhoneOutputControl.route(live, null))
        }
    }

    @Test fun onlyASettledSessionAcceptsAWindowsOutputChoice() {
        for (phase in SessionPhase.entries) {
            val settled = phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)
            assertEquals("$phase", settled, PhoneOutputControl.accepts(phase, OutputKind.USB) { false })
            assertEquals("$phase", settled, PhoneOutputControl.accepts(phase, OutputKind.BLUETOOTH, nearby::contains))
        }
        // Setup and a switch already in progress are refused, not queued.
        for (phase in listOf(SessionPhase.CONNECTING, SessionPhase.SWITCHING))
            assertFalse(PhoneOutputControl.accepts(phase, OutputKind.PHONE) { true })
    }

    @Test fun aMissingNearbyDevicesPermissionRejectsInsteadOfPrompting() {
        for (kind in listOf(OutputKind.BLUETOOTH, OutputKind.LE, OutputKind.HEARING_AID)) {
            val queried = mutableSetOf<String>()
            assertFalse(PhoneOutputControl.accepts(SessionPhase.PLAYING, kind) { queried += it; false })
            assertTrue(queried.isNotEmpty() && queried.all { it in nearby })
            assertFalse(PhoneOutputControl.accepts(SessionPhase.PLAYING, kind) { it == Manifest.permission.BLUETOOTH_CONNECT })
            assertTrue(PhoneOutputControl.accepts(SessionPhase.PLAYING, kind, nearby::contains))
        }
        for (kind in listOf(OutputKind.DEFAULT, OutputKind.PHONE, OutputKind.WIRED, OutputKind.USB, OutputKind.OTHER))
            assertTrue(PhoneOutputControl.accepts(SessionPhase.PLAYING, kind) { false })
    }

    @Test fun aLiveChoiceIsAcknowledgedAsLiveAndTheEffectIsPartOfTheRevision() {
        val choices = listOf("usb" to "USB audio output 1", "speaker" to "phone speaker 1")
        fun snapshot(live: PhoneLiveSettings?) = PhoneSettingsSnapshot(true, listOf(PhoneSetting("audio.output",
            "Media output", "Audio", "choice", "usb", PhoneOutputControl.effect(live), choices = choices)))
        val playing = snapshot(settings(StreamMode.PLAYBACK))
        val headset = snapshot(settings(StreamMode.DUPLEX, MicrophoneKind.SCO))
        // An input switch to or from a headset microphone reloads a Windows editor.
        assertNotEquals(playing.revision, headset.revision)
        fun command(current: PhoneSettingsSnapshot, id: Char) = mapOf("id" to id.toString().repeat(32),
            "base_revision" to current.revision, "changes" to mapOf("audio.output" to "speaker"))
        var applied: Map<String, Any>? = null
        val ack = PhoneControlSession().receive(command(playing, 'a'), { playing }) { applied = it }
        assertEquals("applied", ack?.status)
        assertEquals("Live settings requested.", ack?.message)
        assertEquals(mapOf("audio.output" to "speaker"), applied)
        val held = PhoneControlSession().receive(command(headset, 'b'), { headset }) {}
        assertEquals("Saved. Next-connection settings apply after Stop and Connect.", held?.message)
        assertEquals("rejected", PhoneControlSession().receive(command(headset, 'c'), { playing }) { fail() }?.status)
        // A refused switch (setup, switching, permission) rejects the command.
        val refused = PhoneControlSession().receive(command(playing, 'd'), { playing }) { throw IllegalStateException() }
        assertEquals("rejected", refused?.status)
    }
}
