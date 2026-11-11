package com.maskarauder.micdrop

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager

internal class PlaybackEnvironment(context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)

    fun snapshot(outputAttributes: AudioAttributes = attributes()): EnvironmentSnapshot {
        // This is an OS prediction for MEDIA/MUSIC, not AudioTrack.getRoutedDevice.
        // Do not replace it with getDevices(): connected does not mean selected.
        val routes = if (Build.VERSION.SDK_INT >= 33) try {
            audio.getAudioDevicesForAttributes(outputAttributes).map { type(it.type) }.distinct().sorted()
                .takeIf { it.isNotEmpty() }
        } catch (_: RuntimeException) { null } else null
        val mode = when (audio.mode) {
            AudioManager.MODE_NORMAL -> "normal"
            AudioManager.MODE_IN_COMMUNICATION -> "communication"
            AudioManager.MODE_IN_CALL -> "call"
            AudioManager.MODE_RINGTONE -> "ringtone"
            else -> "other"
        }
        return EnvironmentSnapshot(BuildConfig.VERSION_NAME, BuildConfig.REVISION,
            safe(Build.MANUFACTURER), safe(Build.MODEL), safe(Build.VERSION.RELEASE), Build.VERSION.SDK_INT,
            routes, mode, power.isInteractive, power.isPowerSaveMode)
    }

    companion object {
        fun attributes(): AudioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
        private fun safe(value: String) = value.filter { !it.isISOControl() }.take(80)
        fun type(type: Int): String = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "phone speaker"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired headphones"
            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "USB audio"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP media"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth SCO voice"
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_BLE_BROADCAST -> "Bluetooth LE audio"
            AudioDeviceInfo.TYPE_HEARING_AID -> "hearing aid"
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> "HDMI"
            AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line output"
            else -> "other"
        }
    }
}
