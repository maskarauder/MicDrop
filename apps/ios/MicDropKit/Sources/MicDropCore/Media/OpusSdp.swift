// Exact SDP edits and checks applied to the phone's local answer.; Kotlin `OpusSdp.kt`,
// `StreamReceiver.kt:391,494-511,1588`. Pure MicDropCore (Linux-tested): no AVFoundation/WebRTC, no Foundation.
//
// Text rules shared by every member (Kotlin parity): lengths are UTF-16 code units
// (`String.length`), comparisons and splits operate on UTF-16 code units, never on Swift
// `Character`s (Swift treats "\r\n" as one grapheme and lets combining marks absorb the
// previous scalar, which would change line splitting, `startsWith` and `contains` results).
//
// Case-insensitive comparisons follow the JVM exactly:
// - Kotlin `Regex(…, RegexOption.IGNORE_CASE)` compiles with `CASE_INSENSITIVE | UNICODE_CASE`
//   (Kotlin stdlib `ensureUnicodeCase`; "Case comparison is Unicode-aware");
// - Kotlin `String.equals(other, ignoreCase = true)` is Java `equalsIgnoreCase`.
// Both compare per UTF-16 code unit through `toUpperCase` / `toLowerCase`. Every pattern letter
// used here is ASCII, so the only non-ASCII code units that can match are those whose case
// mapping is an ASCII letter: U+017F 'ſ' (→ 'S', matches 's'), U+0131 'ı' (→ 'I'), U+0130 'İ'
// (→ 'i') and U+212A KELVIN SIGN (→ 'k'). Digits and punctuation never have case variants.

/// Failures of `OpusSdp.stereoAnswer(_:)`.
///
/// every case is classified `SETUP_FAILED` / wire `session_exception` ("Creating the stereo answer failed
/// [SETUP_FAILED]."). No case carries SDP text.
public enum OpusSdpError: Error, Equatable, Sendable {
    /// `require(description.length <= 65536 && '\u0000' !in description)` (`OpusSdp.kt:8`).
    case invalidInput
    /// `require(indices.size <= 1) { "Duplicate Opus parameters" }` (`OpusSdp.kt:24`).
    case duplicateOpusParameters
    /// `check(updated) { "No active stereo Opus audio section" }` (`OpusSdp.kt:41`).
    case noActiveStereoOpusSection
    /// `require(it.length <= 65536)` on the produced answer (`OpusSdp.kt:42`).
    case outputTooLarge
}

/// SDP helpers for the answer the phone installs and submits.
///
/// Only `stereo=1` is ever added: the host encoder derives its channel count from the receiver's `stereo` fmtp in the
/// answer, and `setCodecPreferences` cannot change fmtp parameters (`OpusSdp.kt:3-5`). Never add `maxaveragebitrate`,
/// `ptime`, `sprop-stereo`, `cbr`, `useinbandfec` or any other edit.
public enum OpusSdp {
    /// Maximum description length in UTF-16 code units (`OpusSdp.kt:8,42`, `SR:391`;
    /// host rejects `len(sdp) > 65536`, `server.go:209-243`).
    public static let maximumLength = 65_536

