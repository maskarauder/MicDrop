import Foundation

/// Initial trickle ICE exchange, generation 0 only (Kotlin `TrickleIce`, `TrickleIce.kt:18-72`; host mirror Go
/// `internal/rtc/trickle.go:153-252`).
///
/// Worker-owned: every method is synchronous and called only from the session worker thread. All validation of an
/// incoming delta happens before any native work; the native add is the synchronous closure passed to `accept` (the app
/// bridges `RTCPeerConnection.add` through `SessionWorkerWait`). The first ICE restart retires the exchange
/// (`beforeRestart`).
public final class TrickleExchange: CustomStringConvertible, CustomReflectable {
    /// Request header sent with value `1` on remote v3 `/offer` only (`TrickleIce.kt:75`).
    public static let header = "X-MicDrop-Trickle-ICE"
    public static let maxBytes = 65_536
    public static let maxCandidates = 128
    public static let batchSize = 16

    /// The `ice` wire object, version 1 (Kotlin `TrickleDelta`, `TrickleIce.kt:9-13`).
    ///
    /// Phone → host: always all six keys and always an array (`json()`). Host → phone: `candidates`
    /// may be JSON `null` or absent; both decode as `[]` (`StreamReceiver.kt:1625-1630`).
    public struct Delta: Decodable, Equatable, Sendable,
        CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
    {
        public var version: Int
        public var generation: Int64
        /// Number of the peer's candidates this sender has received (cumulative).
        public var ack: Int
        /// Index, in the sender's local list, of the first entry of `candidates`.
        public var offset: Int
        public var candidates: [ICECandidateWire]
        /// Sender's gathering is complete and this batch reaches the end of its list.
        public var complete: Bool

        public init(
            version: Int = 1, generation: Int64 = 0, ack: Int, offset: Int,
            candidates: [ICECandidateWire], complete: Bool
        ) {
            self.version = version
            self.generation = generation
            self.ack = ack
            self.offset = offset
            self.candidates = candidates
            self.complete = complete
        }

        private enum CodingKeys: String, CodingKey {
            case version, generation, ack, offset, candidates, complete
        }

        /// Host reply decoding (`StreamReceiver.kt:1623-1633`): `version`, `generation`, `ack`,
        /// `offset` (integers) and `complete` (bool) are required; `candidates` null/absent → `[]`;
        /// every entry needs string `mid`, int `index`, string `ufrag`, string `candidate`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            generation = try container.decode(Int64.self, forKey: .generation)
            ack = try container.decode(Int.self, forKey: .ack)
            offset = try container.decode(Int.self, forKey: .offset)
            candidates = try container.decodeIfPresent([ICECandidateWire].self, forKey: .candidates) ?? []
            complete = try container.decode(Bool.self, forKey: .complete)
        }

        public var description: String { "TrickleDelta(private)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }

        /// Phone → host wire object, Kotlin key order (`TrickleIce.kt:10-11`):
        /// `version, generation, ack, offset, candidates, complete`.
        public func json() -> DiagnosticJSON {
            let fields: [(key: String, value: DiagnosticJSON)] = [
                ("version", .int(Int64(version))),
                ("generation", .int(generation)),
                ("ack", .int(Int64(ack))),
                ("offset", .int(Int64(offset))),
                ("candidates", .array(candidates.map { $0.json() })),
                ("complete", .bool(complete)),
            ]
            return .object(fields)
        }

        /// Decodes the host's `ice` member from a raw `/status` response body (status 200 bytes). Undecodable JSON →
        /// `ICEProtocolError.invalidUpdate`; a missing or `null` member → `ICEProtocolError.missingUpdate` (fatal
        /// either way).
        public static func hostUpdate(statusBody: [UInt8]) throws -> Delta {
            let envelope: TrickleStatusEnvelope
            do {
                envelope = try JSONDecoder().decode(TrickleStatusEnvelope.self, from: Data(statusBody))
            } catch {
                throw ICEProtocolError.invalidUpdate
            }
            guard let delta = envelope.ice else { throw ICEProtocolError.missingUpdate }
            return delta
        }
    }

    private let relayOnly: Bool
    private let remoteSections: [ICEDescription.Section]
    private var localSections: [ICEDescription.Section]?
    private var local: [ICECandidateWire] = []
    private var received: [ICECandidateWire] = []
    /// UTF-8 bytes of every `candidate` in `local` / `received` (Kotlin recomputes `sumOf`).
    private var localBytes = 0
    private var receivedBytes = 0
    /// How many of **our** candidates the peer acknowledged.
    private var ack = 0
    private var sentAck = -1
    private var localComplete = false
    private var remoteComplete = false

