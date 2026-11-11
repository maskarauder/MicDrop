package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class TrickleIceTest {
    private fun sdp(user: String, count: Int = 0, kind: String = "host") =
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:$user\r\n" +
            (0 until count).joinToString("") { "a=candidate:$it 1 udp 123 192.0.2.1 ${5000+it} typ $kind\r\n" }

    @Test fun batchesSurviveLostResponseAndFinishWithFinalAcknowledgment() {
        val a = TrickleIce(sdp("phone"), false)
        val b = TrickleIce(sdp("host"), false)
        a.observe(sdp("host", 35), true); b.observe(sdp("phone", 2), true)
        var addedA = 0; var addedB = 0
        val first = a.delta()
        assertEquals(16, first.candidates.size); assertFalse(first.complete)
        b.accept(first) { addedB++; true }; b.accept(first) { addedB++; true }
        assertEquals(16, addedB)
        repeat(5) {
            a.accept(b.delta()) { addedA++; true }
            b.accept(a.delta()) { addedB++; true }
        }
        assertEquals(2, addedA); assertEquals(35, addedB)
        assertTrue(a.finished); assertTrue(b.finished)
    }

    @Test fun allCandidatesAreValidatedBeforeNativeApplication() {
        val good = TrickleIce.parse(sdp("phone", 1)).second.single()
        for (bad in listOf(good.copy(ufrag = "old"), good.copy(mid = "wrong"), good.copy(index = 1),
            good.copy(candidate = good.candidate + " ufrag old"), good.copy(candidate = good.candidate + "\r\na=private"),
            good.copy(candidate = "x".repeat(2049)))) {
            val a = TrickleIce(sdp("phone"), false); a.observe(sdp("host"), false)
            assertThrows(IllegalArgumentException::class.java) {
                a.accept(TrickleDelta(0, 0, listOf(good, bad), false)) { fail("invalid batch applied"); true }
            }
        }
        val relay = TrickleIce(sdp("phone"), true); relay.observe(sdp("host"), false)
        assertThrows(IllegalArgumentException::class.java) {
            relay.accept(TrickleDelta(0, 0, listOf(good), false)) { fail("direct candidate in forced relay"); true }
        }
    }

    @Test fun completionGenerationAndMemoryLimitsStayClosed() {
        val a = TrickleIce(sdp("phone"), false); a.observe(sdp("host", 1), true)
        a.observe(sdp("host", 1), true)
        assertThrows(IllegalArgumentException::class.java) { a.observe(sdp("new", 1), true) }
        assertThrows(IllegalArgumentException::class.java) { a.observe(sdp("host", 2), true) }
        val c = TrickleIce.parse(sdp("phone", 1)).second.single()
        a.accept(TrickleDelta(0, 0, emptyList(), true)) { true }
        assertThrows(IllegalArgumentException::class.java) { a.accept(TrickleDelta(0, 0, listOf(c), false)) { true } }
        assertThrows(IllegalArgumentException::class.java) { TrickleIce.parse(sdp("host", 129)) }
        assertThrows(IllegalArgumentException::class.java) { TrickleIce.parse(sdp("host") + "x".repeat(65536)) }
    }

    @Test fun orderingAckAndConflictingReplayAreRejected() {
        val a = TrickleIce(sdp("phone"), false); a.observe(sdp("host"), false)
        val c = TrickleIce.parse(sdp("phone", 1)).second.single()
        for (bad in listOf(TrickleDelta(1, 0, emptyList(), false), TrickleDelta(0, 1, listOf(c), false),
            TrickleDelta(0, 0, List(17) { c }, false))) {
            assertThrows(IllegalArgumentException::class.java) { a.accept(bad) { fail("invalid ordering applied"); true } }
        }
        a.accept(TrickleDelta(0, 0, listOf(c), false)) { true }
        assertThrows(IllegalArgumentException::class.java) {
            a.accept(TrickleDelta(0, 0, listOf(c.copy(candidate = c.candidate.replace("5000", "5001"))), false)) { true }
        }
        assertFalse(a.text().contains("192.0.2.1")); assertFalse(a.text().contains("phone"))
    }
}
