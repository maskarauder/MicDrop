// Ports `apps/android/app/src/test/java/com/maskarauder/micdrop/OpusSdpTest.kt` (all four vectors, verbatim) and covers
// every bound, error path and UTF-16 / JVM case rule of `OpusSdp`.

import MicDropCore
import XCTest

final class OpusSdpTests: XCTestCase {

    /// `OpusSdpTest.kt:7`: lines joined with CRLF plus a trailing CRLF.
    private func sdp(_ lines: String...) -> String {
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func assertStereoAnswerFails(
        _ input: String, _ expected: OpusSdpError,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try OpusSdp.stereoAnswer(input), file: file, line: line) { error in
            XCTAssertEqual(error as? OpusSdpError, expected, file: file, line: line)
        }
    }

    // MARK: - OpusSdpTest.kt vectors

    func testPreservesTransportAndOtherPayloadsWhileReplacingMono() throws {
        let input = sdp(
            "v=0", "a=ice-pwd:example-credential", "m=audio 9 UDP/TLS/RTP/SAVPF 111 101",
            "a=recvonly", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;stereo=0;useinbandfec=1",
            "a=rtpmap:101 telephone-event/8000", "a=fmtp:101 0-16", "a=candidate:example",
            "m=video 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 VP8/90000", "a=fmtp:111 x=1")
        let answer = try OpusSdp.stereoAnswer(input)
        XCTAssertEqual(
            input.replacingOccurrences(
                of: "minptime=10;stereo=0;useinbandfec=1", with: "minptime=10;useinbandfec=1;stereo=1"),
            answer)
        XCTAssertEqual(answer, try OpusSdp.stereoAnswer(answer))
    }

    func testCreatesMissingFmtpForDynamicPayloadAndPreservesRejectedSection() throws {
        let input = sdp(
            "v=0", "m=audio 0 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 stereo=0", "m=audio 9 UDP/TLS/RTP/SAVPF 109", "a=rtpmap:109 OPUS/48000/2")
        XCTAssertEqual(
            input + "a=fmtp:109 stereo=1\r\n",
            try OpusSdp.stereoAnswer(input.replacingOccurrences(of: "\r\n", with: "\n")))
    }

    func testRemovesDuplicateStereoParameters() throws {
        let input = sdp(
            "v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;stereo=0; STEREO = 0; useinbandfec=1")
        XCTAssertTrue(
            try OpusSdp.stereoAnswer(input).contains("a=fmtp:111 minptime=10;useinbandfec=1;stereo=1\r\n"))
    }

    func testRefusesMissingOrRejectedOpusInsteadOfSilentlyUsingMono() {
        for input in [
            sdp("v=0", "m=audio 0 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2"),
            sdp("v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 0", "a=rtpmap:111 opus/48000/2"),
        ] {
            assertStereoAnswerFails(input, .noActiveStereoOpusSection)
        }
    }

    // MARK: - Input validation and length bounds

    func testRejectsNulAnywhere() {
        let valid = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2")
        assertStereoAnswerFails("\u{0}" + valid, .invalidInput)
        assertStereoAnswerFails(valid + "\u{0}", .invalidInput)
        assertStereoAnswerFails(valid.replacingOccurrences(of: "v=0", with: "v=\u{0}"), .invalidInput)
    }

    func testEmptyDescriptionHasNoActiveSection() {
        assertStereoAnswerFails("", .noActiveStereoOpusSection)
        assertStereoAnswerFails("\r\n\n", .noActiveStereoOpusSection)
    }

    /// Inserts a session-level padding attribute after `v=0` so the text has exactly `count`
    /// UTF-16 code units.
    private func padded(_ base: String, toUTF16Count count: Int) -> String {
        let fill = count - base.utf16.count - "a=x:\r\n".utf16.count
        precondition(fill >= 0)
        let padding = "a=x:" + String(repeating: "y", count: fill) + "\r\n"
        return base.replacingOccurrences(of: "v=0\r\n", with: "v=0\r\n" + padding)
    }