    /// Adds `stereo=1` to every active Opus 48000/2 payload of every active audio section (`OpusSdp.kt:7-43`).
    /// Idempotent on its own output.
    ///
    /// Exact algorithm (on UTF-16 code units):
    /// 1. `description.utf16.count > 65536` or contains U+0000 → `.invalidInput`.
    /// 2. Replace every "\r\n" with "\n" (left to right, non-overlapping, so "\r\r\n" → "\r\n");
    ///    strip trailing '\n' code units only; split on '\n' keeping empty elements.
    /// 3. A media section starts at a line beginning (UTF-16 prefix) "m=" and ends before the
    ///    next "m=" line or at the end.
    /// 4. Section whose m-line split on single ' ' (empties kept) has ≥ 4 tokens,
    ///    token[0] == "m=audio" and token[1] != "0": `payloads = Set(tokens[3...])`. Collect, in
    ///    line order, the payloads of section lines (excluding the m-line) that ENTIRELY match
    ///    `a=rtpmap:([0-9]+) opus/48000/2` with Kotlin `IGNORE_CASE` semantics (Unicode-aware
    ///    simple case mapping, see the file header; ASCII digits; a trailing lone "\r" means no
    ///    match) and whose payload is in `payloads`. For each such payload P, with
    ///    `prefix = "a=fmtp:" + P + " "`:
    ///    - more than one section line with that UTF-16 prefix → `.duplicateOpusParameters`;
    ///    - none → insert `prefix + "stereo=1"` after the section's last line (section grows by 1);
    ///    - one → split the text after the prefix on ';' (empties kept), trim each item with
    ///      Kotlin `trim()` (U+0009–U+000D, U+001C–U+0020, U+00A0, U+1680, U+2000–U+200A,
    ///      U+2028, U+2029, U+202F, U+205F, U+3000 — NOT U+0085), drop empty items and items
    ///      whose key (text before the first '=', or the whole item, Kotlin-trimmed) equals
    ///      "stereo" under Kotlin `equals(ignoreCase = true)`, append "stereo=1", join with ";"
    ///      and replace the line with `prefix + joined`;
    ///    - mark updated.
    ///    Kept edge behaviour: an "a=fmtp:P" line without a trailing space does not match the
    ///    prefix, so a second fmtp line is inserted; port-0 sections are skipped by the string
    ///    compare `!= "0"` (so "00" counts as active); repeated rtpmap lines for one payload
    ///    are processed once each (the second pass rewrites the line the first inserted).
    /// 5. Nothing updated → `.noActiveStereoOpusSection`.
    /// 6. Output = lines joined with "\r\n" plus a trailing "\r\n"; `utf16.count > 65536` →
    ///    `.outputTooLarge`.
    /// Test vectors: `OpusSdpTest.kt` (all four, verbatim).
    public static func stereoAnswer(_ description: String) throws -> String {
        let input = Array(description.utf16)
        guard input.count <= maximumLength, !input.contains(CodeUnit.nul) else {
            throw OpusSdpError.invalidInput
        }
        var lines = splitLines(trimmingTrailingLineFeeds(normalizingCRLF(input)))
        var start = 0
        var updated = false
        while start < lines.count {
            if !hasPrefix(lines[start], Token.mediaLine) {
                start += 1
                continue
            }
            var end = start + 1
            while end < lines.count && !hasPrefix(lines[end], Token.mediaLine) {
                end += 1
            }
            let media = split(lines[start], on: CodeUnit.space)
            if media.count >= 4 && media[0] == Token.audioMedia && media[1] != Token.rejectedPort {
                let payloads = Set(media.dropFirst(3))
                var maps: [[UInt16]] = []
                var index = start + 1
                while index < end {
                    if let payload = opusRtpmapPayload(lines[index]), payloads.contains(payload) {
                        maps.append(payload)
                    }
                    index += 1
                }
                for payload in maps {
                    let prefix = Token.fmtpPrefix + payload + [CodeUnit.space]
                    var matches: [Int] = []
                    var line = start + 1
                    while line < end {
                        if hasPrefix(lines[line], prefix) { matches.append(line) }
                        line += 1
                    }
                    guard matches.count <= 1 else { throw OpusSdpError.duplicateOpusParameters }
                    if let existing = matches.first {
                        let parameters = Array(lines[existing][prefix.count...])
                        lines[existing] = prefix + stereoParameters(parameters)
                    } else {
                        lines.insert(prefix + Token.stereoOne, at: end)
                        end += 1
                    }
                    updated = true
                }
            }
            start = end
        }
        guard updated else { throw OpusSdpError.noActiveStereoOpusSection }
        var output: [UInt16] = []
        output.reserveCapacity(input.count + 64)
        for line in lines {
            output.append(contentsOf: line)
            output.append(CodeUnit.carriageReturn)
            output.append(CodeUnit.lineFeed)
        }
        guard output.count <= maximumLength else { throw OpusSdpError.outputTooLarge }
        // Only ASCII delimiters and BMP whitespace were split or removed, so surrogate pairs are
        // intact and decoding reproduces the input's scalars exactly.
        return String(decoding: output, as: UTF16.self)
    }

    /// The description the phone installs with `setLocalDescription` (`SR:511`, step 3; recovery `SR:1597`): playback
    /// and duplex answers get `stereoAnswer`, microphone-only answers are unmodified.
    public static func localAnswer(_ answer: String, mode: StreamMode) throws -> String {
        switch mode {
        case .playback, .duplex:
            return try stereoAnswer(answer)
        case .microphone:
            return answer
        }
    }

    /// The direction attribute a microphone-mode answer must contain (`SR:510`):
    /// duplex `"a=sendrecv"`, microphone `"a=sendonly"`; playback answers are not checked (`nil`).
    public static func requiredAnswerDirection(for mode: StreamMode) -> String? {
        switch mode {
        case .playback:
            return nil
        case .microphone:
            return "a=sendonly"
        case .duplex:
            return "a=sendrecv"
        }
    }

    /// Kotlin `check(answer.description.contains(...))` (`SR:510`): a plain UTF-16 substring
    /// test. Returns `true` for playback (no check). A `false` result is a non-IO setup failure
    /// (`IllegalStateException` → `SETUP_FAILED`, the engine's `MediaEngineError.directionMismatch`).
    public static func answerHasRequiredDirection(_ answer: String, mode: StreamMode) -> Bool {
        guard let needle = requiredAnswerDirection(for: mode) else { return true }
        return utf16Contains(Array(answer.utf16), Array(needle.utf16))
    }

