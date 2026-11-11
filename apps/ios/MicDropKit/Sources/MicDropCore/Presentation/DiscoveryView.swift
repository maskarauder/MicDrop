import Foundation

/// What `LanDiscovery` publishes to the UI (`LanDiscovery.kt:13-14`).
public struct DiscoveryView: Equatable, Sendable {
    public var searching: Bool
    /// Discovery status line (texts in `Strings.Discovery`); `""` after `clearDiscovery()`.
    public var message: String
    /// `DiscoveryIndex.hosts()` at publish time.
    public var hosts: [DiscoveredHost]
    /// iOS-only: Local Network access is (or may be) denied; drives the discovery `Open Settings` link.
    public var localNetworkBlocked: Bool

    public init(
        searching: Bool = false, message: String = "", hosts: [DiscoveredHost] = [],
        localNetworkBlocked: Bool = false
    ) {
        self.searching = searching
        self.message = message
        self.hosts = hosts
        self.localNetworkBlocked = localNetworkBlocked
    }
}
