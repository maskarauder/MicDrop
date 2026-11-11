// LAN discovery state machine (`LanDiscovery.kt`), over abstract browse/resolve adapters so the machine is
// unit-testable with fakes (`LanDiscoveryTests`).
//
// Every field is an untrusted hint: discovery never installs a pin; the UI can only re-target an
// existing v3 pairing whose key equals the advertised hint (`DiscoveredHost.connection(for:)`).

import Foundation
import MicDropCore
import Network

// MARK: - Adapter contracts

/// `NWBrowser.State` reduced to what the machine needs (state mapping).
enum BonjourBrowseState: Equatable, Sendable {
    case setup
    case ready
    /// `.waiting(error)`; `policyDenied` for `NWError.dns(kDNSServiceErr_PolicyDenied / NoAuth)`.
    case waiting(policyDenied: Bool)
    /// `.failed(error)`; `policyDenied` as above.
    case failed(policyDenied: Bool)
    case cancelled
}

/// One browse result: a `.service` endpoint plus its TXT attributes.
struct BonjourBrowseResult: Equatable {
    let name: String
    let type: String
    let domain: String
    /// `TXTRecordAdapter` output: key → value, `nil` value = key-only entry. `nil` = invalid or absent
    /// TXT metadata (resolution is skipped and the service yields no hosts).
    let attributes: [String: Data?]?
    /// The endpoint handed to the resolver.
    let endpoint: NWEndpoint

    init(name: String, type: String, domain: String, attributes: [String: Data?]?, endpoint: NWEndpoint) {
        self.name = name
        self.type = type
        self.domain = domain
        self.attributes = attributes
        self.endpoint = endpoint
    }

    /// `DiscoveryIndex` service key: `"<name>/<type>/<lowercased domain>"`.
    var key: String { DiscoveryRecord.serviceKey(name: name, type: type, domain: domain) }
}

/// `NWBrowser.Result.Change` reduced (results mapping). Interface-only changes and `.identical` are dropped by the
/// adapter.
enum BonjourBrowseChange: Equatable {
    case added(BonjourBrowseResult)
    case removed(BonjourBrowseResult)
    /// `.changed(old:new:flags:)` with `.metadataChanged`; carries the new result.
    case metadataChanged(BonjourBrowseResult)
}

/// Something that can be cancelled (a resolution or a timer). Idempotent; main actor only.
@MainActor
protocol BonjourCancellable: AnyObject {
    func cancel()
}

/// A Bonjour browser for `_micdrop._tcp` (live: `NWBonjourBrowser`). Callbacks arrive on the main actor.
@MainActor
protocol BonjourBrowsing: AnyObject {
    var onState: (@MainActor (BonjourBrowseState) -> Void)? { get set }
    var onChanges: (@MainActor ([BonjourBrowseChange]) -> Void)? { get set }
    func start()
    /// Idempotent; `.cancelled` follows asynchronously.
    func cancel()
}

/// A resolved service address: canonical dotted IPv4 and port.
struct BonjourResolvedAddress: Equatable, Sendable {
    let host: String
    let port: Int
}

/// Resolves one service endpoint to one IPv4 address (live: `BonjourResolver`). The completion runs on
/// the main actor at most once, and never after `cancel()`.
@MainActor
protocol BonjourResolving: AnyObject {
    func resolve(
        _ endpoint: NWEndpoint,
        completion: @escaping @MainActor (Result<BonjourResolvedAddress, Error>) -> Void
    ) -> BonjourCancellable
}

/// Main-actor timer source (live: `DispatchQueue.main.asyncAfter`), injectable for the 30 s timeout tests.
@MainActor
protocol BonjourScheduling: AnyObject {
    func schedule(afterMs: Int64, _ action: @escaping @MainActor () -> Void) -> BonjourCancellable
}

// MARK: - State machine

/// Process-wide discovery singleton (`LanDiscovery.kt:16-18`, `:198-201`).
///
/// One search at a time, 30 s timeout, at most 8 services resolved, 4 hosts kept per service and
/// 16 displayed (bounds enforced by `DiscoveryIndex`). Only the current search (generation + ticket)
/// updates the UI; late callbacks from an old search or a removed service are ignored. Results stay
/// selectable after the timeout or Stop; only `detach()` clears them.
@MainActor
final class LanDiscovery {
    static let shared = LanDiscovery()

