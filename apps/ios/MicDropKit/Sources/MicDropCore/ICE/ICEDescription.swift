import Foundation

/// One ICE candidate as carried by the `ice` and `continuous_ice` wire objects (Kotlin `TrickleCandidate`,
/// `TrickleIce.kt:5-8`; Go `internal/rtc/trickle.go:24-31`).
///
/// Exactly four keys on the wire: `mid`, `index`, `ufrag`, `candidate` (the SDP attribute value **without** `a=`).
/// Private data: `description`, `debugDescription` and reflection print a fixed label only. Equality and hashing
/// compare UTF-8 bytes (Kotlin/Go semantics), never Swift's Unicode canonical equivalence.
public struct ICECandidateWire: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public var mid: String
    public var index: Int
    public var ufrag: String
    public var candidate: String

    public init(mid: String, index: Int, ufrag: String, candidate: String) {
        self.mid = mid
        self.index = index
        self.ufrag = ufrag
        self.candidate = candidate
    }

    public var description: String { "TrickleCandidate(private)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public static func == (lhs: ICECandidateWire, rhs: ICECandidateWire) -> Bool {
        lhs.index == rhs.index
            && ICEDescription.bytesEqual(lhs.mid, rhs.mid)
            && ICEDescription.bytesEqual(lhs.ufrag, rhs.ufrag)
            && ICEDescription.bytesEqual(lhs.candidate, rhs.candidate)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        ICEDescription.hashBytes(mid, into: &hasher)
        ICEDescription.hashBytes(ufrag, into: &hasher)
        ICEDescription.hashBytes(candidate, into: &hasher)
    }

    /// Wire object in Kotlin key order `mid, index, ufrag, candidate` (`TrickleIce.kt:6`).
    public func json() -> DiagnosticJSON {
        let fields: [(key: String, value: DiagnosticJSON)] = [
            ("mid", .string(mid)),
            ("index", .int(Int64(index))),
            ("ufrag", .string(ufrag)),
            ("candidate", .string(candidate)),
        ]
        return .object(fields)
    }
}

/// SDP parsing and candidate validation shared by trickle and continuous ICE (Kotlin `TrickleIce.parse/valid`,
/// `TrickleIce.kt:79-125`; Go `internal/rtc/trickle.go:38-131`).
///
/// All byte counts are UTF-8. All string comparisons that Kotlin/Go perform on raw text are done on UTF-8 bytes here
/// (`bytesEqual`, `bytesHavePrefix`), never with `String ==`/`hasPrefix` (canonical equivalence / grapheme clustering
/// would accept inputs the host rejects).
public enum ICEDescription {
    public static let maxBytes = 65_536
    public static let maxSections = 8
    public static let maxCandidates = 128
    public static let maxMidBytes = 64
    public static let maxUfragBytes = 256
    public static let maxCandidateBytes = 2_048

    /// One m-section's ICE transport identity (Kotlin `TrickleSection`, `TrickleIce.kt:14-16`). Section equality ("ICE
    /// generation changed") compares `(mid, ufrag, index)` bytewise.
    public struct Section: Hashable, Sendable,
        CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
    {
        public var mid: String
        public var ufrag: String
        public var index: Int

        public init(mid: String, ufrag: String, index: Int) {
            self.mid = mid
            self.ufrag = ufrag
            self.index = index
        }

        public var description: String { "TrickleSection(private)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }

        public static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.index == rhs.index
                && ICEDescription.bytesEqual(lhs.mid, rhs.mid)
                && ICEDescription.bytesEqual(lhs.ufrag, rhs.ufrag)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(index)
            ICEDescription.hashBytes(mid, into: &hasher)
            ICEDescription.hashBytes(ufrag, into: &hasher)
        }
    }

