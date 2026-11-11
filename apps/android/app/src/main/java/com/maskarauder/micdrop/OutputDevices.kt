package com.maskarauder.micdrop

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build

internal data class OutputChoice(val selection: OutputSelection, val title: String)

internal object OutputDevices {
    fun predictedMedia(context: Context): List<OutputDevice>? = if (Build.VERSION.SDK_INT >= 33) try {
        describe(context, context.getSystemService(AudioManager::class.java)
            .getAudioDevicesForAttributes(PlaybackEnvironment.attributes())).takeIf { it.isNotEmpty() }
    } catch (_: RuntimeException) { null } else null
    fun describe(device: AudioDeviceInfo) = OutputDevice(device.id, device.type, device.isSink,
        runCatching { device.address }.getOrDefault(""))
    fun describe(context: Context, devices: List<AudioDeviceInfo>): List<OutputDevice> {
        val raw = devices.map(::describe)
        val paired = if (raw.any { OutputKind.forType(it.type)?.bluetooth == true &&
            BluetoothAudioIdentity.needsPairedLookup(it.address) }) BluetoothAudioIdentity.pairedAddresses(context)
            else emptySet()
        return raw.map { if (OutputKind.forType(it.type)?.bluetooth == true)
            it.copy(address = BluetoothAudioIdentity.visibleAddress(it.address, paired)) else it }
    }
    fun refresh(context: Context, selection: OutputSelection, revealAddress: Boolean = false): OutputSelection? = try {
        lookup(context, selection, revealAddress)
    } catch (_: RuntimeException) { null }
    // Like refresh, but a failed device query throws instead of reading as a
    // missing port, so AudioSettingsStore does not forget a held port.
    fun lookup(context: Context, selection: OutputSelection, revealAddress: Boolean = false): OutputSelection? =
        if (selection.kind.bluetooth && !BluetoothAudioIdentity.permitted(context)) null
        else {
            val devices = context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
            selection.refresh(describe(context, devices), revealAddress)
        }
    fun resolve(context: Context, selection: OutputSelection): AudioDeviceInfo? {
        val devices = context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val chosen = selection.resolve(describe(context, devices.toList())) ?: return null
        return devices.singleOrNull { it.id == chosen.id && it.type == chosen.type }
    }
    fun available(context: Context, selection: OutputSelection): Boolean =
        !selection.explicit || refresh(context, selection) != null
    fun choices(context: Context): List<OutputChoice> {
        val choices = mutableListOf(OutputChoice(OutputSelection(), OutputKind.DEFAULT.label))
        val devices = context.getSystemService(AudioManager::class.java).getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val descriptors = describe(context, devices.toList()).associateBy { it.id }
        for (device in devices) {
            val kind = OutputKind.forType(device.type) ?: continue
            if (!device.isSink) continue
            val descriptor = requireNotNull(descriptors[device.id])
            val name = runCatching { device.productName.toString().filter { !it.isISOControl() }.take(60) }.getOrDefault("")
            val number = choices.count { it.selection.kind == kind } + 1
            choices.add(OutputChoice(OutputSelection(kind, device.id, device.type, descriptor.address),
                "${kind.label} $number${if (name.isEmpty() || kind == OutputKind.PHONE) "" else " · $name"}"))
        }
        return choices
    }
}