    /// Opus capability filter (`SR:494-495`):
    /// `name.equals("opus", ignoreCase = true) && clockRate == 48000 && numChannels == 2`
    /// (Java `equalsIgnoreCase`; a missing clock rate or channel count never matches).
    /// The app passes `RTCRtpCodecCapability.name`, `clockRate?.intValue`, `numChannels?.intValue`.
    public static func isStereoOpusCapability(name: String, clockRate: Int?, channels: Int?) -> Bool {
        return equalsIgnoreCase(Array(name.utf16), Token.opus) && clockRate == 48_000 && channels == 2
    }

    /// Initial `/offer` SDP bound: `require(description.length <= 65536)` (`SR:391`).
    public static func acceptsOfferDescription(_ sdp: String) -> Bool {
        return sdp.utf16.count <= maximumLength
    }

    /// `/recover-offer` SDP bound: `require(description.length in 1..65536)` (`SR:1588`).
    public static func acceptsRecoveryOfferDescription(_ sdp: String) -> Bool {
        let count = sdp.utf16.count
        return count >= 1 && count <= maximumLength
    }

    // MARK: - UTF-16 constants

    private enum CodeUnit {
        static let nul: UInt16 = 0x00
        static let lineFeed: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
        static let space: UInt16 = 0x20
        static let semicolon: UInt16 = 0x3B
        static let equals: UInt16 = 0x3D
    }

    private enum Token {
        static let mediaLine = Array("m=".utf16)
        static let audioMedia = Array("m=audio".utf16)
        static let rejectedPort = Array("0".utf16)
        static let fmtpPrefix = Array("a=fmtp:".utf16)
        static let stereoOne = Array("stereo=1".utf16)
        static let stereoKey = Array("stereo".utf16)
        static let opus = Array("opus".utf16)
        /// Literal head and tail of `a=rtpmap:([0-9]+) opus/48000/2`.
        static let rtpmapHead = Array("a=rtpmap:".utf16)
        static let rtpmapTail = Array(" opus/48000/2".utf16)
    }

    // MARK: - Line handling (Kotlin String semantics)