    /// `ICEDescription.parse(sdp) throws -> (sections, candidates)` — exact port of `TrickleIce.kt:94-125`. Throws the
    /// `ICEProtocolError` constants `invalidDescription`, `sectionLimit`, `sectionsUnavailable`, `invalidTransport`,
    /// `invalidCandidate`.
    public static func parse(_ sdp: String) throws -> (sections: [Section], candidates: [ICECandidateWire]) {
        let size = sdp.utf8.count
        guard (1...maxBytes).contains(size), !sdp.utf8.contains(0) else {
            throw ICEProtocolError.invalidDescription
        }
        var sections: [Section] = []
        var raw: [[String]] = []
        var global = ""
        for line in parseLines(sdp) {
            let last = sections.count - 1
            if bytesHavePrefix(line, "m=") {
                guard sections.count < maxSections else { throw ICEProtocolError.sectionLimit }
                sections.append(Section(mid: "", ufrag: global, index: sections.count))
                raw.append([])
            } else if bytesHavePrefix(line, "a=mid:") && last >= 0 {
                sections[last].mid = dropBytes(line, 6)
            } else if bytesHavePrefix(line, "a=ice-ufrag:") {
                let ufrag = dropBytes(line, 12)
                if last < 0 { global = ufrag } else { sections[last].ufrag = ufrag }
            } else if bytesHavePrefix(line, "a=candidate:") && last >= 0 {
                raw[last].append(dropBytes(line, 2))
            }
        }
        guard !sections.isEmpty else { throw ICEProtocolError.sectionsUnavailable }
        var candidates: [ICECandidateWire] = []
        for (index, section) in sections.enumerated() {
            guard isToken(section.mid, limit: maxMidBytes), isToken(section.ufrag, limit: maxUfragBytes) else {
                throw ICEProtocolError.invalidTransport
            }
            for line in raw[index] {
                let candidate = ICECandidateWire(mid: section.mid, index: index, ufrag: section.ufrag, candidate: line)
                guard isValid(candidate, sections: sections, relayOnly: false), candidates.count < maxCandidates else {
                    throw ICEProtocolError.invalidCandidate
                }
                candidates.append(candidate)
            }
        }
        return (sections, candidates)
    }

    /// Candidate validity rules 1-6 of (`TrickleIce.kt:81-92`, Go `trickle.go:50-80`). `sections` is the receiver's
    /// parse of the **sender's** description.
    public static func isValid(_ c: ICECandidateWire, sections: [Section], relayOnly: Bool) -> Bool {
        guard sections.indices.contains(c.index),
            isToken(c.mid, limit: maxMidBytes),
            isToken(c.ufrag, limit: maxUfragBytes)
        else { return false }
        let bytes = c.candidate.utf8
        guard (1...maxCandidateBytes).contains(bytes.count),
            !bytes.contains(where: { $0 == 0x0D || $0 == 0x0A || $0 == 0x00 })
        else { return false }
        let section = sections[c.index]
        guard bytesEqual(c.mid, section.mid), bytesEqual(c.ufrag, section.ufrag) else { return false }
        let f = tokens(c.candidate)
        guard f.count >= 8,
            bytesHavePrefix(f[0], "candidate:"),
            bytesEqual(f[6], "typ"),
            bytesEqual(f[1], "1") || bytesEqual(f[1], "2")
        else { return false }
        let transport = f[2].lowercased()
        guard bytesEqual(transport, "udp") || bytesEqual(transport, "tcp") else { return false }
        guard let port = Int(f[5]), (1...65_535).contains(port) else { return false }
        let kind = f[7]
        guard ["host", "srflx", "prflx", "relay"].contains(where: { bytesEqual(kind, $0) }) else { return false }
        if relayOnly && !bytesEqual(kind, "relay") { return false }
        var i = 8
        while i + 1 < f.count {
            if bytesEqual(f[i], "ufrag") && !bytesEqual(f[i + 1], c.ufrag) { return false }
            i += 2
        }
        return true
    }

    /// `ContinuousIce.withoutCandidates` (`ContinuousIce.kt:192-194`): analysis-split lines, drop empty lines, every
    /// `a=candidate:` line and the exact line `a=end-of-candidates`; join with CRLF and append a final CRLF.
    public static func withoutCandidates(_ sdp: String) -> String {
        let kept = analysisLines(sdp).filter { line in
            !line.isEmpty && !bytesHavePrefix(line, "a=candidate:") && !bytesEqual(line, "a=end-of-candidates")
        }
        return kept.joined(separator: "\r\n") + "\r\n"
    }

