import XCTest

@testable import MicDropCore

/// Info.plist build identity mapped to Android's `BuildConfig` value domain.
final class BuildInfoTests: XCTestCase {
    func testCIRevisionAndVersionNameProduceTheReportHeader() {
        let build = BuildInfo(infoDictionary: ["MicDropRevision": "0123456789ab", "MicDropVersionName": "0.1.0-dev"])
        XCTAssertEqual(build.revision, "0123456789ab")
        XCTAssertEqual(build.versionName, "0.1.0-dev")
        XCTAssertEqual(build.reportHeader, "MicDrop 0.1.0-dev \u{00B7} build 0123456789ab")
        XCTAssertEqual(build.buildLabel, "Build 0123456789ab")
    }

    func testUnexpandedBuildSettingIsLocal() {
        XCTAssertEqual(BuildInfo(infoDictionary: ["MicDropRevision": "$(MICDROP_REVISION)"]).revision, "local")
    }

    func testUppercaseRevisionIsLocal() {
        XCTAssertEqual(BuildInfo(infoDictionary: ["MicDropRevision": "0123456789AB"]).revision, "local")
    }

    func testFullCommitIsLocalBecauseCIPassesExactlyTwelveCharacters() {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(BuildInfo(infoDictionary: ["MicDropRevision": commit]).revision, "local")
    }

    func testRevisionMustBeExactlyTwelveHexCharacters() {
        for value in ["", "0123456789a", "0123456789abc", "0123456789ag", " 0123456789a", "local", "LOCAL"] {
            XCTAssertEqual(BuildInfo(versionName: "v", revision: value).revision, "local", value)
        }
        XCTAssertEqual(BuildInfo(versionName: "v", revision: "abcdef012345").revision, "abcdef012345")
    }

    func testMissingKeysUseFallbacks() {
        let build = BuildInfo(infoDictionary: [:])
        XCTAssertEqual(build.versionName, "0.1.0-dev")
        XCTAssertEqual(build.revision, "local")
        XCTAssertEqual(build.reportHeader, "MicDrop 0.1.0-dev \u{00B7} build local")
    }

    func testNonStringValuesUseFallbacks() {
        let build = BuildInfo(infoDictionary: ["MicDropRevision": 12, "MicDropVersionName": ["0.1.0"]])
        XCTAssertEqual(build, BuildInfo(versionName: "0.1.0-dev", revision: "local"))
    }

    func testVersionNameDropsControlCharactersAndKeepsEightyScalars() {
        let build = BuildInfo(infoDictionary: ["MicDropVersionName": "a\u{0007}b" + String(repeating: "x", count: 100)])
        XCTAssertEqual(build.versionName.unicodeScalars.count, 80)
        XCTAssertEqual(build.versionName, "ab" + String(repeating: "x", count: 78))
    }

    func testSanitizerRemovesC0DeleteAndC1ButKeepsOtherText() {
        let text = "1\u{0000}2\u{001F}3\u{007F}4\u{0080}5\u{009F}6\u{00A0}\u{00E9}"
        XCTAssertEqual(BuildInfo.sanitized(text), "123456\u{00A0}\u{00E9}")
        XCTAssertEqual(BuildInfo.sanitized("line\r\nbreak\ttab"), "linebreaktab")
    }

    func testLimitCountsUnicodeScalarsLikeGoRunes() {
        let name = String(repeating: "\u{00E9}", count: 81)
        XCTAssertEqual(BuildInfo.sanitized(name).unicodeScalars.count, 80)
        XCTAssertEqual(BuildInfo.sanitized("abc", limit: 2), "ab")
    }

    func testVersionNameOfOnlyControlCharactersFallsBack() {
        XCTAssertEqual(BuildInfo(versionName: "\u{0001}\u{0002}", revision: "local").versionName, "0.1.0-dev")
    }

    func testInfoPlistKeysMatchTheBuildSettings() {
        XCTAssertEqual(BuildInfo.revisionKey, "MicDropRevision")
        XCTAssertEqual(BuildInfo.versionNameKey, "MicDropVersionName")
        XCTAssertEqual(BuildInfo.localRevision, "local")
        XCTAssertEqual(BuildInfo.fallbackVersionName, "0.1.0-dev")
    }
}
