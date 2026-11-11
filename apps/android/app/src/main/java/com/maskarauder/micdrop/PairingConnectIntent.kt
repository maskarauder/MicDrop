package com.maskarauder.micdrop

// A visible Connect action may continue its own approved and durably saved
// pairing once. Loading an old pairing, scanning or observing service state
// never creates this intent. It is not persisted/replayed after backgrounding.
internal class PairingConnectIntent {
    private var operation: Long? = null
    val pending get() = operation != null
    fun begin(id: Long?) { operation = id?.takeIf { it > 0 } }
    fun cancel() { operation = null }
    fun take(successId: Long, working: Boolean, available: Boolean, visibleReady: Boolean): Boolean {
        val expected = operation ?: return false
        if (working) return false
        if (successId != expected || !available) { cancel(); return false }
        if (!visibleReady) return false
        cancel()
        return true
    }
}
