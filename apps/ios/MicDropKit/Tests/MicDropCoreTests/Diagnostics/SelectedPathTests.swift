import XCTest

@testable import MicDropCore

final class SelectedPathTests: XCTestCase {
    func testKeepaliveChecksPreserveSelectedPathAndRTTInBothDirections() {
        for outgoing in [false, true] {
            let metrics = PlaybackMetrics(outgoing: outgoing)
            for state in ["succeeded", "in-progress", "succeeded"] {
                let snapshot = metrics.update(samples(pair: "private-active", state: state, outgoing: outgoing))
                XCTAssertEqual(snapshot.path, "direct / udp", state)
                XCTAssertEqual(snapshot.value("rtt_ms"), 8, state)
                XCTAssertEqual(snapshot.transport.localType, "host", state)
                XCTAssertFalse(snapshot.text().contains("private"))
            }
        }
    }

    func testFailedAndUnselectedPairsCannotSupplyPathOrRTT() {
        let metrics = PlaybackMetrics()
        _ = metrics.update(samples(pair: "private-active"))
        for state in ["failed", "waiting", "frozen", "", "unknown"] {
            // The fixture also contains a succeeded but unselected pair with a different RTT.
            let snapshot = metrics.update(samples(pair: "private-active", state: state))
            XCTAssertEqual(snapshot.transport, .unavailable, state)
            XCTAssertEqual(snapshot.path, "unavailable", state)
            XCTAssertNil(snapshot.value("rtt_ms"), state)
        }
        var missingSelection = samples(pair: "private-active")
        missingSelection.removeValue(forKey: "private-transport")
        XCTAssertEqual(metrics.update(missingSelection).transport, .unavailable)
    }

    func testKeepaliveSelectionCountsSwitchesWithoutCountingRepeatedStates() {
        for outgoing in [false, true] {
            let tracker = RouteSelectionTracker()
            func observe(_ pair: String, state: String = "in-progress") -> RouteSelectionSnapshot {
                tracker.update(
                    samples: samples(pair: pair, state: state, outgoing: outgoing), generation: 1,
                    localSDP: sdp(), remoteSDP: sdp())
            }
            XCTAssertEqual(observe("private-first").switches, 0)
            XCTAssertEqual(observe("private-first", state: "succeeded").switches, 0)
            XCTAssertEqual(observe("private-second").switches, 1)
            let repeated = observe("private-second", state: "succeeded")
            XCTAssertEqual(repeated.switches, 1)
            XCTAssertTrue(repeated.negotiated)
            XCTAssertFalse(repeated.text().contains("private"))
        }
    }

    func testFailedAndObsoleteGenerationPairsCannotEstablishOrReplaceBaseline() {
        let tracker = RouteSelectionTracker()
        func observe(
            _ pair: String, state: String = "in-progress", generation: Int64 = 1,
            localUsername: String = "current", remoteUsername: String = "current", expectedUsername: String = "current"
        ) -> Int64 {
            tracker.update(
                samples: samples(
                    pair: pair, state: state, localUsername: localUsername, remoteUsername: remoteUsername),
                generation: generation, localSDP: sdp(username: expectedUsername),
                remoteSDP: sdp(username: expectedUsername)
            ).switches
        }
        XCTAssertEqual(observe("private-first"), 0)
        XCTAssertEqual(observe("private-failed", state: "failed"), 0)
        XCTAssertEqual(observe("private-stale-local", localUsername: "old"), 0)
        XCTAssertEqual(observe("private-stale-remote", remoteUsername: "old"), 0)
        XCTAssertEqual(observe("private-first", state: "succeeded"), 0)
        XCTAssertEqual(observe("private-second"), 1)

        // A restart clears the baseline, even while stats still point at the old selected pair.
        XCTAssertEqual(observe("private-second", generation: 2, expectedUsername: "next"), 1)
        XCTAssertEqual(
            observe("private-half-new", generation: 2, localUsername: "next", expectedUsername: "next"), 1)
        XCTAssertEqual(
            observe(
                "private-new", generation: 2, localUsername: "next", remoteUsername: "next", expectedUsername: "next"),
            1)
        XCTAssertEqual(
            observe(
                "private-newer", generation: 2, localUsername: "next", remoteUsername: "next", expectedUsername: "next"),
            2)
    }

