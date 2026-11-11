import Foundation

/// Counts-only summary of one gathering observation (Kotlin `IceGatheringSnapshot`, `IceGathering.kt:5-23`; host
/// validation Go `internal/diagnostics/ice_gathering.go:20-48`).
///
/// Only counts and fixed labels; never SDP, addresses, candidate IDs or credentials. `result` is one
/// of the wire labels `complete`, `trickle`, `candidates_ready`, `deadline_with_candidates`,
/// `timed_out`, `no_candidates`.
public struct IceGatheringSnapshot: Equatable, Sendable {
    public static let submittableResults: Set<String> = [
        "complete", "trickle", "candidates_ready", "deadline_with_candidates",
    ]

    public var result: String
    public var elapsedMs: Int64
    public var relayOnly: Bool
    public var hostCandidates: Int
    public var reflexiveCandidates: Int
    public var relayCandidates: Int
    public var otherCandidates: Int
    public var mediaSections: Int
    public var readySections: Int
    public var candidateErrors: Int
    public var lastErrorCode: Int

    public init(
        result: String, elapsedMs: Int64, relayOnly: Bool, hostCandidates: Int,
        reflexiveCandidates: Int, relayCandidates: Int, otherCandidates: Int,
        mediaSections: Int, readySections: Int, candidateErrors: Int, lastErrorCode: Int
    ) {
        self.result = result
        self.elapsedMs = elapsedMs
        self.relayOnly = relayOnly
        self.hostCandidates = hostCandidates
        self.reflexiveCandidates = reflexiveCandidates
        self.relayCandidates = relayCandidates
        self.otherCandidates = otherCandidates
        self.mediaSections = mediaSections
        self.readySections = readySections
        self.candidateErrors = candidateErrors
        self.lastErrorCode = lastErrorCode
    }

    /// The answer may be submitted (`IceGathering.kt:11`).
    public var canSubmit: Bool { Self.submittableResults.contains(result) }

    /// Whether the host's negotiated `ice_gathering_diagnostics_version` accepts this object
    /// (`IceGathering.kt:12`).
    public func canReport(to version: Int) -> Bool {
        version == 3
            || (version == 2 && result != "trickle")
            || (version == 1 && result != "trickle" && result != "candidates_ready")
    }

    /// Object `version`: 3 for `trickle`, 2 for `candidates_ready`, else 1 (`IceGathering.kt:14`).
    public var wireVersion: Int {
        result == "trickle" ? 3 : (result == "candidates_ready" ? 2 : 1)
    }

    /// Copy with another result label (`s.with(result: "trickle")`).
    public func with(result: String) -> IceGatheringSnapshot {
        var copy = self
        copy.result = result
        return copy
    }

    /// `ice_gathering` report object, Kotlin key order (`IceGathering.kt:13-18`).
    public func json() -> DiagnosticJSON {
        let fields: [(key: String, value: DiagnosticJSON)] = [
            ("version", .int(Int64(wireVersion))),
            ("result", .string(result)),
            ("elapsed_ms", .int(elapsedMs)),
            ("relay_only", .bool(relayOnly)),
            ("host_candidates", .int(Int64(hostCandidates))),
            ("reflexive_candidates", .int(Int64(reflexiveCandidates))),
            ("relay_candidates", .int(Int64(relayCandidates))),
            ("other_candidates", .int(Int64(otherCandidates))),
            ("media_sections", .int(Int64(mediaSections))),
            ("ready_sections", .int(Int64(readySections))),
            ("candidate_errors", .int(Int64(candidateErrors))),
            ("last_error_code", .int(Int64(lastErrorCode))),
        ]
        return .object(fields)
    }

    /// Local copy-report text (`IceGathering.kt:19-22`; "Android" → "iPhone").
    public func text() -> String {
        "Initial iPhone ICE gathering: \(result) · \(elapsedMs) ms · Relay only: \(relayOnly)\n"
            + "Local candidates: host=\(hostCandidates), reflexive=\(reflexiveCandidates), "
            + "relay=\(relayCandidates), other=\(otherCandidates) · Ready media: \(readySections)/\(mediaSections)\n"
            + "Candidate gathering errors: \(candidateErrors) · Last code: \(lastErrorCode)\n"
            + "Candidate availability does not prove a working media path."
    }
}

