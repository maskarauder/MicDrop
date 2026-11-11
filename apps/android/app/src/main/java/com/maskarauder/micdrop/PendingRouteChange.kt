package com.maskarauder.micdrop

// A single foreground selection replaces a current stream after its worker has
// ended. No queue, durable restart ticket or consent survives cancellation.
internal class PendingRouteChange<T>(private val limitMs: Long = 20000) {
    private var origin: String? = null
    private var value: T? = null
    private var deadline = 0L
    fun begin(id: String, target: T, nowMs: Long): Boolean {
        if (origin != null) return false
        origin = id; value = target; deadline = nowMs + limitMs
        return true
    }
    fun matches(id: String) = origin == id
    fun expired(nowMs: Long) = origin != null && nowMs >= deadline
    fun take(id: String, nowMs: Long): T? {
        if (!matches(id)) return null
        val target = value.takeUnless { expired(nowMs) }
        cancel()
        return target
    }
    fun cancel() { origin = null; value = null; deadline = 0L }
}

internal object RouteActionScope {
    fun accepts(current: String?, requested: String?, replacing: String?, phase: SessionPhase, safetyOnly: Boolean): Boolean =
        current != null && requested != null && (current == requested ||
            (safetyOnly && requested == replacing && phase in listOf(SessionPhase.SWITCHING, SessionPhase.CONNECTING,
                SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)))
}
