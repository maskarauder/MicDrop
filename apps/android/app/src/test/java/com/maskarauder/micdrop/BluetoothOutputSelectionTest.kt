package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class BluetoothOutputSelectionTest {
    private val address = "AA:BB:CC:DD:EE:10"
    private val otherAddress = "AA:BB:CC:DD:EE:20"
    private val original = OutputDevice(40, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, true, address)
    private val selected = OutputSelection(OutputKind.BLUETOOTH, original.id, original.type, address)

    @Test fun aRecreatedPortCanRestoreOnlyTheOriginalPhysicalHeadset() {
        val recreated = original.copy(id = 60, address = address.lowercase())
        val other = original.copy(id = 70, address = otherAddress)
        val restored = requireNotNull(selected.refresh(listOf(other, recreated)))
        assertEquals(recreated.id, restored.deviceId)
        assertEquals(address.lowercase(), restored.address)
        assertTrue(selected.sameEndpoint(restored))
        assertFalse(selected.matches(recreated)) // Must rebind before actual-route verification.
        assertTrue(restored.verifies(listOf(recreated)))
        assertFalse(restored.verifies(listOf(other)))
        assertFalse(restored.verifies(listOf(recreated, other)))
    }

    @Test fun aReusedPortIdCannotBorrowAnotherHeadsetsIdentity() {
        assertNull(selected.refresh(listOf(original.copy(address = otherAddress))))
        assertNull(selected.refresh(listOf(original.copy(address = ""))))
        assertNull(selected.refresh(listOf(original.copy(address = "XX:XX:XX:XX:EE:10"))))
        assertFalse(selected.sameEndpoint(selected.copy(address = otherAddress)))
    }

    @Test fun outputRecoveryCannotChangeTheBluetoothProfileOrUseAnInputPort() {
        for (type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_HEARING_AID)) {
            assertNull(selected.refresh(listOf(original.copy(id = 60, type = type))))
            assertFalse(selected.sameEndpoint(selected.copy(deviceType = type)))
        }
        assertNull(selected.refresh(listOf(original.copy(id = 60, sink = false))))
    }

    @Test fun ambiguousNewPortsCannotChooseTheFirstMatch() {
        val first = original.copy(id = 60)
        val second = original.copy(id = 70)
        assertNull(selected.refresh(listOf(first, second)))
        assertNull(selected.refresh(listOf(second, first)))
        // Keeping the existing, verified port does not require guessing a new one.
        assertEquals(original.id, requireNotNull(selected.refresh(listOf(original, first))).deviceId)
    }

    @Test fun permissionGrantMayRevealOnlyTheOriginalCachedMaskedPort() {
        val masked = selected.copy(address = "XX:XX:XX:XX:EE:10")
        val visible = original.copy(address = BluetoothAudioIdentity.visibleAddress(masked.address,
            listOf(address, otherAddress)))
        assertNull(masked.refresh(listOf(visible))) // Automatic callbacks cannot learn a new identity.
        val consented = requireNotNull(masked.refresh(listOf(visible), revealAddress = true))
        assertEquals(address.lowercase(), consented.address)
        assertNotNull(consented.refresh(listOf(visible.copy(id = 60))))
        assertNull(masked.refresh(listOf(visible.copy(id = 60)), revealAddress = true))
        assertNull(masked.refresh(listOf(visible.copy(address = otherAddress)), revealAddress = true))
    }

    @Test fun maskedSuffixCollisionsDoNotBecomeAStableOutputIdentity() {
        val masked = selected.copy(address = "XX:XX:XX:XX:EE:10")
        val ambiguous = original.copy(address = BluetoothAudioIdentity.visibleAddress(masked.address,
            listOf(address, "11:22:33:44:EE:10")))
        assertEquals(masked, masked.refresh(listOf(ambiguous), revealAddress = true))
        assertNull(masked.refresh(listOf(ambiguous.copy(id = 60)), revealAddress = true))
    }

    @Test fun missingOpaqueAndSentinelAddressesNeverInitializeANewPhysicalIdentity() {
        for (value in listOf("", "group:1", "00:00:00:00:00:00", "02:00:00:00:00:00")) {
            val addressless = selected.copy(address = value)
            assertEquals(addressless, addressless.refresh(listOf(original.copy(address = value)), revealAddress = true))
            assertNull(addressless.refresh(listOf(original), revealAddress = true))
            assertNull(addressless.refresh(listOf(original.copy(id = 60, address = value)), revealAddress = true))
        }
    }

    @Test fun leAndHearingAidOutputsRetainTheirOwnStableProfile() {
        for ((kind, type) in listOf(OutputKind.LE to AudioDeviceInfo.TYPE_BLE_HEADSET,
                OutputKind.LE to AudioDeviceInfo.TYPE_BLE_SPEAKER,
                OutputKind.HEARING_AID to AudioDeviceInfo.TYPE_HEARING_AID)) {
            val pin = OutputSelection(kind, 40, type, address)
            val recreated = OutputDevice(60, type, true, address.lowercase())
            val restored = requireNotNull(pin.refresh(listOf(recreated)))
            assertTrue(pin.sameEndpoint(restored))
            assertTrue(restored.verifies(listOf(recreated)))
            assertNull(pin.refresh(listOf(original.copy(id = 60))))
        }
    }
}
