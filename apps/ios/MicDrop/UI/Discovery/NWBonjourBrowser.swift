// `NWBrowser` adapter for `LanDiscovery` ("Browser", "State mapping", "Results mapping").
//
// Bonjour browsing needs no multicast entitlement (works with free provisioning), but it needs `NSBonjourServices =
// [_micdrop._tcp]` and `NSLocalNetworkUsageDescription` in Info.plist; without them the browser waits/fails with
// PolicyDenied/NoAuth.

import Foundation
import MicDropCore
import Network

/// Browses `_micdrop._tcp` in `local.` with TXT records, on the main queue.
@MainActor
final class NWBonjourBrowser: BonjourBrowsing {
    /// `kDNSServiceErr_PolicyDenied` (Local Network access not granted).
    nonisolated static var policyDeniedCode: Int32 { -65570 }
    /// `kDNSServiceErr_NoAuth` (missing `NSBonjourServices` entry or denied access).
    nonisolated static var noAuthCode: Int32 { -65555 }

    var onState: (@MainActor (BonjourBrowseState) -> Void)?
    var onChanges: (@MainActor ([BonjourBrowseChange]) -> Void)?

    private let type: String
    private let domain: String
    private var browser: NWBrowser?
    private var cancelled = false

    init(type: String = DiscoveryRecord.type, domain: String = DiscoveryRecord.domain) {
        self.type = type
        self.domain = domain
    }

    func start() {
        guard browser == nil, !cancelled else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.onState?(NWBonjourBrowser.map(state))
            }
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mapped = NWBonjourBrowser.map(changes)
                if !mapped.isEmpty { self.onChanges?(mapped) }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let browser {
            browser.cancel()
        } else {
            // Never started: report `.cancelled` asynchronously like NWBrowser would.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onState?(.cancelled) }
            }
        }
    }

    // MARK: Mapping (pure, unit-testable)

    /// state table.
    nonisolated static func map(_ state: NWBrowser.State) -> BonjourBrowseState {
        switch state {
        case .setup:
            return .setup
        case .ready:
            return .ready
        case .waiting(let error):
            return .waiting(policyDenied: isPolicyDenied(error))
        case .failed(let error):
            return .failed(policyDenied: isPolicyDenied(error))
        case .cancelled:
            return .cancelled
        @unknown default:
            return .setup
        }
    }

    /// `NWError.dns(kDNSServiceErr_PolicyDenied)` or `NWError.dns(kDNSServiceErr_NoAuth)`.
    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == policyDeniedCode || code == noAuthCode
        }
        return false
    }

    /// results mapping: `.added`, `.removed`, `.changed` with `.metadataChanged` (others and `.identical` dropped).
    /// Results whose endpoint is not `.service` are dropped.
    nonisolated static func map(_ changes: Set<NWBrowser.Result.Change>) -> [BonjourBrowseChange] {
        var mapped: [BonjourBrowseChange] = []
        for change in changes {
            switch change {
            case .added(let result):
                if let value = map(result) { mapped.append(.added(value)) }
            case .removed(let result):
                if let value = map(result) { mapped.append(.removed(value)) }
            case .changed(old: _, new: let result, let flags):
                if flags.contains(.metadataChanged), let value = map(result) {
                    mapped.append(.metadataChanged(value))
                }
            case .identical:
                break
            @unknown default:
                break
            }
        }
        return mapped
    }

    nonisolated static func map(_ result: NWBrowser.Result) -> BonjourBrowseResult? {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
        return BonjourBrowseResult(
            name: name, type: type, domain: domain,
            attributes: TXTRecordAdapter.attributes(metadata: result.metadata),
            endpoint: result.endpoint)
    }
}
