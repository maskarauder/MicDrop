import Foundation
import MicDropCore

/// Process-wide `/v1/ice` credential service (Kotlin `RemoteIce.fetch`, `RemoteIce.kt:16-73`). 02 calls it
/// `RemoteIceProvider`.
///
/// State lives in pure `RemoteICECache` (cache until `expires_at - 60`, one attempt per route per 30 s, forced relay
/// requires TURN, a cancelled fetch never commits) and survives Stop/reconnect. Android's `@Synchronized` is reproduced
/// with a FIFO gate held across the whole fetch: concurrent callers wait and then re-evaluate the cache/throttle;
/// callers are never coalesced onto one in-flight result (a second caller after a failure sees the throttle error).
///
/// Called before `/offer` at stage PAIRING (fatal on error) and before each remote `/recover-offer` (retryable for
/// 429/5xx/I/O/throttle, else fatal) —. Session workers use `fetchOnWorker` (bridge). Errors: `HTTPFailure(status)` for
/// non-200, `SignalingTLSFailure(.iceService, …)`, `ControlIOError(.timedOut | .iceServiceUnavailable |
/// .iceUnavailable(.throttled | .tooLarge | .forcedRelayRequiresTURN))`, `ICEProtocolError.invalidConfiguration` (rule
/// violations), `SessionStopped` (cancelled).
actor RemoteICEService {
    static let shared = RemoteICEService()

    /// Worker-side bound on one fetch beyond URLSession's own 16 s resource timeout.
    static let workerTimeoutMs = 20_000

    private let fetcher: any RemoteIceFetching
    private let cache: RemoteICECache
    private var busy = false
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(
        fetcher: any RemoteIceFetching = URLSessionRemoteIceFetcher(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        wallSeconds: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970.rounded(.down)) }
    ) {
        self.fetcher = fetcher
        self.cache = RemoteICECache(clock: clock, wallSeconds: wallSeconds)
    }

    /// `fetch(_:register:)`. `register` receives a handle that cancels this fetch (the session registers it as its
    /// active request so Stop aborts it, `StreamReceiver.kt:1649`); cancelling the calling task has the same effect.
    func fetch(
        _ route: RemoteRoute, timeoutMs: Int = 8_000,
        register: @escaping @Sendable (ControlRequestHandle) -> Void = { _ in }
    ) async throws -> RemoteICEConfiguration {
        let work = Task { try await self.serialized(route, timeoutMs: timeoutMs) }
        register(ControlRequestHandle { work.cancel() })
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Session-worker bridge: blocks the worker in `SessionWorkerWait.runAsync` until the fetch finishes; Stop
    /// (`worker.cancel()`) cancels it and throws `SessionStopped`. `onStart` also receives the cancel handle (e.g. to
    /// store it as the session's active request).
    nonisolated func fetchOnWorker(
        _ route: RemoteRoute, worker: SessionWorkerWait,
        timeoutMs: Int = RemoteICEService.workerTimeoutMs,
        requestTimeoutMs: Int = 8_000,
        onStart: @escaping @Sendable (ControlRequestHandle) -> Void = { _ in }
    )
        throws -> RemoteICEConfiguration
    {
        try worker.runAsync(timeoutMs: timeoutMs) { register in
            try await self.fetch(route, timeoutMs: requestTimeoutMs) { handle in
                register(handle)
                onStart(handle)
            }
        }
    }

    // MARK: - Private

    nonisolated func retryAfterInterruptionOnWorker(_ worker: SessionWorkerWait) throws {
        let _: Bool = try worker.runAsync(timeoutMs: 1_000) { _ in
            await self.retryAfterInterruption()
            return true
        }
    }

    private func retryAfterInterruption() { cache.retryAfterInterruption() }

    /// steps 1-14 under the FIFO gate.
    private func serialized(_ route: RemoteRoute, timeoutMs: Int) async throws -> RemoteICEConfiguration {
        try await acquire()
        defer { release() }
        try Self.checkpoint()
        switch try cache.lookup(url: route.url, token: route.token, forceRelay: route.forceRelay) {
        case .cached(let configuration):
            return configuration
        case .fetch(let attempt):
            guard let url = URL(string: attempt.iceURL) else {
                throw ControlIOError(.iceServiceUnavailable)
            }
            let response: (status: Int, body: Data)
            do {
                response = try await fetcher.fetchICE(
                    url: url, authorization: attempt.authorization, timeoutMs: timeoutMs)
            } catch {
                throw URLSessionRemoteIceFetcher.mapError(error)
            }
            guard response.status == 200 else { throw HTTPFailure(status: response.status) }
            return try cache.complete(attempt, body: response.body, checkpoint: { try Self.checkpoint() })
        }
    }

    /// Kotlin `checkpoint()`: a cancelled fetch (Stop) never commits.
    private static func checkpoint() throws {
        if Task.isCancelled { throw SessionStopped() }
    }

    private func acquire() async throws {
        try Self.checkpoint()
        if !busy {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: SessionStopped())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        // If release already transferred ownership, serialized's checkpoint releases it instead.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: SessionStopped())
    }

    /// Hands the gate to the next waiter in FIFO order, or frees it.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
