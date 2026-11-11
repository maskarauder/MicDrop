// The single saved connection, its observable view, pairing, Forget and Change address (`SavedConnections.kt`).

import Foundation
import MicDropCore
import MicDropIdentity
import MicDropTransport
import Observation
import UIKit

/// One process-wide store (`SavedConnections.kt:245-248`). All state lives on the main actor;
/// Keychain work runs in `CredentialVault`. Every asynchronous completion applies only if its
/// captured operation id still equals `revision` (stale results are dropped,
/// `SavedConnections.kt:115,133,154,218`).
///
/// Observation: `@Observable` for SwiftUI, plus `observe(_:)`, which calls the observer immediately with the current
/// view and then synchronously from every `publish`.
@MainActor
@Observable
public final class SavedConnectionStore {
    /// The process-wide instance over `CredentialVault.shared` and live dependencies. Applies the install sentinel
    /// before the first load.
    public static let shared: SavedConnectionStore = {
        CredentialVault.shared.applyInstallSentinelIfNeeded()
        return SavedConnectionStore(vault: .shared, dependencies: .live)
    }()

    /// Current snapshot (`SavedConnections.kt:33`).
    public private(set) var view: SavedConnectionView = SavedConnectionView()

    /// `view.working` ("observable isWorking").
    public var isWorking: Bool { view.working }

    private let vault: CredentialVault
    private let dependencies: Dependencies
    /// Last confirmed saved link, trimmed (`SavedConnections.kt:31`).
    @ObservationIgnored private var link: String?
    /// Monotonic operation counter (`SavedConnections.kt:32`).
    @ObservationIgnored private var revision: Int64 = 0
    @ObservationIgnored private var pairingAttempt: PairingAttempt?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    /// Insertion-ordered observers (Android `mutableSetOf` is a LinkedHashSet).
    @ObservationIgnored private var observers: [(id: UInt64, callback: (SavedConnectionView) -> Void)] = []
    @ObservationIgnored private var loadWaiters: [UInt64: LoadWaiter] = [:]
    @ObservationIgnored private var nextID: UInt64 = 0

    /// Creates a store and starts loading (`init { load() }`, `SavedConnections.kt:36`). Tests pass
    /// their own vault and dependencies; production uses `shared`.
    public init(vault: CredentialVault, dependencies: Dependencies) {
        self.vault = vault
        self.dependencies = dependencies
        load()
    }

    // MARK: Dependencies

    /// Runs one enrollment for an invitation with the given identity and label, reporting progress text; returns the
    /// approved paired `ConnectionLink` (remote-routed when the invitation was). throws the signaling error types, or
    /// `CancellationError` when cancelled.
    public typealias Enroller =
        @Sendable (
            _ invitation: PairingInvitation, _ identity: PhoneIdentity,
            _ label: String, _ attempt: PairingAttempt,
            _ progress: @escaping @Sendable (String) -> Void
        ) async throws -> ConnectionLink

    /// Injected collaborators (tests replace them).
    public struct Dependencies: Sendable {
        public var enroll: Enroller
        /// Final pairing failure text: (409/410 text, LOCAL_NETWORK, or `ConnectionFailure.describe(.pairing, error)` +
        /// the "Pairing was not saved…" suffix).
        public var describePairingFailure: @Sendable (Error) -> String
        /// Wall-clock Unix seconds (`UnixTime.now()`).
        public var now: @Sendable () -> Int64
        /// Short date + short time for the v2 expiry line.
        public var formatExpiry: @Sendable (Int64) -> String

        public init(
            enroll: @escaping Enroller,
            describePairingFailure: @escaping @Sendable (Error) -> String,
            now: @escaping @Sendable () -> Int64,
            formatExpiry: @escaping @Sendable (Int64) -> String
        ) {
            self.enroll = enroll
            self.describePairingFailure = describePairingFailure
            self.now = now
            self.formatExpiry = formatExpiry
        }

        /// Production wiring.
        public static var live: Dependencies {
            Dependencies(
                enroll: SavedConnectionStore.liveEnroll,
                describePairingFailure: { PairingFailureText.describe($0) },
                now: { UnixTime.now() },
                formatExpiry: { SavedConnectionView.expiryText($0) })
        }
    }

    /// Store errors thrown to callers of `pair` / `updateAddress`.
    public enum StoreError: Error, Sendable, Equatable {
        /// `require(!invitation.expired())` (`SavedConnections.kt:184`); the UI pre-checks expiry.
        case invitationExpired
        /// `require(current.version == 3)` (`SavedConnections.kt:239`).
        case notPaired
    }

    /// `awaitLoaded` timed out (`PlaybackService.kt:277`; caller shows `message`).
    public struct LoadTimeout: Error, Sendable, Equatable, CustomStringConvertible {
        public static let message = "Saved connection could not be loaded."
        public init() {}
        public var description: String { Self.message }
    }

