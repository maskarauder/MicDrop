package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

// These tests drive AudioSettingsStore, the Context-free core that every
// AppAudioSettings call delegates to, over an in-memory map with the same write
// rule as its SharedPreferences editor (a null value removes its key). The port
// lookups stand in for OutputDevices.lookup and MicrophoneRouting.lookup: the
// exact port for a direct device, the saved identity for Bluetooth. MainActivity's
// idle redraw assigns AppAudioSettings.input/output directly. That call site and
// the real Android port lists still need the device reproduction.
class AudioSettingsStoreTest {
    private val address = "12:34:56:78:90:ab"
    private val other = "ab:90:78:56:34:12"
    private val a2dp = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
    private val sco = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    private val speaker = OutputDevice(2, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, true)
    private val wired = OutputDevice(7, AudioDeviceInfo.TYPE_WIRED_HEADSET, true)
    private val usb = OutputDevice(8, AudioDeviceInfo.TYPE_USB_HEADSET, true, "card=1;device=0")
    private val usbOther = OutputDevice(11, AudioDeviceInfo.TYPE_USB_DEVICE, true, "card=2;device=0")
    private val hdmi = OutputDevice(9, AudioDeviceInfo.TYPE_HDMI, true)
    private val headset = OutputDevice(20, a2dp, true, address)
    private val outputs = listOf(speaker, wired, usb, usbOther, hdmi, headset)
    private val phoneMic = MicrophoneDevice(1, AudioDeviceInfo.TYPE_BUILTIN_MIC, true)
    private val wiredMic = MicrophoneDevice(9, AudioDeviceInfo.TYPE_WIRED_HEADSET, true)
    private val usbMic = MicrophoneDevice(10, AudioDeviceInfo.TYPE_USB_HEADSET, true)
    private val usbMicOther = MicrophoneDevice(12, AudioDeviceInfo.TYPE_USB_DEVICE, true)
    private val headsetSink = MicrophoneDevice(30, sco, false, address)
    private val inputs = listOf(phoneMic, wiredMic, usbMic, usbMicOther, headsetSink)

    private class Preferences(var fields: Map<String, Any?> = emptyMap()) {
        val store = AudioSettingsStore({ fields }) { changes -> fields = (fields + changes).filterValues { it != null } }
        // Process death: the same saved fields, nothing in memory.
        fun restart() = Preferences(fields)
    }

    private fun Preferences.output(devices: List<OutputDevice> = outputs): OutputSelection =
        store.output { it.refresh(devices) }
    private fun Preferences.input(devices: List<MicrophoneDevice> = inputs): MicrophoneSelection = store.input { selection ->
        if (selection.kind.bluetooth) selection.refreshBluetooth(devices)
        else selection.takeIf { it.resolveInput(devices) != null }
    }

    private fun chosen(device: OutputDevice) =
        OutputSelection(requireNotNull(OutputKind.forType(device.type)), device.id, device.type, device.address)
    private fun chosen(device: MicrophoneDevice, leStereo: Boolean = true) =
        MicrophoneSelection(requireNotNull(MicrophoneKind.forType(device.type)), device.id, device.type, leStereo)
    private fun headsetMic() = MicrophoneSelection(MicrophoneKind.SCO, 30, sco, headsetEndpoint = HeadsetEndpoint(headsetSink))

    @Test fun aWiredOutputChosenWhileIdleStaysBoundThroughConnect() {
        val prefs = Preferences()
        val selected = chosen(wired)
        prefs.store.selectOutput(selected)
        // The defect: the saved fields alone restore only the kind, which no port matches.
        val cold = prefs.restart().output()
        assertEquals(OutputSelection(OutputKind.WIRED, -1), cold)
        assertNull(cold.refresh(outputs))
        repeat(3) { assertEquals(selected, prefs.output()) } // Idle redraws.
        // Phone toggles and Windows applies update other options; the port stays.
        prefs.store.update { it.copy(outputEnabled = false, echoCancellation = true) }
        val current = prefs.output()
        assertEquals(selected, current)
        assertEquals(wired, current.resolve(outputs))
        // Connect's checkOutputChoice: same kind as saved, and the exact port refreshes.
        assertFalse(prefs.store.load().needsOutputSelection(current))
        assertEquals(current, current.refresh(outputs, revealAddress = true))
    }

    @Test fun usbAndOtherDirectOutputsComeBackAsTheExactPort() {
        for (device in listOf(usb, usbOther, hdmi)) {
            val prefs = Preferences()
            prefs.store.selectOutput(chosen(device))
            assertEquals(chosen(device), prefs.output())
            prefs.store.update { it.copy(microphoneEnabled = true, noiseReduction = true) }
            assertEquals(device, prefs.output().resolve(outputs))
        }
    }

