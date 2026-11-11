package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class HeadsetEndpointTest {
    private val sco = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    private val le = AudioDeviceInfo.TYPE_BLE_HEADSET
    private val original = MicrophoneDevice(30, sco, false, "AA:BB:CC:DD:EE:10")

    @Test fun aTemporarilyMissingEndpointCanReturnOnItsOriginalPort() {
        val pinned = HeadsetEndpoint(original)
        assertNull(pinned.resolve(emptyList()))
        assertEquals(original, pinned.resolve(listOf(original)))
        assertTrue(pinned.matches(original, original))
    }

    @Test fun aUniqueReplacementPortRequiresTheOriginalAddressAndProfile() {
        val pinned = HeadsetEndpoint(original)
        val replacement = original.copy(id = 31, address = original.address.lowercase())
        val car = original.copy(id = 50, address = "AA:BB:CC:DD:EE:20")
        assertEquals(replacement, pinned.resolve(listOf(car, replacement)))
        assertTrue(pinned.matches(replacement, replacement))
        assertFalse(pinned.matches(original, replacement)) // Verify the actual new port too.
        assertFalse(pinned.matches(car, replacement))
        assertNull(pinned.resolve(listOf(original.copy(id = 31, type = le))))
        assertNull(pinned.resolve(listOf(original.copy(id = 31, source = true))))
        assertFalse(pinned.matches(replacement.copy(source = true), replacement))
        assertFalse(pinned.matches(replacement, replacement.copy(source = true)))
    }

    @Test fun aReusedPortIdCannotAuthorizeAnotherHeadset() {
        val pinned = HeadsetEndpoint(original)
        val carReusingId = original.copy(address = "AA:BB:CC:DD:EE:20")
        assertNull(pinned.resolve(listOf(carReusingId)))
        assertFalse(pinned.matches(carReusingId, original))
        assertFalse(pinned.matches(original, carReusingId))
        val replacement = original.copy(id = 31)
        assertEquals(replacement, pinned.resolve(listOf(carReusingId, replacement)))
    }

    @Test fun ambiguousReplacementPortsCannotBeSelected() {
        val pinned = HeadsetEndpoint(original)
        assertNull(pinned.resolve(listOf(original.copy(id = 31), original.copy(id = 32))))
        // An unchanged, unique original port still proves the explicit selection.
        assertEquals(original, pinned.resolve(listOf(original, original.copy(id = 31))))
    }

    @Test fun missingOrRedactedAddressesRequireTheOriginalExactPort() {
        for (address in listOf("", "00:00:00:00:00:00", "02:00:00:00:00:00", "group:1")) {
            val selected = original.copy(address = address)
            val pinned = HeadsetEndpoint(selected)
            assertEquals(selected, pinned.resolve(listOf(selected)))
            assertTrue(pinned.matches(selected, selected))
            assertNull(pinned.resolve(listOf(selected.copy(id = 31))))
            assertFalse(pinned.matches(selected.copy(id = 31), selected))
            assertNull(pinned.resolve(listOf(original))) // Same ID with a changed address is insufficient.
        }
    }

    @Test fun leRecoveryCannotSubstituteAScoOrOutputOnlyProfile() {
        val selected = original.copy(type = le)
        val pinned = HeadsetEndpoint(selected)
        assertNull(pinned.resolve(listOf(original)))
        assertNull(pinned.resolve(listOf(selected.copy(type = AudioDeviceInfo.TYPE_BLE_SPEAKER))))
        val replacement = selected.copy(id = 31)
        assertEquals(replacement, pinned.resolve(listOf(original, replacement)))
        assertTrue(pinned.matches(replacement, replacement))
        assertFalse(pinned.matches(original, replacement))
    }

    @Test fun diagnosticStatesDistinguishMissingIdentityFromMissingProfile() {
        val pinned = HeadsetEndpoint(original)
        assertEquals(HeadsetEndpointState.ORIGINAL, pinned.inspect(listOf(original)).state)
        assertEquals(HeadsetEndpointState.RECREATED, pinned.inspect(listOf(original.copy(id = 31))).state)
        assertEquals(HeadsetEndpointState.PROFILE_MISSING, pinned.inspect(emptyList()).state)
        assertEquals(HeadsetEndpointState.IDENTITY_MISSING,
            pinned.inspect(listOf(original.copy(id = 50, address = "AA:BB:CC:DD:EE:20"))).state)
        assertEquals(HeadsetEndpointState.AMBIGUOUS,
            pinned.inspect(listOf(original.copy(id = 31), original.copy(id = 32))).state)
        val unknown = HeadsetEndpoint(original.copy(address = ""))
        assertEquals(HeadsetEndpointState.ADDRESS_MISSING,
            unknown.inspect(listOf(original.copy(id = 31, address = ""))).state)
    }

    @Test fun permissionRevelationCanUpgradeOnlyTheStillSelectedMaskedPort() {
        val masked = original.copy(address = "XX:XX:XX:XX:EE:10")
        val pinned = HeadsetEndpoint(masked)
        assertFalse(pinned.hasStableAddress)
        val visible = pinned.withVisibleAddress(listOf(original))
        assertTrue(visible.hasStableAddress)
        assertEquals(original.copy(id = 31), visible.resolve(listOf(original.copy(id = 31))))
        assertSame(pinned, pinned.withVisibleAddress(listOf(original.copy(id = 31))))
        assertSame(pinned, pinned.withVisibleAddress(listOf(original.copy(source = true))))
        assertSame(pinned, pinned.withVisibleAddress(listOf(original.copy(type = le))))
        assertSame(pinned, pinned.withVisibleAddress(listOf(original, original)))
        assertSame(pinned, pinned.withVisibleAddress(listOf(original.copy(address = "AA:BB:CC:DD:EE:20"))))
        assertSame(visible, visible.withVisibleAddress(listOf(original.copy(address = "AA:BB:CC:DD:EE:20"))))
        for (address in listOf("", "02:00:00:00:00:00", "group:1")) {
            val unknown = HeadsetEndpoint(original.copy(address = address))
            assertSame(unknown, unknown.withVisibleAddress(listOf(original)))
        }
    }
}