    func testAcceptsExactly65536CodeUnitsWhenTheOutputFits() throws {
        let base = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=1")
        let input = padded(base, toUTF16Count: 65_536)
        XCTAssertEqual(input.utf16.count, OpusSdp.maximumLength)
        XCTAssertEqual(try OpusSdp.stereoAnswer(input), input)
    }

    func testRejectsInputOverTheBound() {
        let base = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=1")
        assertStereoAnswerFails(padded(base, toUTF16Count: 65_537), .invalidInput)
    }

    func testRejectsAnOutputThatGrowsOverTheBound() {
        let base = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2")
        let input = padded(base, toUTF16Count: 65_536)
        // The inserted "a=fmtp:111 stereo=1\r\n" (21 code units) pushes the answer past 65536.
        assertStereoAnswerFails(input, .outputTooLarge)
        let fits = padded(base, toUTF16Count: 65_536 - 21)
        XCTAssertEqual(try OpusSdp.stereoAnswer(fits).utf16.count, 65_536)
    }

    func testLengthIsCountedInUTF16CodeUnitsNotCharacters() {
        // 32_768 emoji = 65_536 code units but only 32_768 Characters.
        let emoji = String(repeating: "\u{1F600}", count: 32_768)
        XCTAssertEqual(emoji.count, 32_768)
        let input = "a" + emoji
        XCTAssertEqual(input.utf16.count, 65_537)
        assertStereoAnswerFails(input, .invalidInput)
        XCTAssertFalse(OpusSdp.acceptsOfferDescription(input))
        XCTAssertTrue(OpusSdp.acceptsOfferDescription(emoji))
    }

    // MARK: - Line handling

    func testLineFeedOnlyInputProducesCRLFAndTrailingNewlinesCollapse() throws {
        let input = "v=0\nm=audio 9 RTP/AVP 111\na=rtpmap:111 opus/48000/2\r\n\r\n\n\n"
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=1"))
    }

