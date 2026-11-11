package com.maskarauder.micdrop

// Worker-owned, elapsed-realtime budget. Signaling retries reuse the same
// generation and SDP. Neither a retry nor another failure moves the deadline.
internal class LanRecovery(val supported: Boolean,
    val limitMs: Long = if (supported) 30_000L else 10_000L,
    private val restartDelayMs: Long = 1000, private val restartIntervalMs: Long = 8000,
    private val maxRestarts: Int = 2
) {
    init { require(limitMs in 5000..300000 && restartDelayMs in 0..10000 && restartIntervalMs in 5000..60000 && maxRestarts in 1..10) }
    private var failedAt: Long? = null
    private var attempts = 0
    private var lastAttemptAt = 0L
    private var lastAcceptedAt: Long? = null
    var established = false
        private set
    var generation = 0L
        private set
    var pending = false
        private set
    var restartRequested = false
        private set
    var answer: String? = null
    val active get() = failedAt != null
    fun signalingFailed(error: Throwable, attemptedAt: Long, stopped: Boolean = false): Boolean {
        if (stopped || !ConnectionFailure.retryableStatus(error, establishedSession = established)) return false
        // Charge the failed request itself to the window. Repeated failures and
        // late network callbacks cannot start a fresh budget or discard an answer.
        observe(false, attemptedAt)
        return true
    }
    fun observe(healthy: Boolean, now: Long): Boolean {
        if (expired(now)) return false
        if (!healthy || pending || restartRequested) { if (failedAt == null) failedAt = now; return false }
        established = true
        val recovered = active
        failedAt = null; attempts = 0; answer = null
        return recovered
    }
    fun remaining(now: Long) = failedAt?.let { (limitMs - (now - it)).coerceAtLeast(0) } ?: limitMs
    fun expired(now: Long) = active && remaining(now) == 0L
    fun networkChanged(now: Long) {
        if (!supported || !established || expired(now)) return
        observe(false, now); restartRequested = true
    }
    fun restartDue(now: Long) = supported && established && active && !pending && !expired(now) && attempts < maxRestarts &&
        (restartRequested || now - requireNotNull(failedAt) >= restartDelayMs) && (attempts == 0 || now - lastAttemptAt >= restartIntervalMs) &&
        (lastAcceptedAt?.let { now - it >= 5000 } ?: true)
    fun begin(now: Long) {
        check(restartDue(now)); generation++; attempts++; lastAttemptAt = now; pending = true; answer = null; restartRequested = false
    }
    // A known handoff already authorizes recovery of this established session.
    // Do not spend a fresh tunneled status round trip before its restart, or
    // insert reporting/sleep between the accepted answer and its confirmation.
    // Failed exchanges keep their generation and prepared answer for retry.
    fun <T> exchangeStatus(now: () -> Long, beforeRestart: () -> Unit,
                          restore: () -> Unit, poll: () -> T): T {
        fun checkDeadline() {
            if (expired(now())) throw java.net.SocketTimeoutException("Media recovery deadline reached")
        }
        checkDeadline()
        if (restartDue(now())) { beforeRestart(); checkDeadline(); begin(now()) }
        if (pending) restore()
        checkDeadline()
        return poll()
    }
    // The host throttles new offers for five seconds. Retain this guard across
    // recovered episodes so a quick return to Wi-Fi cannot provoke HTTP 409.
    fun accepted(now: Long) { check(pending); pending = false; lastAcceptedAt = now }
    fun text() = "LAN media recovery: ${if (active) "recovering" else "settled"} · ICE restarts requested: $generation · Window: ${ConnectionTimeout.seconds(limitMs.toInt())} seconds"
    fun fields(route: String): Map<String, Any> = mapOf("phase" to if (active) "recovering" else "settled",
        "restarts" to generation, "signaling_route" to route)
}
