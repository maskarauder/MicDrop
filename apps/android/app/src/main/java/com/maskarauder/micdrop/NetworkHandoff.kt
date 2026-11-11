package com.maskarauder.micdrop

// Retain one current identity for comparison only. Never serialize Android
// network handles, addresses, SSIDs or carrier names. Initial registration and
// duplicate/late callbacks must not initiate a restart.
internal class DefaultNetworkChanges<T> {
    private var initialized = false
    private var current: T? = null
    private var blocked: Boolean? = null
    fun available(network: T): Boolean {
        if (current == network) return false
        val changed = initialized
        initialized = true; current = network; blocked = null
        return changed
    }
    fun lost(network: T): Boolean {
        if (current != network) return false
        current = null; blocked = null
        return initialized
    }
    fun blocked(network: T, value: Boolean): Boolean {
        if (current != network || blocked == value) return false
        val changed = blocked != null || value
        blocked = value
        return changed
    }
}

// Callback events coalesce into one worker-owned action. A new network during
// recovery cannot reset its deadline or discard an ambiguous pending answer.
internal class NetworkHandoff {
    private var revision = 0L
    private var handled = 0L
    private var changedAt = 0L
    private var armed = false
    private var stopped = false
    @Synchronized fun changed(now: Long): Boolean {
        if (stopped) return false
        revision++; changedAt = now
        return armed
    }
    @Synchronized fun arm() { if (!armed && !stopped) { handled = revision; armed = true } }
    @Synchronized fun take(now: Long): Boolean {
        if (!armed || stopped || revision == handled || now - changedAt < 300) return false
        handled = revision
        return true
    }
    @Synchronized fun waiting() = armed && !stopped && revision != handled
    @Synchronized fun stop() { stopped = true }
}