    private let makeBrowser: @MainActor () -> BonjourBrowsing
    private let resolver: BonjourResolving
    private let scheduler: BonjourScheduling

    private var update: ((DiscoveryView) -> Void)?
    private var generation: UInt64 = 0
    private var searching = false
    /// The current browse task; kept until its browser reports `.cancelled` (Android's reserved
    /// browser), so repeated Find taps never accumulate browsers.
    private var browser: BrowseTask?
    private let index = DiscoveryIndex()
    /// Service key → its current ticket.
    private var tickets: [String: DiscoveryIndex.Ticket] = [:]
    /// Service key → in-flight resolution.
    private var resolutions: [String: BonjourCancellable] = [:]
    private var timeout: BonjourCancellable?
    /// iOS: the browser reported `PolicyDenied` (Local Network access not granted yet).
    private var policyDenied = false
    /// Published `DiscoveryView.localNetworkBlocked`.
    private var localNetworkBlocked = false

    init(
        makeBrowser: @escaping @MainActor () -> BonjourBrowsing = { NWBonjourBrowser() },
        resolver: BonjourResolving? = nil,
        scheduler: BonjourScheduling? = nil
    ) {
        self.makeBrowser = makeBrowser
        self.resolver = resolver ?? BonjourResolver()
        self.scheduler = scheduler ?? MainQueueBonjourScheduler()
    }

    /// `start(onUpdate)` (`LanDiscovery.kt:32-54`).
    func start(onUpdate: @escaping (DiscoveryView) -> Void) {
        update = onUpdate
        if let browser {
            browser.requestStop()
            emit(Strings.Discovery.previousStopping)
            return
        }
        generation &+= 1
        index.clear()
        tickets.removeAll()
        cancelResolutions()
        searching = true
        policyDenied = false
        localNetworkBlocked = false
        let task = BrowseTask(epoch: generation, browser: makeBrowser())
        browser = task
        emit(Strings.Discovery.looking)
        let epoch = generation
        timeout = scheduler.schedule(afterMs: DiscoveryRecord.searchTimeoutMs) { [weak self] in
            guard let self, self.generation == epoch, self.searching else { return }
            self.finish(Strings.Discovery.finished)
        }
        task.browser.onState = { [weak self, weak task] state in
            guard let self, let task else { return }
            self.browseState(state, task)
        }
        task.browser.onChanges = { [weak self, weak task] changes in
            guard let self, let task else { return }
            self.browseChanges(changes, task)
        }
        task.browser.start()
    }

    /// `stop()` (`LanDiscovery.kt:56`).
    func stop() {
        finish(Strings.Discovery.userStopped)
    }

    /// `detach()` (`LanDiscovery.kt:58-62`): stop publishing, end the search and drop all results.
    func detach() {
        update = nil
        finish("")
        index.clear()
        tickets.removeAll()
    }

    // MARK: Private

    private func current(_ task: BrowseTask) -> Bool {
        generation == task.epoch && searching && browser === task
    }

    private func emit(_ message: String) {
        update?(
            DiscoveryView(
                searching: searching, message: message, hosts: index.hosts(),
                localNetworkBlocked: localNetworkBlocked))
    }

    /// `finish(msg)` (`LanDiscovery.kt:66-77`). The index is kept.
    private func finish(_ message: String) {
        searching = false
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        browser?.requestStop()
        cancelResolutions()
        var text = message
        if message == Strings.Discovery.finished && index.hosts().isEmpty {
            if policyDenied {
                // iOS: the 30 s window ended while Local Network access was still denied.
                localNetworkBlocked = true
                text = Strings.Discovery.blocked
            } else {
                text = Strings.Discovery.noneFound
            }
        }
        emit(text)
    }

    private func cancelResolutions() {
        let pending = resolutions.values
        resolutions.removeAll()
        for resolution in pending { resolution.cancel() }
    }

