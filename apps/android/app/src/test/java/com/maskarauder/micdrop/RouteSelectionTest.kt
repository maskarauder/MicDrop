package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class RouteSelectionTest {
    private fun sdp(options: String = "trickle renomination") =
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-options:$options\r\na=ice-ufrag:current\r\n"

    @Test fun capabilityRequiresExactOptionsOnEveryActiveAudioSection() {
        assertTrue(RouteSelection.advertises(sdp()))
        assertTrue(RouteSelection.advertises("v=0\na=ice-options:trickle renomination\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"))
        assertTrue(RouteSelection.advertises(sdp() + "m=audio 0 UDP/TLS/RTP/SAVPF 111\na=ice-options:trickle\n"))
        assertFalse(RouteSelection.advertises(sdp() + "m=audio 9 UDP/TLS/RTP/SAVPF 111\na=ice-options:trickle\n"))
        assertFalse(RouteSelection.advertises("a=ice-options:renomination\n" + sdp("trickle")))
        for (options in listOf("", "trickle", "x-renomination", "renomination-extra", "RENOMINATION"))
            assertFalse(RouteSelection.advertises(sdp(options)))
        for (value in listOf(null, "", "a=ice-options:renomination", sdp().replace("m=audio", "m=video"),
            sdp("trickle") + "a=candidate:renomination\n", sdp() + "x".repeat(65536)))
            assertFalse(RouteSelection.advertises(value))
    }

    private fun samples(pair: String, outgoing: Boolean = false): Map<String, RtcSample> {
        fun sample(id: String, type: String, vararg fields: Pair<String, Any>) = RtcSample(id, type, 1e6, mapOf(*fields))
        return listOf(sample("audio", if (outgoing) "outbound-rtp" else "inbound-rtp", "kind" to "audio", "transportId" to "private-transport"),
            sample("private-transport", "transport", "selectedCandidatePairId" to pair),
            sample(pair, "candidate-pair", "state" to "succeeded", "localCandidateId" to "local", "remoteCandidateId" to "remote"),
            sample("local", "local-candidate", "usernameFragment" to "current"),
            sample("remote", "remote-candidate", "usernameFragment" to "current"),
            sample("unrelated", "candidate-pair", "state" to "succeeded")).associateBy { it.id }
    }

    @Test fun sampledSwitchesExcludeInitialSelectionDuplicatesAndRestartBaseline() {
        for (outgoing in listOf(false, true)) {
            val tracker = RouteSelection()
            fun observe(pair: String, generation: Long = 0) = tracker.update(samples(pair, outgoing), generation, sdp(), sdp())
            assertEquals(0L, observe("private-first").switches)
            assertEquals(0L, observe("private-first").switches)
            assertEquals(1L, observe("private-second").switches)
            assertEquals(1L, observe("private-restarted", 1).switches)
            val changed = observe("private-later", 1)
            assertEquals(2L, changed.switches)
            assertEquals(1L, changed.generation)
            assertTrue(changed.negotiated)
            assertEquals(setOf("version", "local_renomination", "remote_renomination", "negotiated", "generation", "observed_switches"), changed.fields().keys)
            assertFalse(changed.fields().toString().contains("private"))
            assertFalse(changed.text().contains("private"))
        }
    }

    @Test fun missingFailedOversizedAndUnrelatedPairsCannotInventSwitches() {
        val tracker = RouteSelection()
        tracker.update(samples("first"), 0, sdp(), sdp())
        val failed = samples("failed").toMutableMap()
        failed["failed"] = failed.getValue("failed").copy(members = mapOf("state" to "failed"))
        val ambiguous = samples("another").toMutableMap()
        ambiguous["second-audio"] = RtcSample("second-audio", "outbound-rtp", 1e6,
            mapOf("kind" to "audio", "transportId" to "other-transport"))
        for (data in listOf(emptyMap(), samples("another") - "audio", samples("another") - "private-transport",
            failed, ambiguous, samples("x".repeat(513))))
            assertEquals(0L, tracker.update(data, 0, sdp(), sdp()).switches)
        assertEquals(1L, tracker.update(samples("later"), 0, sdp(), sdp()).switches)
    }

    @Test fun mixedSupportRemainsUnnegotiatedAndRestartUpdatesCapability() {
        val tracker = RouteSelection()
        val mixed = tracker.update(samples("first"), 0, sdp(), sdp("trickle"))
        assertTrue(mixed.local); assertFalse(mixed.remote); assertFalse(mixed.negotiated)
        val restarted = tracker.update(samples("second"), 2, sdp("trickle"), sdp())
        assertFalse(restarted.local); assertTrue(restarted.remote); assertFalse(restarted.negotiated)
        assertEquals(0L, restarted.switches)
        assertEquals(1000000L, tracker.update(emptyMap(), Long.MAX_VALUE, null, null).generation)
    }

    @Test fun oldOrUnprovenPairsDuringRestartDoNotBecomeTheNewBaseline() {
        val tracker = RouteSelection()
        tracker.update(samples("old"), 0, sdp(), sdp())
        val next = sdp().replace("current", "next-generation")
        assertEquals(0L, tracker.update(samples("old"), 1, next, next).switches)
        assertEquals(0L, tracker.update(samples("new") - "remote", 1, next, next).switches)
        fun fresh(pair: String) = samples(pair).mapValues { (_, sample) ->
            if (sample.type.endsWith("-candidate")) sample.copy(members = mapOf("usernameFragment" to "next-generation")) else sample
        }
        assertEquals(0L, tracker.update(fresh("new"), 1, next, next).switches)
        assertEquals(1L, tracker.update(fresh("later"), 1, next, next).switches)
    }

    @Test fun keepaliveChecksPreserveCurrentGenerationProofButRejectOldCredentials() {
        fun checking(pair: String, username: String = "current") = samples(pair).mapValues { (_, sample) ->
            when (sample.type) {
                "candidate-pair" -> sample.copy(members = sample.members + ("state" to "in-progress"))
                "local-candidate", "remote-candidate" -> sample.copy(members = mapOf("usernameFragment" to username))
                else -> sample
            }
        }
        val tracker = RouteSelection()
        assertEquals(0L, tracker.update(checking("first"), 1, sdp(), sdp()).switches)
        assertEquals(0L, tracker.update(samples("first"), 1, sdp(), sdp()).switches)
        assertEquals(0L, tracker.update(checking("stale", "old"), 1, sdp(), sdp()).switches)
        assertEquals(0L, tracker.update(checking("missing") - "remote", 1, sdp(), sdp()).switches)
        assertEquals(1L, tracker.update(checking("second"), 1, sdp(), sdp()).switches)
        assertEquals(1L, tracker.update(samples("second"), 1, sdp(), sdp()).switches)
        // Restart still creates a new baseline and requires both new ufrags.
        val next = sdp().replace("current", "next")
        assertEquals(1L, tracker.update(checking("old-baseline"), 2, next, next).switches)
        assertEquals(1L, tracker.update(checking("new", "next"), 2, next, next).switches)
        assertEquals(2L, tracker.update(checking("newer", "next"), 2, next, next).switches)
    }
}
