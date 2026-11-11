import Foundation

/// A decoded `/pair` success body (Go `manager.go:301-308`):
/// `{"version":1,"state":"pending","request_id":"<12 hex>"}` or
/// `{"version":1,"state":"approved","request_id":""}`.
public enum PairingReply: Equatable, Sendable {
    case pending(requestID: String)
    case approved
}

/// Enrollment client: `POST /pair` and the approval poll loop (Android `PairingClient.enroll`,
/// `PairingClient.kt:59-123`).
///
/// Not a session worker: it runs in a `Task` and calls the async `ControlTransport.send`
/// directly; a LAN request also ends with the approval window (`sendWithinWindow`). The transport
/// is built for the paired link the invitation produces (LAN or remote tunnel; the factory
/// captures the phone identity). A remote link first verifies the pinned LAN host and polls there
/// until the first retryable failure, then retries through rendezvous at once
/// (`PairingClient.kt:72-77,129-132`; `docs/REMOTE_ACCESS.md`).
public struct PairingClient: Sendable {
    /// Builds the control transport for the paired connection link (LAN `LanControlTransport`
    /// or `RemoteControlTransport`, both in MicDropTransport; the app captures the identity).
    public typealias TransportFactory = @Sendable (ConnectionLink) throws -> any ControlTransport

    /// Direct LAN for a remote paired link: the handshake-only `LocalProbe` and the LAN `/pair`
    /// transport. The app builds both over one non-cellular `LanSignalingRoute`.
    public struct LocalRoute: Sendable {
        public let probe: any LocalHostProbing
        public let transport: any ControlTransport

        public init(probe: any LocalHostProbing, transport: any ControlTransport) {
            self.probe = probe
            self.transport = transport
        }
    }

    /// Builds the direct LAN route for a remote paired link (`LanNetwork` + `LocalProbe`).
    public typealias LocalRouteFactory = @Sendable (ConnectionLink) -> LocalRoute

    /// Called around the LAN probe and at the start of every poll iteration; returns the closure that ends it. The app
    /// wraps each in `UIApplication.beginBackgroundTask(withName: "MicDrop pairing")` whose expiration handler cancels
    /// nothing.
    public typealias IterationLease = @Sendable () async -> (@Sendable () async -> Void)

    /// Clocks and sleep, injectable for deadline tests.
    public struct Timing: Sendable {
        /// Monotonic milliseconds that advance during sleep (Android `elapsedRealtime`).
        public var monotonicNowMs: @Sendable () -> Int64
        /// Wall-clock Unix seconds (expiry checks).
        public var wallNowSeconds: @Sendable () -> Int64
        /// Cancellable sleep; throws `CancellationError` when the task is cancelled.
        public var sleepMs: @Sendable (Int64) async throws -> Void
        /// Waits out the approval time left for one LAN `/pair` request (`sendWithinWindow`); cancelled when
        /// the request ends first. Separate from `sleepMs`, so a test clock whose poll sleep advances at once
        /// does not expire requests. Defaults to `Task.sleep`.
        public var awaitDeadlineMs: @Sendable (Int64) async throws -> Void

        public init(
            monotonicNowMs: @escaping @Sendable () -> Int64,
            wallNowSeconds: @escaping @Sendable () -> Int64,
            sleepMs: @escaping @Sendable (Int64) async throws -> Void,
            awaitDeadlineMs: @escaping @Sendable (Int64) async throws -> Void = Timing.taskSleepMs
        ) {
            self.monotonicNowMs = monotonicNowMs
            self.wallNowSeconds = wallNowSeconds
            self.sleepMs = sleepMs
            self.awaitDeadlineMs = awaitDeadlineMs
        }

        /// `Task.sleep` for a non-negative number of milliseconds; throws `CancellationError` when cancelled.
        public static let taskSleepMs: @Sendable (Int64) async throws -> Void = { milliseconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        }

        /// Production timing: `clock.nowMs()` (app `SystemMonotonicClock`), `UnixTime.now()`, `Task.sleep` for poll
        /// delays and request deadlines.
        public static func live(clock: any MonotonicClock) -> Timing {
            Timing(
                monotonicNowMs: { clock.nowMs() },
                wallNowSeconds: { UnixTime.now() },
                sleepMs: taskSleepMs, awaitDeadlineMs: taskSleepMs)
        }
    }

