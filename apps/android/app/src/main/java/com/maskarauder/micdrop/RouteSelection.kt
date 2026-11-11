package com.maskarauder.micdrop

internal data class RouteSelectionSnapshot(val local: Boolean, val remote: Boolean,
                                          val generation: Long, val switches: Long) {
    val negotiated: Boolean get() = local && remote
    fun fields(): Map<String, Any> = linkedMapOf("version" to 1,
        "local_renomination" to local, "remote_renomination" to remote, "negotiated" to negotiated,
        "generation" to generation, "observed_switches" to switches)
    fun text(): String = "Route renomination: ${if (negotiated) "negotiated" else "not negotiated"}" +
        " · Phone support: $local · Windows support: $remote · Observed route switches: $switches · ICE generation: $generation"
}

internal class RouteSelection {
    private var previous: String? = null
    private var generation = 0L
    private var switches = 0L

    fun update(samples: Map<String, RtcSample>, currentGeneration: Long,
               localSdp: String?, remoteSdp: String?): RouteSelectionSnapshot {
        if (generation != currentGeneration) { previous = null; generation = currentGeneration }
        val transports = samples.values.filter { it.type in setOf("inbound-rtp", "outbound-rtp") &&
            it.members["kind"] == "audio" }.mapNotNull { it.members["transportId"] as? String }.toSet()
        val transport = transports.singleOrNull()?.let { samples[it] }?.takeIf { it.type == "transport" }
        val pair = (transport?.members?.get("selectedCandidatePairId") as? String)?.let { samples[it] }
            // A periodic STUN ping changes the pair state without changing its
            // selection or generation. Both current usernames are checked below.
            ?.takeIf { it.type == "candidate-pair" && it.members["state"] in setOf("succeeded", "in-progress") }
        // IDs are private, bounded comparison state only. Missing stats keep the
        // last known pair; polling may miss intermediate changes.
        val current = generation == 0L || (usernameMatches(localSdp,
            (pair?.members?.get("localCandidateId") as? String)?.let { samples[it] }?.takeIf { it.type == "local-candidate" }) &&
            usernameMatches(remoteSdp, (pair?.members?.get("remoteCandidateId") as? String)?.let { samples[it] }
                ?.takeIf { it.type == "remote-candidate" }))
        pair?.id?.takeIf { current && it.isNotEmpty() && it.length <= 512 }?.let {
            if (previous != null && previous != it) switches = (switches + 1).coerceAtMost(1000000)
            previous = it
        }
        return RouteSelectionSnapshot(advertises(localSdp), advertises(remoteSdp),
            generation.coerceIn(0, 1000000), switches)
    }

    companion object {
        private data class AudioSection(val options: Set<String>, val username: String?)
        private fun usernameMatches(sdp: String?, candidate: RtcSample?): Boolean {
            val username = candidate?.members?.get("usernameFragment") as? String ?: return false
            val sections = audioSections(sdp)
            return username.isNotEmpty() && sections.isNotEmpty() && sections.all { it.username == username }
        }
        // SDP capability is authoritative; Java has no explicit toggle. Observe
        // exact ICE option tokens on every active audio section, with normal
        // session-level inheritance. Never manufacture or rewrite SDP options.
        fun advertises(sdp: String?): Boolean = audioSections(sdp).let { sections ->
            sections.isNotEmpty() && sections.all { "renomination" in it.options }
        }
        private fun audioSections(sdp: String?): List<AudioSection> {
            if (sdp == null || sdp.length > 65536) return emptyList()
            var session = emptySet<String>()
            var sessionUsername: String? = null
            var username: String? = null
            var inMedia = false
            var audio = false
            var options: Set<String>? = null
            val sections = mutableListOf<AudioSection>()
            fun finish() { if (audio) sections += AudioSection(options ?: session, username ?: sessionUsername) }
            for (line in sdp.lineSequence()) {
                if (line.startsWith("m=")) {
                    finish(); inMedia = true; options = null; username = null
                    val fields = line.substring(2).split(Regex("\\s+"))
                    audio = fields.size >= 3 && fields[0] == "audio" &&
                        (fields[1].substringBefore('/').toIntOrNull() ?: 0) > 0
                } else if (line.startsWith("a=ice-options:")) {
                    val tokens = line.substringAfter(':').trim().split(Regex("\\s+")).toSet()
                    if (inMedia) options = (options ?: emptySet()) + tokens else session = session + tokens
                } else if (line.startsWith("a=ice-ufrag:")) {
                    if (inMedia) username = line.substringAfter(':') else sessionUsername = line.substringAfter(':')
                }
            }
            finish()
            return sections
        }
    }
}
