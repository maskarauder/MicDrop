package com.maskarauder.micdrop

// Accessed only by the worker holding AudioSessionOwner. Keep one recently
// stopped session in memory so a network handoff cannot lose its only Stop.
// The destination digest includes the pinned host and the phone's credentials.
internal class SessionStopRetry {
    class Stop(val destination: String, val token: String, val reason: String, val startedMs: Long) {
        var acknowledged = false
            internal set
    }
    private var previous: Stop? = null

    fun remember(destination: String, token: String, reason: String, nowMs: Long): Stop =
        Stop(destination, token, reason, nowMs).also { previous = it }

    fun acknowledge(stop: Stop) {
        if (previous === stop) stop.acknowledged = true
    }

    // Run before allocating another offer, with an ordinary cancellable
    // request. Failure keeps the old credential and prevents an ambiguous new
    // offer. An acknowledged Stop still enables the short native-teardown wait.
    fun beforeOffer(destination: String, nowMs: Long, notify: (Stop) -> Unit): Boolean {
        val stop = previous ?: return false
        if (nowMs - stop.startedMs !in 0L until 120_000L) { previous = null; return false }
        if (stop.destination != destination) return false
        if (!stop.acknowledged) {
            try { notify(stop) }
            catch (error: HttpFailure) {
                // The old session expired or a successor owns the host. This
                // credential cannot stop that successor; never replace it with
                // cancellation by phone identity or the new offer's nonce.
                if (error.status != 401 && error.status != 410) throw error
            }
            acknowledge(stop)
        }
        return true
    }

    fun accepted(destination: String) {
        if (previous?.destination == destination) previous = null
    }

    companion object { val shared = SessionStopRetry() }
}
