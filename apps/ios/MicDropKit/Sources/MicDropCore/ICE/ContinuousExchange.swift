import Foundation

/// Continuous ICE replacement snapshots for one ICE generation (Kotlin `ContinuousIce`, `ContinuousIce.kt:12-69`; host
/// mirror Go `internal/rtc/continuous.go:47-173`).
///
/// Worker-owned: synchronous, called only from the session worker. A restart creates a fresh exchange for the new
/// generation. Acknowledged sets carry only counters; no event history grows with the session.
public final class ContinuousExchange: CustomStringConvertible, CustomReflectable {
    /// Request header sent with value `1` on remote v3 `/offer` only (`ContinuousIce.kt:188`).
    public static let header = "X-MicDrop-Continuous-ICE"
    public static let maxCandidates = 64
    public static let maxBytes = 32_768
    public static let maxRevision: Int64 = 1_000_000_000

    /// The `continuous_ice` wire object, version 1 (Kotlin `IceSnapshot`, `ContinuousIce.kt:3-8`).
    ///
    /// `candidates == nil` means "acknowledged, omitted": `json()` omits the key (never `null`);
    /// `[]` explicitly empties the set. Host replies may omit the key or send `null` → nil.
    /// Generation/revision/ack are Int64 (Kotlin `Long`; Go uint64 values stay ≤ 1e9 / 1e6).
    public struct Snapshot: Decodable, Equatable, Sendable,
        CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
    {
        public var version: Int
        public var generation: Int64
        public var revision: Int64
        public var ack: Int64
        public var candidates: [ICECandidateWire]?

        public init(
            version: Int = 1, generation: Int64, revision: Int64, ack: Int64,
            candidates: [ICECandidateWire]?
        ) {
            self.version = version
            self.generation = generation
            self.revision = revision
            self.ack = ack
            self.candidates = candidates
        }

        private enum CodingKeys: String, CodingKey {
            case version, generation, revision, ack, candidates
        }

        /// Host reply decoding (`StreamReceiver.kt:1635-1646`): `version`, `generation`, `revision`,
        /// `ack` required integers; `candidates` optional (absent/null → nil).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            generation = try container.decode(Int64.self, forKey: .generation)
            revision = try container.decode(Int64.self, forKey: .revision)
            ack = try container.decode(Int64.self, forKey: .ack)
            candidates = try container.decodeIfPresent([ICECandidateWire].self, forKey: .candidates)
        }

        public var description: String { "IceSnapshot(private)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }

        /// Phone → host wire object, Kotlin key order (`ContinuousIce.kt:132-133`):
        /// `version, generation, revision, ack[, candidates]`.
        public func json() -> DiagnosticJSON {
            var fields: [(key: String, value: DiagnosticJSON)] = [
                ("version", .int(Int64(version))),
                ("generation", .int(generation)),
                ("revision", .int(revision)),
                ("ack", .int(ack)),
            ]
            if let candidates = candidates {
                fields.append((key: "candidates", value: .array(candidates.map { $0.json() })))
            }
            return .object(fields)
        }

        /// Decodes the host's `continuous_ice` member from a raw `/status` response body. Undecodable JSON →
        /// `ICEProtocolError.invalidSnapshot`; missing/`null` member → `ICEProtocolError.missingUpdate` (fatal either
        /// way).
        public static func hostUpdate(statusBody: [UInt8]) throws -> Snapshot {
            let envelope: ContinuousStatusEnvelope
            do {
                envelope = try JSONDecoder().decode(ContinuousStatusEnvelope.self, from: Data(statusBody))
            } catch {
                throw ICEProtocolError.invalidSnapshot
            }
            guard let snapshot = envelope.continuousICE else { throw ICEProtocolError.missingUpdate }
            return snapshot
        }
    }

    /// The accepted ICE generation (0 initially; the restart generation afterwards). The session requires `generation
    /// == LanRecovery.generation` before every poll (fatal otherwise).
    public let generation: Int64

    private let relayOnly: Bool
    private let remoteSections: [ICEDescription.Section]
    /// Accepted remote set, canonical order.
    private var remote: [ICECandidateWire]
    private var localSections: [ICEDescription.Section]?
    private var local: [ICECandidateWire] = []
    private var revision: Int64 = 0
    private var remoteRevision: Int64 = 0
    private var ack: Int64 = 0

    /// `init(remote, relayOnly, generation)`: parses the host's (restart) offer; its embedded candidates must pass
    /// `checked`. Throws on an invalid offer (fatal).
    public init(remoteDescription: String, relayOnly: Bool, generation: Int64) throws {
        let parsed = try ICEDescription.parse(remoteDescription)
        self.generation = generation
        self.relayOnly = relayOnly
        self.remoteSections = parsed.sections
        self.remote = try ContinuousExchange.checked(parsed.candidates, sections: parsed.sections, relayOnly: relayOnly)
    }

