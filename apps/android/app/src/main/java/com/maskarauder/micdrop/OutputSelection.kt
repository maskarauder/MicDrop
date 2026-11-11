package com.maskarauder.micdrop

import android.media.AudioDeviceInfo

internal enum class OutputKind(val label: String) {
    DEFAULT("Android media output"), PHONE("phone speaker"), WIRED("wired headphones"),
    USB("USB audio output"), BLUETOOTH("Bluetooth media output"), LE("Bluetooth LE output"), HEARING_AID("hearing aid output"),
    OTHER("audio output");

    val bluetooth get() = this in listOf(BLUETOOTH, LE, HEARING_AID)

    companion object {
        fun forType(type: Int): OutputKind? = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> PHONE
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> WIRED
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_ACCESSORY -> USB
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> BLUETOOTH
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> LE
            AudioDeviceInfo.TYPE_HEARING_AID -> HEARING_AID
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC,
            AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> OTHER
            else -> null // Communication-only sinks follow the chosen microphone.
        }
    }
}

internal data class OutputDevice(val id: Int, val type: Int, val sink: Boolean, val address: String = "")

// Port IDs are process-local. Stable Bluetooth address/profile can be saved
// privately, but are never included in reports or exported options.
internal data class OutputSelection(val kind: OutputKind = OutputKind.DEFAULT, val deviceId: Int = 0,
    val deviceType: Int = 0, val address: String = "", val returnOnBluetooth: Boolean = false) {
    val explicit get() = kind != OutputKind.DEFAULT
    val temporarySpeaker get() = kind == OutputKind.PHONE && returnOnBluetooth
    val preferenceKind get() = if (temporarySpeaker) OutputKind.DEFAULT else kind
    fun matches(device: OutputDevice?): Boolean = device != null && device.sink &&
        OutputKind.forType(device.type) == kind && device.type == deviceType &&
        (if (kind == OutputKind.PHONE && deviceId == 0) true else device.id == deviceId) &&
        sameAddress(device.address)
    private fun sameAddress(value: String): Boolean = if (kind.bluetooth) {
        val stable = BluetoothAudioIdentity.stableAddress(address)
        if (stable != null) BluetoothAudioIdentity.stableAddress(value) == stable else address == value
    } else address.isEmpty() || address == value
    fun resolve(devices: List<OutputDevice>): OutputDevice? =
        if (!explicit) null else devices.singleOrNull { matches(it) }
    fun verifies(devices: List<OutputDevice>): Boolean = devices.isNotEmpty() &&
        (!explicit || devices.all { matches(it) })

    fun sameEndpoint(other: OutputSelection): Boolean = kind == other.kind && deviceType == other.deviceType &&
        (if (kind.bluetooth && BluetoothAudioIdentity.stableAddress(address) != null)
            sameAddress(other.address) else deviceId == other.deviceId && address == other.address)

    // A service may accept the receiver's automatic return only while it still
    // owns the temporary speaker choice. New explicit choices keep authority.
    fun acceptsUpdate(other: OutputSelection): Boolean =
        (sameEndpoint(other) && temporarySpeaker == other.temporarySpeaker) || (temporarySpeaker && !other.explicit)

    // A new Android port can identify the same Bluetooth headset only through
    // a unique stable address and the original media profile. Names, redacted
    // suffixes, and the mere presence of another headset are insufficient.
    fun refresh(devices: List<OutputDevice>, revealAddress: Boolean = false): OutputSelection? {
        if (!explicit) return this
        if (!kind.bluetooth) return takeIf { resolve(devices) != null }
        val profile = devices.filter { it.sink && it.type == deviceType && OutputKind.forType(it.type) == kind }
        val exact = profile.singleOrNull { it.id == deviceId }
        val stable = BluetoothAudioIdentity.stableAddress(address)
        if (stable != null) {
            val chosen = exact?.takeIf { sameAddress(it.address) } ?: profile.singleOrNull { sameAddress(it.address) }
                ?: return null
            return copy(deviceId = chosen.id, address = stable)
        }
        if (exact == null) return null
        if (revealAddress && BluetoothAudioIdentity.sameRedactedAddress(address, exact.address))
            return copy(address = requireNotNull(BluetoothAudioIdentity.stableAddress(exact.address)))
        return takeIf { matches(exact) }
    }

    companion object {
        fun fallbackSpeaker(): OutputSelection = restored(OutputKind.PHONE).copy(returnOnBluetooth = true)
        fun restored(kind: OutputKind?): OutputSelection = if (kind == OutputKind.PHONE)
            OutputSelection(OutputKind.PHONE, deviceType = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
            else OutputSelection() // An external port must be explicitly selected again.
    }
}

// Serialized with StreamReceiver's audio lock. A stale route callback or native
// track verification cannot release a newer selection's gate, or defeat Stop.
internal class OutputRouteChange(initial: OutputSelection, private val limitMs: Long = 5000,
    private val bluetoothRecoveryMs: Long = BLUETOOTH_RECOVERY_MS) {
    companion object { const val BLUETOOTH_RECOVERY_MS = 20_000L }
    var selection = initial
        private set
    var ticket = 0L
        private set
    var pending = initial.explicit
        private set
    var invalid = false
        private set
    var recovering = false
        private set
    private var deadline: Long? = null
    private var stopped = false
    fun request(value: OutputSelection): Boolean {
        if (stopped) return false
        selection = value; ticket++; pending = true; invalid = false; recovering = false; deadline = null
        return true
    }
    fun returnToDefault(id: Long, bluetoothReturned: Boolean): Boolean {
        if (stopped || id != ticket || !selection.temporarySpeaker || !bluetoothReturned) return false
        return request(OutputSelection())
    }
    fun trackStarted() {
        if (stopped) return
        ticket++; pending = true; invalid = false
        if (!recovering) deadline = null
    }
    fun recoverBluetooth(id: Long, nowMs: Long): Boolean {
        if (stopped || id != ticket || !selection.kind.bluetooth || recovering) return false
        ticket++; pending = true; invalid = false; recovering = true
        deadline = nowMs + bluetoothRecoveryMs
        return true
    }
    fun recoverSpeaker(id: Long, nowMs: Long): Boolean {
        if (stopped || id != ticket || selection.kind != OutputKind.PHONE || pending || recovering) return false
        ticket++; pending = true; invalid = false; recovering = true
        deadline = nowMs + limitMs
        return true
    }
    fun rebind(id: Long, value: OutputSelection): Boolean {
        if (stopped || id != ticket || !pending || !selection.sameEndpoint(value)) return false
        if (selection != value) { selection = value; ticket++ }
        return true // Retain the original recovery/selection deadline.
    }
    fun beginCheck(id: Long, nowMs: Long): Boolean {
        if (stopped || id != ticket || !pending) return false
        if (deadline == null) deadline = nowMs + limitMs
        return true
    }
    fun verified(id: Long): Boolean {
        if (stopped || id != ticket || !pending || invalid) return false
        pending = false; recovering = false; deadline = null
        return true
    }
    fun lost(id: Long): Boolean {
        if (stopped || id != ticket || pending || !selection.explicit) return false
        invalid = true
        return true
    }
    fun expired(nowMs: Long) = !stopped && pending && deadline?.let { nowMs >= it } == true
    fun stop() { stopped = true; pending = false; recovering = false; deadline = null }
}
