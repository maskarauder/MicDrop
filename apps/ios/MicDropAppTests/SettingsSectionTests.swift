import MicDropCore
import XCTest

@testable import MicDrop

/// The main screen's sections since split Debugging into Advanced and Diagnostics: Android's order
/// (`listOf(connectionSection, outputSection, microphoneSection, advancedSection, diagnosticsSection)`), its
/// instance-state keys (the `@SceneStorage` keys of `MainView`) and titles.
final class SettingsSectionTests: XCTestCase {
    func testSectionsFollowAndroidOrderKeysAndTitles() {
        XCTAssertEqual(SettingsSectionID.allCases, [.connection, .output, .microphone, .advanced, .diagnostics])
        XCTAssertEqual(
            SettingsSectionID.allCases.map(\.storageKey),
            ["section.connection", "section.output", "section.microphone", "section.advanced", "section.diagnostics"])
        XCTAssertEqual(
            SettingsSectionID.allCases.map(\.title),
            ["Connection setup", "Audio output", "Microphone", "Advanced", "Diagnostics"])
        XCTAssertEqual(SettingsSectionID.allCases.filter(\.defaultExpanded), [.connection])
    }
}
