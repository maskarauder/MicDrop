package com.maskarauder.micdrop

// Addresses stay in memory. The adapter uses a snapshot of the public HFP
// proxy; the session worker owns requests and cleanup, never its callbacks.
internal interface ScoProfileConnection {
    fun connectedAddresses(): List<String>
    fun supportsAudioRequest(address: String): Boolean
    fun startAudio(address: String): Boolean
    fun stopOwnedAudio(address: String)
}

internal enum class ScoProfileCheck(val text: String) {
    UNAVAILABLE("Bluetooth headset profile unavailable"),
    DISCONNECTED("original headset not connected to the SCO profile"),
    AMBIGUOUS("original headset profile identity ambiguous"),
    UNSUPPORTED("original headset does not support the SCO audio request"),
    ACCEPTED("original headset SCO audio request accepted; waiting for audio endpoint"),
    REJECTED("Android rejected the original headset SCO audio request"),
    WAITING("waiting to retry the original headset SCO audio request"),
    CANCELLED("SCO audio restoration cancelled or expired")
}

internal class ScoProfileRecovery(private val endpoint: HeadsetEndpoint) {
    private var acceptedEpisode: Long? = null
    private var owned: Pair<ScoProfileConnection, String>? = null

    fun request(connection: ScoProfileConnection?, recovery: HeadsetRecovery,
                nowMs: () -> Long, allowed: () -> Boolean): ScoProfileCheck {
        val ticket = recovery.current() ?: return ScoProfileCheck.CANCELLED
        if (!allowed() || recovery.remaining(nowMs()) == 0L) return ScoProfileCheck.CANCELLED
        if (connection == null) return ScoProfileCheck.UNAVAILABLE
        return try {
            val matches = connection.connectedAddresses().filter(endpoint::matchesScoAddress)
            if (!allowed() || recovery.remaining(nowMs()) == 0L) return ScoProfileCheck.CANCELLED
            if (matches.isEmpty()) return ScoProfileCheck.DISCONNECTED
            if (matches.size != 1) return ScoProfileCheck.AMBIGUOUS
            // Do not repeat an accepted asynchronous request: that can cancel
            // an in-flight HFP connection. A new episode can request it again.
            if (acceptedEpisode == ticket.episode) return ScoProfileCheck.ACCEPTED
            val address = matches.single()
            if (!connection.supportsAudioRequest(address)) return ScoProfileCheck.UNSUPPORTED
            if (!allowed() || !recovery.profileRequestDue(nowMs()))
                return if (!allowed() || recovery.remaining(nowMs()) == 0L)
                    ScoProfileCheck.CANCELLED else ScoProfileCheck.WAITING
            if (!allowed()) return ScoProfileCheck.CANCELLED
            if (!connection.startAudio(address)) return ScoProfileCheck.REJECTED
            // Retain ownership even if Stop/expiry happened inside the IPC:
            // cleanup must release that accepted request, with samples gated.
            owned = connection to address
            acceptedEpisode = ticket.episode
            if (!allowed() || recovery.remaining(nowMs()) == 0L) ScoProfileCheck.CANCELLED
            else ScoProfileCheck.ACCEPTED
        } catch (_: RuntimeException) { ScoProfileCheck.UNAVAILABLE }
    }

    fun close() {
        val request = owned ?: return
        owned = null
        request.first.stopOwnedAudio(request.second)
    }
}
