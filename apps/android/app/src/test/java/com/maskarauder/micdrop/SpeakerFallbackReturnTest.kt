package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class SpeakerFallbackReturnTest {
    private val bluetooth = OutputDevice(40, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, true, "synthetic-headset")
    private val phone = OutputDevice(2, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, true)
    private val temporary = OutputSelection.fallbackSpeaker()

    @Test fun onlyAReturningBluetoothMediaInventoryAdvancesTheHandoff() {
        val inventory = BluetoothMediaInventory()
        inventory.update(listOf(phone, bluetooth.copy(sink = false),
            bluetooth.copy(type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO)))
        assertFalse(inventory.available)
        assertEquals(0L, inventory.generation)
        for (type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_HEARING_AID)) {
            val next = bluetooth.copy(type = type)
            inventory.update(listOf(next, phone))
            assertTrue(inventory.available)
            val generation = inventory.generation
            inventory.update(listOf(next, phone.copy(id = 3)))
            assertEquals(generation, inventory.generation)
            inventory.update(listOf(phone))
            assertFalse(inventory.available)
            assertEquals(generation, inventory.generation)
            inventory.update(listOf(next, phone))
            assertEquals(generation + 1, inventory.generation)
        }
    }

    @Test fun temporarySpeakerReturnsToDefaultOnlyAfterANewBluetoothAvailability() {
        val inventory = BluetoothMediaInventory()
        inventory.update(listOf(bluetooth, phone))
        val baseline = inventory.generation
        val route = OutputRouteChange(temporary)
        assertFalse(route.returnToDefault(route.ticket, inventory.available && inventory.generation > baseline))
        inventory.update(listOf(phone))
        assertFalse(route.returnToDefault(route.ticket, inventory.available && inventory.generation > baseline))
        inventory.update(listOf(bluetooth, phone))
        assertTrue(route.returnToDefault(route.ticket, inventory.available && inventory.generation > baseline))
        assertEquals(OutputSelection(), route.selection)
        assertTrue(route.pending)
        assertFalse(route.returnToDefault(route.ticket, true)) // One handoff, no repeated selection.
    }

    @Test fun removingAnotherDeviceOrChangingNonBluetoothInventoryDoesNotCauseReturn() {
        val inventory = BluetoothMediaInventory()
        val second = bluetooth.copy(id = 41, address = "synthetic-other")
        inventory.update(listOf(bluetooth, second, phone))
        val baseline = inventory.generation
        inventory.update(listOf(bluetooth, phone))
        assertTrue(inventory.available)
        assertEquals(baseline, inventory.generation)
        inventory.update(listOf(bluetooth, phone,
            OutputDevice(50, AudioDeviceInfo.TYPE_USB_HEADSET, true)))
        assertEquals(baseline, inventory.generation)
        inventory.update(listOf(bluetooth, second, phone))
        assertEquals(baseline + 1, inventory.generation)
    }

    @Test fun aBluetoothAddedCallbackCanReportReturnThroughAReusedPort() {
        val inventory = BluetoothMediaInventory()
        inventory.update(listOf(bluetooth, phone))
        val baseline = inventory.generation
        inventory.update(listOf(bluetooth, phone))
        assertEquals(baseline, inventory.generation)
        inventory.update(listOf(bluetooth, phone), bluetoothAdded = true)
        assertEquals(baseline + 1, inventory.generation)
        inventory.update(listOf(phone), bluetoothAdded = true)
        assertFalse(inventory.available)
        assertEquals(baseline + 1, inventory.generation)
    }

    @Test fun automaticReturnPreservesSilenceFocusAndRequiresFreshSpeakerConsentAfterLoss() {
        for (enabled in listOf(false, true)) {
            val route = OutputRouteChange(temporary)
            val gate = AudioOutputGate(enabled)
            val focus = MediaOutputFocus()
            val policy = DefaultOutputPolicy(temporary)
            route.verified(route.ticket)
            focus.lose(true)
            val speakerTicket = route.ticket
            assertTrue(route.returnToDefault(speakerTicket, true))
            gate.hold(); policy.select(route.selection, protectSpeakerOnReturn = true)
            assertFalse(route.verified(speakerTicket))
            policy.observe(listOf(OutputKind.PHONE))
            assertEquals(OutputPause.BLUETOOTH, policy.pause)
            assertTrue(gate.muted || policy.held || focus.pause != null)
            policy.observe(listOf(OutputKind.BLUETOOTH))
            assertTrue(route.verified(route.ticket)); gate.verified()
            assertEquals(enabled, gate.enabled)
            assertTrue(gate.muted || policy.held || focus.pause != null)
            assertTrue(focus.gain())
            assertEquals(!enabled, gate.muted || policy.held || focus.pause != null)
            policy.observe(listOf(OutputKind.PHONE))
            assertEquals(OutputPause.BLUETOOTH, policy.pause)
            assertTrue(policy.held) // Losing Bluetooth does not regrant speaker playback.
        }
    }

    @Test fun aPinnedChoiceStopOrNewRequestSupersedesAutomaticReturn() {
        val permanentPhone = OutputSelection.restored(OutputKind.PHONE)
        assertFalse(OutputRouteChange(permanentPhone).returnToDefault(0, true))
        val route = OutputRouteChange(temporary)
        val old = route.ticket
        route.request(permanentPhone)
        assertFalse(route.returnToDefault(old, true))
        assertFalse(route.returnToDefault(route.ticket, true))
        assertFalse(permanentPhone.acceptsUpdate(OutputSelection()))
        assertFalse(permanentPhone.acceptsUpdate(temporary))
        assertTrue(temporary.acceptsUpdate(OutputSelection()))
        assertFalse(temporary.acceptsUpdate(permanentPhone))
        route.request(temporary)
        val pending = route.ticket
        route.stop()
        assertFalse(route.returnToDefault(pending, true))
        assertFalse(route.verified(pending))
    }

    @Test fun speakerRepairCanBeSupersededWithoutAcceptingItsLateVerification() {
        val route = OutputRouteChange(temporary)
        route.verified(route.ticket)
        assertTrue(route.recoverSpeaker(route.ticket, 1000))
        val repair = route.ticket
        assertTrue(route.returnToDefault(repair, true))
        assertFalse(route.recovering)
        assertFalse(route.verified(repair))
        assertFalse(route.expired(6000))
    }
}
