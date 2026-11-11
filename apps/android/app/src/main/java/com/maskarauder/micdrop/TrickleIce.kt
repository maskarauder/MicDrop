package com.maskarauder.micdrop

// Worker-owned private signaling. No SDP, addresses or ICE credentials in
// diagnostic fields or error messages. Mirror the bounded host wire contract.
internal data class TrickleCandidate(val mid: String, val index: Int, val ufrag: String, val candidate: String) {
    fun fields(): Map<String, Any> = mapOf("mid" to mid, "index" to index, "ufrag" to ufrag, "candidate" to candidate)
    override fun toString() = "TrickleCandidate(private)"
}
internal data class TrickleDelta(val ack: Int, val offset: Int, val candidates: List<TrickleCandidate>, val complete: Boolean) {
    fun fields(): Map<String, Any> = mapOf("version" to 1, "generation" to 0, "ack" to ack, "offset" to offset,
        "candidates" to candidates.map { it.fields() }, "complete" to complete)
    override fun toString() = "TrickleDelta(private)"
}
internal data class TrickleSection(val mid: String, val ufrag: String, val index: Int) {
    override fun toString() = "TrickleSection(private)"
}

internal class TrickleIce(remote: String, private val relayOnly: Boolean) {
    private val remoteSections = parse(remote).first
    private var localSections: List<TrickleSection>? = null
    private val local = mutableListOf<TrickleCandidate>()
    private val received = mutableListOf<TrickleCandidate>()
    private var ack = 0
    private var sentAck = -1
    private var localComplete = false
    private var remoteComplete = false
    var finished = false
        private set

    fun observe(sdp: String, complete: Boolean) {
        val (sections, candidates) = parse(sdp)
        require(localSections == null || localSections == sections) { "ICE generation changed" }
        localSections = sections
        for (c in candidates) {
            if (c in local) continue
            require(!localComplete && valid(c, sections, relayOnly) && local.size < MAX_CANDIDATES &&
                local.sumOf { it.candidate.length } + c.candidate.length <= MAX_BYTES) { "ICE candidate limit" }
            local.add(c)
        }
        localComplete = localComplete || complete
    }

    fun delta(): TrickleDelta {
        val end = minOf(local.size, ack + BATCH_SIZE)
        sentAck = received.size
        return TrickleDelta(received.size, ack, local.subList(ack, end).toList(), localComplete && end == local.size)
    }

    fun accept(d: TrickleDelta, apply: (TrickleCandidate) -> Boolean) {
        require(d.ack in ack..local.size && d.offset in 0..received.size && d.candidates.size <= BATCH_SIZE &&
            d.offset + d.candidates.size <= MAX_CANDIDATES) { "Invalid ICE update" }
        var bytes = received.sumOf { it.candidate.length }
        for ((i, c) in d.candidates.withIndex()) {
            val at = d.offset + i
            require(valid(c, remoteSections, relayOnly)) { "Invalid ICE candidate" }
            if (at < received.size) require(received[at] == c) { "Conflicting ICE update" }
            else {
                bytes += c.candidate.length
                require(!remoteComplete && bytes <= MAX_BYTES) { "ICE candidate limit" }
            }
        }
        require(!d.complete || d.offset + d.candidates.size >= received.size) { "Invalid ICE completion" }
        for ((i, c) in d.candidates.withIndex()) {
            if (d.offset + i < received.size) continue
            check(apply(c)) { "ICE candidate rejected" }
            received.add(c)
        }
        ack = d.ack; remoteComplete = remoteComplete || d.complete
        finished = localComplete && remoteComplete && ack == local.size && sentAck == received.size
    }

    fun text() = "Incremental ICE: ${if (finished) "complete" else "exchanging"} · Local candidates: ${local.size} · Acknowledged: $ack · Remote candidates: ${received.size}"

    companion object {
        const val HEADER = "X-MicDrop-Trickle-ICE"
        const val MAX_BYTES = 65536
        const val MAX_CANDIDATES = 128
        const val BATCH_SIZE = 16
        private fun token(s: String, limit: Int) = s.length in 1..limit && s.all { it.code in 33..126 }

        fun valid(c: TrickleCandidate, sections: List<TrickleSection>, relayOnly: Boolean): Boolean {
            if (c.index !in sections.indices || !token(c.mid, 64) || !token(c.ufrag, 256) ||
                c.candidate.length !in 1..2048 || c.candidate.any { it == '\r' || it == '\n' || it == '\u0000' }) return false
            val section = sections[c.index]
            if (c.mid != section.mid || c.ufrag != section.ufrag) return false
            val f = c.candidate.trim().split(Regex("\\s+"))
            if (f.size < 8 || !f[0].startsWith("candidate:") || f[6] != "typ" || f[1] !in listOf("1", "2") ||
                f[2].lowercase() !in listOf("udp", "tcp") || f[5].toIntOrNull() !in 1..65535 ||
                f[7] !in listOf("host", "srflx", "prflx", "relay") || (relayOnly && f[7] != "relay")) return false
            for (i in 8 until f.size - 1 step 2) if (f[i] == "ufrag" && f[i+1] != c.ufrag) return false
            return true
        }

        fun parse(sdp: String): Pair<List<TrickleSection>, List<TrickleCandidate>> {
            require(sdp.length in 1..MAX_BYTES && '\u0000' !in sdp) { "Invalid ICE description" }
            val sections = mutableListOf<TrickleSection>()
            val raw = mutableListOf<MutableList<String>>()
            var global = ""
            for (line in sdp.replace("\r\n", "\n").split('\n')) {
                val i = sections.lastIndex
                when {
                    line.startsWith("m=") -> {
                        require(sections.size < 8) { "ICE section limit" }
                        sections.add(TrickleSection("", global, sections.size)); raw.add(mutableListOf())
                    }
                    line.startsWith("a=mid:") && i >= 0 -> sections[i] = sections[i].copy(mid = line.removePrefix("a=mid:"))
                    line.startsWith("a=ice-ufrag:") -> {
                        val u = line.removePrefix("a=ice-ufrag:")
                        if (i < 0) global = u else sections[i] = sections[i].copy(ufrag = u)
                    }
                    line.startsWith("a=candidate:") && i >= 0 -> raw[i].add(line.substring(2))
                }
            }
            require(sections.isNotEmpty()) { "ICE sections unavailable" }
            val candidates = mutableListOf<TrickleCandidate>()
            for ((i, section) in sections.withIndex()) {
                require(token(section.mid, 64) && token(section.ufrag, 256)) { "Invalid ICE transport" }
                for (line in raw[i]) {
                    val c = TrickleCandidate(section.mid, i, section.ufrag, line)
                    require(valid(c, sections, false) && candidates.size < MAX_CANDIDATES) { "Invalid ICE candidate" }
                    candidates.add(c)
                }
            }
            return sections to candidates
        }
    }
}