    /// `candidateKey(value)` (`ContinuousIce.kt:205-208`): tokens after removing a leading `a=`, first 8 tokens plus
    /// every extension pair-chunk whose first element is not `ufrag`, joined with one space.
    public static func candidateKey(_ value: String) -> String {
        let parts = candidateParts(value)
        var kept = Array(parts.prefix(8))
        for chunk in extensionChunks(parts) where !bytesEqual(chunk[0], "ufrag") {
            kept.append(contentsOf: chunk)
        }
        return kept.joined(separator: " ")
    }

    /// `candidateUser(value)` (`ContinuousIce.kt:209-210`): the value of the single two-element `ufrag` extension
    /// chunk; zero or several → nil.
    public static func candidateUser(_ value: String) -> String? {
        let users = extensionChunks(candidateParts(value)).filter { $0.count == 2 && bytesEqual($0[0], "ufrag") }
        return users.count == 1 ? users[0][1] : nil
    }

    /// Whitespace tokenization: trim, split on runs of ASCII whitespace (space, `\t`, `\n`, `\u{0B}`, `\u{0C}`, `\r`),
    /// no empty tokens (an all-space value yields `[]`).
    public static func tokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isASCIIWhitespace(scalar) {
                if !current.isEmpty {
                    result.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// Parse split of (`TrickleIce.kt:99`): every `\r\n` becomes `\n`, then split on `\n` keeping empty pieces; lines
    /// are not trimmed, so a lone `\r` stays inside its line. Works on Unicode scalars (Swift treats `\r\n` as one
    /// `Character`).
    public static func parseLines(_ sdp: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var pendingCR = false
        for scalar in sdp.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" {
                    lines.append(String(current))
                    current = String.UnicodeScalarView()
                    continue
                }
                current.append("\r")
            }
            if scalar == "\r" {
                pendingCR = true
            } else if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if pendingCR { current.append("\r") }
        lines.append(String(current))
        return lines
    }

