package com.maskarauder.micdrop

// These identities are process-local. Reports contain only comparisons/counts,
// never addresses, route IDs or headset names. A prediction is not actual output.
internal object DefaultMediaTarget {
    fun matches(actual: List<OutputDevice>?, predicted: List<OutputDevice>?): Boolean? {
        if (actual.isNullOrEmpty() || predicted.isNullOrEmpty()) return null
        return actual.size == predicted.size && actual.all { device ->
            predicted.count { target -> same(device, target) } == 1
        } && predicted.all { target -> actual.count { device -> same(device, target) } == 1 }
    }
    private fun same(a: OutputDevice, b: OutputDevice): Boolean {
        if (!a.sink || !b.sink || a.id != b.id || a.type != b.type) return false
        val left = BluetoothAudioIdentity.stableAddress(a.address)
        val right = BluetoothAudioIdentity.stableAddress(b.address)
        return if (left != null || right != null) left != null && left == right else a.address == b.address
    }
}

internal data class SystemMediaRoute(val id: String, val type: Int, val selected: Boolean)

// MediaRouter2 does not expose a public Bluetooth address. Learn its opaque ID
// only while the pinned AudioTrack AND Android's predicted default both verify
// the original output, with exactly one matching selected system route. Never
// infer identity from a name, ID syntax, profile type alone or route ordering.
internal class SelectedMediaTarget {
    private var selection: OutputSelection? = null
    private var route: SystemMediaRoute? = null
    private var candidate: Pair<OutputSelection, SystemMediaRoute>? = null
    private var candidateSince = 0L
    private val transfers = OutputRestartBudget(intervalMs = 3000)
    private var stopped = false
    val known get() = route != null
    fun learn(chosen: OutputSelection, actual: List<OutputDevice>?, predicted: List<OutputDevice>?, routes: List<SystemMediaRoute>, nowMs: Long) {
        if (stopped || !chosen.kind.bluetooth || actual == null || predicted == null ||
            BluetoothAudioIdentity.stableAddress(chosen.address) == null ||
            !chosen.verifies(actual) || !chosen.verifies(predicted)) { candidate = null; return }
        val selected = routes.filter { it.selected }.singleOrNull()?.takeIf { it.type == chosen.deviceType }
            ?: run { candidate = null; return }
        val next = chosen to selected
        // These independent OS observations can lag during a transition. Learn
        // only a stable association, never the first transient callback sample.
        if (candidate != next) { candidate = next; candidateSince = nowMs; return }
        if (nowMs - candidateSince < 1000) return
        selection = chosen; route = selected
    }
    fun newEpisode() { if (!stopped) { transfers.newRoute(); candidate = null } }
    fun reset() { selection = null; route = null; candidate = null; transfers.newRoute() }
    fun request(chosen: OutputSelection, routes: List<SystemMediaRoute>, nowMs: Long): String? {
        if (stopped || selection?.sameEndpoint(chosen) != true) return null
        val original = route ?: return null
        val available = routes.singleOrNull { it.id == original.id && it.type == original.type } ?: return null
        if (available.selected) return null
        transfers.request()
        return available.id.takeIf { transfers.take(nowMs) }
    }
    fun stop() { stopped = true; transfers.stop(); selection = null; route = null; candidate = null }
}
