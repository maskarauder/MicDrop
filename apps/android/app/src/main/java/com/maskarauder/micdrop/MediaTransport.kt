package com.maskarauder.micdrop

// Selected-pair observations only. A relay candidate's "protocol" can be UDP
// even when this endpoint reaches TURN over TCP or TLS. Only the local
// candidate knows that hop; never infer the other endpoint's hop from its SDP.
internal data class MediaTransportSnapshot(
    val localType: String = "unavailable", val remoteType: String = "unavailable",
    val candidateProtocol: String = "unavailable", val relayProtocol: String = "unavailable"
) {
    val path: String get() = when {
        localType == "relay" || remoteType == "relay" || relayProtocol in turnProtocols -> "relay"
        localType in directTypes && remoteType in directTypes -> "direct"
        else -> "unavailable"
    }
    val legacyPath: String get() = path + if (candidateProtocol in candidateProtocols) " / $candidateProtocol" else ""

    fun fields(): Map<String, Any> = linkedMapOf("version" to 1,
        "local_candidate_type" to localType, "remote_candidate_type" to remoteType,
        "candidate_protocol" to candidateProtocol, "relay_protocol" to relayProtocol)

    fun turnText(): String = when (relayProtocol) {
        "udp" -> "UDP"; "tcp" -> "TCP"; "tls" -> "TLS"
        "not_applicable" -> "not used"
        else -> "unavailable"
    }

    companion object {
        private val directTypes = setOf("host", "srflx", "prflx")
        private val candidateTypes = directTypes + "relay"
        private val candidateProtocols = setOf("udp", "tcp")
        private val turnProtocols = setOf("udp", "tcp", "tls")

        fun selected(local: RtcSample?, remote: RtcSample?): MediaTransportSnapshot {
            fun label(value: Any?, allowed: Set<String>) = (value as? String)?.takeIf { it in allowed } ?: "unavailable"
            val localType = label(local?.members?.get("candidateType"), candidateTypes)
            val remoteType = label(remote?.members?.get("candidateType"), candidateTypes)
            val relay = local?.members?.get("relayProtocol")
            val hop = when (localType) {
                "relay" -> label(relay, turnProtocols)
                // libwebrtc can retain relayProtocol on a local peer-reflexive
                // candidate derived from TURN. Missing is normal for direct ICE.
                "prflx" -> if (relay == null || relay == "") "not_applicable" else label(relay, turnProtocols)
                "host", "srflx" -> "not_applicable"
                else -> "unavailable"
            }
            return MediaTransportSnapshot(localType, remoteType,
                label(local?.members?.get("protocol"), candidateProtocols), hop)
        }

        // Windows' own local-candidate observation supplies its TURN hop.
        // A missing/older host or malformed report is unknown, never guessed.
        fun reported(fields: Map<String, Any?>): MediaTransportSnapshot {
            if (fields["version"] != 1) return MediaTransportSnapshot()
            val local = fields["local_candidate_type"] as? String ?: return MediaTransportSnapshot()
            val remote = fields["remote_candidate_type"] as? String ?: return MediaTransportSnapshot()
            val protocol = fields["candidate_protocol"] as? String ?: return MediaTransportSnapshot()
            val relay = fields["relay_protocol"] as? String ?: return MediaTransportSnapshot()
            if (local !in candidateTypes + "unavailable" || remote !in candidateTypes + "unavailable" ||
                protocol !in candidateProtocols + "unavailable" || relay !in turnProtocols + setOf("unavailable", "not_applicable"))
                return MediaTransportSnapshot()
            if (when (local) {
                "host", "srflx" -> relay != "not_applicable"
                "relay" -> relay == "not_applicable"
                "unavailable" -> relay != "unavailable"
                else -> false
            }) return MediaTransportSnapshot()
            return MediaTransportSnapshot(local, remote, protocol, relay)
        }
    }
}
