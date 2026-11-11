package com.maskarauder.micdrop

import java.io.IOException

internal class SignalingRoutesUnavailable : IOException("Rendezvous and LAN signaling unavailable")
internal class OfferFallbackRequired : IOException("Cancel the previous offer before changing transport")

// Worker-owned route for one session. Priority never bypasses verified identity
// or the cancellation required before replaying an ambiguous initial offer.
internal class SignalingRoute(private val remote: Boolean,
    private val initialOrder: ConnectionOrder = ConnectionOrder.LAN_FIRST,
    private val recoveryOrder: ConnectionOrder = ConnectionOrder.RENDEZVOUS_FIRST
) {
    var direct = !remote
        private set
    var probe = if (remote) "not tried" else "not needed"
        private set
    var fallback = "none"
        private set
    private var checkWhenHealthy = remote && initialOrder == ConnectionOrder.LAN_FIRST
    private var localIsFallback = false
    private var starting = true
    private var startupFallback = false
    private val history = ArrayDeque<String>()
    private fun record(event: String) {
        if (history.lastOrNull() == event) return
        if (history.size == 8) history.removeFirst()
        history.addLast(event)
    }
    fun initial(probeLocal: () -> Boolean) {
        if (!remote) return
        check(probe == "not tried")
        if (initialOrder == ConnectionOrder.RENDEZVOUS_FIRST) {
            record("Connect: rendezvous first"); return
        }
        direct = checkLocal(probeLocal)
        startupFallback = !direct
        fallback = if (direct) "none" else "LAN unavailable"
        record(if (direct) "Connect: LAN verified" else "Connect: LAN unavailable")
    }
    fun recover(probeLocal: () -> Boolean = { false }) {
        starting = false
        if (!remote) return
        localIsFallback = false
        checkWhenHealthy = initialOrder == ConnectionOrder.LAN_FIRST
        direct = recoveryOrder == ConnectionOrder.LAN_FIRST && checkLocal(probeLocal)
        fallback = if (recoveryOrder == ConnectionOrder.LAN_FIRST)
            (if (direct) "recovery: LAN first" else "recovery: LAN unavailable") else "recovery: rendezvous first"
        record(if (direct) "Recovery: LAN verified" else if (recoveryOrder == ConnectionOrder.LAN_FIRST)
            "Recovery: LAN unavailable" else "Recovery: rendezvous first")
    }
    fun upgrade(probeLocal: () -> Boolean) {
        starting = false; localIsFallback = false
        if (!remote || direct || !checkWhenHealthy) return
        checkWhenHealthy = false
        if (checkLocal(probeLocal)) {
            direct = true; localIsFallback = false; fallback = "none"; record("Healthy: LAN verified")
        }
    }
    fun localFallback(probeLocal: () -> Boolean): Boolean {
        if (!remote || (starting && startupFallback) || !checkLocal(probeLocal)) return false
        direct = true; localIsFallback = true; checkWhenHealthy = false; fallback = "rendezvous unavailable"
        record("Fallback: LAN verified")
        return true
    }
    private fun checkLocal(probeLocal: () -> Boolean): Boolean {
        val available = probeLocal()
        probe = if (available) "verified" else "unavailable"
        return available
    }
    fun needsRemoteIce(forceRelay: Boolean) = remote && (!direct || forceRelay)
    fun reportRoute(lanRoute: String) = if (direct) lanRoute else "default"
    val label get() = if (direct) "direct LAN" else "HTTPS rendezvous"
    private fun transportFailure(error: IOException) = error !is HttpFailure &&
        error !is SignalingNetworkChanged && ConnectionFailure.retryableStatus(error)
    fun text(forceRelay: Boolean) = "Signaling: $label · Local probe: $probe · Fallback: $fallback" +
        "\nCellular media candidates: ${if (remote) "allowed" else "excluded"} · Force TURN relay: $forceRelay" +
        "\nSignaling history: ${history.joinToString(" → ")}"

    fun <T> exchange(path: String, local: () -> T, rendezvous: () -> T,
                     probeLocal: () -> Boolean, cancelled: () -> Boolean,
                     networkPending: () -> Boolean = { false }): T {
        if (!remote) return local()
        val repeatable = path in setOf("/status", "/recover-offer", "/recover-answer", "/stop", "/cancel-offer", "/microphone")
        fun handoffCheckpoint() {
            // A cancelled heartbeat is not a failed attempt on the new network.
            // Let the worker coalesce callbacks, hold audio and start recovery.
            // Cleanup must still run, and ambiguous setup must never be replayed.
            if (repeatable && path !in setOf("/stop", "/cancel-offer") && networkPending())
                throw SignalingNetworkChanged()
        }
        handoffCheckpoint()
        if (direct) {
            record("Request: LAN")
            try { return local() }
            catch (error: IOException) {
                if (cancelled() || !transportFailure(error)) throw error
                handoffCheckpoint()
                if (path == "/offer" && starting && !localIsFallback) {
                    direct = false; startupFallback = true; fallback = "LAN interrupted"
                    throw OfferFallbackRequired()
                }
                if (!repeatable) throw error
                if (localIsFallback) throw SignalingRoutesUnavailable()
                direct = false // Reconnect through rendezvous before trying LAN again.
                if (starting) startupFallback = true
            }
        }
        try { handoffCheckpoint(); record("Request: rendezvous"); return rendezvous() }
        catch (error: IOException) {
            if (cancelled() || !transportFailure(error)) throw error
            handoffCheckpoint()
            val unsent = error is SignalingRequestNotSent
            // An answer is not idempotent. Never replay an ambiguous answer.
            if (!repeatable && !unsent && path != "/offer") throw error
            val reachable = localFallback {
                handoffCheckpoint()
                probeLocal().also { handoffCheckpoint() }
            }
            handoffCheckpoint()
            if (!reachable) throw SignalingRoutesUnavailable()
            // A lost offer may have allocated Windows resources. Cancellation
            // must be acknowledged and a new nonce issued before another offer.
            if (path == "/offer" && !unsent) throw OfferFallbackRequired()
            try { record("Request: LAN"); return local() }
            catch (localError: IOException) {
                if (cancelled() || !transportFailure(localError)) throw localError
                handoffCheckpoint()
                throw SignalingRoutesUnavailable()
            }
        }
    }
}