    /// Observes the evidence-filtered local description (`ContinuousCandidateEvidence.description(for:)`, `observe`,
    /// `ContinuousIce.kt:157-166`).
    public func observe(localDescription: String) throws {
        let (sections, parsed) = try ICEDescription.parse(localDescription)
        if let known = localSections, known != sections { throw ICEProtocolError.generationChanged }
        let current = try Self.checked(parsed, sections: sections, relayOnly: relayOnly)
        if revision == 0 || local != current {
            guard revision < Self.maxRevision else { throw ICEProtocolError.revisionLimit }
            revision += 1
            local = current
        }
        localSections = sections
    }

    /// Next outgoing snapshot (`snapshot`, `ContinuousIce.kt:168`): candidates omitted once the peer acknowledged our
    /// current revision.
    public func snapshot() -> Snapshot {
        Snapshot(
            generation: generation, revision: revision, ack: remoteRevision,
            candidates: ack == revision ? nil : local)
    }

    /// Accepts the host's snapshot (`accept`, `ContinuousIce.kt:170-182`): removals (old − new) before additions (new −
    /// old). `add`/`remove` perform the native calls; false = rejected.
    public func accept(
        _ snapshot: Snapshot, add: (ICECandidateWire) throws -> Bool,
        remove: (ICECandidateWire) throws -> Bool
    ) throws {
        guard snapshot.version == 1, snapshot.generation == generation,
            snapshot.revision >= max(1, remoteRevision), snapshot.revision <= Self.maxRevision,
            snapshot.ack >= ack, snapshot.ack <= revision
        else { throw ICEProtocolError.invalidSnapshot }
        if let candidates = snapshot.candidates {
            let replacement = try Self.checked(candidates, sections: remoteSections, relayOnly: relayOnly)
            guard snapshot.revision != remoteRevision || replacement == remote else {
                throw ICEProtocolError.conflictingSnapshot
            }
            // Whole replacement validated; removals (old − new) precede additions (new − old).
            let incoming = Set(replacement)
            let accepted = Set(remote)
            for candidate in remote where !incoming.contains(candidate) {
                guard try remove(candidate) else { throw ICEProtocolError.removalRejected }
            }
            for candidate in replacement where !accepted.contains(candidate) {
                guard try add(candidate) else { throw ICEProtocolError.candidateRejected }
            }
            remote = replacement
        } else {
            guard snapshot.revision == remoteRevision else { throw ICEProtocolError.missingSnapshot }
        }
        remoteRevision = snapshot.revision
        ack = snapshot.ack
    }

    /// Phone-side check before `accept` (`StreamReceiver.kt:1636-1637`): a present `candidates`
    /// array has at most 64 entries, else `snapshotLimit`. Skipped revisions are legal.
    public static func validateIncoming(_ snapshot: Snapshot) throws {
        if let candidates = snapshot.candidates, candidates.count > maxCandidates {
            throw ICEProtocolError.snapshotLimit
        }
    }

    /// The SDP the phone submits in continuous mode (`/answer`, `/recover-answer`): every candidate line removed
    /// (`ContinuousIce.kt:192-194`).
    public static func withoutCandidates(_ sdp: String) -> String {
        ICEDescription.withoutCandidates(sdp)
    }

    /// Validated canonical set (`checked`, `ContinuousIce.kt:148-155`).
    static func checked(
        _ candidates: [ICECandidateWire], sections: [ICEDescription.Section],
        relayOnly: Bool
    ) throws -> [ICECandidateWire] {
        let total = candidates.reduce(0) { $0 + $1.candidate.utf8.count }
        guard candidates.count <= maxCandidates, total <= maxBytes else { throw ICEProtocolError.snapshotLimit }
        for candidate in candidates {
            guard ICEDescription.isValid(candidate, sections: sections, relayOnly: relayOnly),
                !containsMarkup(candidate.mid), !containsMarkup(candidate.ufrag), !containsMarkup(candidate.candidate),
                candidate.candidate.utf8.allSatisfy({ (32...126).contains($0) })
            else { throw ICEProtocolError.invalidSnapshot }
        }
        guard Set(candidates).count == candidates.count else { throw ICEProtocolError.duplicateCandidate }
        return candidates.sorted { lhs, rhs in
            if lhs.index != rhs.index { return lhs.index < rhs.index }
            return lhs.candidate.utf8.lexicographicallyPrecedes(rhs.candidate.utf8)
        }
    }

