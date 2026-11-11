package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class AudioDevicePreferencesTest {
    private val address = "12:34:56:78:90:ab"
    private val other = "ab:90:78:56:34:12"
    private val sco = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    private val a2dp = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
    private val input = MicrophoneSelection(MicrophoneKind.SCO, 10, sco,
        headsetEndpoint = HeadsetEndpoint(MicrophoneDevice(10, sco, false, address)))
    private val output = OutputSelection(OutputKind.BLUETOOTH, 20, a2dp, address)
    private val preferences = AudioPreferences(preferredInputKind = input.kind, preferredOutputKind = output.kind)

    @Test fun processRestartRebindsOnlyTheSameIdentityAndProfileToNewPorts() {
        val fields = AudioDevicePreferences.inputFields(input) + AudioDevicePreferences.outputFields(output)
        val coldInput = AudioDevicePreferences.input(fields, preferences)
        val coldOutput = AudioDevicePreferences.output(fields, preferences)
        assertEquals(-1, coldInput.deviceId); assertEquals(-1, coldOutput.deviceId)
        val reboundInput = coldInput.refreshBluetooth(listOf(MicrophoneDevice(101, sco, false, address)))!!
        val reboundOutput = coldOutput.refresh(listOf(OutputDevice(201, a2dp, true, address)))!!
        assertEquals(101, reboundInput.deviceId); assertEquals(201, reboundOutput.deviceId)
        assertEquals(fields, AudioDevicePreferences.inputFields(reboundInput) + AudioDevicePreferences.outputFields(reboundOutput))
        assertEquals(setOf("inputBluetoothAddress", "inputBluetoothType", "outputBluetoothAddress", "outputBluetoothType"), fields.keys)
        assertFalse(AudioPreferences.from(preferences.fields() + fields).fields().values.contains(address))
        assertFalse(fields.values.contains(10)); assertFalse(fields.values.contains(20))
    }

    @Test fun absentAmbiguousRedactedAndChangedProfilesRemainUnavailable() {
        val savedInput = AudioDevicePreferences.input(AudioDevicePreferences.inputFields(input), preferences)
        val savedOutput = AudioDevicePreferences.output(AudioDevicePreferences.outputFields(output), preferences)
        for (devices in listOf(emptyList(), listOf(MicrophoneDevice(10, sco, false, other)),
            listOf(MicrophoneDevice(101, sco, false, address), MicrophoneDevice(102, sco, false, address)),
            listOf(MicrophoneDevice(10, sco, false, "XX:XX:XX:78:90:AB")),
            listOf(MicrophoneDevice(10, AudioDeviceInfo.TYPE_BLE_HEADSET, false, address))))
            assertNull(savedInput.refreshBluetooth(devices, revealAddress = true))
        for (devices in listOf(emptyList(), listOf(OutputDevice(20, a2dp, true, other)),
            listOf(OutputDevice(201, a2dp, true, address), OutputDevice(202, a2dp, true, address)),
            listOf(OutputDevice(20, a2dp, true, "XX:XX:XX:78:90:AB")),
            listOf(OutputDevice(20, AudioDeviceInfo.TYPE_BLE_HEADSET, true, address))))
            assertNull(savedOutput.refresh(devices, revealAddress = true))
        // Failed matches do not erase the saved choice. A later explicit
        // connection can resolve the same endpoint after its return.
        assertNotNull(savedInput.refreshBluetooth(listOf(MicrophoneDevice(103, sco, false, address))))
        assertNotNull(savedOutput.refresh(listOf(OutputDevice(203, a2dp, true, address))))
    }

    @Test fun invalidSavedDataAndOldKindOnlySettingsNeverFallBackToAnotherDevice() {
        val valid = AudioDevicePreferences.inputFields(input) + AudioDevicePreferences.outputFields(output)
        for (fields in listOf(emptyMap(), valid + mapOf("inputBluetoothAddress" to "", "outputBluetoothAddress" to "02:00:00:00:00:00"),
            valid + mapOf("inputBluetoothType" to a2dp, "outputBluetoothType" to sco),
            valid + mapOf("inputBluetoothType" to "7", "outputBluetoothAddress" to 123))) {
            val savedInput = AudioDevicePreferences.input(fields, preferences)
            val savedOutput = AudioDevicePreferences.output(fields, preferences)
            assertEquals(MicrophoneKind.SCO, savedInput.kind)
            assertEquals(OutputKind.BLUETOOTH, savedOutput.kind)
            assertNull(savedInput.refreshBluetooth(listOf(MicrophoneDevice(10, sco, false, address)), true))
            assertNull(savedOutput.refresh(listOf(OutputDevice(20, a2dp, true, address)), true))
        }
    }

    @Test fun aNewChoiceClearsTheOldIdentityAndTemporarySpeakerRestoresDefault() {
        val noIdentity = AudioDevicePreferences.inputFields(input.copy(headsetEndpoint = null))
        assertTrue(noIdentity.values.all { it == null })
        assertTrue(AudioDevicePreferences.outputFields(output.copy(address = "")).values.all { it == null })
        assertTrue(AudioDevicePreferences.inputFields(MicrophoneSelection()).values.all { it == null })
        val temporary = OutputSelection.fallbackSpeaker()
        assertTrue(AudioDevicePreferences.outputFields(temporary).values.all { it == null })
        assertEquals(OutputSelection(), AudioDevicePreferences.output(emptyMap<String, Any>(),
            preferences.copy(preferredOutputKind = temporary.preferenceKind)))
        // A stored SCO identity cannot be reinterpreted as an LE or wired mic.
        val changed = AudioDevicePreferences.input(AudioDevicePreferences.inputFields(input),
            preferences.copy(preferredInputKind = MicrophoneKind.LE))
        assertNull(changed.refreshBluetooth(listOf(MicrophoneDevice(10, AudioDeviceInfo.TYPE_BLE_HEADSET, false, address))))
    }
}
