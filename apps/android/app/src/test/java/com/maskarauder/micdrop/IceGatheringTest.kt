package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class IceGatheringTest {
    @Test fun earlyPolicyPreservesFallbacksAndRequiresContinuousReadiness() {
        val udp = "turn:relay.test:3478?transport=udp"
        assertTrue(InitialRelayGathering.eligible(true, listOf(udp)))
        assertTrue(InitialRelayGathering.eligible(true, listOf("stun:relay.test:3478", udp)))
        assertFalse(InitialRelayGathering.eligible(false, listOf(udp)))
        for (urls in listOf(emptyList(), listOf("stun:relay.test:3478"), listOf(udp, udp),
            listOf(udp, "turn:relay2.test:3478?transport=udp"), listOf(udp, "turns:relay.test:5349?transport=tcp"),
            listOf("turn:relay.test:3478?transport=tcp"), listOf("turns:relay.test:5349?transport=tcp"))) {
            assertFalse(InitialRelayGathering.eligible(true, urls))
        }
        val early = InitialRelayGathering(true)
        assertFalse(early.ready(false, 0))
        assertFalse(early.ready(true, 100))
        assertFalse(early.ready(true, 599))
        assertTrue(early.ready(true, 600))
        assertFalse(early.ready(false, 601))
        assertFalse(early.ready(true, 700))
        assertFalse(early.ready(true, 1199))
        assertTrue(early.ready(true, 1200))
        val disabled = InitialRelayGathering(false)
        assertFalse(disabled.ready(true, 0)); assertFalse(disabled.ready(true, 15000))
    }

    @Test fun earlyDiagnosticsAreNegotiatedWithoutChangingOldReports() {
        val normal = check(audio + candidate())
        assertTrue(normal.canReportTo(1)); assertTrue(normal.canReportTo(2))
        assertFalse(normal.canReportTo(0))
        assertEquals(1, normal.fields()["version"])
        val early = normal.copy(result = "candidates_ready", elapsedMs = 600)
        assertTrue(early.canSubmit); assertTrue(early.canReportTo(2))
        assertFalse(early.canReportTo(1)); assertFalse(early.canReportTo(0))
        assertEquals(2, early.fields()["version"])
    }
    @Test fun restartRequiresRenewedCredentialsAndCallbackProvenanceAtDeadline() {
        val previous = audio + "a=ice-pwd:old-password\r\n" + candidate()
        val current = previous.replace("current-secret", "new-secret").replace("old-password", "new-password")
        val proof = listOf(0 to candidate(suffix = "ufrag new-secret").removePrefix("a="))
        fun result(sdp: String = current, complete: Boolean = false, evidence: List<Pair<Int, String>> = proof) =
            IceGathering.recovery(sdp, previous, complete, true, true, 8000, evidence)
        assertTrue(result().canSubmit)
        assertTrue(result(complete = true, evidence = emptyList()).canSubmit)
        assertFalse(result(evidence = emptyList()).canSubmit)
        assertFalse(result(evidence = listOf(1 to proof[0].second)).canSubmit)
        assertFalse(result(evidence = listOf(0 to candidate(suffix = "ufrag current-secret"))).canSubmit)
        assertFalse(result(sdp = previous, complete = true).canSubmit)
        assertFalse(result(sdp = current.replace("new-password", "old-password"), complete = true).canSubmit)
        assertFalse(result(sdp = current.replace("typ relay", "typ host")).canSubmit)
        assertFalse(IceGathering.recovery(current, previous, false, false, true, 8000, proof).canSubmit)
        val stale = listOf(0 to candidate(suffix = "ufrag current-secret"))
        assertTrue(result(evidence = stale + proof).canSubmit)
    }

    @Test fun restartEvidenceHasABoundedLifetimeAndSize() {
        val evidence = RecoveryCandidates()
        repeat(1000) { evidence.add(0, "x".repeat(1000)) }
        assertTrue(evidence.snapshot().sumOf { it.second.length } <= 65536)
        evidence.clear(); assertTrue(evidence.snapshot().isEmpty())
        evidence.add(-1, "candidate"); evidence.add(0, "x".repeat(4097))
        assertTrue(evidence.snapshot().isEmpty())
    }
    private val audio = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-ufrag:current-secret\r\na=rtcp-mux\r\n"
    private fun candidate(kind: String = "relay", component: Int = 1, suffix: String = "") =
        "a=candidate:private-foundation $component udp 1677734911 203.0.113.17 49170 typ $kind $suffix\r\n"
    private fun check(sdp: String, complete: Boolean = false, remote: Boolean = true, relayOnly: Boolean = true) =
        IceGathering.initial(sdp, complete, remote, relayOnly, 15001)

    @Test fun remoteDeadlineKeepsUsableRelayEvenIfAnotherInterfaceNeverFinishes() {
        val result = check(audio + candidate())
        assertTrue(result.canSubmit)
        assertEquals("deadline_with_candidates", result.result)
        assertEquals(1, result.relayCandidates)
        assertEquals(1, result.readySections)
        assertEquals(15001L, result.elapsedMs)
        assertEquals("complete", check(audio + candidate(), complete = true).result)
    }

    @Test fun relayPolicyDoesNotBecomeDirectAndLanStillRequiresCompletion() {
        assertFalse(check(audio + candidate("host")).canSubmit)
        assertFalse(check(audio + candidate("srflx")).canSubmit)
        assertTrue(check(audio + candidate("host"), relayOnly = false).canSubmit)
        assertFalse(check(audio + candidate(), remote = false).canSubmit)
        assertTrue(check(audio + candidate("host"), complete = true, remote = false, relayOnly = false).canSubmit)
        assertEquals("no_candidates", check(audio, complete = true).result)
        assertEquals("timed_out", check(audio).result)
        assertFalse(check("", complete = true).canSubmit)
    }

    @Test fun everyActiveSectionNeedsTheCorrectComponentsAndCurrentGeneration() {
        assertFalse(check(audio + candidate(component = 2)).canSubmit)
        assertFalse(check(audio + candidate(component = 3)).canSubmit)
        val noMux = audio.replace("a=rtcp-mux\r\n", "")
        assertFalse(check(noMux + candidate()).canSubmit)
        assertTrue(check(noMux + candidate() + candidate(component = 2)).canSubmit)
        assertFalse(check(audio + candidate() + audio).canSubmit)
        assertTrue(check(audio + candidate() + audio.replace("m=audio 9", "m=audio 0")).canSubmit)
        assertFalse(check(audio.replace("m=audio", "m=video") + candidate()).canSubmit)
        assertFalse(check(audio + candidate(suffix = "ufrag old-secret")).canSubmit)
        assertTrue(check(audio + candidate(suffix = "ufrag current-secret")).canSubmit)
        assertFalse(check(audio.replace("a=ice-ufrag:current-secret\r\n", "") + candidate()).canSubmit)
        assertTrue(check("a=ice-ufrag:current-secret\r\n" +
            audio.replace("a=ice-ufrag:current-secret\r\n", "") + candidate()).canSubmit)
    }

    @Test fun unexpectedSdkDescriptionsDoNotAuthorizeAnAnswer() {
        for (line in listOf("a=candidate:broken", candidate().replace("typ relay", "type relay"),
            candidate().replace("49170", "0"), candidate().replace(" udp ", " unknown "),
            candidate(suffix = "ufrag"))) assertFalse(check(audio + line).canSubmit)
        assertFalse(check(audio + candidate() + "x".repeat(65536)).canSubmit)
    }

    @Test fun diagnosticsExposeOnlyCountsAndNumericErrors() {
        val errors = IceGatheringErrors()
        errors.record(701); errors.record(401)
        val result = IceGathering.initial(audio + candidate(), false, true, true, 15001, errors.snapshot())
        assertEquals(2, result.candidateErrors)
        assertEquals(401, result.lastErrorCode)
        assertEquals(setOf("version", "result", "elapsed_ms", "relay_only", "host_candidates", "reflexive_candidates",
            "relay_candidates", "other_candidates", "media_sections", "ready_sections", "candidate_errors", "last_error_code"), result.fields().keys)
        for (privateValue in listOf("203.0.113.17", "49170", "private-foundation", "current-secret")) {
            assertFalse(result.fields().toString().contains(privateValue))
            assertFalse(result.text().contains(privateValue))
        }
        errors.record(-1)
        assertEquals(3 to 0, errors.snapshot())
        // The report owns a frozen snapshot, not mutable callback counters.
        assertEquals(2, result.candidateErrors)
    }
}
