import Foundation

/// Route renomination observation for the report's `route_selection` object (Kotlin `RouteSelectionSnapshot`,
/// `RouteSelection.kt:3-11`; host validation Go `internal/rtc/route_selection.go:14-17`).
public struct RouteSelectionSnapshot: Equatable, Sendable {
    /// Host bound for `generation` and `observed_switches`.
    public static let maxCount: Int64 = 1_000_000

    /// Every active local audio section advertises `a=ice-options:` token `renomination`.
    public let local: Bool
    /// Same for the remote (Windows) description.
    public let remote: Bool
    public let generation: Int64
    public let switches: Int64

    public init(local: Bool, remote: Bool, generation: Int64, switches: Int64) {
        self.local = local
        self.remote = remote
        self.generation = generation
        self.switches = switches
    }

    public var negotiated: Bool { local && remote }

    /// Wire object, Kotlin key order (`RouteSelection.kt:6-8`).
    public func json() -> DiagnosticJSON {
        let fields: [(key: String, value: DiagnosticJSON)] = [
            ("version", .int(1)),
            ("local_renomination", .bool(local)),
            ("remote_renomination", .bool(remote)),
            ("negotiated", .bool(negotiated)),
            ("generation", .int(generation)),
            ("observed_switches", .int(switches)),
        ]
        return .object(fields)
    }

    /// Copy-report line (`RouteSelection.kt:9-10`).
    public func text() -> String {
        "Route renomination: \(negotiated ? "negotiated" : "not negotiated") · Phone support: \(local) · Windows support: \(remote) · Observed route switches: \(switches) · ICE generation: \(generation)"
    }
}

/// Selected-pair switch counter across stats polls (Kotlin `RouteSelection`, `RouteSelection.kt:13-80`; native mirror
/// `native/rtc/route_selection.h`).
///
/// Worker-owned. Candidate-pair IDs are private, bounded comparison state only (never reported).
/// Missing stats keep the last known pair; polling may miss intermediate changes.
public final class RouteSelectionTracker {
    public static let maxPairIDBytes = 512

    private var previous: String?
    private var generation: Int64 = 0
    private var switches: Int64 = 0

    public init() {}

    /// `update(samples, currentGeneration, localSDP, remoteSDP)`; the session passes `LanRecovery.generation` (restarts
    /// begun) as `generation` (`StreamReceiver.kt:697-698`).
    public func update(
        samples: [String: RtcSample], generation currentGeneration: Int64,
        localSDP: String?, remoteSDP: String?
    ) -> RouteSelectionSnapshot {
        if generation != currentGeneration {
            previous = nil
            generation = currentGeneration
        }
        let transports = Set(
            samples.values.filter { sample in
                (Self.isType(sample, "inbound-rtp") || Self.isType(sample, "outbound-rtp"))
                    && Self.member(sample, "kind", equals: "audio")
            }
            .compactMap { Self.string($0, "transportId") })
        let transport = transports.count == 1 ? Self.sample(samples, transports.first, type: "transport") : nil
        let pairID = transport.flatMap { Self.string($0, "selectedCandidatePairId") }
        let pair = Self.sample(samples, pairID, type: "candidate-pair")
            // Keepalive checks can change state without changing the selected path.
            // Both candidate usernames must still prove the current restart generation.
            .flatMap {
                Self.member($0, "state", equals: "succeeded") || Self.member($0, "state", equals: "in-progress")
                    ? $0 : nil
            }
        // At generation 0 any selected pair counts; after a restart only a pair whose both
        // candidates carry the current descriptions' ufrags may become the baseline.
        let localCandidate = Self.sample(
            samples, pair.flatMap { Self.string($0, "localCandidateId") }, type: "local-candidate")
        let remoteCandidate = Self.sample(
            samples, pair.flatMap { Self.string($0, "remoteCandidateId") }, type: "remote-candidate")
        let current =
            generation == 0
            || (Self.usernameMatches(localSDP, localCandidate) && Self.usernameMatches(remoteSDP, remoteCandidate))
        if let id = pair?.id, current, !id.isEmpty, id.utf8.count <= Self.maxPairIDBytes {
            if let known = previous, !ICEDescription.bytesEqual(known, id) {
                switches = min(switches + 1, RouteSelectionSnapshot.maxCount)
            }
            previous = id
        }
        return RouteSelectionSnapshot(
            local: Self.advertisesRenomination(localSDP), remote: Self.advertisesRenomination(remoteSDP),
            generation: min(max(generation, 0), RouteSelectionSnapshot.maxCount), switches: switches)
    }