    /// Any of `"` `\` `<` `>` `&` (rule 7; keeps the escaped snapshot inside the 96 KiB status envelope, Go
    /// `continuous.go:62`).
    private static func containsMarkup(_ value: String) -> Bool {
        value.utf8.contains { $0 == 0x22 || $0 == 0x5C || $0 == 0x3C || $0 == 0x3E || $0 == 0x26 }
    }

    /// Copy-report line (`ContinuousIce.kt:184-185`).
    public func text() -> String {
        "Continuous ICE: generation \(generation) · Revision: \(revision) · Acknowledged: \(ack) · Local candidates: \(local.count) · Remote candidates: \(remote.count)"
    }

    public var description: String { "ContinuousExchange(private)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Decoding shell for the `continuous_ice` member of a `/status` reply; other keys are ignored.
private struct ContinuousStatusEnvelope: Decodable {
    let continuousICE: ContinuousExchange.Snapshot?

    private enum CodingKeys: String, CodingKey {
        case continuousICE = "continuous_ice"
    }
}

/// Callback provenance for continuous ICE (Kotlin `ContinuousCandidates`, `ContinuousIce.kt:201-234`).
///
/// Thread-safe (`NSLock`): `add`/`remove` arrive on the WebRTC signaling thread, the worker calls
/// `description(for:)`. Proves each local candidate came from the current SDK generation, because SDP
/// candidate lines omit ` ufrag <value>` while SDK callback candidates include it. Callbacks never
/// perform native work. Overflow is sticky until `clear()` and makes the next status step fatal.
public final class ContinuousCandidateEvidence: @unchecked Sendable, CustomReflectable {
    public static let maxIndex = 7
    public static let maxEntryBytes = 2_048
    public static let maxEntries = 128
    public static let maxTotalBytes = 65_536

    private struct Key: Hashable {
        let index: Int
        let key: [UInt8]  // UTF-8 of `ICEDescription.candidateKey(value)`
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private var overflow = false

    public init() {}

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
        overflow = false
    }

    /// `peerConnection(_:didGenerate:)`: `sdp` is `candidate.sdp` (no `a=`). Entries outside
    /// index 0...7, outside 1...2048 bytes or without exactly one ` ufrag` extension are ignored.
    public func add(index: Int, sdp: String) {
        let size = sdp.utf8.count
        guard (0...Self.maxIndex).contains(index), (1...Self.maxEntryBytes).contains(size),
            ICEDescription.candidateUser(sdp) != nil
        else { return }
        let key = Key(index: index, key: Array(ICEDescription.candidateKey(sdp).utf8))
        lock.lock()
        defer { lock.unlock() }
        let existing = values[key]
        let total = values.values.reduce(0) { $0 + $1.utf8.count }
        if (existing == nil && values.count >= Self.maxEntries)
            || total - (existing?.utf8.count ?? 0) + size > Self.maxTotalBytes
        {
            overflow = true
            return
        }
        values[key] = sdp
    }

    /// `peerConnection(_:didRemove:)`: the SDK reports index −1, which matches every section.
    public func remove(index: Int, sdp: String) {
        let key = Array(ICEDescription.candidateKey(sdp).utf8)
        let user = ICEDescription.candidateUser(sdp)
        lock.lock()
        defer { lock.unlock() }
        values = values.filter { entry in
            guard index == -1 || entry.key.index == index, entry.key.key == key else { return true }
            if let user = user {
                guard let other = ICEDescription.candidateUser(entry.value),
                    ICEDescription.bytesEqual(other, user)
                else { return true }
            }
            return false
        }
    }

    /// The local description as observed by `ContinuousExchange.observe`: validates the SDK description, drops empty
    /// lines and `a=end-of-candidates`, and replaces each `a=candidate:` line by its proven callback value (current
    /// section ufrag) or drops it. Joined with CRLF plus a final CRLF. Throws `evidenceLimit` after an overflow.
    public func description(for localDescription: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !overflow else { throw ICEProtocolError.evidenceLimit }
        let sections = try ICEDescription.parse(localDescription).sections
        var index = -1
        var out: [String] = []
        for line in ICEDescription.analysisLines(localDescription) {
            if ICEDescription.bytesHavePrefix(line, "m=") { index += 1 }
            if !ICEDescription.bytesHavePrefix(line, "a=candidate:") {
                if !line.isEmpty && !ICEDescription.bytesEqual(line, "a=end-of-candidates") { out.append(line) }
            } else if index >= 0, index < sections.count,
                let value = values[Key(index: index, key: Array(ICEDescription.candidateKey(line).utf8))],
                let user = ICEDescription.candidateUser(value),
                ICEDescription.bytesEqual(user, sections[index].ufrag)
            {
                out.append("a=" + value)
            }
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