    /// Kotlin `replace("\r\n", "\n")`: left-to-right, non-overlapping.
    private static func normalizingCRLF(_ units: [UInt16]) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            let pair = index + 1 < units.count && units[index + 1] == CodeUnit.lineFeed
            if units[index] == CodeUnit.carriageReturn && pair {
                result.append(CodeUnit.lineFeed)
                index += 2
            } else {
                result.append(units[index])
                index += 1
            }
        }
        return result
    }

    /// Kotlin `trimEnd('\n')`.
    private static func trimmingTrailingLineFeeds(_ units: [UInt16]) -> [UInt16] {
        var end = units.count
        while end > 0 && units[end - 1] == CodeUnit.lineFeed { end -= 1 }
        return Array(units[0..<end])
    }

    /// Kotlin `split('\n')`: n delimiters give n + 1 elements (empties kept, `"" → [""]`).
    private static func splitLines(_ units: [UInt16]) -> [[UInt16]] {
        return split(units, on: CodeUnit.lineFeed)
    }

    /// Kotlin `split(c)` for a single delimiter code unit, keeping every empty element.
    private static func split(_ units: [UInt16], on delimiter: UInt16) -> [[UInt16]] {
        var parts: [[UInt16]] = []
        var current: [UInt16] = []
        for unit in units {
            if unit == delimiter {
                parts.append(current)
                current = []
            } else {
                current.append(unit)
            }
        }
        parts.append(current)
        return parts
    }

    /// Kotlin `startsWith(prefix)` (exact code units, case-sensitive).
    private static func hasPrefix(_ units: [UInt16], _ prefix: [UInt16]) -> Bool {
        guard units.count >= prefix.count else { return false }
        var index = 0
        while index < prefix.count {
            if units[index] != prefix[index] { return false }
            index += 1
        }
        return true
    }

    /// Kotlin `String.contains(String)`: code-unit substring search.
    private static func utf16Contains(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > haystack.count { return false }
        var start = 0
        while start + needle.count <= haystack.count {
            var offset = 0
            while offset < needle.count && haystack[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }

    // MARK: - rtpmap and fmtp rules

    /// `Regex("a=rtpmap:([0-9]+) opus/48000/2", IGNORE_CASE).matchEntire(line)?.groupValues[1]`.
    /// The digit run is greedy and must be followed by the literal " opus/48000/2" and the end of
    /// the line; the next pattern character is a space, so backtracking cannot change the split.
    private static func opusRtpmapPayload(_ line: [UInt16]) -> [UInt16]? {
        let head = Token.rtpmapHead
        let tail = Token.rtpmapTail
        guard line.count >= head.count + 1 + tail.count else { return nil }
        var index = 0
        while index < head.count {
            if !patternMatches(line[index], head[index]) { return nil }
            index += 1
        }
        let digitsStart = index
        while index < line.count && line[index] >= 0x30 && line[index] <= 0x39 {
            index += 1
        }
        let digitsEnd = index
        guard digitsEnd > digitsStart, line.count - digitsEnd == tail.count else { return nil }
        var offset = 0
        while offset < tail.count {
            if !patternMatches(line[digitsEnd + offset], tail[offset]) { return nil }
            offset += 1
        }
        return Array(line[digitsStart..<digitsEnd])
    }

    /// Rewrites the text after `a=fmtp:P ` (`OpusSdp.kt:31-34`): split on ';', Kotlin `trim()`,
    /// drop empty items and `stereo` keys (case-insensitive), append `stereo=1`, join with ';'.
    private static func stereoParameters(_ text: [UInt16]) -> [UInt16] {
        var kept: [[UInt16]] = []
        for item in split(text, on: CodeUnit.semicolon) {
            let trimmed = kotlinTrim(item)
            if trimmed.isEmpty { continue }
            let key: [UInt16]
            if let equalsIndex = trimmed.firstIndex(of: CodeUnit.equals) {
                key = Array(trimmed[0..<equalsIndex])
            } else {
                key = trimmed
            }
            if equalsIgnoreCase(kotlinTrim(key), Token.stereoKey) { continue }
            kept.append(trimmed)
        }
        kept.append(Token.stereoOne)
        var joined: [UInt16] = []
        for (position, item) in kept.enumerated() {
            if position > 0 { joined.append(CodeUnit.semicolon) }
            joined.append(contentsOf: item)
        }
        return joined
    }

    /// Kotlin `CharSequence.trim()` with `Char.isWhitespace()`.
    private static func kotlinTrim(_ units: [UInt16]) -> [UInt16] {
        var start = 0
        var end = units.count
        while start < end && isKotlinWhitespace(units[start]) { start += 1 }
        while end > start && isKotlinWhitespace(units[end - 1]) { end -= 1 }
        return Array(units[start..<end])
    }

    /// Kotlin `Char.isWhitespace()` (= Java `Character.isWhitespace || Character.isSpaceChar`):
    /// U+0009–U+000D, U+001C–U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F,
    /// U+205F, U+3000. U+0085 (NEL) and U+180E are not whitespace.
    private static func isKotlinWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009...0x000D, 0x001C...0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
            0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    // MARK: - JVM case-insensitive comparison

    /// Java `equalsIgnoreCase` of a code-unit array against an ASCII-lowercase constant.
    private static func equalsIgnoreCase(_ units: [UInt16], _ lowercaseASCII: [UInt16]) -> Bool {
        guard units.count == lowercaseASCII.count else { return false }
        var index = 0
        while index < units.count {
            if !patternMatches(units[index], lowercaseASCII[index]) { return false }
            index += 1
        }
        return true
    }

    /// One code unit against one ASCII pattern code unit under Java/Kotlin case-insensitive
    /// rules: equal, or (pattern letter) `toLowerCase(toUpperCase(unit))` equals the letter.
    /// Non-letter pattern characters (digits, punctuation, space) match only themselves.
    private static func patternMatches(_ unit: UInt16, _ pattern: UInt16) -> Bool {
        if unit == pattern { return true }
        let lower: UInt16
        if pattern >= 0x41 && pattern <= 0x5A {
            lower = pattern + 0x20
        } else if pattern >= 0x61 && pattern <= 0x7A {
            lower = pattern
        } else {
            return false
        }
        return foldedToASCIILowercase(unit) == lower
    }

    /// `Character.toLowerCase(Character.toUpperCase(unit))` restricted to the code units whose
    /// result is an ASCII letter; every other code unit maps to itself (never an ASCII letter).
    private static func foldedToASCIILowercase(_ unit: UInt16) -> UInt16 {
        switch unit {
        case 0x41...0x5A:
            return unit + 0x20
        case 0x017F:  // LATIN SMALL LETTER LONG S → 'S' → 's'
            return 0x73
        case 0x0131, 0x0130:  // DOTLESS I → 'I' → 'i'; CAPITAL I WITH DOT ABOVE → 'i'
            return 0x69
        case 0x212A:  // KELVIN SIGN → 'k'
            return 0x6B
        default:
            return unit
        }
    }
}
