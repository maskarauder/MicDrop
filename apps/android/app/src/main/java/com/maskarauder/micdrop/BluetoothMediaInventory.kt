package com.maskarauder.micdrop

// Detect returning media ports only. This never selects a particular headset
// or proves the actual AudioTrack route; the worker verifies that separately.
internal class BluetoothMediaInventory {
    private var ports = emptySet<OutputDevice>()
    @Volatile var available = false
        private set
    @Volatile var generation = 0L
        private set

    @Synchronized fun update(devices: Collection<OutputDevice>, bluetoothAdded: Boolean = false) {
        val next = devices.filter { it.sink && OutputKind.forType(it.type)?.bluetooth == true }.toSet()
        if (next.any { it !in ports } || (bluetoothAdded && next.isNotEmpty())) generation++
        ports = next
        available = next.isNotEmpty()
    }
}