    /// Non-I/O enrollment failures (fatal, classified `SETUP_FAILED`; Android `require` /
    /// `IllegalArgumentException`, `PairingClient.kt:61,103-111`).
    public enum Failure: Error, Equatable, Sendable {
        /// `require(!invitation.expired())` before the first request.
        case invitationExpired
        /// Reply body over 1024 bytes (`PairingClient.kt:90-100`).
        case replyTooLarge
        /// Not a strict JSON object, or not exactly `version, state, request_id`.
        case malformedReply
        /// `version` is not the integer literal 1.
        case unsupportedVersion
        /// Pending `request_id` not `^[0-9a-f]{12}$`.
        case invalidRequestID
        /// `state` neither `pending` nor `approved` ("Unsupported pairing response").
        case unsupportedState
    }

    /// Request path (`manager.go:253`).
    public static let path = "/pair"
    /// Reply cap for LAN and remote.
    public static let maxReplyBytes = 1024
    /// Upper bound of the enrollment window (`PairingClient.kt:64`).
    public static let maxWindowMs: Int64 = 300_000
    /// Poll / retry delay cap (`PairingClient.kt:120`).
    public static let pollIntervalMs: Int64 = 3_000
    /// LAN connect and read timeout cap (`PairingClient.kt:83-84`).
    public static let lanRequestCapMs: Int64 = 5_000
    /// Remote whole-exchange deadline cap (`PairingClient.kt:76`).
    public static let remoteRequestCapMs: Int64 = 15_000
    /// Remote-link LAN probe bound (branch `LocalProbe.kt:18`, the `LAN_PROBE` default).
    public static let lanProbeTimeoutMs: Int64 = 1_500
    /// HTTP statuses retried within the window (`PairingClient.kt:117`).
    public static let retryableStatuses: Set<Int> = [429, 503]

    /// Retryable-error progress text (`PairingClient.kt:118`).
    public static let retryText = "Waiting for Windows. Pairing will retry within the approval window."
    /// Retry progress while iOS Local Network access may be blocked.
    public static let localNetworkRetryText =
        "Waiting for Windows. Allow Local Network access for MicDrop if iOS asks. Pairing will retry within the approval window."

    /// No-op lease (default when the caller does not need background time).
    public static let noLease: IterationLease = { return {} }

    public let makeTransport: TransportFactory
    public let timing: Timing
    public let iterationLease: IterationLease
    /// `nil` polls a remote link only through rendezvous.
    public let makeLocalRoute: LocalRouteFactory?

    public init(
        makeTransport: @escaping TransportFactory, timing: Timing,
        iterationLease: @escaping IterationLease = PairingClient.noLease,
        makeLocalRoute: LocalRouteFactory? = nil
    ) {
        self.makeTransport = makeTransport
        self.timing = timing
        self.iterationLease = iterationLease
        self.makeLocalRoute = makeLocalRoute
    }

