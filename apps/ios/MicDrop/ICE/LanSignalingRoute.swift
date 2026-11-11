import Foundation
import MicDropCore
import MicDropTransport
import Network

/// LAN signaling route policy, label and wake-on-change (port of `LanNetwork.kt`).
///
/// Android binds each LAN control request to the Wi-Fi/Ethernet network whose routes reach the private host (respecting
/// an active VPN). iOS cannot read routes; the equivalent safety property is that LAN control never leaves over
/// cellular: `configure(_:)` sets `prohibitedInterfaceTypes = [.cellular]` on the LAN transport's `NWParameters` (via
/// `NIOTSConnectionBootstrap.configureNWParameters`), VPN interfaces stay allowed. After the connection is ready,
/// `LanControlTransport` reads `NIOTSChannelOptions.currentPath` and calls `recordReadyPath(path)`; a connect that
/// cannot become ready because only cellular exists calls `recordReadyPath(nil)` (= `recordUnavailable()`) and throws
/// `ControlIOError(.lanNetworkUnavailable)`. MicDropTransport cannot see this app type: pass `transportHooks`
/// (`ControlConnector.LANPathHooks`) to `ControlConnector.transportServices(lanHooks:)` for the session's
/// `LanControlTransport`.
///
/// Wi-Fi/Ethernet changes only wake the worker. Remote links also use this monitor for verified
/// direct fallback; `SignalingRoute.reportRoute` supplies `default` while using rendezvous.
/// Media candidate policy remains based on the remote link, independently of its control route.
///
/// Thread-safe (`NSLock`): the transport records from its event loop, the worker reads.
final class LanSignalingRoute: @unchecked Sendable {

    /// `lan_recovery.signaling_route` vocabulary (host `G/internal/diagnostics/report.go:131-136`);
    /// raw values are the wire labels, verbatim.
    enum Label: String, Sendable, Equatable, CaseIterable {
        /// Before the first LAN request, and always for remote sessions.
        case `default` = "default"
        case wifi = "wifi"
        case ethernet = "ethernet"
        /// A private-IP connection leaving on a non-Wi-Fi/Ethernet interface is a tunnel.
        case vpn = "vpn"
        /// No eligible (non-cellular) network; the request failed with "LAN network unavailable".
        case unavailable = "unavailable"
    }

    /// The signaling host (`ConnectionLink.endpoint.host` description, or `"remote"`).
    let host: String
    /// `LanAddress.bytes(host) != nil` (Kotlin `local`, `LanNetwork.kt:26`).
    let isLocal: Bool

    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var route: Label = .default
    private var active = false
    private var monitors: [NWPathMonitor] = []

    init(
        host: String, onChange: @escaping @Sendable () -> Void,
        queue: DispatchQueue = DispatchQueue(label: "com.maskarauder.micdrop.lan-route")
    ) {
        self.host = host
        self.isLocal = LanAddress.bytes(host) != nil
        self.onChange = onChange
        self.queue = queue
    }

    /// Current label (`routeLabel()`).
    var label: String {
        lock.lock()
        defer { lock.unlock() }
        return route.rawValue
    }

    /// Copy-report line for LAN sessions (`LanNetwork.kt:70`):
    /// `"LAN signaling route: <route> · Cellular media candidates: excluded|allowed"`.
    var text: String {
        "LAN signaling route: \(label) · Cellular media candidates: \(isLocal ? "excluded" : "allowed")"
    }

    /// Copy-report line used instead of `text` for remote sessions (`StreamReceiver.kt:742`).
    static func remoteText(forceRelay: Bool) -> String {
        "Remote signaling: HTTPS rendezvous · Cellular media candidates: allowed · Force TURN relay: \(forceRelay)"
    }

    /// Registers the Wi-Fi and wired-Ethernet monitors (wake only) for local hosts
    /// (`LanNetwork.kt:37-43`). Failure-free on iOS; idempotent.
    func start() {
        lock.lock()
        guard isLocal, !active, monitors.isEmpty else {
            lock.unlock()
            return
        }
        active = true
        let created = [
            NWPathMonitor(requiredInterfaceType: .wifi), NWPathMonitor(requiredInterfaceType: .wiredEthernet),
        ]
        monitors = created
        lock.unlock()
        for monitor in created {
            monitor.pathUpdateHandler = { [weak self] _ in self?.pathChanged() }
            monitor.start(queue: queue)
        }
    }

    /// Unregisters the monitors (`LanNetwork.kt:71-75`); permanent.
    func close() {
        lock.lock()
        active = false
        let current = monitors
        monitors = []
        lock.unlock()
        for monitor in current { monitor.cancel() }
    }

    /// LAN `NWParameters` policy: never cellular for a local host; VPNs allowed; no internet validation requirement. No
    /// change for non-local hosts.
    func configure(_ parameters: NWParameters) {
        guard isLocal else { return }
        parameters.prohibitedInterfaceTypes = [.cellular]
    }

    /// Records the label from a ready LAN control connection's path. `nil` follows the
    /// `ControlConnector.LANPathHooks.onReadyPath` contract: the connect failed because no eligible (non-cellular) path
    /// exists → `unavailable` (`LanNetwork.kt:61`; on success the transport always has a path,
    /// `NIOTSChannelOptions.currentPath` is non-optional). Ignored for non-local hosts.
    func recordReadyPath(_ path: NWPath?) {
        guard isLocal else { return }
        guard let path else {
            recordUnavailable()
            return
        }
        let next = Self.label(for: path)
        lock.lock()
        route = next
        lock.unlock()
    }

    /// A LAN connect failed because no non-cellular path exists (`selected()` → `unavailable`,
    /// `LanNetwork.kt:61`). Ignored for non-local hosts.
    func recordUnavailable() {
        guard isLocal else { return }
        lock.lock()
        route = .unavailable
        lock.unlock()
    }

    /// Closure form of `configure(_:)` for `NIOTSConnectionBootstrap.configureNWParameters`.
    var parametersConfigurator: @Sendable (NWParameters) -> Void {
        { [self] parameters in self.configure(parameters) }
    }

    /// Closure form of `recordReadyPath(_:)` for the LAN transport.
    var readyPathRecorder: @Sendable (NWPath?) -> Void {
        { [self] path in self.recordReadyPath(path) }
    }

    /// The MicDropTransport LAN hooks for this route: `configureParameters` = `configure(_:)` (the transport already
    /// prohibits cellular; this re-applies the same policy), `onReadyPath` = `recordReadyPath(_:)`. Remote sessions may
    /// pass it too (both are no-ops for a non-local host). Usage: `ControlConnector.transportServices(lanHooks:
    /// route.transportHooks)`.
    var transportHooks: ControlConnector.LANPathHooks {
        ControlConnector.LANPathHooks(configureParameters: parametersConfigurator, onReadyPath: readyPathRecorder)
    }

    /// Ready-path label: `.other` → `vpn` first (Android checks the VPN default before Wi-Fi/Ethernet,
    /// `LanNetwork.kt:47-50`), then `.wifi` → `wifi`, `.wiredEthernet` → `ethernet`; any other ready path reports
    /// `default` (the system default route was used).
    static func label(for path: NWPath) -> Label {
        if path.usesInterfaceType(.other) { return .vpn }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .default
    }

    private func pathChanged() {
        lock.lock()
        let wake = active
        lock.unlock()
        if wake { onChange() }
    }
}