    func testMissingAmbiguousAndOversizedStatsKeepTheLastKnownSelection() {
        let tracker = RouteSelectionTracker()
        func observe(_ values: [String: RtcSample]) -> Int64 {
            tracker.update(samples: values, generation: 1, localSDP: sdp(), remoteSDP: sdp()).switches
        }
        XCTAssertEqual(observe(samples(pair: "private-first")), 0)
        var missingCandidate = samples(pair: "private-missing", state: "in-progress")
        missingCandidate.removeValue(forKey: "private-remote")
        var ambiguous = samples(pair: "private-ambiguous", state: "in-progress")
        ambiguous["other-audio"] = sample(
            "other-audio", "outbound-rtp", ["kind": .string("audio"), "transportId": .string("other-transport")])
        for values in [
            [:], missingCandidate, ambiguous,
            samples(pair: "", state: "in-progress"),
            samples(pair: String(repeating: "x", count: 513), state: "in-progress"),
            samples(pair: String(repeating: "é", count: 257), state: "in-progress"),
        ] {
            XCTAssertEqual(observe(values), 0)
        }
        XCTAssertEqual(observe(samples(pair: "private-first", state: "in-progress")), 0)
        XCTAssertEqual(observe(samples(pair: "private-next", state: "in-progress")), 1)
    }

    func testRenominationRequiresExactTokensOnEveryActiveAudioSection() {
        XCTAssertTrue(RouteSelectionTracker.advertisesRenomination(sdp()))
        XCTAssertTrue(
            RouteSelectionTracker.advertisesRenomination(
                "v=0\na=ice-options:trickle renomination\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"))
        XCTAssertTrue(
            RouteSelectionTracker.advertisesRenomination(
                sdp() + "m=audio 0 UDP/TLS/RTP/SAVPF 111\na=ice-options:trickle\n"))
        XCTAssertFalse(RouteSelectionTracker.advertisesRenomination(sdp() + sdp(options: "trickle")))
        XCTAssertFalse(
            RouteSelectionTracker.advertisesRenomination(
                "a=ice-options:renomination\n" + sdp(options: "trickle")))
        for options in ["", "trickle", "x-renomination", "renomination-extra", "RENOMINATION"] {
            XCTAssertFalse(RouteSelectionTracker.advertisesRenomination(sdp(options: options)), options)
        }
        for value in [nil, "", "a=ice-options:renomination", sdp() + String(repeating: "x", count: 65_536)] {
            XCTAssertFalse(RouteSelectionTracker.advertisesRenomination(value))
        }
    }

    func testGenerationProofUsesInheritedAndOverriddenAudioUsernames() {
        let tracker = RouteSelectionTracker()
        let inherited = "v=0\na=ice-ufrag:current\na=ice-options:renomination\nm=audio 9 UDP/TLS/RTP/SAVPF 111\n"
        func observe(_ pair: String, description: String) -> Int64 {
            tracker.update(
                samples: samples(pair: pair, state: "in-progress"), generation: 1,
                localSDP: description, remoteSDP: inherited
            ).switches
        }
        XCTAssertEqual(observe("private-first", description: inherited), 0)
        XCTAssertEqual(observe("private-stale", description: inherited + "a=ice-ufrag:next\n"), 0)
        XCTAssertEqual(observe("private-mixed", description: inherited + sdp(username: "next")), 0)
        XCTAssertEqual(observe("private-first", description: inherited), 0)
        XCTAssertEqual(observe("private-next", description: inherited), 1)
    }

    func testSessionMetricsKeepSelectedRelayPathAcrossRepeatedKeepalivePingsInEveryMode() throws {
        // libwebrtc marks the selected, writable pair in-progress while each periodic STUN keepalive is
        // outstanding; selection still comes from the transport (`K:MediaTransportTest.kt:66-84`,
        // native `media_transport_test.cc:44-58`).
        for mode in StreamMode.allCases {
            for hop in ["udp", "tcp", "tls"] {
                let label = "\(mode.rawValue) \(hop)"
                let data = relaySamples(hop: hop, outgoing: mode == .microphone)
                var checking = data
                checking["pair"] = relayPair(state: "in-progress", roundTripTime: 0.25)
                var unselected = checking
                unselected.removeValue(forKey: "private-transport")

                let metrics = SessionMetrics(mode: mode)
                let first = metrics.update(data)
                let expected = first.transport
                XCTAssertEqual(expected.relayProtocol, hop, label)
                XCTAssertEqual(expected.path, "relay", label)
                assertNoPrivateValues(first, label)
                for cycle in 1...3 {
                    let context = "\(label) cycle \(cycle)"
                    let snapshot = metrics.update(checking)
                    XCTAssertEqual(snapshot.transport, expected, context)
                    XCTAssertEqual(try XCTUnwrap(snapshot.value("rtt_ms"), context), 250, accuracy: 0.001, context)
                    XCTAssertEqual(snapshot.path, "relay / udp", context)
                    // The phone's own TURN hop, never the remote candidate's TCP hop.
                    XCTAssertEqual(snapshot.transport.relayProtocol, hop, context)
                    XCTAssertTrue(snapshot.text().contains("Network RTT: 250.0 ms"), context)
                    assertNoPrivateValues(snapshot, context)

                    let settled = metrics.update(data)
                    XCTAssertEqual(settled.transport, expected, context)
                    XCTAssertEqual(try XCTUnwrap(settled.value("rtt_ms"), context), 8, accuracy: 0.001, context)
                    assertNoPrivateValues(settled, context)

                    let missing = metrics.update(unselected)
                    XCTAssertEqual(missing.transport, .unavailable, context)
                    XCTAssertNil(missing.value("rtt_ms"), context)
                    assertNoPrivateValues(missing, context)
                }
            }
        }
    }

