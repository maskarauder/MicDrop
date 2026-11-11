package com.maskarauder.micdrop

internal data class HeadsetRecoveryTicket(val episode: Long, val revision: Long)

// Shared by route callbacks and the session worker. Repeated changes invalidate
// a pending resume without extending its original deadline. Native audio gates
// and completion are serialized separately by StreamReceiver's audio lock.
internal class HeadsetRecovery(private val limitMs: Long = WINDOW_MS) {
    companion object {
        const val WINDOW_MS = 20_000L
        const val WINDOW_SECONDS = WINDOW_MS / 1000
    }

    private var startedAt: Long? = null
    private var episode = 0L
    private var revision = 0L
    private var cancelled = false
    private var lastSelectionAt: Long? = null
    private var episodeSelections = 0
    private var totalSelections = 0L
    private var completed = 0L
    private var routeReleased = false
    private var totalRouteReleases = 0L
    private var lastProfileRequestAt: Long? = null
    private var episodeProfileRequests = 0
    private var totalProfileRequests = 0L
    private var lastCheck = "not started"

    @Synchronized fun request(nowMs: Long): Boolean {
        if (cancelled) return false
        if (startedAt == null) {
            startedAt = nowMs; episode++; lastSelectionAt = null; episodeSelections = 0
            routeReleased = false; lastCheck = "checking selected headset"
            lastProfileRequestAt = null; episodeProfileRequests = 0
        }
        revision++
        return true
    }

    @Synchronized fun current(): HeadsetRecoveryTicket? =
        if (startedAt == null || cancelled) null else HeadsetRecoveryTicket(episode, revision)

    @Synchronized fun pending(): Boolean = startedAt != null && !cancelled
    @Synchronized fun remaining(nowMs: Long): Long =
        startedAt?.let { (limitMs - (nowMs - it)).coerceAtLeast(0) } ?: 0

    @Synchronized fun reselectionDue(nowMs: Long, endpointAvailable: Boolean = true): Boolean {
        if (!endpointAvailable || !pending() || remaining(nowMs) == 0L || episodeSelections >= 3 ||
            lastSelectionAt?.let { nowMs - it < 500 } == true) return false
        lastSelectionAt = nowMs; episodeSelections++
        totalSelections = minOf(totalSelections + 1, 9007199254740991L)
        return true
    }

    @Synchronized fun routeReleaseDue(nowMs: Long, endpointAvailable: Boolean): Boolean {
        if (endpointAvailable || !pending() || remaining(nowMs) == 0L || routeReleased) return false
        routeReleased = true
        totalRouteReleases = minOf(totalRouteReleases + 1, 9007199254740991L)
        return true
    }

    // Separate from AudioManager reselection: the pinned SCO headset may be
    // profile-connected but have no AudioDeviceInfo until its HFP audio starts.
    // The original recovery deadline still owns both kinds of request.
    @Synchronized fun profileRequestDue(nowMs: Long): Boolean {
        if (!pending() || remaining(nowMs) == 0L || episodeProfileRequests >= 3 ||
            lastProfileRequestAt?.let { nowMs - it < 500 } == true) return false
        lastProfileRequestAt = nowMs; episodeProfileRequests++
        totalProfileRequests = minOf(totalProfileRequests + 1, 9007199254740991L)
        return true
    }

    // Callers supply fixed, redacted route-status labels, never device identity.
    @Synchronized fun observe(check: String) { if (pending()) lastCheck = check }

    @Synchronized fun complete(ticket: HeadsetRecoveryTicket, nowMs: Long): Boolean {
        if (current() != ticket || remaining(nowMs) == 0L) return false
        startedAt = null
        completed = minOf(completed + 1, 9007199254740991L)
        return true
    }

    @Synchronized fun cancel() { cancelled = true; startedAt = null }
    @Synchronized fun text(): String = "Selected headset recovery: ${if (cancelled) "stopped" else if (pending()) "restoring" else "settled"} · " +
        "Window: $limitMs ms · Completed: $completed · Reselection requests: $totalSelections · Route releases: $totalRouteReleases · " +
        "SCO profile requests: $totalProfileRequests · Last check: $lastCheck"
}
