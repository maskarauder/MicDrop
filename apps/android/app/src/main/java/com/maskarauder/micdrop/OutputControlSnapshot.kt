package com.maskarauder.micdrop

// Immutable, bounded summary. No device ID/name/address or system route ID.
internal data class OutputControlSnapshot(val selection: String, val requestedEnabled: Boolean,
    val phase: String, val pause: String, val defaultMatches: Boolean?, val systemRouteKnown: Boolean,
    val transfers: Int, val transferResult: String, val recreations: Int, val nearbyPermission: Boolean?) {
    fun fields(): Map<String, Any?> = linkedMapOf("version" to 1, "selection" to selection,
        "requested_enabled" to requestedEnabled, "phase" to phase, "pause" to pause,
        "default_matches" to defaultMatches, "system_route_known" to systemRouteKnown,
        "transfers" to transfers, "transfer_result" to transferResult, "playout_recreations" to recreations,
        "nearby_permission" to nearbyPermission)
}
