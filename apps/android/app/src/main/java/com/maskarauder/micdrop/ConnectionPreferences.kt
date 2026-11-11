package com.maskarauder.micdrop

internal enum class ConnectionOrder(val label: String) {
    LAN_FIRST("LAN → rendezvous"), RENDEZVOUS_FIRST("Rendezvous → LAN")
}

internal enum class ConnectionSettingsGroup(val label: String) {
    RECOVERY("Connection and recovery"), REQUESTS("Request timeouts"), WEBRTC("WebRTC timeouts"),
    AUDIO("Bluetooth recovery")
}

// User-facing connection and recovery deadlines, in milliseconds. Protocol/security expiry,
// initial route verification and heartbeat cadence are deliberately independent.
internal enum class ConnectionTimeout(val label: String, val defaultMs: Int, val minimumMs: Int,
    val maximumMs: Int, val group: ConnectionSettingsGroup) {
    RECOVERY("Media connection / recovery window", 30000, 5000, 300000, ConnectionSettingsGroup.RECOVERY),
    SETUP("Windows offer-to-answer window", 45000, 10000, 120000, ConnectionSettingsGroup.RECOVERY),
    BUSY_HOST("Wait for Windows to finish the previous session", 5000, 0, 30000, ConnectionSettingsGroup.RECOVERY),
    RESTART_DELAY("Delay before first ICE restart", 1000, 0, 10000, ConnectionSettingsGroup.RECOVERY),
    RESTART_INTERVAL("Interval between ICE restarts", 8000, 5000, 60000, ConnectionSettingsGroup.RECOVERY),
    LAN_PROBE("LAN verification", 1500, 250, 5000, ConnectionSettingsGroup.REQUESTS),
    LAN_STATUS("LAN status request", 2000, 250, 15000, ConnectionSettingsGroup.REQUESTS),
    LAN_REQUEST("Other LAN control requests", 8000, 1000, 30000, ConnectionSettingsGroup.REQUESTS),
    REMOTE_REQUEST("Rendezvous control request", 8000, 1000, 30000, ConnectionSettingsGroup.REQUESTS),
    ICE_SERVICE("STUN / TURN configuration request", 8000, 1000, 30000, ConnectionSettingsGroup.REQUESTS),
    LAN_STOP("LAN Stop / cancellation budget", 2000, 500, 10000, ConnectionSettingsGroup.REQUESTS),
    REMOTE_STOP("Remote Stop / cancellation budget", 5000, 500, 15000, ConnectionSettingsGroup.REQUESTS),
    INITIAL_OFFER("Initial offer request", 40000, 1000, 60000, ConnectionSettingsGroup.WEBRTC),
    CANCEL_OFFER("Offer cancellation", 5000, 500, 15000, ConnectionSettingsGroup.REQUESTS),
    INITIAL_ICE("Initial ICE gathering", 15000, 1000, 30000, ConnectionSettingsGroup.WEBRTC),
    INITIAL_SDP("Initial SDP operation", 15000, 1000, 30000, ConnectionSettingsGroup.WEBRTC),
    RECOVERY_ICE("Recovery ICE gathering", 8000, 1000, 30000, ConnectionSettingsGroup.WEBRTC),
    RECOVERY_OFFER("Recovery offer request", 18000, 1000, 30000, ConnectionSettingsGroup.WEBRTC),
    RECOVERY_ANSWER("Recovery SDP / answer operation", 5000, 1000, 30000, ConnectionSettingsGroup.WEBRTC),
    BLUETOOTH_RECOVERY("Selected Bluetooth input / output recovery", 20000, 5000, 120000, ConnectionSettingsGroup.AUDIO);

    fun parseSeconds(text: String): Int? {
        if (!text.matches(Regex("[0-9]+(?:\\.[0-9]{1,3})?")) || text.length > 12) return null
        val value = runCatching { text.toBigDecimal().movePointRight(3).intValueExact() }.getOrNull()
        return value?.takeIf { it in minimumMs..maximumMs }
    }
    companion object {
        fun seconds(ms: Int) = java.math.BigDecimal(ms).movePointLeft(3).stripTrailingZeros().toPlainString()
    }
}