    private func browseState(_ state: BonjourBrowseState, _ task: BrowseTask) {
        switch state {
        case .setup:
            break
        case .ready:
            task.started = true
            if task.stopRequested || !current(task) {
                task.requestStop()
                return
            }
            if policyDenied {
                policyDenied = false
                localNetworkBlocked = false
                emit(Strings.Discovery.looking)
            }
        case .waiting(let denied):
            // Local Network prompt showing or declined: keep searching; the 30 s timer continues.
            guard denied, current(task) else { return }
            policyDenied = true
            localNetworkBlocked = true
            emit(Strings.Discovery.localNetworkPrompt)
        case .failed(let denied):
            // Android `onStartDiscoveryFailed` (`LanDiscovery.kt:105-112`): release the reserved browser
            // and finish, whether or not this search is still current.
            guard browser === task else { return }
            browser = nil
            if denied || policyDenied {
                localNetworkBlocked = true
                finish(Strings.Discovery.blocked)
            } else {
                finish(Strings.Discovery.couldNotStart)
            }
        case .cancelled:
            guard browser === task else { return }
            let wasCurrent = current(task)
            browser = nil
            if wasCurrent { finish(Strings.Discovery.browserStopped) }
        }
    }

    private func browseChanges(_ changes: [BonjourBrowseChange], _ task: BrowseTask) {
        for change in changes {
            guard current(task) else { return }
            switch change {
            case .added(let result):
                add(result, task)
            case .removed(let result):
                let key = result.key
                index.remove(key)
                tickets[key] = nil
                resolutions.removeValue(forKey: key)?.cancel()
                emit(Strings.Discovery.looking)
            case .metadataChanged(let result):
                let key = result.key
                if let ticket = tickets[key], index.contains(ticket) {
                    resolutions.removeValue(forKey: key)?.cancel()
                    resolve(result, ticket: ticket, task: task)
                } else {
                    add(result, task)
                }
            }
        }
    }

    /// Service found (`LanDiscovery.kt:122-133`; `.added`).
    private func add(_ result: BonjourBrowseResult, _ task: BrowseTask) {
        guard DiscoveryRecord.acceptsType(result.type),
            !result.name.allSatisfy({ $0.isWhitespace })
        else { return }
        let key = result.key
        guard let ticket = index.claim(key) else { return }
        tickets[key] = ticket
        resolve(result, ticket: ticket, task: task)
    }

    /// Resolution (`LanDiscovery.kt:137-196`). An invalid TXT skips network resolution (same visible outcome as
    /// Android, which resolved first and parsed after).
    private func resolve(_ result: BonjourBrowseResult, ticket: DiscoveryIndex.Ticket, task: BrowseTask) {
        let key = result.key
        guard let attributes = result.attributes, Set(attributes.keys) == DiscoveryRecord.txtKeys else {
            index.update(ticket, hosts: [])
            emit(Strings.Discovery.select)
            return
        }
        // A reference flag (not a captured `var`): the completion may run before `resolve` returns.
        let completed = CompletionFlag()
        let resolution = resolver.resolve(result.endpoint) { [weak self] outcome in
            completed.value = true
            guard let self, self.current(task), self.index.contains(ticket) else { return }
            self.resolutions[key] = nil
            switch outcome {
            case .success(let address):
                self.index.update(
                    ticket,
                    hosts: DiscoveryRecord.parse(
                        addresses: [address.host], port: address.port,
                        attributes: attributes))
                self.emit(Strings.Discovery.select)
            case .failure:
                self.index.remove(ticket.service)
                self.tickets[key] = nil
                self.emit(Strings.Discovery.unresolved)
            }
        }
        if !completed.value { resolutions[key] = resolution }
    }

    /// Set by a resolution completion that ran synchronously inside `resolve`.
    @MainActor
    private final class CompletionFlag {
        var value = false
    }
}

/// One browse attempt bound to the generation that started it.
@MainActor
private final class BrowseTask {
    let epoch: UInt64
    let browser: BonjourBrowsing
    var started = false
    var stopRequested = false

    init(epoch: UInt64, browser: BonjourBrowsing) {
        self.epoch = epoch
        self.browser = browser
    }

    /// `requestStop()`: `NWBrowser.cancel()` is idempotent and valid before `.ready`.
    func requestStop() {
        stopRequested = true
        browser.cancel()
    }
}

/// `DispatchQueue.main.asyncAfter` timer.
@MainActor
final class MainQueueBonjourScheduler: BonjourScheduling {
    init() {}

    func schedule(afterMs: Int64, _ action: @escaping @MainActor () -> Void) -> BonjourCancellable {
        let timer = ScheduledAction(action)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(afterMs))) {
            MainActor.assumeIsolated { timer.fire() }
        }
        return timer
    }

    @MainActor
    private final class ScheduledAction: BonjourCancellable {
        private var action: (@MainActor () -> Void)?

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func fire() {
            let pending = action
            action = nil
            pending?()
        }

        func cancel() {
            action = nil
        }
    }
}
