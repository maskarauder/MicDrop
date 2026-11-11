package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class OutputSelectionTest {
    private val bluetooth = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
    private val original = OutputDevice(40, bluetooth, true, "synthetic-left")
    private val selection = OutputSelection(OutputKind.BLUETOOTH, original.id, original.type, original.address)

    @Test fun onlyTheChosenPortAndAddressCanResolveOrVerify() {
        assertEquals(original, selection.resolve(listOf(original, original.copy(id = 41))))
        assertNull(selection.resolve(listOf(original.copy(id = 41))))
        assertNull(selection.resolve(listOf(original.copy(address = "synthetic-other"))))
        assertNull(selection.resolve(listOf(original.copy(sink = false))))
        assertTrue(selection.verifies(listOf(original)))
        assertFalse(selection.verifies(emptyList()))
        assertFalse(selection.verifies(listOf(original, original.copy(id = 41))))
        assertFalse(selection.verifies(listOf(original.copy(type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO))))
    }

    @Test fun defaultRoutingAndTheBuiltInSpeakerHaveDifferentContracts() {
        val speaker = OutputDevice(2, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, true)
        val phone = OutputSelection.restored(OutputKind.PHONE)
        assertEquals(speaker, phone.resolve(listOf(speaker, original)))
        assertTrue(phone.verifies(listOf(speaker)))
        assertFalse(phone.verifies(listOf(original)))
        assertFalse(phone.verifies(listOf(speaker, original)))
        assertTrue(OutputSelection().verifies(listOf(original)))
        assertTrue(OutputSelection().verifies(listOf(speaker)))
        assertFalse(OutputSelection().verifies(emptyList()))
        assertNull(OutputSelection.restored(OutputKind.BLUETOOTH).resolve(listOf(original)))
    }

    @Test fun mediaRoutesDoNotPretendCommunicationProfilesAreMediaSinks() {
        assertNull(OutputKind.forType(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertNull(OutputKind.forType(AudioDeviceInfo.TYPE_BUILTIN_MIC))
        assertEquals(OutputKind.LE, OutputKind.forType(AudioDeviceInfo.TYPE_BLE_HEADSET))
        assertEquals(OutputKind.HEARING_AID, OutputKind.forType(AudioDeviceInfo.TYPE_HEARING_AID))
        assertEquals(OutputKind.BLUETOOTH, OutputKind.forType(bluetooth))
    }

    @Test fun lateCallbacksAndVerificationCannotReleaseANewerChoiceOrStop() {
        val route = OutputRouteChange(selection)
        val old = route.ticket
        route.beginCheck(old, 100)
        assertTrue(route.request(OutputSelection.restored(OutputKind.PHONE)))
        assertFalse(route.verified(old))
        assertFalse(route.lost(old))
        assertTrue(route.pending)
        val current = route.ticket
        val gate = AudioOutputGate(enabled = false, held = true)
        if (route.verified(current)) gate.verified()
        assertTrue(gate.muted) // Route completion preserves user silence.
        gate.stop(); route.stop()
        assertFalse(route.request(selection))
        assertFalse(route.verified(current))
        gate.request(true); gate.verified()
        assertTrue(gate.muted)
    }

    @Test fun routeVerificationHasABoundedWindowAndDefaultClearsAPin() {
        val route = OutputRouteChange(selection, 5000)
        route.beginCheck(route.ticket, 1000)
        route.beginCheck(route.ticket, 4000)
        assertFalse(route.expired(5999))
        assertTrue(route.expired(6000))
        assertTrue(route.request(OutputSelection()))
        assertFalse(route.expired(9000))
        assertTrue(route.pending) // Explicitly clearing the old track preference still needs an acknowledgment.
        assertTrue(route.verified(route.ticket))
        assertFalse(route.lost(route.ticket)) // Default delegates later media routing to Android.
    }

    @Test fun anUnexpectedPinnedRouteLossCannotBeVerifiedAway() {
        val route = OutputRouteChange(selection)
        assertTrue(route.verified(route.ticket))
        assertTrue(route.lost(route.ticket))
        assertTrue(route.invalid)
        assertFalse(route.verified(route.ticket))
        assertTrue(route.request(OutputSelection.restored(OutputKind.PHONE)))
        assertFalse(route.invalid)
        assertTrue(route.pending)
    }
}
