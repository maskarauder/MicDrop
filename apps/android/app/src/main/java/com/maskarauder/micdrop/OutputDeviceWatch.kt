package com.maskarauder.micdrop

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

// Inventory changes wake the worker even if Android has discarded the old
// AudioTrack (whose routing listener can no longer report a replacement).
// Ports stay local, and are used only to detect changes, never to choose a
// Bluetooth device in place of Android's default media route.
internal class OutputDeviceWatch(context: Context, private val changed: (Boolean) -> Unit) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var ports = emptySet<OutputDevice>()
    private val bluetooth = BluetoothMediaInventory()
    val bluetoothAvailable get() = bluetooth.available
    val bluetoothGeneration get() = bluetooth.generation
    private var registered = false
    private var initialAddedPending = false
    private val clearInitialAdded = Runnable { synchronized(lock) { initialAddedPending = false } }
    private val callback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(devices: Array<out AudioDeviceInfo>) {
            val isInitial = synchronized(lock) { initialAddedPending.also { initialAddedPending = false } }
            val added = !isInitial && devices.any { it.isSink && OutputKind.forType(it.type)?.bluetooth == true }
            refresh(false, added)
        }
        override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) =
            refresh(devices.any { it.isSink && OutputKind.forType(it.type)?.bluetooth == true })
    }
    private fun refresh(bluetoothRemoved: Boolean, bluetoothAdded: Boolean = false, notify: Boolean = true) {
        val shouldNotify = synchronized(lock) {
            val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter {
                it.isSink && OutputKind.forType(it.type) != null
            }
            // Android may reuse a port ID while its physical Bluetooth target changes.
            val latest = devices.map(OutputDevices::describe).toSet()
            bluetooth.update(latest, bluetoothAdded)
            val different = latest != ports
            ports = latest
            notify && (different || bluetoothRemoved || bluetoothAdded)
        }
        if (shouldNotify) changed(bluetoothRemoved)
    }
    fun start() {
        refresh(false, notify = false)
        val shouldRegister = synchronized(lock) {
            if (registered) false
            else {
                registered = true
                initialAddedPending = true
                true
            }
        }
        if (shouldRegister) {
            manager.registerAudioDeviceCallback(callback, mainHandler)
            mainHandler.post(clearInitialAdded)
        }
    }
    fun close() {
        mainHandler.removeCallbacks(clearInitialAdded)
        val wasRegistered = synchronized(lock) {
            initialAddedPending = false
            registered.also { registered = false }
        }
        if (wasRegistered) manager.unregisterAudioDeviceCallback(callback)
    }
}