/// Pure analysis of a local description's gathering state (Kotlin `IceGathering`, `IceGathering.kt:66-189`).
public enum IceGatheringAnalyzer {
    public static let maxDescriptionBytes = 65_536
    public static let maxElapsedMs: Int64 = 120_000

    /// Initial gathering (`IceGathering.kt:75-77`): the SDK may omit the redundant per-candidate
    /// ufrag; the enclosing current description supplies the generation.
    public static func initial(
        _ sdp: String, complete: Bool, remote: Bool, relayOnly: Bool,
        elapsedMs: Int64,
        errors: (count: Int, lastCode: Int) = (count: 0, lastCode: 0)
    ) -> IceGatheringSnapshot {
        analyze(
            sdp, complete: complete, remote: remote, relayOnly: relayOnly, elapsedMs: elapsedMs,
            errors: errors, requireCandidateUfrag: false)
    }

    /// Restart gathering (`IceGathering.kt:79-88`): requires renewed credentials; a partial result
    /// must prove its candidates through callback evidence (`RecoveryCandidateEvidence.snapshot()`).
    public static func recovery(
        _ sdp: String, previous: String, complete: Bool, remote: Bool,
        relayOnly: Bool, elapsedMs: Int64,
        evidence: [(index: Int, sdp: String)] = []
    ) -> IceGatheringSnapshot {
        let fresh = freshCredentials(sdp, previous: previous)
        let observed = complete ? sdp : withCandidateProof(sdp, evidence: evidence)
        var result = analyze(
            observed, complete: complete, remote: remote, relayOnly: relayOnly,
            elapsedMs: elapsedMs, errors: (count: 0, lastCode: 0),
            requireCandidateUfrag: !complete)
        if !fresh {
            result.result = "timed_out"
            result.readySections = 0
        }
        return result
    }

    /// Every active section's ICE ufrag **and** pwd changed versus `previous` (`IceGathering.kt:90-97,119-133`).
    public static func freshCredentials(_ sdp: String, previous: String) -> Bool {
        let before = credentials(previous)
        let after = credentials(sdp)
        guard !before.isEmpty, before.count == after.count else { return false }
        for (old, renewed) in zip(before, after) {
            guard !old.ufrag.isEmpty, !old.pwd.isEmpty, !renewed.ufrag.isEmpty, !renewed.pwd.isEmpty,
                !ICEDescription.bytesEqual(old.ufrag, renewed.ufrag),
                !ICEDescription.bytesEqual(old.pwd, renewed.pwd)
            else { return false }
        }
        return true
    }

    /// `(ufrag, pwd)` of every active m-section (`IceGathering.kt:119-133`): trimmed analysis lines;
    /// session-level values before the first `m=` seed each section; later section lines overwrite
    /// them. A section is inactive only when its port (Kotlin
    /// `substringAfter(' ').substringBefore(' ').substringBefore('/')`) parses to exactly 0.
    static func credentials(_ sdp: String) -> [(ufrag: String, pwd: String)] {
        guard sdp.utf8.count <= maxDescriptionBytes else { return [] }
        var user = ""
        var password = ""
        var sections: [(active: Bool, ufrag: String, pwd: String)] = []
        for raw in ICEDescription.analysisLines(sdp) {
            let line = ICEDescription.kotlinTrimmed(raw)
            if ICEDescription.bytesHavePrefix(line, "m=") {
                let port = ICEDescription.substringBefore(
                    ICEDescription.substringBefore(ICEDescription.substringAfter(line, " "), " "), "/")
                sections.append((active: ICEDescription.kotlinInt(port) != 0, ufrag: user, pwd: password))
            } else if ICEDescription.bytesHavePrefix(line, "a=ice-ufrag:") {
                let value = ICEDescription.substringAfter(line, ":")
                if sections.isEmpty { user = value } else { sections[sections.count - 1].ufrag = value }
            } else if ICEDescription.bytesHavePrefix(line, "a=ice-pwd:") {
                let value = ICEDescription.substringAfter(line, ":")
                if sections.isEmpty { password = value } else { sections[sections.count - 1].pwd = value }
            }
        }
        return sections.filter { $0.active }.map { (ufrag: $0.ufrag, pwd: $0.pwd) }
    }

