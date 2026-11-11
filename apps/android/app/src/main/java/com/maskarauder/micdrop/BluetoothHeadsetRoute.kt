package com.maskarauder.micdrop

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHeadset
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context

// AudioManager can list only the newly active classic Bluetooth headset.
// Public HFP voice-audio requests name a connected headset directly. This
// optional adapter is opened only for an explicitly started SCO microphone.
@SuppressLint("MissingPermission") // Every operation rechecks Nearby Devices consent.
internal class BluetoothHeadsetRoute(private val context: Context) {
    private val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val lock = Any()
    private var closed = false
    private var proxy: BluetoothHeadset? = null
    private val listener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, connection: BluetoothProfile) {
            if (profile != BluetoothProfile.HEADSET || connection !is BluetoothHeadset) return
            val dispose = synchronized(lock) {
                if (closed) true else { proxy = connection; false }
            }
            if (dispose) runCatching { adapter?.closeProfileProxy(BluetoothProfile.HEADSET, connection) }
        }
        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.HEADSET) synchronized(lock) { proxy = null }
        }
    }

    fun open() {
        if (BluetoothAudioIdentity.permitted(context))
            runCatching { adapter?.getProfileProxy(context, listener, BluetoothProfile.HEADSET) }
    }

    fun connection(): ScoProfileConnection? {
        if (!BluetoothAudioIdentity.permitted(context)) return null
        val headset = synchronized(lock) { if (closed) null else proxy } ?: return null
        return object : ScoProfileConnection {
            private fun selected(address: String): BluetoothDevice? {
                if (!BluetoothAudioIdentity.permitted(context)) return null
                val expected = BluetoothAudioIdentity.stableAddress(address) ?: return null
                return headset.connectedDevices.singleOrNull {
                    BluetoothAudioIdentity.stableAddress(it.address) == expected
                }
            }
            override fun connectedAddresses(): List<String> =
                if (BluetoothAudioIdentity.permitted(context)) headset.connectedDevices.map { it.address } else emptyList()
            override fun supportsAudioRequest(address: String): Boolean =
                selected(address)?.let { headset.isVoiceRecognitionSupported(it) } == true
            override fun startAudio(address: String): Boolean =
                selected(address)?.let { headset.startVoiceRecognition(it) } == true
            override fun stopOwnedAudio(address: String) {
                // Cancel our accepted asynchronous request too, before audio
                // is connected. Passing the owned device never infers a new
                // headset from the current audio default.
                val device = selected(address) ?: return
                headset.stopVoiceRecognition(device)
            }
        }
    }

    fun close() {
        val connection = synchronized(lock) {
            closed = true
            val current = proxy; proxy = null; current
        }
        if (connection != null) adapter?.closeProfileProxy(BluetoothProfile.HEADSET, connection)
    }
}