    func testLoneCarriageReturnsStayInTheLine() throws {
        // "\r\r\n" → "\r" + "\n": the first line keeps a trailing "\r"; an rtpmap line ending in
        // "\r" does not match the full-line pattern.
        let input =
            "v=0\r\r\nm=audio 9 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2\r\r\na=rtpmap:111 opus/48000/2\r\n"
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            "v=0\r\r\nm=audio 9 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2\r\r\na=rtpmap:111 opus/48000/2\r\n"
                + "a=fmtp:111 stereo=1\r\n")
        assertStereoAnswerFails(
            "v=0\r\nm=audio 9 RTP/AVP 111\r\na=rtpmap:111 opus/48000/2\r\r\n", .noActiveStereoOpusSection)
    }

    func testSplitsOnCodeUnitsEvenWhenCombiningMarksFollowALineFeed() throws {
        // Swift treats "\n\u{301}" as one Character; Kotlin splits on the '\n' code unit.
        let input = "v=0\nm=audio 9 RTP/AVP 111\n\u{301}a=x:\u{65E5}\u{672C}\u{1F600}\na=rtpmap:111 opus/48000/2\n"
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            "v=0\r\nm=audio 9 RTP/AVP 111\r\n\u{301}a=x:\u{65E5}\u{672C}\u{1F600}\r\na=rtpmap:111 opus/48000/2\r\n"
                + "a=fmtp:111 stereo=1\r\n")
    }

    // MARK: - Sections and payloads

    func testInsertsAtTheEndOfEachActiveAudioSection() throws {
        let input = sdp(
            "v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=mid:0",
            "m=audio 9 RTP/AVP 96", "a=rtpmap:96 opus/48000/2", "a=fmtp:96 useinbandfec=1", "a=mid:1")
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            sdp(
                "v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=mid:0", "a=fmtp:111 stereo=1",
                "m=audio 9 RTP/AVP 96", "a=rtpmap:96 opus/48000/2", "a=fmtp:96 useinbandfec=1;stereo=1",
                "a=mid:1"))
    }

    func testProcessesPayloadsInRtpmapOrder() throws {
        let input = sdp(
            "v=0", "m=audio 9 RTP/AVP 109 111", "a=rtpmap:111 opus/48000/2", "a=rtpmap:109 opus/48000/2",
            "a=fmtp:109 stereo=0", "a=ssrc:1 cname:x")
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            sdp(
                "v=0", "m=audio 9 RTP/AVP 109 111", "a=rtpmap:111 opus/48000/2", "a=rtpmap:109 opus/48000/2",
                "a=fmtp:109 stereo=1", "a=ssrc:1 cname:x", "a=fmtp:111 stereo=1"))
    }

    func testRepeatedRtpmapRewritesTheInsertedLineInsteadOfDuplicatingIt() throws {
        let input = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=rtpmap:111 opus/48000/2")
        XCTAssertEqual(try OpusSdp.stereoAnswer(input), input + "a=fmtp:111 stereo=1\r\n")
    }

    func testDuplicateFmtpLinesAreRejected() {
        let input = sdp(
            "v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 a=1", "a=fmtp:111 b=2")
        assertStereoAnswerFails(input, .duplicateOpusParameters)
    }

    func testFmtpPrefixRequiresTheTrailingSpace() throws {
        let bare = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111")
        XCTAssertEqual(try OpusSdp.stereoAnswer(bare), bare + "a=fmtp:111 stereo=1\r\n")
        let longer = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:1111 x=1")
        XCTAssertEqual(try OpusSdp.stereoAnswer(longer), longer + "a=fmtp:111 stereo=1\r\n")
    }

    func testMediaLineTokenRules() throws {
        let input = sdp(
            "v=0",
            "m=audio 00 RTP/AVP 111", "a=rtpmap:111 opus/48000/2",  // "00" != "0": active
            "m=audio  9 RTP/AVP 112", "a=rtpmap:112 opus/48000/2",  // empty token kept: token[1] == ""
            "m=AUDIO 9 RTP/AVP 113", "a=rtpmap:113 opus/48000/2",  // media type is case-sensitive
            "m=audio 9 RTP", "a=rtpmap:RTP opus/48000/2")  // fewer than 4 tokens
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            sdp(
                "v=0",
                "m=audio 00 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=1",
                "m=audio  9 RTP/AVP 112", "a=rtpmap:112 opus/48000/2", "a=fmtp:112 stereo=1",
                "m=AUDIO 9 RTP/AVP 113", "a=rtpmap:113 opus/48000/2",
                "m=audio 9 RTP", "a=rtpmap:RTP opus/48000/2"))
    }

    func testSessionLevelAndVideoLinesAreIgnored() throws {
        let input = sdp(
            "v=0", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=0", "m=audio 9 RTP/AVP 111",
            "a=rtpmap:111 opus/48000/2")
        XCTAssertEqual(try OpusSdp.stereoAnswer(input), input + "a=fmtp:111 stereo=1\r\n")
        assertStereoAnswerFails(
            sdp("v=0", "m=video 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2"), .noActiveStereoOpusSection)
    }

    func testRtpmapMustMatchTheWholeLine() {
        let input = sdp(
            "v=0", "m=audio 9 RTP/AVP 1 2 3 4 5 6", "a=rtpmap:1 opus/48000/2 ", "a=rtpmap:2 opus/48000/1",
            "a=rtpmap: 3 opus/48000/2", "a=rtpmap:4 opus/48000", "a=rtpmap:x opus/48000/2",
            "a=rtpmap:5 opus/48000/2/x", " a=rtpmap:6 opus/48000/2")
        assertStereoAnswerFails(input, .noActiveStereoOpusSection)
    }

    func testRtpmapPayloadMustBeListedOnTheMediaLine() {
        assertStereoAnswerFails(
            sdp("v=0", "m=audio 9 RTP/AVP 0111", "a=rtpmap:111 opus/48000/2"), .noActiveStereoOpusSection)
    }

    // MARK: - JVM case rules (Kotlin IGNORE_CASE is Unicode-aware; equals(ignoreCase) = equalsIgnoreCase)

    func testRtpmapIsCaseInsensitiveIncludingLongS() throws {
        let input = sdp(
            "v=0", "m=audio 9 RTP/AVP 111 112 113", "A=RTPMAP:111 OpUs/48000/2", "a=rtpmap:112 opu\u{17F}/48000/2",
            "a=rtpmap:113 op\u{1D58}s/48000/2")
        XCTAssertEqual(try OpusSdp.stereoAnswer(input), input + "a=fmtp:111 stereo=1\r\na=fmtp:112 stereo=1\r\n")
    }

    func testFmtpPrefixIsCaseSensitive() throws {
        let input = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "A=FMTP:111 stereo=0")
        XCTAssertEqual(try OpusSdp.stereoAnswer(input), input + "a=fmtp:111 stereo=1\r\n")
    }

    func testParameterTrimAndStereoKeyRules() throws {
        let parameters = [
            "\u{17F}tereo=0",  // long s equals 's' under equalsIgnoreCase: dropped
            "Stereo",  // no '=': the whole item is the key: dropped
            " stereo =1",  // key trimmed: dropped
            "stereo2=1",  // other key: kept
            "x=stereo",  // value, not key: kept
            "\u{A0}STEREO=1\u{3000}",  // NBSP and ideographic space are Kotlin whitespace: dropped
            "\u{85}stereo=0",  // NEL is not Kotlin whitespace: kept verbatim
            "\u{301}stereo=0",  // combining mark is part of the key: kept
            "",  // empty: dropped
            "minptime=10",
            "\u{2003}",  // em space only: empty after trim: dropped
        ].joined(separator: ";")
        let input = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 " + parameters)
        XCTAssertEqual(
            try OpusSdp.stereoAnswer(input),
            sdp(
                "v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2",
                "a=fmtp:111 stereo2=1;x=stereo;\u{85}stereo=0;\u{301}stereo=0;minptime=10;stereo=1"))
    }

    func testEmptyParameterItemsAreDropped() throws {
        let input = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 ;;minptime=10;;")
        XCTAssertTrue(try OpusSdp.stereoAnswer(input).contains("\r\na=fmtp:111 minptime=10;stereo=1\r\n"))
    }

    func testStereoAnswerIsIdempotent() throws {
        let inputs = [
            sdp("v=0", "m=audio 9 RTP/AVP 111", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 stereo=0;minptime=10"),
            sdp("v=0", "m=audio 9 RTP/AVP 109", "a=rtpmap:109 OPUS/48000/2"),
            "v=0\nm=audio 9 RTP/AVP 111\na=rtpmap:111 opus/48000/2\n",
        ]
        for input in inputs {
            let once = try OpusSdp.stereoAnswer(input)
            XCTAssertEqual(try OpusSdp.stereoAnswer(once), once)
        }
    }

    // MARK: - Mode helpers (SR:509-511)

    func testLocalAnswerMungesOnlyPlaybackModes() throws {
        let answer = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=sendrecv", "a=rtpmap:111 opus/48000/2")
        let stereo = answer + "a=fmtp:111 stereo=1\r\n"
        XCTAssertEqual(try OpusSdp.localAnswer(answer, mode: .playback), stereo)
        XCTAssertEqual(try OpusSdp.localAnswer(answer, mode: .duplex), stereo)
        XCTAssertEqual(try OpusSdp.localAnswer(answer, mode: .microphone), answer)
        // A microphone answer is never parsed, even when it would fail the stereo edit.
        XCTAssertEqual(try OpusSdp.localAnswer("v=0\n", mode: .microphone), "v=0\n")
        XCTAssertThrowsError(try OpusSdp.localAnswer("v=0\n", mode: .playback)) { error in
            XCTAssertEqual(error as? OpusSdpError, .noActiveStereoOpusSection)
        }
    }

    func testRequiredAnswerDirection() {
        XCTAssertNil(OpusSdp.requiredAnswerDirection(for: .playback))
        XCTAssertEqual(OpusSdp.requiredAnswerDirection(for: .microphone), "a=sendonly")
        XCTAssertEqual(OpusSdp.requiredAnswerDirection(for: .duplex), "a=sendrecv")
    }

    func testAnswerHasRequiredDirectionIsAPlainSubstringTest() {
        let sendOnly = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=sendonly")
        let sendRecv = sdp("v=0", "m=audio 9 RTP/AVP 111", "a=sendrecv")
        XCTAssertTrue(OpusSdp.answerHasRequiredDirection(sendOnly, mode: .microphone))
        XCTAssertFalse(OpusSdp.answerHasRequiredDirection(sendRecv, mode: .microphone))
        XCTAssertTrue(OpusSdp.answerHasRequiredDirection(sendRecv, mode: .duplex))
        XCTAssertFalse(OpusSdp.answerHasRequiredDirection(sendOnly, mode: .duplex))
        XCTAssertTrue(OpusSdp.answerHasRequiredDirection("", mode: .playback))
        XCTAssertTrue(OpusSdp.answerHasRequiredDirection("xa=sendonlyx", mode: .microphone))
        XCTAssertFalse(OpusSdp.answerHasRequiredDirection("A=SENDONLY", mode: .microphone))
        // Code-unit search: a combining mark after the needle does not hide it.
        XCTAssertTrue(OpusSdp.answerHasRequiredDirection("a=sendrecv\u{301}", mode: .duplex))
    }

    func testStereoOpusCapabilityFilter() {
        XCTAssertTrue(OpusSdp.isStereoOpusCapability(name: "opus", clockRate: 48_000, channels: 2))
        XCTAssertTrue(OpusSdp.isStereoOpusCapability(name: "OPUS", clockRate: 48_000, channels: 2))
        XCTAssertTrue(OpusSdp.isStereoOpusCapability(name: "Opus", clockRate: 48_000, channels: 2))
        XCTAssertTrue(OpusSdp.isStereoOpusCapability(name: "opu\u{17F}", clockRate: 48_000, channels: 2))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "opus", clockRate: 48_000, channels: 1))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "opus", clockRate: 44_100, channels: 2))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "opus", clockRate: nil, channels: 2))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "opus", clockRate: 48_000, channels: nil))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "multiopus", clockRate: 48_000, channels: 2))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "opus ", clockRate: 48_000, channels: 2))
        XCTAssertFalse(OpusSdp.isStereoOpusCapability(name: "", clockRate: 48_000, channels: 2))
    }

    func testOfferDescriptionBounds() {
        XCTAssertEqual(OpusSdp.maximumLength, 65_536)
        XCTAssertTrue(OpusSdp.acceptsOfferDescription(""))
        XCTAssertTrue(OpusSdp.acceptsOfferDescription(String(repeating: "a", count: 65_536)))
        XCTAssertFalse(OpusSdp.acceptsOfferDescription(String(repeating: "a", count: 65_537)))
    }

    func testRecoveryOfferDescriptionBounds() {
        XCTAssertFalse(OpusSdp.acceptsRecoveryOfferDescription(""))
        XCTAssertTrue(OpusSdp.acceptsRecoveryOfferDescription("v"))
        XCTAssertTrue(OpusSdp.acceptsRecoveryOfferDescription(String(repeating: "a", count: 65_536)))
        XCTAssertFalse(OpusSdp.acceptsRecoveryOfferDescription(String(repeating: "a", count: 65_537)))
        XCTAssertFalse(
            OpusSdp.acceptsRecoveryOfferDescription(String(repeating: "\u{1F600}", count: 32_768) + "a"))
    }

    func testErrorsAreDistinctAndCarryNoText() {
        let all: [OpusSdpError] = [
            .invalidInput, .duplicateOpusParameters, .noActiveStereoOpusSection, .outputTooLarge,
        ]
        XCTAssertEqual(Set(all.map { "\($0)" }).count, 4)
        for (index, error) in all.enumerated() {
            for (other, candidate) in all.enumerated() {
                XCTAssertEqual(error == candidate, index == other)
            }
        }
    }
}