    /// One m-section as seen by `analyze` (Kotlin `IceGathering.Section`).
    private struct AnalyzedSection {
        let audio: Bool
        let rejected: Bool
        var ufrag: String?
        var mux = false
        var candidates: [[String]] = []
    }

    /// `analyze(sdp, complete, remote, relayOnly, elapsedMs, errors, requireCandidateUfrag)`
    /// (`IceGathering.kt:135-188`).
    static func analyze(
        _ sdp: String, complete: Bool, remote: Bool, relayOnly: Bool, elapsedMs: Int64,
        errors: (count: Int, lastCode: Int), requireCandidateUfrag: Bool
    ) -> IceGatheringSnapshot {
        var sessionUfrag: String?
        var sections: [AnalyzedSection] = []
        // An unexpected oversized description cannot authorize a partial answer or produce
        // unbounded diagnostics (`IceGathering.kt:140-142`).
        if sdp.utf8.count <= maxDescriptionBytes {
            for raw in ICEDescription.analysisLines(sdp) {
                let line = ICEDescription.kotlinTrimmed(raw)
                if ICEDescription.bytesHavePrefix(line, "m=") {
                    let parts = ICEDescription.kotlinFields(ICEDescription.dropBytes(line, 2))
                    // Kotlin `parts.getOrNull(1)?.substringBefore('/')?.toIntOrNull()`.
                    let port: Int32? =
                        parts.count > 1
                        ? ICEDescription.kotlinInt(ICEDescription.substringBefore(parts[1], "/")) : nil
                    let audio =
                        parts.count >= 4 && ICEDescription.bytesEqual(parts[0], "audio")
                        && (port.map { $0 > 0 } ?? false) && ICEDescription.bytesContain(parts[2], "RTP/")
                    sections.append(AnalyzedSection(audio: audio, rejected: port == 0))
                } else if ICEDescription.bytesHavePrefix(line, "a=ice-ufrag:") {
                    let value = ICEDescription.substringAfter(line, ":")
                    let ufrag: String? = value.isEmpty ? nil : value
                    if sections.isEmpty { sessionUfrag = ufrag } else { sections[sections.count - 1].ufrag = ufrag }
                } else if ICEDescription.bytesEqual(line, "a=rtcp-mux") {
                    if !sections.isEmpty { sections[sections.count - 1].mux = true }
                } else if ICEDescription.bytesHavePrefix(line, "a=candidate:") {
                    if !sections.isEmpty {
                        sections[sections.count - 1].candidates.append(ICEDescription.kotlinFields(line))
                    }
                }
            }
        }
        var host = 0
        var reflexive = 0
        var relay = 0
        var other = 0
        var media = 0
        var ready = 0
        for section in sections where !section.rejected {
            media += 1
            var rtp = false
            var rtcp = false
            let ufrag = section.ufrag ?? sessionUfrag
            for candidate in section.candidates {
                let typed = candidate.count >= 8 && ICEDescription.bytesEqual(candidate[6], "typ")
                let kind = typed ? candidate[7] : "other"
                let known: Bool
                if ICEDescription.bytesEqual(kind, "host") {
                    host += 1
                    known = true
                } else if ICEDescription.bytesEqual(kind, "srflx") || ICEDescription.bytesEqual(kind, "prflx") {
                    reflexive += 1
                    known = true
                } else if ICEDescription.bytesEqual(kind, "relay") {
                    relay += 1
                    known = true
                } else {
                    other += 1
                    known = false
                }
                if !known || (relayOnly && !ICEDescription.bytesEqual(kind, "relay")) { continue }
                let transport = candidate[2].lowercased()
                guard ICEDescription.bytesEqual(transport, "udp") || ICEDescription.bytesEqual(transport, "tcp"),
                    let port = ICEDescription.kotlinInt(candidate[5]), (1...65_535).contains(port)
                else { continue }
                // The SDK may omit the redundant per-candidate ufrag; the enclosing current local
                // description then supplies the generation (`IceGathering.kt:174-178`).
                let ufrags = ICEDescription.extensionChunks(candidate).filter {
                    ICEDescription.bytesEqual($0[0], "ufrag")
                }
                if requireCandidateUfrag && ufrags.count != 1 { continue }
                guard let expected = ufrag,
                    !ufrags.contains(where: { $0.count != 2 || !ICEDescription.bytesEqual($0[1], expected) })
                else { continue }
                let component = ICEDescription.kotlinInt(candidate[1])
                if component == 1 {
                    rtp = true
                } else if component == 2 {
                    rtcp = true
                }
            }
            if section.audio && rtp && (section.mux || rtcp) { ready += 1 }
        }
        let usable = media > 0 && ready == media
        let result: String
        if complete {
            result = usable ? "complete" : "no_candidates"
        } else {
            result = remote && usable ? "deadline_with_candidates" : "timed_out"
        }
        return IceGatheringSnapshot(
            result: result, elapsedMs: min(max(elapsedMs, 0), maxElapsedMs), relayOnly: relayOnly,
            hostCandidates: host, reflexiveCandidates: reflexive, relayCandidates: relay,
            otherCandidates: other, mediaSections: media, readySections: ready,
            candidateErrors: errors.count, lastErrorCode: errors.lastCode)
    }

