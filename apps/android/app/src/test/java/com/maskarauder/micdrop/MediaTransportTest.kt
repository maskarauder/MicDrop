package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class MediaTransportTest {
    private fun stats(localType: String = "relay", hop: String? = "tls", remoteType: String = "relay",
                      outgoing: Boolean = false): Map<String, RtcSample> {
        fun sample(id: String, type: String, vararg fields: Pair<String, Any>) = RtcSample(id, type, 1e6, mapOf(*fields))
        return listOf(
            sample("first-unrelated", "candidate-pair", "state" to "succeeded", "localCandidateId" to "unused"),
            sample("unused", "local-candidate", "candidateType" to "host", "protocol" to "tcp"),
            sample("audio", if (outgoing) "outbound-rtp" else "inbound-rtp", "kind" to "audio", "transportId" to "private-transport"),
            sample("private-transport", "transport", "selectedCandidatePairId" to "pair"),
            sample("pair", "candidate-pair", "state" to "succeeded", "localCandidateId" to "local", "remoteCandidateId" to "remote"),
            RtcSample("local", "local-candidate", 1e6, mapOf("candidateType" to localType, "protocol" to "udp",
                "address" to "private-address", "url" to "turns:private-host", "usernameFragment" to "private-credential") +
                if (hop == null) emptyMap() else mapOf("relayProtocol" to hop)),
            sample("remote", "remote-candidate", "candidateType" to remoteType, "relayProtocol" to "tcp")
        ).associateBy { it.id }
    }

    @Test fun selectedLocalTurnHopIsSeparateFromUdpCandidateForEveryMode() {
        for (mode in StreamMode.entries) for (hop in listOf("udp", "tcp", "tls")) {
            val data = stats(hop = hop, outgoing = mode == StreamMode.MICROPHONE)
            val snapshot = SessionMetrics(mode).update(data)
            assertEquals("relay / udp", snapshot.path)
            assertEquals(hop, snapshot.transport.relayProtocol)
            assertEquals(hop.uppercase(), snapshot.transport.turnText())
            assertEquals(setOf("version", "local_candidate_type", "remote_candidate_type", "candidate_protocol", "relay_protocol"),
                snapshot.transport.fields().keys)
            assertFalse(snapshot.transport.fields().toString().contains("private"))
        }
    }

    @Test fun neverInfersOwnTurnHopFromPeerOrFromCandidateProtocol() {
        val direct = PlaybackMetrics().update(stats("host", null))
        assertEquals("relay / udp", direct.path) // The peer uses TURN, this endpoint does not.
        assertEquals("not_applicable", direct.transport.relayProtocol)
        assertEquals("not used", direct.transport.turnText())
        val unknown = PlaybackMetrics().update(stats(hop = null))
        assertEquals("relay / udp", unknown.path)
        assertEquals("unavailable", unknown.transport.turnText())
        val prflx = PlaybackMetrics().update(stats("prflx", "tls", "host"))
        assertEquals("relay / udp", prflx.path)
        assertEquals("tls", prflx.transport.relayProtocol)
        assertEquals("direct / udp", PlaybackMetrics().update(stats("prflx", null, "host")).path)
    }

    @Test fun missingFailedOrUnlinkedPairsStayUnknown() {
        val data = stats()
        for (missing in listOf("audio", "private-transport", "pair")) {
            assertEquals(MediaTransportSnapshot(), PlaybackMetrics().update(data - missing).transport)
        }
        val pair = data.getValue("pair")
        for (state in listOf("failed", "waiting", "frozen", "private-text")) {
            assertEquals(MediaTransportSnapshot(), PlaybackMetrics().update(data + (pair.id to
                pair.copy(members = pair.members + ("state" to state)))).transport)
        }
        assertEquals("unavailable", PlaybackMetrics().update(data - "local").transport.relayProtocol)
        val local = data.getValue("local")
        assertEquals("unavailable", PlaybackMetrics().update(data + (local.id to local.copy(type = "remote-candidate"))).transport.localType)
        assertEquals("tls", PlaybackMetrics().update(data - "remote").transport.relayProtocol)
    }

    @Test fun selectedPairRemainsObservableDuringKeepalivePings() {
        for (mode in StreamMode.entries) {
            val metrics = SessionMetrics(mode)
            val data = stats(outgoing = mode == StreamMode.MICROPHONE)
            val pair = data.getValue("pair")
            val expected = metrics.update(data).transport
            // libwebrtc sets a previously succeeded pair to in-progress for
            // each periodic STUN ping. Selection still comes from transport.
            repeat(3) {
                val checking = data + (pair.id to pair.copy(members = pair.members +
                    mapOf("state" to "in-progress", "currentRoundTripTime" to 0.25)))
                val snapshot = metrics.update(checking)
                assertEquals(expected, snapshot.transport)
                assertEquals(250.0, snapshot.values["rtt_ms"]!!, 0.001)
                assertEquals(expected, metrics.update(data).transport)
                assertEquals(MediaTransportSnapshot(), metrics.update(checking - "private-transport").transport)
            }
        }
    }

    @Test fun unknownValuesNeverReachReports() {
        val data = stats("private-local", "private-hop", "private-remote").toMutableMap()
        val local = data.getValue("local")
        data[local.id] = local.copy(members = local.members + ("protocol" to "private-protocol"))
        val transport = PlaybackMetrics().update(data).transport
        assertEquals(MediaTransportSnapshot(), transport)
        assertFalse(transport.fields().toString().contains("private"))
        assertEquals("unavailable", PlaybackMetrics().update(stats(hop = "private-hop")).transport.relayProtocol)
    }

    @Test fun windowsReportsRequireVersionFixedLabelsAndConsistentLocalHop() {
        for (local in listOf("relay", "prflx")) for (hop in listOf("udp", "tcp", "tls", "unavailable")) {
            val expected = MediaTransportSnapshot(local, "host", "udp", hop)
            assertEquals(expected, MediaTransportSnapshot.reported(expected.fields()))
        }
        val direct = MediaTransportSnapshot("host", "relay", "udp", "not_applicable")
        assertEquals(direct, MediaTransportSnapshot.reported(direct.fields()))
        val fields = MediaTransportSnapshot("relay", "host", "udp", "tls").fields()
        val bad = listOf(emptyMap(), fields - "relay_protocol", fields + ("version" to 2),
            fields + ("version" to "1"), fields + ("local_candidate_type" to "private"),
            fields + ("candidate_protocol" to "tls"), fields + ("relay_protocol" to "private"),
            fields + ("relay_protocol" to "not_applicable"), fields + ("local_candidate_type" to "host"),
            fields + ("local_candidate_type" to "unavailable"))
        for (report in bad) assertEquals(MediaTransportSnapshot(), MediaTransportSnapshot.reported(report))
    }
}