    /// Analysis split of (Kotlin `lineSequence()`): split on `\r\n`, `\n` or `\r`, keeping empty pieces (`"a\r\n"` →
    /// `["a", ""]`). Lines are not trimmed.
    public static func analysisLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if afterCR {
                afterCR = false
                if scalar == "\n" { continue }
            }
            if scalar == "\r" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                afterCR = true
            } else if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    // MARK: - Internal helpers (shared by the ICE files of this module)

    /// `iceToken` (`TrickleIce.kt:79`, Go `trickle.go:38-48`): 1...limit bytes, each 33...126.
    static func isToken(_ value: String, limit: Int) -> Bool {
        let bytes = value.utf8
        return (1...limit).contains(bytes.count) && bytes.allSatisfy { (33...126).contains($0) }
    }

    /// Tokens of a candidate value after removing one leading `a=` (Kotlin
    /// `value.removePrefix("a=").trim().split(Regex("\\s+"))`, `ContinuousIce.kt:204`).
    static func candidateParts(_ value: String) -> [String] {
        if bytesHavePrefix(value, "a=") {
            return tokens(String(decoding: value.utf8.dropFirst(2), as: UTF8.self))
        }
        return tokens(value)
    }

    /// `tokens[8...]` chunked in pairs (`[t8,t9],[t10,t11],…`); a trailing single token forms a
    /// one-element chunk (Kotlin `drop(8).chunked(2)`).
    static func extensionChunks(_ parts: [String]) -> [[String]] {
        guard parts.count > 8 else { return [] }
        var chunks: [[String]] = []
        var i = 8
        while i < parts.count {
            chunks.append(Array(parts[i..<min(i + 2, parts.count)]))
            i += 2
        }
        return chunks
    }

    static func bytesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func bytesHavePrefix(_ value: String, _ prefix: String) -> Bool {
        value.utf8.starts(with: prefix.utf8)
    }

    static func bytesHaveSuffix(_ value: String, _ suffix: String) -> Bool {
        value.utf8.count >= suffix.utf8.count && value.utf8.reversed().starts(with: suffix.utf8.reversed())
    }

    /// Kotlin `CharSequence.contains(other)` on UTF-8 bytes.
    static func bytesContain(_ value: String, _ needle: String) -> Bool {
        let haystack = Array(value.utf8)
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return true }
        guard haystack.count >= pattern.count else { return false }
        for start in 0...(haystack.count - pattern.count)
        where haystack[start..<(start + pattern.count)].elementsEqual(pattern) {
            return true
        }
        return false
    }

    /// The text after the first `count` bytes. Callers only drop an ASCII prefix they matched, so
    /// the remainder starts on a scalar boundary.
    static func dropBytes(_ value: String, _ count: Int) -> String {
        String(decoding: value.utf8.dropFirst(count), as: UTF8.self)
    }

    /// Kotlin `removePrefix(prefix)`.
    static func removingPrefix(_ value: String, _ prefix: String) -> String {
        bytesHavePrefix(value, prefix) ? dropBytes(value, prefix.utf8.count) : value
    }

    /// Kotlin `substringAfter(delimiter)`: the text after the first `delimiter` scalar, or the whole
    /// value when it is missing (Kotlin's default `missingDelimiterValue`).
    static func substringAfter(_ value: String, _ delimiter: Unicode.Scalar) -> String {
        guard let index = value.unicodeScalars.firstIndex(of: delimiter) else { return value }
        return String(value.unicodeScalars[value.unicodeScalars.index(after: index)...])
    }

    /// Kotlin `substringBefore(delimiter)`: the text before the first `delimiter` scalar, or the
    /// whole value when it is missing.
    static func substringBefore(_ value: String, _ delimiter: Unicode.Scalar) -> String {
        guard let index = value.unicodeScalars.firstIndex(of: delimiter) else { return value }
        return String(value.unicodeScalars[..<index])
    }

    /// Kotlin `String.toIntOrNull()` (32-bit `Int`, optional leading `+`/`-`, decimal digits).
    /// Swift's `Int32(_:)` has the same grammar for ASCII text.
    static func kotlinInt(_ value: String) -> Int32? {
        Int32(value)
    }

    /// Kotlin `String.trim()`: removes leading and trailing characters for which Kotlin/JVM
    /// `Char.isWhitespace()` is true (`Character.isWhitespace || Character.isSpaceChar`): U+0009-U+000D,
    /// U+001C-U+001F and the Unicode space, line and paragraph separators (Zs, Zl, Zp). Used only where
    /// the Kotlin source trims before an analysis split (`IceGathering.kt`, `RouteSelection.kt`).
    static func kotlinTrimmed(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isKotlinWhitespace($0) }) else { return "" }
        guard let last = scalars.lastIndex(where: { !isKotlinWhitespace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// Kotlin `split(Regex("\\s+"))`: splits on runs of the Java regex class `\s` (`[ \t\n\x0B\f\r]`)
    /// and keeps a leading and a trailing empty piece (`" a"` → `["", "a"]`, `""` → `[""]`). Unlike
    /// `tokens(_:)`, which drops empty pieces, this reproduces Kotlin field positions when the text
    /// was not trimmed first (e.g. `"m= audio …".substring(2)`).
    static func kotlinFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = String.UnicodeScalarView()
        var inSeparator = false
        for scalar in value.unicodeScalars {
            if isASCIIWhitespace(scalar) {
                if !inSeparator {
                    fields.append(String(current))
                    current = String.UnicodeScalarView()
                    inSeparator = true
                }
            } else {
                inSeparator = false
                current.append(scalar)
            }
        }
        fields.append(String(current))
        return fields
    }

    static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
            0x3000:
            return true
        default:
            return false
        }
    }

    static func hashBytes(_ value: String, into hasher: inout Hasher) {
        hasher.combine(value.utf8.count)
        for byte in value.utf8 { hasher.combine(byte) }
    }

    static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return true
        default: return false
        }
    }
}