    /// `withCandidateProof(sdp, evidence)` (`IceGathering.kt:99-117`): analysed only, never sent. Each description
    /// candidate line is replaced by the first callback candidate of the same m-section index that carries a current
    /// `ufrag` and matches it apart from `ufrag`.
    static func withCandidateProof(_ sdp: String, evidence: [(index: Int, sdp: String)]) -> String {
        guard sdp.utf8.count <= maxDescriptionBytes else { return "" }
        // Kotlin `value.trim().removePrefix("a=").split(Regex("\\s+"))`.
        func proofTokens(_ value: String) -> [String] {
            ICEDescription.kotlinFields(ICEDescription.removingPrefix(ICEDescription.kotlinTrimmed(value), "a="))
        }
        func withoutUfrag(_ parts: [String]) -> [[UInt8]] {
            var kept = parts.prefix(8).map { Array($0.utf8) }
            for chunk in ICEDescription.extensionChunks(parts) where !ICEDescription.bytesEqual(chunk[0], "ufrag") {
                kept.append(contentsOf: chunk.map { Array($0.utf8) })
            }
            return kept
        }
        var users = Set<[UInt8]>()
        for raw in ICEDescription.analysisLines(sdp) {
            let line = ICEDescription.kotlinTrimmed(raw)
            if ICEDescription.bytesHavePrefix(line, "a=ice-ufrag:") {
                users.insert(Array(ICEDescription.substringAfter(line, ":").utf8))
            }
        }
        let proof: [(index: Int, parts: [String])] = evidence.prefix(RecoveryCandidateEvidence.maxEntries)
            .filter { $0.sdp.utf8.count <= RecoveryCandidateEvidence.maxEntryBytes }
            .map { (index: $0.index, parts: proofTokens($0.sdp)) }
            .filter { entry in
                ICEDescription.extensionChunks(entry.parts).contains { chunk in
                    chunk.count == 2 && ICEDescription.bytesEqual(chunk[0], "ufrag")
                        && users.contains(Array(chunk[1].utf8))
                }
            }
        var index = -1
        let lines = ICEDescription.analysisLines(sdp).map { line -> String in
            if ICEDescription.bytesHavePrefix(line, "m=") { index += 1 }
            guard ICEDescription.bytesHavePrefix(line, "a=candidate:") else { return line }
            let key = withoutUfrag(proofTokens(line))
            guard let match = proof.first(where: { $0.index == index && withoutUfrag($0.parts) == key }) else {
                return line
            }
            return "a=" + match.parts.joined(separator: " ")
        }
        return lines.joined(separator: "\r\n")
    }
}