    private func assertNoPrivateValues(
        _ snapshot: PlaybackSnapshot, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        for output in [
            snapshot.transport.json().encodedString(), snapshot.metricsJSON().encodedString(), snapshot.text(),
        ] {
            XCTAssertFalse(output.contains("private"), context, file: file, line: line)
        }
    }

    private func sdp(options: String = "trickle renomination", username: String = "current") -> String {
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-options:\(options)\r\na=ice-ufrag:\(username)\r\n"
    }

    private func sample(_ id: String, _ type: String, _ members: [String: StatValue]) -> RtcSample {
        RtcSample(id: id, type: type, timestampUs: 1_000_000, members: members)
    }

    private func samples(
        pair: String, state: String = "succeeded", outgoing: Bool = false,
        localUsername: String = "current", remoteUsername: String = "current"
    ) -> [String: RtcSample] {
        let values = [
            sample(
                "audio", outgoing ? "outbound-rtp" : "inbound-rtp",
                [
                    "kind": .string("audio"), "transportId": .string("private-transport"),
                ]),
            sample("private-transport", "transport", ["selectedCandidatePairId": .string(pair)]),
            sample(
                pair, "candidate-pair",
                [
                    "state": .string(state), "currentRoundTripTime": .number(0.008),
                    "localCandidateId": .string("private-local"), "remoteCandidateId": .string("private-remote"),
                ]),
            sample(
                "private-unselected", "candidate-pair",
                [
                    "state": .string("succeeded"), "currentRoundTripTime": .number(9),
                ]),
            sample(
                "private-local", "local-candidate",
                [
                    "candidateType": .string("host"), "protocol": .string("udp"),
                    "usernameFragment": .string(localUsername),
                ]),
            sample(
                "private-remote", "remote-candidate",
                [
                    "candidateType": .string("host"), "usernameFragment": .string(remoteUsername),
                ]),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    /// Android `MediaTransportTest.stats()`: the selected local candidate reaches TURN over `hop` with a UDP
    /// candidate, the remote relay's own TCP hop must never be read as the phone's, and a succeeded but
    /// unselected pair links to a different local candidate.
    private func relaySamples(hop: String, outgoing: Bool) -> [String: RtcSample] {
        let values = [
            sample(
                "first-unrelated", "candidate-pair",
                [
                    "state": .string("succeeded"), "currentRoundTripTime": .number(9),
                    "localCandidateId": .string("unused"),
                ]),
            sample("unused", "local-candidate", ["candidateType": .string("host"), "protocol": .string("tcp")]),
            sample(
                "audio", outgoing ? "outbound-rtp" : "inbound-rtp",
                ["kind": .string("audio"), "transportId": .string("private-transport")]),
            sample("private-transport", "transport", ["selectedCandidatePairId": .string("pair")]),
            relayPair(state: "succeeded", roundTripTime: 0.008),
            sample(
                "local", "local-candidate",
                [
                    "candidateType": .string("relay"), "protocol": .string("udp"), "relayProtocol": .string(hop),
                    "address": .string("private-address"), "url": .string("turns:private-host"),
                    "usernameFragment": .string("private-credential"),
                ]),
            sample("remote", "remote-candidate", ["candidateType": .string("relay"), "relayProtocol": .string("tcp")]),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
    }

    private func relayPair(state: String, roundTripTime: Double) -> RtcSample {
        sample(
            "pair", "candidate-pair",
            [
                "state": .string(state), "currentRoundTripTime": .number(roundTripTime),
                "localCandidateId": .string("local"), "remoteCandidateId": .string("remote"),
            ])
    }
}
