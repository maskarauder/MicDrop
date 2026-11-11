package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class SpeakerOutputRecoveryTest {
    private val phone = OutputSelection.restored(OutputKind.PHONE)
    private val speaker = OutputDevice(2, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, true)
    private val bluetooth = OutputDevice(40, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, true, "synthetic-headset")

    @Test fun transientSpeakerLossHasOneDeadlineAcrossCallbacksAndTrackRecreation() {
        val route = OutputRouteChange(phone)
        assertTrue(route.verified(route.ticket))
        val original = route.ticket
        assertTrue(route.recoverSpeaker(original, 1000))
        assertTrue(route.pending)
        assertTrue(route.recovering)
        assertFalse(route.invalid)
        assertFalse(route.verified(original))
        assertFalse(route.recoverSpeaker(route.ticket, 2000))
        route.trackStarted()
        route.beginCheck(route.ticket, 4000)
        assertFalse(route.recoverSpeaker(route.ticket, 5000))
        assertFalse(route.expired(5999))
        assertTrue(route.expired(6000))
    }

    @Test fun onlyTheSpeakerCanReleaseRepairAndUserSilenceIsPreserved() {
        for (enabled in listOf(false, true)) {
            val route = OutputRouteChange(phone)
            val gate = AudioOutputGate(enabled)
            route.verified(route.ticket)
            route.recoverSpeaker(route.ticket, 0); gate.hold()
            for (wrong in listOf(emptyList(), listOf(bluetooth), listOf(speaker, bluetooth))) {
                assertFalse(route.selection.verifies(wrong))
                assertTrue(route.pending)
                assertTrue(gate.muted)
            }
            assertTrue(route.selection.verifies(listOf(speaker)))
            assertTrue(route.verified(route.ticket)); gate.verified()
            assertFalse(route.recovering)
            assertFalse(route.pending)
            assertEquals(enabled, gate.enabled)
            assertEquals(!enabled, gate.muted)
        }
    }

    @Test fun aNewOutputOrStopSupersedesSpeakerRepairAndLateVerification() {
        val choices = listOf(OutputSelection(), OutputSelection(OutputKind.BLUETOOTH,
            bluetooth.id, bluetooth.type, bluetooth.address))
        for (next in choices) {
            val route = OutputRouteChange(phone)
            route.verified(route.ticket); route.recoverSpeaker(route.ticket, 0)
            val repair = route.ticket
            assertTrue(route.request(next))
            assertFalse(route.recovering)
            assertFalse(route.verified(repair))
            assertFalse(route.recoverSpeaker(repair, 1000))
            assertEquals(next, route.selection)
            assertFalse(route.expired(6000))
        }
        val stopped = OutputRouteChange(phone)
        stopped.verified(stopped.ticket); stopped.recoverSpeaker(stopped.ticket, 0)
        val repair = stopped.ticket
        stopped.stop(); stopped.trackStarted()
        assertFalse(stopped.recoverSpeaker(repair, 1000))
        assertFalse(stopped.verified(repair))
        assertFalse(stopped.request(OutputSelection()))
    }

    @Test fun speakerRepairDoesNotReplaceInitialVerificationOrExternalLossContracts() {
        val fresh = OutputRouteChange(phone)
        fresh.beginCheck(fresh.ticket, 1000)
        assertFalse(fresh.recoverSpeaker(fresh.ticket, 4000))
        assertTrue(fresh.expired(6000))
        val wired = OutputRouteChange(OutputSelection(OutputKind.WIRED, 3, AudioDeviceInfo.TYPE_WIRED_HEADPHONES))
        wired.verified(wired.ticket)
        assertFalse(wired.recoverSpeaker(wired.ticket, 0))
        assertTrue(wired.lost(wired.ticket))
        assertTrue(wired.invalid)
    }
}
