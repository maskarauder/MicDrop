import AVFoundation
import XCTest

@testable import MicDrop

final class AudioSessionInterruptionTests: XCTestCase {
    func testRouteDisconnectionUsesSDKReasonAndDoesNotBecomeFocusLoss() {
        let reason = AudioSessionEventMonitor.InterruptionReason(
            rawValue: AVAudioSession.InterruptionReason.routeDisconnected.rawValue)
        XCTAssertEqual(reason, .routeDisconnected)
        XCTAssertEqual(reason.avReason, .routeDisconnected)
        XCTAssertFalse(reason.isFocusLoss)
        XCTAssertTrue(AudioSessionEventMonitor.InterruptionReason(rawValue: nil).isFocusLoss)
        XCTAssertTrue(AudioSessionEventMonitor.InterruptionReason(rawValue: UInt.max).isFocusLoss)
    }
}
