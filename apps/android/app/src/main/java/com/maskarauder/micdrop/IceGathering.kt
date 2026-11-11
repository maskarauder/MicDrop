package com.maskarauder.micdrop

// Only counts and fixed labels leave this file. Never retain SDP, addresses,
// candidate IDs, ICE credentials, TURN URLs or native error text in a report.
internal data class IceGatheringSnapshot(
    val result: String, val elapsedMs: Long, val relayOnly: Boolean,
    val hostCandidates: Int, val reflexiveCandidates: Int, val relayCandidates: Int,
    val otherCandidates: Int, val mediaSections: Int, val readySections: Int,
    val candidateErrors: Int, val lastErrorCode: Int
) {
    val canSubmit: Boolean get() = result in listOf("complete", "trickle", "candidates_ready", "deadline_with_candidates")
    fun canReportTo(version: Int): Boolean = version == 3 || (version == 2 && result != "trickle") || (version == 1 && result !in listOf("trickle", "candidates_ready"))
    fun fields(): Map<String, Any> = linkedMapOf(
        "version" to if (result == "trickle") 3 else if (result == "candidates_ready") 2 else 1, "result" to result, "elapsed_ms" to elapsedMs, "relay_only" to relayOnly,
        "host_candidates" to hostCandidates, "reflexive_candidates" to reflexiveCandidates,
        "relay_candidates" to relayCandidates, "other_candidates" to otherCandidates,
        "media_sections" to mediaSections, "ready_sections" to readySections,
        "candidate_errors" to candidateErrors, "last_error_code" to lastErrorCode)
    fun text(): String = "Initial Android ICE gathering: $result · ${elapsedMs} ms · Relay only: $relayOnly\n" +
        "Local candidates: host=$hostCandidates, reflexive=$reflexiveCandidates, relay=$relayCandidates, other=$otherCandidates · Ready media: $readySections/$mediaSections\n" +
        "Candidate gathering errors: $candidateErrors · Last code: $lastErrorCode\n" +
        "Candidate availability does not prove a working media path."
}

// Match the native host's narrow initial optimization. A missing relay never
// shortens the overall budget. Multiple endpoints and TCP/TLS keep full gathering.
internal class InitialRelayGathering(private val enabled: Boolean) {
    private var readyAt: Long? = null
    fun ready(usable: Boolean, now: Long): Boolean {
        if (!enabled || !usable) { readyAt = null; return false }
        if (readyAt == null) readyAt = now
        return now - requireNotNull(readyAt) >= 500
    }
    companion object {
        fun eligible(relayOnly: Boolean, urls: List<String>): Boolean {
            if (!relayOnly || urls.any { !it.startsWith("turn:") && !it.startsWith("turns:") && !it.startsWith("stun:") }) return false
            val turns = urls.filter { it.startsWith("turn:") || it.startsWith("turns:") }
            return turns.size == 1 && turns[0].startsWith("turn:") && turns[0].endsWith("?transport=udp")
        }
    }
}

internal class IceGatheringErrors {
    private var count = 0
    private var lastCode = 0
    @Synchronized fun record(code: Int) {
        count = minOf(count + 1, 1_000_000)
        lastCode = code.takeIf { it in 0..999 } ?: 0
    }
    @Synchronized fun snapshot(): Pair<Int, Int> = count to lastCode
}

// Local, bounded SDK evidence only. Callback candidates include their ufrag;
// SDP candidate lines omit it. Neither this buffer nor its contents are logged.
internal class RecoveryCandidates {
    private val values = mutableListOf<Pair<Int, String>>()
    private var bytes = 0
    @Synchronized fun clear() { values.clear(); bytes = 0 }
    @Synchronized fun add(index: Int, sdp: String) {
        if (index < 0 || sdp.length !in 1..4096 || bytes + sdp.length > 65536 || values.size >= 256) return
        values += index to sdp; bytes += sdp.length
    }
    @Synchronized fun snapshot(): List<Pair<Int, String>> = values.toList()
}

internal object IceGathering {
    private class Section(val audio: Boolean, val rejected: Boolean) {
        var ufrag: String? = null
        var mux = false
        val candidates = mutableListOf<List<String>>()
    }

    // Initial connections may omit the redundant candidate ufrag. Restarts use
    // recovery() below, which requires fresh credentials and explicit provenance.
    fun initial(sdp: String, complete: Boolean, remote: Boolean, relayOnly: Boolean,
        elapsedMs: Long, errors: Pair<Int, Int> = 0 to 0): IceGatheringSnapshot =
        analyze(sdp, complete, remote, relayOnly, elapsedMs, errors, false)

    fun recovery(sdp: String, previous: String, complete: Boolean, remote: Boolean,
        relayOnly: Boolean, elapsedMs: Long, candidates: List<Pair<Int, String>> = emptyList()): IceGatheringSnapshot {
        val fresh = freshCredentials(sdp, previous)
        // A partial restart must prove candidates came from the renewed SDK
        // generation, not merely inherit the enclosing SDP's new credentials.
        // Complete gathering retains the existing current-description contract.
        val observed = if (complete) sdp else withCandidateProof(sdp, candidates)
        val result = analyze(observed, complete, remote, relayOnly, elapsedMs, 0 to 0, !complete)
        return if (fresh) result else result.copy(result = "timed_out", readySections = 0)
    }

