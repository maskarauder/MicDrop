import Foundation
import XCTest

@testable import MicDropCore

final class RemoteICEInterruptionTests: XCTestCase {
    private struct Clock: MonotonicClock { func nowMs() -> Int64 { 1_000 } }

    func testInterruptedNetworkReopensThrottleForReplacementNetwork() throws {
        let cache = RemoteICECache(clock: Clock(), wallSeconds: { 1_000 })
        _ = try cache.lookup(url: "https://relay.example", token: "test", forceRelay: false)
        XCTAssertThrowsError(try cache.lookup(url: "https://relay.example", token: "test", forceRelay: false)) {
            XCTAssertEqual($0 as? ControlIOError, ControlIOError(.iceUnavailable(.throttled)))
        }
        cache.retryAfterInterruption()
        guard case .fetch = try cache.lookup(url: "https://relay.example", token: "test", forceRelay: false) else {
            return XCTFail("replacement network remained throttled")
        }
    }

    func testInterruptionRetainsValidCachedCredentials() throws {
        let cache = RemoteICECache(clock: Clock(), wallSeconds: { 1_000 })
        guard
            case .fetch(let attempt) = try cache.lookup(url: "https://relay.example", token: "test", forceRelay: false)
        else {
            return XCTFail("initial fetch missing")
        }
        let configuration = try cache.complete(
            attempt, body: Data("{\"version\":1,\"expires_at\":1600,\"ice_servers\":[]}".utf8), checkpoint: {})
        cache.retryAfterInterruption()
        guard
            case .cached(let reused) = try cache.lookup(url: "https://relay.example", token: "test", forceRelay: false)
        else {
            return XCTFail("valid credentials were discarded")
        }
        XCTAssertEqual(reused, configuration)
    }
}