    @Test fun wiredAndUsbMicrophonesStayBoundAndFollowTheSavedStereoOption() {
        for (device in listOf(wiredMic, usbMic)) {
            val prefs = Preferences()
            val selected = chosen(device)
            prefs.store.selectInput(selected)
            assertEquals(-1, prefs.restart().input().deviceId)
            repeat(3) { assertEquals(selected, prefs.input()) }
            assertEquals(device, prefs.input().resolveInput(inputs))
            prefs.store.update { it.copy(microphoneEnabled = true) }
            // Connect: the kind check passes and the exact port still resolves.
            val current = prefs.input()
            assertFalse(prefs.store.load().needsInputSelection(current))
            assertEquals(device, current.resolveInput(inputs))
            // Windows can edit LE stereo alone; the same port stays chosen.
            prefs.store.update { it.copy(leStereo = false) }
            assertEquals(selected.copy(leStereo = false), prefs.input())
        }
    }

    @Test fun aLaterSaveOfAnotherPortOfTheSameKindIsAdopted() {
        // Windows phone control and the services save the concrete port they chose.
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(usb))
        prefs.store.selectOutput(chosen(usbOther))
        assertEquals(usbOther, prefs.output().resolve(outputs))
        prefs.store.selectOutput(chosen(usb))
        assertEquals(usb, prefs.output().resolve(outputs))
        val mic = Preferences()
        mic.store.selectInput(chosen(usbMic))
        mic.store.selectInput(chosen(usbMicOther))
        assertEquals(chosen(usbMicOther), mic.input())
    }

    @Test fun aWiredOrUsbPortSavedByWindowsIsResolvableForConnect() {
        val prefs = Preferences()
        prefs.store.selectOutput(OutputSelection())
        assertEquals(OutputSelection(), prefs.output())
        prefs.store.selectOutput(chosen(usb)) // While the phone shows the default output.
        assertEquals(chosen(usb), prefs.output())
        assertFalse(prefs.store.load().needsOutputSelection(prefs.output()))
        assertEquals(usb, prefs.output().resolve(outputs))
        val mic = Preferences()
        mic.store.selectInput(chosen(wiredMic))
        assertEquals(chosen(wiredMic), mic.input())
    }

    @Test fun aSaveOfAnotherOutputReplacesTheHeldPort() {
        val bluetooth = OutputSelection(OutputKind.BLUETOOTH, 20, a2dp, address)
        for ((edit, expected) in listOf(OutputSelection() to OutputSelection(),
                OutputSelection.restored(OutputKind.PHONE) to OutputSelection.restored(OutputKind.PHONE),
                OutputSelection.fallbackSpeaker() to OutputSelection(), bluetooth to bluetooth,
                chosen(usb) to chosen(usb), OutputSelection(OutputKind.WIRED, -1) to OutputSelection(OutputKind.WIRED, -1))) {
            val prefs = Preferences()
            prefs.store.selectOutput(chosen(wired))
            prefs.store.selectOutput(edit)
            assertEquals(expected, prefs.output())
        }
    }

    @Test fun aSaveOfAnotherInputReplacesTheHeldPort() {
        for (edit in listOf(chosen(usbMic), MicrophoneSelection(), headsetMic(),
                MicrophoneSelection(MicrophoneKind.WIRED, -1, 0))) {
            val prefs = Preferences()
            prefs.store.selectInput(chosen(wiredMic))
            prefs.store.selectInput(edit)
            val loaded = prefs.input()
            assertEquals(edit.kind, loaded.kind)
            assertEquals(edit.deviceId, loaded.deviceId)
        }
    }

    @Test fun bluetoothChoicesStillFollowTheSavedIdentity() {
        val prefs = Preferences()
        prefs.store.selectOutput(OutputSelection(OutputKind.BLUETOOTH, 20, a2dp, address))
        assertEquals(21, prefs.output(outputs - headset + OutputDevice(21, a2dp, true, address)).deviceId)
        assertEquals(-1, prefs.output(outputs - headset + OutputDevice(22, a2dp, true, other)).deviceId)
        val mic = Preferences()
        mic.store.selectInput(headsetMic())
        assertEquals(30, mic.input().deviceId)
        assertEquals(31, mic.input(inputs - headsetSink + MicrophoneDevice(31, sco, false, address)).deviceId)
        // Without a stable address nothing is saved, so the port is not held either.
        val unstable = OutputDevice(20, a2dp, true)
        prefs.store.selectOutput(OutputSelection(OutputKind.BLUETOOTH, 20, a2dp))
        assertEquals(OutputSelection(OutputKind.BLUETOOTH, -1), prefs.output(outputs - headset + unstable))
        mic.store.selectInput(MicrophoneSelection(MicrophoneKind.SCO, 30, sco))
        assertEquals(-1, mic.input(inputs - headsetSink + MicrophoneDevice(30, sco, false)).deviceId)
    }

    @Test fun phoneSpeakerDefaultAndBuiltInMicrophoneAreUnchanged() {
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(speaker))
        assertEquals(OutputSelection.restored(OutputKind.PHONE), prefs.output())
        prefs.store.selectOutput(OutputSelection.fallbackSpeaker())
        assertEquals(OutputSelection(), prefs.output())
        prefs.store.selectInput(chosen(phoneMic))
        assertEquals(MicrophoneSelection(), prefs.input())
    }

    @Test fun anUnpluggedPortIsForgottenAndAReplugIsNeverBoundSilently() {
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(wired))
        val unplugged = outputs - wired
        val after = prefs.output(unplugged)
        assertEquals(OutputSelection(OutputKind.WIRED, -1), after)
        assertNull(after.refresh(unplugged)) // Connect asks for the output again.
        // Forgotten: not even a port with the original ID is bound again.
        assertEquals(OutputSelection(OutputKind.WIRED, -1), prefs.output())
        val replugged = unplugged + wired.copy(id = 12)
        assertEquals(OutputSelection(OutputKind.WIRED, -1), prefs.output(replugged))
        prefs.store.selectOutput(chosen(wired.copy(id = 12))) // A new explicit choice binds it.
        assertEquals(12, prefs.output(replugged).deviceId)

        val mic = Preferences()
        mic.store.selectInput(chosen(wiredMic))
        assertEquals(MicrophoneSelection(MicrophoneKind.WIRED, -1, 0), mic.input(inputs - wiredMic))
        assertEquals(MicrophoneSelection(MicrophoneKind.WIRED, -1, 0), mic.input())
    }

    @Test fun aKindChangeThroughUpdateClearsTheHeldPort() {
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(wired))
        prefs.store.selectInput(chosen(wiredMic))
        prefs.store.update { it.copy(preferredOutputKind = OutputKind.DEFAULT, preferredInputKind = MicrophoneKind.BUILT_IN) }
        prefs.store.update { it.copy(preferredOutputKind = OutputKind.WIRED, preferredInputKind = MicrophoneKind.WIRED) }
        assertEquals(OutputSelection(OutputKind.WIRED, -1), prefs.output())
        assertEquals(-1, prefs.input().deviceId)
    }

    @Test fun noPortIdIsSavedAndANewProcessHasOnlyTheKind() {
        for (device in listOf(wired, usb, hdmi)) {
            val prefs = Preferences()
            prefs.store.selectOutput(chosen(device))
            assertEquals(setOf("preferredOutputKind"), prefs.fields.keys)
            assertEquals(chosen(device), prefs.output())
            assertEquals(OutputSelection(chosen(device).kind, -1), prefs.restart().output())
        }
        for (device in listOf(wiredMic, usbMic)) {
            val prefs = Preferences()
            prefs.store.selectInput(chosen(device))
            assertEquals(setOf("preferredInputKind", "leStereo"), prefs.fields.keys)
            assertEquals(-1, prefs.restart().input().deviceId)
        }
    }

    @Test fun aFailedDeviceQueryIsNotAnUnplug() {
        // OutputDevices.lookup and MicrophoneRouting.lookup throw when AudioManager fails.
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(usb))
        var failures = 1
        assertEquals(OutputSelection(OutputKind.USB, -1),
            prefs.store.output { if (failures-- > 0) throw IllegalStateException("audioserver") else it.refresh(outputs) })
        assertEquals(chosen(usb), prefs.output())
        val mic = Preferences()
        mic.store.selectInput(chosen(usbMic))
        failures = 2
        assertEquals(MicrophoneSelection(MicrophoneKind.USB, -1, 0),
            mic.store.input { if (failures-- > 0) throw SecurityException("audioserver") else it })
        assertEquals(chosen(usbMic), mic.input())
    }

    @Test fun aSaveMadeDuringTheLookupIsKept() {
        // A service save can land while the activity's lookup is in flight.
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(usb))
        var first = true
        prefs.store.output { if (first) { first = false; prefs.store.selectOutput(chosen(usbOther)); null } else it.refresh(outputs) }
        assertEquals(chosen(usbOther), prefs.output())
        val mic = Preferences()
        mic.store.selectInput(chosen(usbMic))
        first = true
        mic.store.input { if (first) { first = false; mic.store.selectInput(chosen(usbMicOther)); null } else null }
        assertEquals(chosen(usbMicOther), mic.input())
    }

    @Test fun serviceReportsResaveOnlyWhileTheSavedChoiceIsTheSessionPort() {
        // The guards in PlaybackService/MicrophoneService.onOutputSelection and
        // onMicrophoneSelection: re-save the receiver's report only while the saved
        // choice is the session's port, never over a newer Windows save.
        val prefs = Preferences()
        prefs.store.selectOutput(chosen(usb))
        assertTrue(prefs.output().sameEndpoint(chosen(usb)))
        prefs.store.selectOutput(chosen(usb))
        assertEquals(chosen(usb), prefs.output())
        prefs.store.selectOutput(chosen(usbOther))
        assertFalse(prefs.output().sameEndpoint(chosen(usb)))
        val mic = Preferences()
        mic.store.selectInput(chosen(usbMic))
        assertTrue(mic.input().sameDevice(chosen(usbMic)))
        mic.store.selectInput(chosen(usbMic))
        assertEquals(chosen(usbMic), mic.input())
        mic.store.selectInput(chosen(usbMicOther))
        assertFalse(mic.input().sameDevice(chosen(usbMic)))
    }
}
