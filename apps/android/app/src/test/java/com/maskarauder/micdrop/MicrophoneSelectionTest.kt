package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class MicrophoneSelectionTest {
    private fun source(id: Int, type: Int, address: String = "") = MicrophoneDevice(id, type, true, address)
    private fun sink(id: Int, type: Int, address: String = "") = MicrophoneDevice(id, type, false, address)

    @Test fun outputOnlyDevicesCannotBeChosenAsMicrophones() {
        for (type in listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_BROADCAST, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                AudioDeviceInfo.TYPE_HEARING_AID))
            assertNull(MicrophoneKind.forType(type))
        assertNull(MicrophoneSelection().resolveInput(listOf(sink(1, AudioDeviceInfo.TYPE_BUILTIN_MIC))))
    }

    @Test fun directSelectionNeverFallsBackToAnotherAttachedInput() {
        val first = source(10, AudioDeviceInfo.TYPE_USB_HEADSET)
        val second = source(20, AudioDeviceInfo.TYPE_USB_HEADSET)
        val phone = source(1, AudioDeviceInfo.TYPE_BUILTIN_MIC)
        val selected = MicrophoneSelection(MicrophoneKind.USB, 20, AudioDeviceInfo.TYPE_USB_HEADSET)
        assertEquals(second, selected.resolveInput(listOf(phone, first, second)))
        assertNull(selected.resolveInput(listOf(phone, first)))
        assertFalse(selected.matchesInput(first, second))
        assertFalse(selected.matchesInput(phone, second))
        assertTrue(selected.matchesInput(second, second))
        assertEquals(phone, MicrophoneSelection().resolveInput(listOf(first, phone)))
    }

    @Test fun bluetoothRequiresTheChosenSinkAndItsMatchingSource() {
        for ((kind, type) in listOf(MicrophoneKind.SCO to AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                MicrophoneKind.LE to AudioDeviceInfo.TYPE_BLE_HEADSET)) {
            val selected = MicrophoneSelection(kind, 30, type)
            val output = sink(30, type, "selected")
            val wrong = source(40, type, "other")
            val input = source(50, type, "selected")
            assertEquals(input, selected.resolveInput(listOf(wrong, input), output))
            assertNull(selected.resolveInput(listOf(input), sink(31, type, "selected")))
            assertNull(selected.resolveInput(listOf(wrong), output))
            assertNull(selected.resolveInput(listOf(input), null))
            assertFalse(selected.matchesOutput(input)) // Source/sink have distinct IDs and roles.
            assertTrue(selected.matchesOutput(output))
            assertFalse(selected.matchesInput(wrong, input))
            assertFalse(selected.matchesInput(source(50, AudioDeviceInfo.TYPE_BUILTIN_MIC), input))
        }
    }

    @Test fun missingBluetoothAddressMustBeUnambiguous() {
        val type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        val selected = MicrophoneSelection(MicrophoneKind.SCO, 30, type)
        val first = source(40, type)
        val second = source(50, type)
        assertEquals(first, selected.resolveInput(listOf(first), sink(30, type)))
        assertNull(selected.resolveInput(listOf(first, second), sink(30, type)))
        assertNull(selected.resolveInput(listOf(first), sink(30, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)))
    }

    @Test fun aNewCarConnectionDoesNotAuthorizeItsSinkOrMicrophone() {
        val type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        val headset = MicrophoneSelection(MicrophoneKind.SCO, 30, type)
        val selectedSink = sink(30, type, "headset")
        val selectedSource = source(40, type, "headset")
        val carSink = sink(50, type, "car")
        val carSource = source(60, type, "car")
        assertEquals(selectedSource, headset.resolveInput(listOf(carSource, selectedSource), selectedSink))
        assertNull(headset.resolveInput(listOf(carSource, selectedSource), carSink))
        assertFalse(headset.matchesOutput(carSink))
        assertFalse(headset.matchesInput(carSource, selectedSource))
        // Removing the selected source never falls back to another SCO input.
        assertNull(headset.resolveInput(listOf(carSource), selectedSink))
        // Initial selection requires this exact port. Only an already active
        // session's separately pinned HeadsetEndpoint can authorize a new port.
        assertFalse(headset.matchesOutput(sink(31, type, "headset")))
    }

    @Test fun leStereoDoesNotChangeClassicOrDirectInputProfiles() {
        for (kind in listOf(MicrophoneKind.BUILT_IN, MicrophoneKind.WIRED, MicrophoneKind.USB, MicrophoneKind.SCO)) {
            for (stereo in listOf(true, false)) {
                val selection = MicrophoneSelection(kind = kind, leStereo = stereo)
                assertFalse(selection.leStereoRequested)
                assertEquals(kind == MicrophoneKind.SCO, selection.voiceInput)
                assertEquals(if (kind == MicrophoneKind.SCO) 1 else 2, selection.outputChannels)
            }
        }
        val le = MicrophoneSelection(MicrophoneKind.LE, 30, AudioDeviceInfo.TYPE_BLE_HEADSET)
        assertTrue(le.leStereoRequested)
        assertFalse(le.voiceInput)
        assertTrue(le.acceptsOutputChannels(2))
        assertFalse(le.acceptsOutputChannels(1))
        assertFalse(le.acceptsOutputChannels(0))
        val mono = le.copy(leStereo = false)
        assertFalse(mono.leStereoRequested)
        assertTrue(mono.voiceInput)
        assertTrue(mono.acceptsOutputChannels(1))
        assertFalse(mono.acceptsOutputChannels(2))
        assertTrue(mono.sameDevice(le))
        assertFalse(le.sameDevice(le.copy(deviceId = 31)))
    }

    @Test fun explicitHeadsetChoiceRetainsIdentityForAFreshManualConnection() {
        val type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        val original = sink(30, type, "AA:BB:CC:DD:EE:10")
        val selected = requireNotNull(MicrophoneSelection(MicrophoneKind.SCO, 30, type)
            .refreshBluetooth(listOf(original)))
        assertNotNull(selected.headsetEndpoint)
        assertNull(selected.refreshBluetooth(emptyList()))
        val recreated = original.copy(id = 31)
        val car = sink(50, type, "AA:BB:CC:DD:EE:20")
        val refreshed = requireNotNull(selected.refreshBluetooth(listOf(car, recreated)))
        assertEquals(31, refreshed.deviceId)
        assertSame(selected.headsetEndpoint, refreshed.headsetEndpoint)
        assertEquals(source(41, type, original.address), refreshed.resolveInput(
            listOf(source(51, type, car.address), source(41, type, original.address)), recreated))
        assertNull(refreshed.refreshBluetooth(listOf(car)))
        assertNull(refreshed.refreshBluetooth(listOf(recreated, original.copy(id = 32))))
    }

    @Test fun manualRefreshPreservesTheProfileAndCannotInferIdentityFromOneNewPort() {
        val original = sink(30, AudioDeviceInfo.TYPE_BLE_HEADSET, "AA:BB:CC:DD:EE:10")
        val le = requireNotNull(MicrophoneSelection(MicrophoneKind.LE, 30, original.type, false)
            .refreshBluetooth(listOf(original)))
        val refreshed = requireNotNull(le.refreshBluetooth(listOf(original.copy(id = 31))))
        assertFalse(refreshed.leStereo)
        assertNull(le.refreshBluetooth(listOf(original.copy(type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO))))
        for (address in listOf("", "02:00:00:00:00:00")) {
            val unknown = requireNotNull(MicrophoneSelection(MicrophoneKind.LE, 30, original.type)
                .refreshBluetooth(listOf(original.copy(address = address))))
            assertNull(unknown.refreshBluetooth(listOf(original.copy(id = 31, address = address))))
        }
        // A saved port without a live identity can only initialize that exact port.
        assertNull(MicrophoneSelection(MicrophoneKind.LE, 30, original.type)
            .refreshBluetooth(listOf(original.copy(id = 31))))
        assertNull(MicrophoneSelection().refreshBluetooth(listOf(original)))
    }

    @Test fun explicitMonoCapabilitiesRejectStereoWithoutChangingTheSelectedDevice() {
        val le = MicrophoneSelection(MicrophoneKind.LE, 30, AudioDeviceInfo.TYPE_BLE_HEADSET)
        assertTrue(le.supportsOutputChannels(intArrayOf())) // Unspecified by Android.
        assertTrue(le.supportsOutputChannels(intArrayOf(1, 2)))
        assertTrue(le.supportsOutputChannels(intArrayOf(2)))
        assertFalse(le.supportsOutputChannels(intArrayOf(1)))
        assertTrue(le.copy(leStereo = false).supportsOutputChannels(intArrayOf(1)))
        // Compatibility stays on LE. It cannot authorize SCO or a phone mic.
        for (selection in listOf(le, le.copy(leStereo = false))) {
            assertFalse(selection.matchesOutput(sink(30, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)))
            assertNull(selection.resolveInput(listOf(source(40, AudioDeviceInfo.TYPE_BUILTIN_MIC)),
                sink(30, AudioDeviceInfo.TYPE_BLE_HEADSET)))
        }
    }

    @Test fun anExplicitStartAfterNearbyConsentPinsACachedMaskedPortBeforeRecreation() {
        val type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        val address = "AA:BB:CC:DD:EE:10"
        val masked = sink(30, type, "XX:XX:XX:XX:EE:10")
        val selected = requireNotNull(MicrophoneSelection(MicrophoneKind.SCO, 30, type)
            .refreshBluetooth(listOf(masked)))
        val revealed = masked.copy(address = BluetoothAudioIdentity.visibleAddress(masked.address,
            listOf(address, "AA:BB:CC:DD:EE:20")))
        assertNull(selected.refreshBluetooth(listOf(revealed))) // Idle refresh cannot change its identity.
        assertNull(selected.refreshBluetooth(listOf(revealed.copy(id = 31)), revealAddress = true))
        val ready = requireNotNull(selected.refreshBluetooth(listOf(revealed), revealAddress = true))
        assertTrue(requireNotNull(ready.headsetEndpoint).hasStableAddress)
        val recreated = revealed.copy(id = 31)
        val car = sink(50, type, "AA:BB:CC:DD:EE:20")
        val refreshed = requireNotNull(ready.refreshBluetooth(listOf(car, recreated)))
        assertEquals(31, refreshed.deviceId)
        assertSame(ready.headsetEndpoint, refreshed.headsetEndpoint)
        assertNull(ready.refreshBluetooth(listOf(car)))
        assertEquals(source(41, type, recreated.address), refreshed.resolveInput(
            listOf(source(61, type, car.address), source(41, type, recreated.address)), recreated))
    }
}