    /// Both sides complete and fully acknowledged; status bodies then omit `ice`.
    public private(set) var finished = false

    /// `init(remote, relayOnly)`: parses the host's offer for its sections; an invalid offer throws (fatal
    /// `SETUP_FAILED`).
    public init(remoteDescription: String, relayOnly: Bool) throws {
        self.relayOnly = relayOnly
        self.remoteSections = try ICEDescription.parse(remoteDescription).sections
    }

    /// Adds the local description's new candidates (`observe`, `TrickleIce.kt:30-41`). Read `complete` (gathering
    /// state) **before** the description.
    public func observe(localDescription: String, complete: Bool) throws {
        let (sections, candidates) = try ICEDescription.parse(localDescription)
        if let known = localSections, known != sections { throw ICEProtocolError.generationChanged }
        localSections = sections
        for candidate in candidates where !local.contains(candidate) {
            let size = candidate.candidate.utf8.count
            guard !localComplete,
                ICEDescription.isValid(candidate, sections: sections, relayOnly: relayOnly),
                local.count < Self.maxCandidates,
                localBytes + size <= Self.maxBytes
            else { throw ICEProtocolError.candidateLimit }
            local.append(candidate)
            localBytes += size
        }
        localComplete = localComplete || complete
    }

    /// Next outgoing delta (`delta`, `TrickleIce.kt:43-47`).
    public func delta() -> Delta {
        let end = min(local.count, ack + Self.batchSize)
        sentAck = received.count
        return Delta(
            ack: received.count, offset: ack, candidates: Array(local[ack..<end]),
            complete: localComplete && end == local.count)
    }

    /// Accepts the host's delta (`accept`, `TrickleIce.kt:49-70`). `apply` performs the native add for each new
    /// candidate and returns false when WebRTC rejected it.
    public func accept(_ delta: Delta, apply: (ICECandidateWire) throws -> Bool) throws {
        let count = delta.candidates.count
        guard ack <= delta.ack, delta.ack <= local.count,
            delta.offset >= 0, delta.offset <= received.count,
            count <= Self.batchSize,
            delta.offset + count <= Self.maxCandidates
        else { throw ICEProtocolError.invalidUpdate }
        var bytes = receivedBytes
        for (i, candidate) in delta.candidates.enumerated() {
            let at = delta.offset + i
            guard ICEDescription.isValid(candidate, sections: remoteSections, relayOnly: relayOnly) else {
                throw ICEProtocolError.invalidCandidate
            }
            if at < received.count {
                guard received[at] == candidate else { throw ICEProtocolError.conflictingUpdate }
            } else {
                bytes += candidate.candidate.utf8.count
                guard !remoteComplete, bytes <= Self.maxBytes else { throw ICEProtocolError.candidateLimit }
            }
        }
        guard !delta.complete || delta.offset + count >= received.count else {
            throw ICEProtocolError.invalidCompletion
        }
        // All validation is done; native work starts here (`TrickleIce.kt:63-67`).
        for (i, candidate) in delta.candidates.enumerated() where delta.offset + i >= received.count {
            guard try apply(candidate) else { throw ICEProtocolError.candidateRejected }
            received.append(candidate)
            receivedBytes += candidate.candidate.utf8.count
        }
        ack = delta.ack
        remoteComplete = remoteComplete || delta.complete
        finished = localComplete && remoteComplete && ack == local.count && sentAck == received.count
    }

    /// Phone-side checks on the host's `ice` object before `accept` (`StreamReceiver.kt:1624-1626`):
    /// `version == 1 && generation == 0` else `invalidGeneration`; at most 16 candidates else
    /// `batchLimit`.
    public static func validateIncoming(_ delta: Delta) throws {
        guard delta.version == 1, delta.generation == 0 else { throw ICEProtocolError.invalidGeneration }
        guard delta.candidates.count <= batchSize else { throw ICEProtocolError.batchLimit }
    }

    /// Copy-report line (`TrickleIce.kt:72`).
    public func text() -> String {
        "Incremental ICE: \(finished ? "complete" : "exchanging") · Local candidates: \(local.count) · Acknowledged: \(ack) · Remote candidates: \(received.count)"
    }

    public var description: String { "TrickleExchange(private)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Decoding shell for the `ice` member of a `/status` reply; every other key is ignored.
private struct TrickleStatusEnvelope: Decodable {
    let ice: TrickleExchange.Delta?
}