internal data class ConnectionPreferences(
    val initialOrder: ConnectionOrder = ConnectionOrder.LAN_FIRST,
    val recoveryOrder: ConnectionOrder = ConnectionOrder.RENDEZVOUS_FIRST,
    val timeouts: Map<ConnectionTimeout, Int> = emptyMap(),
    val maxRestarts: Int = 2
) {
    init {
        require(maxRestarts in 1..10)
        require(timeouts.all { (key, value) -> value in key.minimumMs..key.maximumMs })
    }
    operator fun get(timeout: ConnectionTimeout): Int = timeouts[timeout] ?: timeout.defaultMs
    fun fields(): Map<String, Any> = ConnectionTimeout.entries.associate { it.name to get(it) } + mapOf(
        "initialOrder" to initialOrder.name, "recoveryOrder" to recoveryOrder.name, "maxRestarts" to maxRestarts)
    fun offerHeaders(): Map<String, String> = mapOf(RECOVERY_HEADER to get(ConnectionTimeout.RECOVERY).toString(),
        SETUP_HEADER to get(ConnectionTimeout.SETUP).toString())

    fun negotiated(supported: Boolean, version: Int, recoveryMs: Int, setupMs: Int, heartbeatMs: Int): ConnectionDeadlines {
        val recovery = minOf(get(ConnectionTimeout.RECOVERY), if (supported) 300000 else 10000)
        if (version == 1) {
            require(recoveryMs == recovery && setupMs == get(ConnectionTimeout.SETUP) && heartbeatMs == recoveryMs + 5000) {
                "Windows did not confirm connection deadlines"
            }
            return ConnectionDeadlines(recoveryMs, setupMs, heartbeatMs, DeadlineState.CONFIRMED)
        }
        val legacy = if (supported) 30000 else 10000
        return ConnectionDeadlines(minOf(get(ConnectionTimeout.RECOVERY), legacy),
            minOf(get(ConnectionTimeout.SETUP), 45000), legacy + 5000, DeadlineState.LEGACY)
    }
    // Before any Windows offer reply. Keeps the legacy numbers; only the report label differs.
    fun unnegotiated() = negotiated(false, 0, 0, 0, 0).copy(state = DeadlineState.NOT_NEGOTIATED)
    fun text(deadlines: ConnectionDeadlines) =
        "Connection order — initial: ${initialOrder.label} · recovery: ${recoveryOrder.label}" +
        "\nConnection deadlines — requested recovery: ${get(ConnectionTimeout.RECOVERY)} ms · " +
        when (deadlines.state) {
            DeadlineState.NOT_NEGOTIATED -> "requested setup: ${get(ConnectionTimeout.SETUP)} ms · not negotiated (no Windows offer reply)"
            DeadlineState.REJECTED -> "requested setup: ${get(ConnectionTimeout.SETUP)} ms · not negotiated (Windows offer reply rejected)"
            DeadlineState.LEGACY, DeadlineState.CONFIRMED ->
                "effective: ${deadlines.recoveryMs} ms · setup: ${deadlines.setupMs} ms · Windows heartbeat: ${deadlines.heartbeatMs} ms" +
                (if (deadlines.state == DeadlineState.CONFIRMED) " · confirmed by Windows" else " · legacy Windows limits (update Windows for custom deadlines)")
        } +
        "\nConnection timing (ms): " + ConnectionTimeout.entries.joinToString(", ") { "${it.name.lowercase()}=${get(it)}" } +
        " · max ICE restarts=$maxRestarts"

    companion object {
        const val RECOVERY_HEADER = "X-MicDrop-Recovery-Window-Ms"
        const val SETUP_HEADER = "X-MicDrop-Setup-Window-Ms"
        fun from(fields: Map<String, *>): ConnectionPreferences = ConnectionPreferences(
            initialOrder = ConnectionOrder.entries.firstOrNull { it.name == fields["initialOrder"] } ?: ConnectionOrder.LAN_FIRST,
            recoveryOrder = ConnectionOrder.entries.firstOrNull { it.name == fields["recoveryOrder"] } ?: ConnectionOrder.RENDEZVOUS_FIRST,
            timeouts = ConnectionTimeout.entries.associateWith { key ->
                (fields[key.name] as? Int)?.takeIf { it in key.minimumMs..key.maximumMs } ?: key.defaultMs
            }, maxRestarts = (fields["maxRestarts"] as? Int)?.takeIf { it in 1..10 } ?: 2)
    }
}

// REJECTED: Windows replied to /offer but the reply failed validation before negotiation finished.
internal enum class DeadlineState { NOT_NEGOTIATED, REJECTED, LEGACY, CONFIRMED }

internal data class ConnectionDeadlines(val recoveryMs: Int, val setupMs: Int, val heartbeatMs: Int, val state: DeadlineState)