    /// Enrolls this phone with the invitation's host and returns the paired connection (the
    /// caller saves `connection.pairedRecord()`).
    ///
    /// Throws `CancellationError` when `attempt` (or the task) is cancelled — always checked before classifying an
    /// error; `HTTPFailure(status: 410)` when the window ends (or the last retried `ControlIOError` with kind
    /// `.localNetworkDenied`, so the failure text shows `LOCAL_NETWORK`); any non-retryable transport/TLS/HTTP/reply
    /// error as is. `progress` receives `pendingText(id)` / `retryText` / `localNetworkRetryText`.
    public func enroll(
        _ invitation: PairingInvitation, clientKey: String, label: String,
        attempt: PairingAttempt,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ConnectionLink {
        try await withTaskCancellationHandler {
            try await performEnrollment(
                invitation, clientKey: clientKey, label: label, attempt: attempt, progress: progress)
        } onCancel: {
            attempt.cancel()
        }
    }

    private func performEnrollment(
        _ invitation: PairingInvitation, clientKey: String, label: String,
        attempt: PairingAttempt, progress: @escaping @Sendable (String) -> Void
    ) async throws -> ConnectionLink {
        try attempt.checkpoint()
        let wall = timing.wallNowSeconds()
        guard !invitation.isExpired(now: wall) else { throw Failure.invitationExpired }
        let connection = try invitation.connection(clientKey: clientKey)
        let linkTransport = try makeTransport(connection)
        let start = timing.monotonicNowMs()
        let window = Self.windowMs(expiresAt: invitation.expiresAt, wallNowSeconds: wall)
        let body = Self.requestBody(secret: invitation.secret, label: label)
        // Use elapsed time rather than adding a deadline to an injected Int64 clock.
        func remaining() -> Int64 {
            let elapsed = timing.monotonicNowMs().subtractingReportingOverflow(start)
            guard !elapsed.overflow else { return 0 }
            return window - min(window, max(0, elapsed.partialValue))
        }
        // A remote link polls the verified LAN host first (branch `PairingClient.kt:72-77`).
        var local: LocalRoute?
        if connection.remote != nil, remaining() > 0, let route = makeLocalRoute?(connection) {
            let timeout = Int(min(Self.lanProbeTimeoutMs, max(1, remaining())))
            local = try await probe(route, timeoutMs: timeout, attempt: attempt) ? route : nil
        }
        var lastRetry: Error?
        while remaining() > 0 && !invitation.isExpired(now: timing.wallNowSeconds()) {
            try attempt.checkpoint()
            let endLease = await iterationLease()
            let transport = local?.transport ?? linkTransport
            let tunnelled = connection.remote != nil && local == nil
            let reply: Result<PairingReply, Error>
            do {
                try attempt.checkpoint()
                // The background lease may suspend: never dispatch an expired invitation.
                guard remaining() > 0, !invitation.isExpired(now: timing.wallNowSeconds()) else {
                    throw HTTPFailure(410)
                }
                let request = Self.request(body: body)
                let timeoutMs = Self.requestTimeoutMs(remainingMs: remaining(), remote: tunnelled)
                let response: ControlResponse
                if tunnelled {
                    response = try await transport.send(request, timeoutMs: timeoutMs) { handle in
                        attempt.register(closer: { handle.cancel() })
                    }
                } else {
                    response = try await sendWithinWindow(
                        request, over: transport, timeoutMs: timeoutMs, windowMs: remaining(), attempt: attempt)
                }
                try attempt.checkpoint()
                reply = .success(try Self.decodeReply(response.body))
            } catch {
                reply = .failure(error)
            }
            attempt.clearCloser()
            await endLease()
            try attempt.checkpoint()
            switch reply {
            case .success(.approved):
                return connection
            case .success(.pending(let requestID)):
                lastRetry = nil
                progress(Self.pendingText(requestID))
            case .failure(let error):
                if PairingFailureText.isCancellation(error) { throw CancellationError() }
                guard PairingFailureText.isRetryable(error) else { throw error }
                lastRetry = error
                progress(Self.retryProgressText(for: error))
                // Enrollment receipts are idempotent for this phone and secret: switch to
                // rendezvous and retry without the poll delay (branch `PairingClient.kt:129-132`).
                if local != nil {
                    local = nil
                    continue
                }
            }
            guard remaining() > 0, !invitation.isExpired(now: timing.wallNowSeconds()) else { break }
            let delay = Self.sleepMs(remainingMs: remaining())
            let sleep = Task { try await timing.sleepMs(delay) }
            attempt.register(closer: { sleep.cancel() })
            do {
                try await withTaskCancellationHandler {
                    try await sleep.value
                } onCancel: {
                    sleep.cancel()
                }
            } catch {
                attempt.clearCloser()
                try attempt.checkpoint()
                throw error
            }
            attempt.clearCloser()
        }
        try attempt.checkpoint()
        if let lastRetry, PairingFailureText.isLocalNetworkDenied(lastRetry) { throw lastRetry }
        throw HTTPFailure(410)
    }

    /// One TLS-only probe of the pinned LAN host (branch `PairingClient.kt:72-77`): sends no
    /// invitation secret. An I/O-class failure is an unavailable LAN; cancellation always wins.
    private func probe(_ route: LocalRoute, timeoutMs: Int, attempt: PairingAttempt) async throws -> Bool {
        try attempt.checkpoint()
        let endLease = await iterationLease()
        let verdict: Result<Bool, Error>
        do {
            try attempt.checkpoint()
            let reachable = try await route.probe.reachable(timeoutMs: timeoutMs) { handle in
                attempt.register(closer: { handle.cancel() })
            }
            verdict = .success(reachable)
        } catch {
            verdict = .failure(error)
        }
        attempt.clearCloser()
        await endLease()
        try attempt.checkpoint()
        switch verdict {
        case .success(let reachable):
            return reachable
        case .failure(let error):
            if PairingFailureText.isCancellation(error) { throw CancellationError() }
            guard ConnectionFailure.isIOClass(error) else { throw error }
            return false
        }
    }

    /// One LAN `/pair` request (a LAN link, or the verified LAN host of a remote link) bounded by the approval
    /// time left, `windowMs`. `LanControlTransport` ends a request only at `min(t, connect cap) + t` (up to
    /// 10 s here), which can outlast a short window, so the first of the reply, `timing.awaitDeadlineMs(windowMs)`
    /// and Stop wins. Expiry cancels the request's handle and task and throws `ControlIOError(.timedOut)`
    /// (retryable: the loop then finds no time left and ends with HTTP 410). Stop (`attempt.cancel()` or task
    /// cancellation) throws `CancellationError`. A transport result that arrives first, such as a paired-TLS trust
    /// failure, keeps its classification; a late reply or error is ignored. The tunnelled path needs no wrapper:
    /// its whole exchange is already capped at the time left (`requestTimeoutMs`).
    private func sendWithinWindow(
        _ request: ControlRequest, over transport: any ControlTransport, timeoutMs: Int, windowMs: Int64,
        attempt: PairingAttempt
    ) async throws -> ControlResponse {
        let race = WindowedRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ControlResponse, Error>) in
                race.wait(continuation)
                attempt.register(closer: { race.abandon(CancellationError()) })
                race.track(
                    Task {
                        do {
                            // Stop or expiry before the task ran: the invitation secret is never sent.
                            try Task.checkCancellation()
                            let response = try await transport.send(request, timeoutMs: timeoutMs) { handle in
                                race.attach(handle)
                            }
                            race.complete(.success(response))
                        } catch {
                            race.complete(.failure(error))
                        }
                    })
                race.track(
                    Task {
                        do { try await timing.awaitDeadlineMs(windowMs) } catch { return }
                        race.abandon(ControlIOError(.timedOut))
                    })
            }
        } onCancel: {
            race.abandon(CancellationError())
        }
    }

    /// First-wins state of one `sendWithinWindow` request. Thread-safe; callbacks run outside the lock.
    private final class WindowedRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ControlResponse, Error>?
        private var outcome: Result<ControlResponse, Error>?
        private var abandoned = false
        private var handle: ControlRequestHandle?
        private var tasks: [Task<Void, Never>] = []

        /// Installs the waiting continuation; resumes it at once when the outcome is already known.
        func wait(_ next: CheckedContinuation<ControlResponse, Error>) {
            lock.lock()
            guard let outcome else {
                continuation = next
                lock.unlock()
                return
            }
            lock.unlock()
            next.resume(with: outcome)
        }

        /// Keeps the request or deadline task; cancels it at once when the outcome is already known.
        func track(_ task: Task<Void, Never>) {
            lock.lock()
            let finished = outcome != nil
            if !finished { tasks.append(task) }
            lock.unlock()
            if finished { task.cancel() }
        }

        /// The request's cancel handle; cancelled at once when the window already ended or Stop won.
        func attach(_ next: ControlRequestHandle) {
            lock.lock()
            let cancelNow = abandoned
            if !cancelNow { handle = next }
            lock.unlock()
            if cancelNow { next.cancel() }
        }

        /// The transport's own result, unless the window already ended or Stop won.
        func complete(_ result: Result<ControlResponse, Error>) {
            finish(result, abandon: false)
        }

        /// Ends the wait without the reply (window expiry or Stop): cancels the request.
        func abandon(_ error: Error) {
            finish(.failure(error), abandon: true)
        }

        private func finish(_ result: Result<ControlResponse, Error>, abandon: Bool) {
            lock.lock()
            guard outcome == nil else {
                lock.unlock()
                return
            }
            outcome = result
            abandoned = abandon
            let waiting = continuation
            continuation = nil
            let request = abandon ? handle : nil
            handle = nil
            let pending = tasks
            tasks = []
            lock.unlock()
            request?.cancel()
            for task in pending { task.cancel() }
            waiting?.resume(with: result)
        }
    }

    // MARK: - Pure helpers (exact ports, unit-tested)

    /// Enrollment window `min(300 000, (expiresAt − wallNow) × 1000)` ms (`PairingClient.kt:64-65`).
    public static func windowMs(expiresAt: Int64, wallNowSeconds: Int64) -> Int64 {
        let delta = expiresAt.subtractingReportingOverflow(wallNowSeconds)
        if delta.overflow { return expiresAt > wallNowSeconds ? maxWindowMs : 0 }
        return min(maxWindowMs / 1000, max(0, delta.partialValue)) * 1000
    }

    /// Per-request timeout: LAN `clamp(remaining, 1, 5000)` (connect and per-read,
    /// `PairingClient.kt:83-84`); remote `min(15000, max(1, remaining))` for the whole tunnel
    /// exchange (`PairingClient.kt:76`). The LAN transport also ends the whole request at its
    /// absolute deadline `min(t, connect cap) + t` (at most 10 s here), and `sendWithinWindow`
    /// ends it when the approval window does, so a reply that keeps trickling cannot hold back
    /// the next poll, the retry, the rendezvous fallback or the end of the window.
    public static func requestTimeoutMs(remainingMs: Int64, remote: Bool) -> Int {
        let bounded = max(1, remainingMs)
        return Int(min(remote ? remoteRequestCapMs : lanRequestCapMs, bounded))
    }

    /// Delay before the next poll `min(3000, max(1, remaining))` ms (`PairingClient.kt:120`).
    public static func sleepMs(remainingMs: Int64) -> Int64 {
        min(pollIntervalMs, max(1, remainingMs))
    }

    /// `{"version":1,"secret":"<secret>","label":"<label>"}` in Android order (`PairingClient.kt:66-67`). JSON integer
    /// `1`, no other members.
    public static func requestBody(secret: String, label: String) -> [UInt8] {
        Array(
            StrictJSONObject.encode([
                "version": .integer(1),
                "secret": .string(secret),
                "label": .string(label),
            ]).utf8)
    }

    /// The `/pair` control request: POST (body present), no `Authorization`, no offer attempt, no trickle headers,
    /// 1024-byte reply cap.
    public static func request(body: [UInt8]) -> ControlRequest {
        ControlRequest(
            path: path, bearer: nil, offerAttempt: nil, trickleHeaders: false,
            body: Data(body), maxResponseBytes: maxReplyBytes)
    }

    /// Strict reply decoding (`PairingClient.kt:103-111`): ≤ 1024 bytes; strict JSON object with
    /// exactly `version`, `state`, `request_id`; `version` the integer literal 1; `approved`
    /// ignores `request_id` (it is `""`); `pending` requires `^[0-9a-f]{12}$`; any other state
    /// is fatal.
    public static func decodeReply(_ body: [UInt8]) throws -> PairingReply {
        guard body.count <= maxReplyBytes else {
            throw Failure.replyTooLarge
        }
        let json: StrictJSONObject
        do {
            json = try StrictJSONObject(utf8: body)
        } catch {
            throw Failure.malformedReply
        }
        guard json.count == 3, json.keys == ["version", "state", "request_id"] else {
            throw Failure.malformedReply
        }
        guard case .integer(1)? = json.value("version") else {
            throw Failure.unsupportedVersion
        }
        guard case .string(let state)? = json.value("state") else {
            throw Failure.malformedReply
        }
        switch state {
        case "approved":
            return .approved
        case "pending":
            guard case .string(let id)? = json.value("request_id"), isRequestID(id) else {
                throw Failure.invalidRequestID
            }
            return .pending(requestID: id)
        default:
            throw Failure.unsupportedState
        }
    }

    /// Pending progress text (`PairingClient.kt:109`).
    public static func pendingText(_ id: String) -> String {
        "Waiting for Windows approval.\nRequest ID: \(id)\nIn the Windows app, open Phones, check that this request ID matches, then select Approve."
    }

    /// `localNetworkRetryText` after a Local Network denial, else `retryText`.
    public static func retryProgressText(for error: Error) -> String {
        PairingFailureText.isLocalNetworkDenied(error) ? localNetworkRetryText : retryText
    }

    /// `^[0-9a-f]{12}$` (Go `manager.go:289-294`).
    private static func isRequestID(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count == 12 else {
            return false
        }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