    /// `update(_:generation:localSDP:remoteSDP:)` spelling used by 03 (same behaviour).
    public func update(
        _ samples: [String: RtcSample], generation currentGeneration: Int64,
        localSDP: String?, remoteSDP: String?
    ) -> RouteSelectionSnapshot {
        update(samples: samples, generation: currentGeneration, localSDP: localSDP, remoteSDP: remoteSDP)
    }

    /// Every active audio section (port > 0) carries the exact, case-sensitive token `renomination` in its effective
    /// `a=ice-options` (media-level replaces session-level); nil, oversize (>65536 bytes) or audio-less descriptions →
    /// false. Never rewrite SDP (`RouteSelection.kt:50-52`).
    public static func advertisesRenomination(_ sdp: String?) -> Bool {
        let sections = audioSections(sdp)
        return !sections.isEmpty && sections.allSatisfy { $0.renomination }
    }

    /// `advertises(_:)` spelling used by 03 (same behaviour as `advertisesRenomination(_:)`).
    public static func advertises(_ sdp: String?) -> Bool {
        advertisesRenomination(sdp)
    }

    // MARK: - Private (Kotlin `RouteSelection` companion, `RouteSelection.kt:40-79`)

    /// `usernameFragment` of the candidate is non-empty and equals the effective `a=ice-ufrag` of
    /// every active audio section of `sdp` (which must have at least one).
    private static func usernameMatches(_ sdp: String?, _ candidate: RtcSample?) -> Bool {
        guard let candidate = candidate, let username = string(candidate, "usernameFragment") else { return false }
        let sections = audioSections(sdp)
        return !username.isEmpty && !sections.isEmpty
            && sections.allSatisfy { section in
                section.username.map { ICEDescription.bytesEqual($0, username) } ?? false
            }
    }

    /// Active audio sections with their effective options and ufrag. Untrimmed analysis lines; a
    /// media-level `a=ice-options` replaces (does not merge with) the session-level set; several
    /// media-level lines merge (`RouteSelection.kt:53-78`).
    private static func audioSections(_ sdp: String?) -> [(renomination: Bool, username: String?)] {
        guard let sdp = sdp, sdp.utf8.count <= IceGatheringAnalyzer.maxDescriptionBytes else { return [] }
        var sessionRenomination = false
        var sessionUsername: String?
        var username: String?
        var inMedia = false
        var audio = false
        var renomination: Bool?
        var sections: [(renomination: Bool, username: String?)] = []
        func finish() {
            if audio {
                sections.append(
                    (renomination: renomination ?? sessionRenomination, username: username ?? sessionUsername))
            }
        }
        for line in ICEDescription.analysisLines(sdp) {
            if ICEDescription.bytesHavePrefix(line, "m=") {
                finish()
                inMedia = true
                renomination = nil
                username = nil
                let fields = ICEDescription.kotlinFields(ICEDescription.dropBytes(line, 2))
                audio =
                    fields.count >= 3 && ICEDescription.bytesEqual(fields[0], "audio")
                    && (ICEDescription.kotlinInt(ICEDescription.substringBefore(fields[1], "/")) ?? 0) > 0
            } else if ICEDescription.bytesHavePrefix(line, "a=ice-options:") {
                let tokens = ICEDescription.kotlinFields(
                    ICEDescription.kotlinTrimmed(ICEDescription.substringAfter(line, ":")))
                let advertised = tokens.contains { ICEDescription.bytesEqual($0, "renomination") }
                if inMedia {
                    renomination = (renomination ?? false) || advertised
                } else {
                    sessionRenomination = sessionRenomination || advertised
                }
            } else if ICEDescription.bytesHavePrefix(line, "a=ice-ufrag:") {
                let value = ICEDescription.substringAfter(line, ":")
                if inMedia { username = value } else { sessionUsername = value }
            }
        }
        finish()
        return sections
    }

    private static func isType(_ sample: RtcSample, _ type: String) -> Bool {
        ICEDescription.bytesEqual(sample.type, type)
    }

    /// Kotlin `members[key] as? String`.
    private static func string(_ sample: RtcSample, _ key: String) -> String? {
        if case .string(let value)? = sample.members[key] { return value }
        return nil
    }

    /// Kotlin `members[key] == value` for a string value.
    private static func member(_ sample: RtcSample, _ key: String, equals value: String) -> Bool {
        string(sample, key).map { ICEDescription.bytesEqual($0, value) } ?? false
    }

    /// `id?.let { samples[it] }?.takeIf { it.type == type }`.
    private static func sample(_ samples: [String: RtcSample], _ id: String?, type: String) -> RtcSample? {
        guard let id = id, let sample = samples[id], isType(sample, type) else { return nil }
        return sample
    }
}
