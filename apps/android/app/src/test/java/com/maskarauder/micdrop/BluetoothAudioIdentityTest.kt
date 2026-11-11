package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class BluetoothAudioIdentityTest {
    private val headset = "AA:BB:CC:DD:EE:10"
    private val car = "AA:BB:CC:DD:EE:20"
    private val cached = "XX:XX:XX:XX:EE:10"

    @Test fun aCachedMaskedAddressRequiresOnePairedIdentity() {
        assertEquals(headset.lowercase(), BluetoothAudioIdentity.visibleAddress(cached, listOf(car, headset)))
        assertEquals(headset.lowercase(), BluetoothAudioIdentity.visibleAddress(cached.lowercase(), listOf(headset)))
        assertEquals(cached, BluetoothAudioIdentity.visibleAddress(cached, emptyList()))
        assertEquals(cached, BluetoothAudioIdentity.visibleAddress(cached, listOf(car)))
        // Repeated/case-varied entries are still one physical address.
        assertEquals(headset.lowercase(), BluetoothAudioIdentity.visibleAddress(cached, listOf(headset, headset.lowercase())))
    }

    @Test fun suffixCollisionsNeverChooseTheFirstPairedHeadset() {
        val collision = "11:22:33:44:EE:10"
        for (paired in listOf(listOf(headset, collision), listOf(collision, headset)))
            assertEquals(cached, BluetoothAudioIdentity.visibleAddress(cached, paired))
    }

    @Test fun emptyOpaqueAndSentinelAddressesCannotBeReconstructed() {
        for (address in listOf("", "group:1", "00:00:00:00:00:00", "02:00:00:00:00:00",
                "XX:XX:XX:EE:10", "XX:XX:XX:XX:XX:10")) {
            assertEquals(address, BluetoothAudioIdentity.visibleAddress(address, listOf(headset)))
            assertNull(BluetoothAudioIdentity.stableAddress(address))
            assertFalse(BluetoothAudioIdentity.sameRedactedAddress(address, headset))
        }
        assertEquals("XX:XX:XX:XX:00:00", BluetoothAudioIdentity.visibleAddress("XX:XX:XX:XX:00:00",
            listOf("00:00:00:00:00:00", "02:00:00:00:00:00")))
    }

    @Test fun visibleAddressesDoNotBorrowIdentityFromThePairedList() {
        assertEquals(car.lowercase(), BluetoothAudioIdentity.visibleAddress(car, listOf(headset)))
        assertFalse(BluetoothAudioIdentity.sameRedactedAddress(cached, car))
        assertTrue(BluetoothAudioIdentity.sameRedactedAddress(cached, headset))
        assertFalse(BluetoothAudioIdentity.sameRedactedAddress(cached, cached))
    }
}
