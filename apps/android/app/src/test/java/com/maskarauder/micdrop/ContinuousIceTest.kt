package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class ContinuousIceTest {
    private fun sdp(user: String, port: Int? = null) =
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:$user\r\na=ice-pwd:password-$user\r\n" +
            (port?.let { "a=candidate:a 1 udp 123 192.0.2.1 $it typ host\r\n" } ?: "")

    @Test fun snapshotsReplaceAndRemoveAfterInitialExchangeWithLostResponses() {
        val a = ContinuousIce(sdp("phone"), false, 2)
        val b = ContinuousIce(sdp("host"), false, 2)
        b.observe(sdp("phone"))
        val native = mutableSetOf<TrickleCandidate>()
        var added = 0; var removed = 0
        val add: (TrickleCandidate) -> Boolean = { added++; assertTrue(native.add(it)); true }
        val remove: (TrickleCandidate) -> Boolean = { removed++; assertTrue(native.remove(it)); true }
        repeat(1000) { i ->
            a.observe(sdp("host", 5000 + i))
            val update = a.snapshot()
            b.accept(update, add, remove); b.accept(update, add, remove)
            a.accept(b.snapshot(), { true }, { true })
            assertEquals(1, native.size)
            assertNull(a.snapshot().candidates)
        }
        assertEquals(1000, added); assertEquals(999, removed)
        a.observe(sdp("host"))
        assertEquals(emptyList<Any>(), a.snapshot().fields()["candidates"])
        b.accept(a.snapshot(), add, remove)
        assertTrue(native.isEmpty())
        assertFalse(a.text().contains("192.0.2")); assertFalse(a.text().contains("password"))
    }

    @Test fun snapshotValidationPrecedesAnyNativeOperation() {
        val a = ContinuousIce(sdp("phone"), false, 2); a.observe(sdp("host", 5000))
        val first = a.snapshot(); val c = first.candidates!!.single()
        val fail: (TrickleCandidate) -> Boolean = { fail("invalid snapshot reached SDK"); false }
        for (d in listOf(first.copy(version = 2), first.copy(generation = 0), first.copy(ack = 99),
            first.copy(revision = 0), first.copy(revision = ContinuousIce.MAX_REVISION + 1), first.copy(candidates = null),
            first.copy(candidates = listOf(c.copy(ufrag = "old"))), first.copy(candidates = listOf(c, c)),
            first.copy(candidates = listOf(c.copy(candidate = c.candidate + " ufrag old"))),
            first.copy(candidates = (0..64).map { c.copy(candidate = c.candidate.replace("5000", "${5000+it}")) }),
            first.copy(candidates = (0..19).map { c.copy(candidate = c.candidate.replace("5000", "${5000+it}") + " " + "x".repeat(1800)) }))) {
            val b = ContinuousIce(sdp("host"), false, 2); b.observe(sdp("phone"))
            assertThrows(IllegalArgumentException::class.java) { b.accept(d, fail, fail) }
        }
        val relay = ContinuousIce(sdp("host"), true, 2); relay.observe(sdp("phone"))
        assertThrows(IllegalArgumentException::class.java) { relay.accept(first, fail, fail) }
    }

    @Test fun credentialsAndRevisionsCannotBeReopened() {
        val a = ContinuousIce(sdp("phone"), false, 2); a.observe(sdp("host", 5000))
        val b = ContinuousIce(sdp("host"), false, 2); b.observe(sdp("phone"))
        val first = a.snapshot(); b.accept(first, { true }, { true })
        a.observe(sdp("host", 5001))
        assertThrows(IllegalArgumentException::class.java) { b.accept(a.snapshot().copy(revision = first.revision), { true }, { true }) }
        b.accept(a.snapshot(), { true }, { true })
        assertThrows(IllegalArgumentException::class.java) { b.accept(first, { true }, { true }) }
        assertThrows(IllegalArgumentException::class.java) { a.observe(sdp("renewed", 5001)) }
        assertTrue(IceGathering.freshCredentials(sdp("new"), sdp("old")))
        assertFalse(IceGathering.freshCredentials(sdp("same"), sdp("same")))
    }

    @Test fun callbackProofExcludesStaleGenerationsAndReleasesRemovedCandidates() {
        val evidence = ContinuousCandidates()
        val line = "candidate:a 1 udp 123 192.0.2.1 5000 typ host"
        assertFalse(evidence.description(sdp("new", 5000)).contains("a=candidate:"))
        evidence.add(0, "$line ufrag old")
        assertFalse(evidence.description(sdp("new", 5000)).contains("a=candidate:"))
        evidence.clear(); evidence.add(0, "$line ufrag new")
        assertTrue(evidence.description(sdp("new", 5000)).contains("ufrag new"))
        evidence.remove(-1, "$line ufrag new")
        assertFalse(evidence.description(sdp("new", 5000)).contains("a=candidate:"))
        repeat(1000) { i ->
            val candidate = line.replace("5000", "${5000+i}") + " ufrag new"
            evidence.add(0, candidate); evidence.remove(-1, candidate)
        }
        assertFalse(evidence.description(sdp("new", 5000)).contains("a=candidate:"))
        assertFalse(ContinuousIce.withoutCandidates(sdp("new", 5000)).contains("a=candidate:"))
    }
}