    fun freshCredentials(sdp: String, previous: String): Boolean {
        val before = credentials(previous)
        val after = credentials(sdp)
        return before.isNotEmpty() && before.size == after.size && before.zip(after).all { (old, new) ->
            old.first.isNotEmpty() && old.second.isNotEmpty() && new.first.isNotEmpty() && new.second.isNotEmpty() &&
                old.first != new.first && old.second != new.second
        }
    }

    private fun withCandidateProof(sdp: String, candidates: List<Pair<Int, String>>): String {
        if (sdp.length > 65536) return ""
        fun tokens(value: String) = value.trim().removePrefix("a=").split(Regex("\\s+"))
        fun withoutUfrag(parts: List<String>) = parts.take(8) + parts.drop(8).chunked(2)
            .filterNot { it[0] == "ufrag" }.flatten()
        val users = sdp.lineSequence().map { it.trim() }.filter { it.startsWith("a=ice-ufrag:") }
            .map { it.substringAfter(':') }.toSet()
        val proof = candidates.take(256).filter { it.second.length <= 4096 }.map { it.first to tokens(it.second) }
            .filter { (_, parts) -> parts.drop(8).chunked(2).any { it.size == 2 && it[0] == "ufrag" && it[1] in users } }
        var index = -1
        return sdp.lineSequence().map { line ->
            if (line.startsWith("m=")) index++
            if (!line.startsWith("a=candidate:")) line else {
                val parts = tokens(line)
                val match = proof.firstOrNull { it.first == index && withoutUfrag(it.second) == withoutUfrag(parts) }
                if (match == null) line else "a=" + match.second.joinToString(" ")
            }
        }.joinToString("\r\n")
    }

    private fun credentials(sdp: String): List<Pair<String, String>> {
        if (sdp.length > 65536) return emptyList()
        var user = ""; var password = ""
        var part: MutableList<String>? = null
        val sections = mutableListOf<Pair<Boolean, MutableList<String>>>()
        for (line in sdp.lineSequence().map { it.trim() }) when {
            line.startsWith("m=") -> {
                part = mutableListOf(user, password)
                sections += (line.substringAfter(' ').substringBefore(' ').substringBefore('/').toIntOrNull() != 0) to part
            }
            line.startsWith("a=ice-ufrag:") -> if (part == null) user = line.substringAfter(':') else part[0] = line.substringAfter(':')
            line.startsWith("a=ice-pwd:") -> if (part == null) password = line.substringAfter(':') else part[1] = line.substringAfter(':')
        }
        return sections.filter { it.first }.map { it.second[0] to it.second[1] }
    }

    private fun analyze(sdp: String, complete: Boolean, remote: Boolean, relayOnly: Boolean,
        elapsedMs: Long, errors: Pair<Int, Int>, requireCandidateUfrag: Boolean): IceGatheringSnapshot {
        var sessionUfrag: String? = null
        var section: Section? = null
        val sections = mutableListOf<Section>()
        // Local SDK output is trusted, but an unexpected oversized description
        // cannot authorize a partial answer or produce unbounded diagnostics.
        if (sdp.length <= 65536) for (line in sdp.lineSequence().map { it.trim() }) {
            when {
                line.startsWith("m=") -> {
                    val parts = line.substring(2).split(Regex("\\s+"))
                    val port = parts.getOrNull(1)?.substringBefore('/')?.toIntOrNull()
                    section = Section(parts.size >= 4 && parts[0] == "audio" && port != null && port > 0 &&
                        parts[2].contains("RTP/"), port == 0).also { sections += it }
                }
                line.startsWith("a=ice-ufrag:") -> {
                    val value = line.substringAfter(':').takeIf { it.isNotEmpty() }
                    if (section == null) sessionUfrag = value else section.ufrag = value
                }
                line == "a=rtcp-mux" -> section?.mux = true
                line.startsWith("a=candidate:") -> section?.candidates?.add(line.split(Regex("\\s+")))
            }
        }
        var host = 0; var reflexive = 0; var relay = 0; var other = 0
        var media = 0; var ready = 0
        for (part in sections.filterNot { it.rejected }) {
            media++
            var rtp = false; var rtcp = false
            val ufrag = part.ufrag ?: sessionUfrag
            for (candidate in part.candidates) {
                val kind = if (candidate.size >= 8 && candidate[6] == "typ") candidate[7] else "other"
                when (kind) {
                    "host" -> host++
                    "srflx", "prflx" -> reflexive++
                    "relay" -> relay++
                    else -> other++
                }
                if (kind !in listOf("host", "srflx", "prflx", "relay") || (relayOnly && kind != "relay")) continue
                if (candidate[2].lowercase() !in listOf("udp", "tcp") || candidate[5].toIntOrNull() !in 1..65535) continue
                // The SDK may omit the redundant per-candidate ufrag. Its
                // enclosing current local description then supplies generation.
                val candidateUfrags = candidate.drop(8).chunked(2).filter { it[0] == "ufrag" }
                if (requireCandidateUfrag && candidateUfrags.size != 1) continue
                if (ufrag == null || candidateUfrags.any { it.size != 2 || it[1] != ufrag }) continue
                when (candidate[1].toIntOrNull()) { 1 -> rtp = true; 2 -> rtcp = true }
            }
            if (part.audio && rtp && (part.mux || rtcp)) ready++
        }
        val usable = media > 0 && ready == media
        val result = if (complete) { if (usable) "complete" else "no_candidates" }
            else if (remote && usable) "deadline_with_candidates" else "timed_out"
        return IceGatheringSnapshot(result, elapsedMs.coerceIn(0, 120000), relayOnly,
            host, reflexive, relay, other, media, ready, errors.first, errors.second)
    }
}
