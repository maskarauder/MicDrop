package com.maskarauder.micdrop

import android.media.AudioDeviceInfo

internal enum class MicrophoneKind(val label: String, val bluetooth: Boolean = false) {
    BUILT_IN("built-in microphone"), WIRED("wired headset microphone"), USB("USB microphone"),
    SCO("Bluetooth SCO microphone", true), LE("Bluetooth LE microphone", true);

    companion object {
        fun forType(type: Int): MicrophoneKind? = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> BUILT_IN
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> WIRED
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY -> USB
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> SCO
            AudioDeviceInfo.TYPE_BLE_HEADSET -> LE
            else -> null // A2DP, headphones without a mic and BLE speakers are not inputs.
        }
    }
}

// IDs/addresses exist only for local comparisons. Reports contain fixed kind
// labels, never these descriptors or a device product name.
internal data class MicrophoneDevice(val id: Int, val type: Int, val source: Boolean, val address: String = "")

internal data class MicrophoneSelection(val kind: MicrophoneKind = MicrophoneKind.BUILT_IN,
    val deviceId: Int = 0, val deviceType: Int = AudioDeviceInfo.TYPE_BUILTIN_MIC,
    val leStereo: Boolean = true,
    val headsetEndpoint: HeadsetEndpoint? = null) {
    // LE Audio is a distinct transport, not another name for classic SCO.
    // Preserve SCO's verified mono voice path; request stereo for LE unless
    // the user explicitly chooses its mono compatibility profile.
    val leStereoRequested get() = kind == MicrophoneKind.LE && leStereo
    val voiceInput get() = kind == MicrophoneKind.SCO || (kind == MicrophoneKind.LE && !leStereo)
    val outputChannels get() = if (voiceInput) 1 else 2
    fun acceptsOutputChannels(channels: Int) = channels == outputChannels
    fun supportsOutputChannels(advertised: IntArray): Boolean =
        advertised.none { it > 0 } || outputChannels in advertised
    fun sameDevice(other: MicrophoneSelection): Boolean = kind == other.kind &&
        deviceId == other.deviceId && deviceType == other.deviceType

    fun matchesOutput(device: MicrophoneDevice?): Boolean = kind.bluetooth && device != null &&
        !device.source && device.id == deviceId && device.type == deviceType &&
        MicrophoneKind.forType(device.type) == kind

    // Refresh only the concrete port for a previously explicit headset choice.
    // This grants no capture/resume intent. A rebound port is never persisted.
    fun refreshBluetooth(devices: List<MicrophoneDevice>, revealAddress: Boolean = false): MicrophoneSelection? {
        if (!kind.bluetooth) return null
        val endpoint = if (revealAddress) headsetEndpoint?.withVisibleAddress(devices) else headsetEndpoint
        val chosen = (if (endpoint == null) devices.singleOrNull { matchesOutput(it) }
            else endpoint.resolve(devices)) ?: return null
        if (chosen.type != deviceType || MicrophoneKind.forType(chosen.type) != kind) return null
        return copy(deviceId = chosen.id, headsetEndpoint = endpoint ?: HeadsetEndpoint(chosen))
    }

    fun resolveInput(inputs: List<MicrophoneDevice>, communication: MicrophoneDevice? = null): MicrophoneDevice? {
        val candidates = inputs.filter { it.source && MicrophoneKind.forType(it.type) == kind }
        if (kind == MicrophoneKind.BUILT_IN) return candidates.firstOrNull()
        if (!kind.bluetooth) return candidates.singleOrNull { it.id == deviceId && it.type == deviceType }
        if (!matchesOutput(communication)) return null
        val matching = candidates.filter { it.type == deviceType &&
            (communication!!.address.isEmpty() || it.address == communication.address) }
        // Android chooses the matching source for a communication sink. When
        // its address is unavailable, require one unambiguous source of that
        // profile. Never pick the first of several Bluetooth microphones.
        return matching.singleOrNull()
    }

    fun matchesInput(actual: MicrophoneDevice?, expected: MicrophoneDevice?): Boolean =
        actual != null && expected != null && actual.source && MicrophoneKind.forType(actual.type) == kind &&
            (kind == MicrophoneKind.BUILT_IN || (actual.id == expected.id && actual.type == expected.type))
}