    // MARK: Observation

    /// Registers `observer`, calls it immediately with the current view
    /// (`SavedConnections.kt:38`), then synchronously from every later publish until the token is
    /// cancelled or released.
    public func observe(_ observer: @escaping (SavedConnectionView) -> Void) -> ObservationToken {
        nextID += 1
        let id = nextID
        observers.append((id: id, callback: observer))
        let token = ObservationToken { [weak self] in
            self?.observers.removeAll { $0.id == id }
        }
        observer(view)
        return token
    }

    // MARK: Queries

    /// `connection()` (`SavedConnections.kt:41-48`): the saved link for Connect/Reconnect/resume, or nil when working,
    /// absent or expired. An expired v2 link first publishes its expired saved view.
    public func connection() -> String? {
        if view.working { return nil }
        guard let saved = link, let parsed = try? ConnectionLink.parse(saved) else { return nil }
        if parsed.isExpired(now: dependencies.now()) {
            publish(savedView(parsed))
            return nil
        }
        return saved
    }

    /// Resume lookup (`PlaybackService.kt:274-292`): waits until the view is not `working` (immediately if it already
    /// is not), then returns `connection()` (nil = absent, expired or forgotten; the caller checks the ticket). Throws
    /// `LoadTimeout` after `timeout` and `CancellationError` if the calling task is cancelled.
    public func awaitLoaded(timeout: Duration = .seconds(10)) async throws -> String? {
        if !view.working { return connection() }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishWaiter(id, with: .failure(LoadTimeout()))
                }
                loadWaiters[id] = LoadWaiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWaiter(id, with: .failure(CancellationError())) }
        }
    }

    // MARK: Mutations

    /// `remember(text)` (`SavedConnections.kt:121-138`): save after authenticated playback (and Change address). v1 and
    /// unparsable links, a running pairing, or an unchanged confirmed link are ignored. Failure keeps the previous
    /// link.
    public func remember(_ text: String) {
        guard let parsed = try? ConnectionLink.parse(text), parsed.version.rawValue >= 2,
            pairingAttempt == nil
        else { return }
        // Kotlin `trim()` (the same normalization every parse and the resume digest use).
        let normalized = ConnectionLink.trimmed(text)
        if normalized == link && !view.working { return }
        revision += 1
        let operation = revision
        var working = view
        working.working = true
        publish(working)
        Task {
            let saved: Bool
            do {
                try await vault.writeSavedLink(normalized)
                saved = true
            } catch {
                saved = false
            }
            guard operation == revision else { return }
            if saved, let confirmed = try? ConnectionLink.parse(normalized) {
                link = normalized
                publish(savedView(confirmed))
            } else {
                var failed = view
                failed.message = SavedConnectionView.Messages.saveNotConfirmed
                failed.working = false
                publish(failed)
            }
        }
    }

    /// `forget()` (`SavedConnections.kt:140-159`): cancel pairing, drop the link, delete the saved link and the phone
    /// identity. Never contacts Windows. The UI also cancels the pairing intent, stops a PAUSED session and clears the
    /// resume ticket.
    public func forget() {
        cancelPairingWork()
        pairingAttempt = nil
        pairingTask = nil
        revision += 1
        let operation = revision
        link = nil
        publish(SavedConnectionView(message: SavedConnectionView.Messages.forgetting))
        Task {
            let removed: Bool
            do {
                try await vault.forgetAll()
                removed = true
            } catch {
                removed = false
            }
            guard operation == revision else { return }
            publish(
                SavedConnectionView(
                    message: removed
                        ? SavedConnectionView.Messages.forgotten : SavedConnectionView.Messages.forgetNotConfirmed,
                    present: !removed, working: false))
        }
    }

    /// `pair(text, label)` (`SavedConnections.kt:177-229`). Returns the operation id for `PairingConnectIntent.begin`,
    /// or nil when working / needs Forget. Throws the invitation parse error, or `StoreError.invitationExpired`.
    public func pair(_ text: String, label: String) throws -> Int64? {
        if view.working { return nil }
        if view.needsForget {
            revision += 1
            var refused = view
            refused.message = SavedConnectionView.Messages.pairingRefusedUnreadable
            refused.pairingFailureID = revision
            publish(refused)
            return nil
        }
        let invitation = try PairingInvitation.parse(text)
        guard !invitation.isExpired(now: dependencies.now()) else { throw StoreError.invitationExpired }
        let previous = link
        revision += 1
        let operation = revision
        let attempt = PairingAttempt()
        pairingAttempt = attempt
        var started = view
        started.message = SavedConnectionView.Messages.pairingStarted
        started.working = true
        started.pairing = true
        started.pairingFailureID = 0
        started.pairingSuccessID = 0
        publish(started)
        let vault = self.vault
        let enroll = dependencies.enroll
        let describe = dependencies.describePairingFailure
        let task = Task {
            var record: String?
            var failed = false
            var message = SavedConnectionView.Messages.pairingCancelled
            do {
                try attempt.checkpoint()
                // A missing paired key requires explicit Forget, never silent replacement.
                if let previous { _ = try await vault.validateSaved(previous) }
                let identity = try await vault.ensureIdentity()
                let connection = try await enroll(invitation, identity, label, attempt) { [weak self] progress in
                    // Android `main.post` (FIFO): progress is applied before the completion below,
                    // whose continuation is also enqueued on the main queue.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.applyProgress(progress, operation: operation, attempt: attempt)
                        }
                    }
                }
                try attempt.checkpoint()
                let value = try connection.pairedRecord()
                try await vault.writeSavedLink(value)
                record = value
            } catch {
                // Cancellation (`CancellationError`/`SessionStopped` in the cause chain), and errors caused by the
                // cancel, keep the cancelled message (Android `InterruptedException`); anything else is a pairing
                // failure.
                if !PairingFailureText.isCancellation(error) && !attempt.isCancelled {
                    failed = true
                    message = describe(error)
                }
            }
            finishPairing(
                operation: operation, attempt: attempt, previous: previous,
                record: record, failed: failed, message: message)
        }
        pairingTask = task
        // `attempt.cancel()` (from any path) also cancels the task, so a poll sleep ends at once.
        attempt.bind(task)
        return operation
    }

    /// `cancelPairing()` (`SavedConnections.kt:231-234`).
    public func cancelPairing() {
        cancelPairingWork()
        var cancelling = view
        cancelling.message = SavedConnectionView.Messages.pairingCancelling
        publish(cancelling)
    }

    /// "Change Windows address" (`SavedConnections.kt:236-241`). Saves immediately through `remember`.: the remote
    /// route is **preserved** (`ConnectionLink.withEndpoint` keeps it). Throws for an invalid endpoint or a non-v3
    /// link; returns silently when there is no usable saved link.
    public func updateAddress(host: String, port: Int) throws {
        guard let previous = connection() else { return }
        let current = try ConnectionLink.parse(previous)
        guard current.version.rawValue == 3 else { throw StoreError.notPaired }
        let endpoint = try LANEndpoint(host: host, port: port)
        let record = try current.withEndpoint(endpoint).pairedRecord()
        remember(record)
    }

    // MARK: Private

    /// Startup load (`SavedConnections.kt:93-117`).
    private func load() {
        revision += 1
        let operation = revision
        let vault = self.vault
        Task {
            let outcome = await vault.loadSavedConnection()
            guard operation == revision else { return }
            switch outcome {
            case .saved(let text):
                if let parsed = try? ConnectionLink.parse(text) {
                    link = text
                    publish(savedView(parsed))
                } else {
                    link = nil
                    publish(
                        SavedConnectionView(
                            message: SavedConnectionView.Messages.savedOrIdentityUnreadable,
                            present: true, working: false, needsForget: true))
                }
            case .absent(let identityPresent):
                link = nil
                publish(
                    SavedConnectionView(
                        message: SavedConnectionView.Messages.noSavedConnection,
                        present: identityPresent, working: false))
            case .unreadable:
                link = nil
                publish(
                    SavedConnectionView(
                        message: SavedConnectionView.Messages.savedUnreadable,
                        present: true, working: false, needsForget: true))
            case .invalid:
                link = nil
                publish(
                    SavedConnectionView(
                        message: SavedConnectionView.Messages.savedOrIdentityUnreadable,
                        present: true, working: false, needsForget: true))
            }
        }
    }

    /// Progress text from the enrollment, applied only while current and not cancelled
    /// (`SavedConnections.kt:198-200`).
    private func applyProgress(_ progress: String, operation: Int64, attempt: PairingAttempt) {
        guard operation == revision, !attempt.isCancelled else { return }
        var update = view
        update.message = progress
        publish(update)
    }

    /// Pairing completion on main, only if still current (`SavedConnections.kt:217-226`).
    private func finishPairing(
        operation: Int64, attempt: PairingAttempt, previous: String?,
        record: String?, failed: Bool, message: String
    ) {
        guard operation == revision else { return }
        pairingAttempt = nil
        pairingTask = nil
        if let record, let parsed = try? ConnectionLink.parse(record) {
            link = record
            var saved = savedView(parsed)
            saved.pairingSuccessID = attempt.isCancelled ? 0 : operation
            publish(saved)
        } else {
            var result =
                previous.flatMap { try? ConnectionLink.parse($0) }.map { savedView($0) }
                ?? SavedConnectionView(present: true, working: false)
            result.message = message
            result.pairingFailureID = (failed && !attempt.isCancelled) ? operation : 0
            publish(result)
        }
    }

    private func cancelPairingWork() {
        pairingAttempt?.cancel()
        pairingTask?.cancel()
    }

    private func savedView(_ parsed: ConnectionLink) -> SavedConnectionView {
        SavedConnectionView.saved(parsed, now: dependencies.now(), formatExpiry: dependencies.formatExpiry)
    }

    /// Sets `view`, notifies observers synchronously, then resolves resume waiters once the view
    /// is not `working` (`SavedConnections.kt:50-53`).
    private func publish(_ next: SavedConnectionView) {
        view = next
        for observer in observers { observer.callback(next) }
        guard !next.working, !loadWaiters.isEmpty else { return }
        // Remove every waiter first: connection() may publish an expiry update, which must not
        // see (and re-resolve) these waiters (Android unsubscribes first, `PlaybackService.kt:281`).
        let waiting = loadWaiters.sorted { $0.key < $1.key }
        loadWaiters.removeAll()
        for (_, waiter) in waiting {
            waiter.timer.cancel()
            waiter.continuation.resume(returning: connection())
        }
    }

    private func finishWaiter(_ id: UInt64, with result: Result<String?, Error>) {
        guard let waiter = loadWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(with: result)
    }

    private struct LoadWaiter {
        let continuation: CheckedContinuation<String?, Error>
        let timer: Task<Void, Never>
    }

    /// Live enrollment: `PairingClient` (MicDropCore) polls `/pair` in the calling task over the transport
    /// `ControlTransportFactory` picks for the paired link the invitation produces (`LanControlTransport`, or
    /// `RemoteControlTransport` when the invitation carried a rendezvous route). A remote link first probes and polls
    /// the pinned LAN host over one non-cellular `LanSignalingRoute`, then falls back to rendezvous
    /// (`PairingClient.kt:72-77`). Every request installs a fresh `ControlTLS.setup(for:identity:)` with this phone's
    /// certificate and signer. Deadlines use `SystemMonotonicClock` (advances during sleep, like `elapsedRealtime`).
    /// The probe and each poll iteration run inside one `PairingBackgroundTask`, whose expiration cancels nothing.
    private nonisolated static func liveEnroll(
        _ invitation: PairingInvitation, _ identity: PhoneIdentity,
        _ label: String, _ attempt: PairingAttempt,
        _ progress: @escaping @Sendable (String) -> Void
    ) async throws -> ConnectionLink {
        let client = PairingClient(
            makeTransport: { link in ControlTransportFactory.make(for: link, identity: identity) },
            timing: .live(clock: SystemMonotonicClock()),
            iterationLease: {
                let lease = await PairingBackgroundTask.begin()
                return { await lease.end() }
            },
            makeLocalRoute: { link in
                let route = LanSignalingRoute(host: link.endpoint.host.description, onChange: {})
                let connector = ControlConnector.transportServices(lanHooks: route.transportHooks)
                return PairingClient.LocalRoute(
                    probe: LocalProbe(
                        link: link, connector: connector,
                        tls: { try ControlTLS.setup(for: link, identity: identity) }),
                    transport: LanControlTransport(link: link, identity: identity, connector: connector))
            })
        return try await client.enroll(
            invitation, clientKey: identity.fingerprint, label: label,
            attempt: attempt, progress: progress)
    }
}

// MARK: - Nested helper types

extension SavedConnectionStore {
    /// Handle returned by `observe(_:)`. `cancel()` (or releasing the token) stops delivery; it is
    /// safe from any thread (removal hops to the main actor). This public nested type is the
    /// saved-connection store's registration handle.
    public final class ObservationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var onCancel: (@MainActor () -> Void)?

        init(onCancel: @escaping @MainActor () -> Void) {
            self.onCancel = onCancel
        }

        public func cancel() {
            lock.lock()
            let action = onCancel
            onCancel = nil
            lock.unlock()
            guard let action else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { action() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
            }
        }

        deinit { cancel() }
    }

    /// One `UIApplication` background task around a pairing poll iteration: named `MicDrop pairing`; the expiration
    /// handler only ends the task (it cancels nothing; the loop resumes when the app returns and re-checks the approval
    /// window).
    @MainActor
    public final class PairingBackgroundTask {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        private init() {}

        public static func begin() -> PairingBackgroundTask {
            let task = PairingBackgroundTask()
            task.identifier = UIApplication.shared.beginBackgroundTask(withName: "MicDrop pairing") { [weak task] in
                MainActor.assumeIsolated { task?.end() }
            }
            return task
        }

        /// Ends the background task; idempotent.
        public func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
