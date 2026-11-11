import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

final class RemoteICEServiceTests: XCTestCase {
    /// Holds the first real fetch until explicitly released. Cleanup also releases a fetch that
    /// starts late, so a failed assertion never leaves a checked continuation suspended.
    private final class Fetcher: RemoteIceFetching, @unchecked Sendable {
        private struct State {
            var hosts: [String] = []
            var continuation: CheckedContinuation<Void, Never>?
            var released = false
        }
        private let state = Locked(State())
        let started: XCTestExpectation

        init(started: XCTestExpectation) { self.started = started }

        var hosts: [String] { state.withLock { $0.hosts } }

        func fetchICE(url: URL, authorization: String) async throws -> (status: Int, body: Data) {
            let first = state.withLock { value in
                value.hosts.append(url.host ?? "")
                return value.hosts.count == 1
            }
            if first {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let released = state.withLock { value in
                        guard !value.released else { return true }
                        value.continuation = continuation
                        return false
                    }
                    if released { continuation.resume() }
                    started.fulfill()
                }
            }
            return (200, Data("{\"version\":1,\"expires_at\":1600,\"ice_servers\":[]}".utf8))
        }

        func release() {
            let continuation = state.withLock { value in
                value.released = true
                let continuation = value.continuation
                value.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }

    func testCancellingQueuedTaskDoesNotWaitForActiveFetch() async throws {
        try await checkQueuedCancellation(cancelTask: true)
    }

    func testCancellingQueuedHandleDoesNotWaitForActiveFetch() async throws {
        try await checkQueuedCancellation(cancelTask: false)
    }

    private func checkQueuedCancellation(cancelTask: Bool) async throws {
        let activeStarted = expectation(description: "active fetch held")
        let activeFinished = expectation(description: "active fetch finished")
        let queuedRegistered = expectation(description: "queued fetch registered")
        let queuedFinished = expectation(description: "cancelled fetch finished before release")
        let laterRegistered = expectation(description: "later fetch registered")
        let laterFinished = expectation(description: "later fetch acquired gate")
        let fetcher = Fetcher(started: activeStarted)
        defer { fetcher.release() }
        let service = RemoteICEService(fetcher: fetcher, wallSeconds: { 1000 })
        let first = try RemoteRoute(
            url: "https://first.example", token: String(repeating: "A", count: 43), forceRelay: false)
        let second = try RemoteRoute(
            url: "https://second.example", token: String(repeating: "A", count: 43), forceRelay: false)
        let activeResult = Locked<Result<RemoteICEConfiguration, Error>?>(nil)
        let queuedResult = Locked<Result<RemoteICEConfiguration, Error>?>(nil)
        let laterResult = Locked<Result<RemoteICEConfiguration, Error>?>(nil)
        let handle = Locked<ControlRequestHandle?>(nil)
        let active = Task {
            do { activeResult.value = .success(try await service.fetch(first)) } catch {
                activeResult.value = .failure(error)
            }
            activeFinished.fulfill()
        }
        defer { active.cancel() }
        await fulfillment(of: [activeStarted], timeout: 2)
        let queued = Task {
            do {
                queuedResult.value = .success(
                    try await service.fetch(second) { request in
                        handle.value = request
                        queuedRegistered.fulfill()
                    })
            } catch { queuedResult.value = .failure(error) }
            queuedFinished.fulfill()
        }
        defer { queued.cancel() }
        await fulfillment(of: [queuedRegistered], timeout: 2)
        if cancelTask { queued.cancel() } else { handle.value?.cancel() }
        await fulfillment(of: [queuedFinished], timeout: 2)
        if case .failure(let error)? = queuedResult.value {
            XCTAssertTrue(error is SessionStopped)
        } else {
            XCTFail("queued fetch did not finish with cancellation")
        }
        XCTAssertEqual(fetcher.hosts, ["first.example"])

        // Reuse the cancelled caller's route immediately: it must not have fetched, committed
        // credentials, spent its throttle, released another caller's gate or stranded the FIFO.
        let later = Task {
            do {
                laterResult.value = .success(
                    try await service.fetch(second) { _ in laterRegistered.fulfill() })
            } catch { laterResult.value = .failure(error) }
            laterFinished.fulfill()
        }
        defer { later.cancel() }
        await fulfillment(of: [laterRegistered], timeout: 2)
        XCTAssertEqual(fetcher.hosts, ["first.example"])
        fetcher.release()
        await fulfillment(of: [activeFinished, laterFinished], timeout: 2)
        XCTAssertNoThrow(try activeResult.value?.get())
        XCTAssertNoThrow(try laterResult.value?.get())
        XCTAssertNotNil(activeResult.value)
        XCTAssertNotNil(laterResult.value)
        XCTAssertEqual(fetcher.hosts, ["first.example", "second.example"])
    }
}
