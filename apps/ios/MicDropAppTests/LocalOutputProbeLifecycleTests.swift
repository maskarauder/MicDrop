import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

final class LocalOutputProbeLifecycleTests: XCTestCase {
    func testStopBeforeQueuedStartFinishesEvenAfterCallerDropsProbe() async {
        let queue = DispatchQueue(label: "MicDrop.tests.suspendedProbe")
        queue.suspend()
        let ended = expectation(description: "probe teardown completed")
        ended.expectedFulfillmentCount = 1
        ended.assertForOverFulfill = true
        var probe: LocalOutputProbe? = LocalOutputProbe(
            clock: SystemMonotonicClock(), onSnapshot: { _ in XCTFail("stopped probe rendered") },
            onEnded: { message in
                XCTAssertEqual(message, LocalOutputProbe.stoppedMessage)
                ended.fulfill()
            }, queue: queue)
        weak var retainedUntilTeardown = probe
        probe?.start()
        probe?.playClick()
        probe?.close()
        probe?.close()
        XCTAssertFalse(probe?.isRunning ?? true)
        probe = nil
        XCTAssertNotNil(retainedUntilTeardown)
        queue.resume()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertNil(retainedUntilTeardown)
    }

    func testStopClearsAndDisablesPendingRenderChirps() {
        let render = LocalOutputProbe.RenderState()
        render.armClick()
        XCTAssertEqual(render.takeChirpStart(advance: 1), 0)
        render.stop()
        XCTAssertNil(render.takeChirpStart(advance: 1))
        render.armClick()
        XCTAssertNil(render.takeChirpStart(advance: 1))
    }

    func testOutputPortMappingsMatchAppleSDKConstants() {
        XCTAssertTrue(AudioRouteInspector.portTypeConstantsMatchSDK())
    }
}