/// The native host's narrow single-UDP-relay early-submit rule (Kotlin `InitialRelayGathering`,
/// `IceGathering.kt:25-41`; native `ice_gathering.h:46-67`).
///
/// A usable relay set must persist 500 ms; any unusable observation resets readiness.
public struct InitialRelayGathering: Sendable {
    public static let readyAfterMs: Int64 = 500

    public let enabled: Bool
    private var readyAt: Int64?

    public init(enabled: Bool) {
        self.enabled = enabled
        self.readyAt = nil
    }

    public mutating func ready(usable: Bool, nowMs: Int64) -> Bool {
        guard enabled, usable else {
            readyAt = nil
            return false
        }
        let start = readyAt ?? nowMs
        readyAt = start
        return nowMs - start >= Self.readyAfterMs
    }

    /// Forced relay with exactly one TURN URL, which is `turn:…?transport=udp` (STUN URLs allowed).
    /// `urls` = every URL actually passed to the peer (`RemoteICEConfiguration.urls`).
    public static func eligible(relayOnly: Bool, urls: [String]) -> Bool {
        func isTURN(_ url: String) -> Bool {
            ICEDescription.bytesHavePrefix(url, "turn:") || ICEDescription.bytesHavePrefix(url, "turns:")
        }
        guard relayOnly, !urls.contains(where: { !isTURN($0) && !ICEDescription.bytesHavePrefix($0, "stun:") })
        else { return false }
        let turns = urls.filter(isTURN)
        return turns.count == 1 && ICEDescription.bytesHavePrefix(turns[0], "turn:")
            && ICEDescription.bytesHaveSuffix(turns[0], "?transport=udp")
    }
}

/// Candidate-gathering error counter fed by `peerConnection(_:didFailToGatherIceCandidate:)` (Kotlin
/// `IceGatheringErrors`, `IceGathering.kt:43-51`). Thread-safe.
public final class IceGatheringErrors: @unchecked Sendable {
    public static let maxCount = 1_000_000

    private let lock = NSLock()
    private var count = 0
    private var lastCode = 0

    public init() {}

    /// Counts the error; codes outside 0...999 are recorded as 0.
    public func record(code: Int) {
        lock.lock()
        defer { lock.unlock() }
        count = min(count + 1, Self.maxCount)
        lastCode = (0...999).contains(code) ? code : 0
    }

    public func snapshot() -> (count: Int, lastCode: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (count: count, lastCode: lastCode)
    }
}

/// Bounded callback candidates collected during a non-continuous restart (Kotlin `RecoveryCandidates`,
/// `IceGathering.kt:55-64`). Thread-safe; never logged.
public final class RecoveryCandidateEvidence: @unchecked Sendable, CustomReflectable {
    public static let maxEntryBytes = 4_096
    public static let maxTotalBytes = 65_536
    public static let maxEntries = 256

    private let lock = NSLock()
    private var values: [(index: Int, sdp: String)] = []
    private var bytes = 0

    public init() {}

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
        bytes = 0
    }

    /// Ignored unless `index >= 0`, 1...4096 bytes, the 64 KiB total and 256 entries still fit.
    public func add(index: Int, sdp: String) {
        let size = sdp.utf8.count
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, (1...Self.maxEntryBytes).contains(size),
            bytes + size <= Self.maxTotalBytes, values.count < Self.maxEntries
        else { return }
        values.append((index: index, sdp: sdp))
        bytes += size
    }

    public func snapshot() -> [(index: Int, sdp: String)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
