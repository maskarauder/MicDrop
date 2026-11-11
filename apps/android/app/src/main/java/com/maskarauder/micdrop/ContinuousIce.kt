package com.maskarauder.micdrop

internal data class IceSnapshot(val generation: Long, val revision: Long, val ack: Long,
    val candidates: List<TrickleCandidate>?, val version: Int = 1) {
    fun fields(): Map<String, Any> = mutableMapOf<String, Any>("version" to version, "generation" to generation,
        "revision" to revision, "ack" to ack).apply { candidates?.let { put("candidates", it.map { c -> c.fields() }) } }
    override fun toString() = "IceSnapshot(private)"
}

// Worker-owned replacement snapshots. Acknowledged sets need only counters on
// subsequent heartbeats. No event history grows with the session's duration.
internal class ContinuousIce(remote: String, private val relayOnly: Boolean, val generation: Long) {
    private val remoteSections = TrickleIce.parse(remote).first
    private var remote = checked(TrickleIce.parse(remote).second, remoteSections)
    private var localSections: List<TrickleSection>? = null
    private var local = emptyList<TrickleCandidate>()
    private var revision = 0L
    private var remoteRevision = 0L
    private var ack = 0L

    private fun checked(cs: List<TrickleCandidate>, sections: List<TrickleSection>): List<TrickleCandidate> {
        require(cs.size <= MAX_CANDIDATES && cs.sumOf { it.candidate.length } <= MAX_BYTES) { "ICE snapshot limit" }
        for (c in cs) require(TrickleIce.valid(c, sections, relayOnly) &&
            (c.mid + c.ufrag + c.candidate).none { it in "\"\\<>&" } &&
            c.candidate.all { it.code in 32..126 }) { "Invalid ICE snapshot" }
        require(cs.distinct().size == cs.size) { "Duplicate ICE candidate" }
        return cs.sortedWith(compareBy({ it.index }, { it.candidate }))
    }

    fun observe(sdp: String) {
        val (sections, parsed) = TrickleIce.parse(sdp)
        require(localSections == null || localSections == sections) { "ICE generation changed" }
        val cs = checked(parsed, sections)
        if (revision == 0L || local != cs) {
            check(revision < MAX_REVISION) { "ICE revision limit" }
            revision++; local = cs
        }
        localSections = sections
    }

    fun snapshot() = IceSnapshot(generation, revision, remoteRevision, if (ack == revision) null else local.toList())

    fun accept(d: IceSnapshot, add: (TrickleCandidate) -> Boolean, remove: (TrickleCandidate) -> Boolean) {
        require(d.version == 1 && d.generation == generation && d.revision in maxOf(1, remoteRevision)..MAX_REVISION &&
            d.ack in ack..revision) { "Invalid ICE snapshot" }
        if (d.candidates == null) require(d.revision == remoteRevision) { "Missing ICE snapshot" }
        else {
            val cs = checked(d.candidates, remoteSections)
            require(d.revision != remoteRevision || cs == remote) { "Conflicting ICE snapshot" }
            for (c in remote) if (c !in cs) check(remove(c)) { "ICE removal rejected" }
            for (c in cs) if (c !in remote) check(add(c)) { "ICE candidate rejected" }
            remote = cs
        }
        remoteRevision = d.revision; ack = d.ack
    }

    fun text() = "Continuous ICE: generation $generation · Revision: $revision · Acknowledged: $ack" +
        " · Local candidates: ${local.size} · Remote candidates: ${remote.size}"

    companion object {
        const val HEADER = "X-MicDrop-Continuous-ICE"
        const val MAX_CANDIDATES = 64
        const val MAX_BYTES = 32768
        const val MAX_REVISION = 1_000_000_000L
        fun withoutCandidates(sdp: String) = sdp.lineSequence().map { it.trimEnd('\r') }
            .filter { it.isNotEmpty() && !it.startsWith("a=candidate:") && it != "a=end-of-candidates" }
            .joinToString("\r\n", postfix = "\r\n")
    }
}

// Callback evidence proves each candidate belongs to the current SDK generation,
// even when local SDP omits its ufrag. SDK removals release evidence; restarts
// clear it before applying the new offer. Callbacks never perform native work.
internal class ContinuousCandidates {
    private val values = mutableMapOf<Pair<Int, String>, String>()
    private var overflow = false
    private fun parts(value: String) = value.removePrefix("a=").trim().split(Regex("\\s+"))
    private fun key(value: String): String {
        val p = parts(value)
        return (p.take(8) + p.drop(8).chunked(2).filterNot { it[0] == "ufrag" }.flatten()).joinToString(" ")
    }
    private fun user(value: String) = parts(value).drop(8).chunked(2)
        .singleOrNull { it.size == 2 && it[0] == "ufrag" }?.get(1)
    @Synchronized fun clear() { values.clear(); overflow = false }
    @Synchronized fun add(index: Int, value: String) {
        if (index !in 0..7 || value.length !in 1..2048 || user(value) == null) return
        val k = index to key(value)
        if ((k !in values && values.size >= 128) || values.values.sumOf { it.length } - (values[k]?.length ?: 0) + value.length > 65536) {
            overflow = true; return
        }
        values[k] = value
    }
    @Synchronized fun remove(index: Int, value: String) {
        val k = key(value)
        values.entries.removeAll { (index == -1 || it.key.first == index) && it.key.second == k &&
            (user(value) == null || user(it.value) == user(value)) }
    }
    @Synchronized fun description(sdp: String): String {
        check(!overflow) { "ICE evidence limit" }
        val sections = TrickleIce.parse(sdp).first
        var index = -1
        return sdp.lineSequence().map { it.trimEnd('\r') }.mapNotNull { line ->
            if (line.startsWith("m=")) index++
            if (!line.startsWith("a=candidate:")) line.takeIf { it.isNotEmpty() && it != "a=end-of-candidates" }
            else values[index to key(line)]?.takeIf { user(it) == sections.getOrNull(index)?.ufrag }?.let { "a=$it" }
        }.joinToString("\r\n", postfix = "\r\n")
    }
}
