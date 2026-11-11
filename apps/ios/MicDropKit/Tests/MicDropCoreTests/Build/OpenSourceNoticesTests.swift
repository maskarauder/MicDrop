import MicDropCore
import XCTest

/// every bundled notice file, in order, joined like `K:MainActivity.kt:522`.
final class OpenSourceNoticesTests: XCTestCase {
    private struct LoadFailure: Error, Equatable {}

    func testCombinedJoinsResourcesInOrderWithABlankLine() {
        var requested: [String] = []
        let text = OpenSourceNotices.combined { name -> String in
            requested.append(name)
            return String(name.prefix(1))
        }
        XCTAssertEqual(text, "N\n\nL\n\ni\n\nw")
        XCTAssertEqual(requested, ["NOTICE", "LICENSE", "ios-notices.txt", "webrtc-notice.txt"])
    }

    func testLoaderErrorPropagates() {
        XCTAssertThrowsError(
            try OpenSourceNotices.combined { name -> String in
                if name == "webrtc-notice.txt" { throw LoadFailure() }
                return "A"
            }
        ) { error in
            XCTAssertEqual(error as? LoadFailure, LoadFailure())
        }
    }

    func testTitleAndUnavailableText() {
        XCTAssertEqual(OpenSourceNotices.title, "Open-source notices")
        XCTAssertEqual(OpenSourceNotices.unavailableText, "Open-source notices are unavailable in this build.")
    }
}
