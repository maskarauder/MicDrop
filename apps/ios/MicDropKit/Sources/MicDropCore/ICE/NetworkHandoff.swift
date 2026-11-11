import Foundation

/// Default-network change filter (Kotlin `DefaultNetworkChanges`, `NetworkHandoff.kt:6-27`).
///
/// Retains one current identity for comparison only; never serialized. The first default network after observer
/// registration is not a change; a duplicate or a delayed loss of a previous network is not a change. On iOS `T` is the
/// path identity of (primary interface name, index, type).: iOS never calls `blocked(_:_:)` (no blocked-status
/// callback); it is kept for test parity.
public struct DefaultNetworkChanges<T: Equatable> {
    private var initialized = false
    private var current: T?
    private var blockedState: Bool?

    public init() {}

    /// A default network became available; true when this is a real change.
    @discardableResult
    public mutating func available(_ network: T) -> Bool {
        if current == network { return false }
        let changed = initialized
        initialized = true
        current = network
        blockedState = nil
        return changed
    }

    /// The current default network was lost; a loss of any other network is ignored.
    @discardableResult
    public mutating func lost(_ network: T) -> Bool {
        if current != network { return false }
        current = nil
        blockedState = nil
        return initialized
    }

    /// Android blocked-status edge (`NetworkHandoff.kt:21-26`). Never called on iOS.
    @discardableResult
    public mutating func blocked(_ network: T, _ value: Bool) -> Bool {
        if current != network || blockedState == value { return false }
        let changed = blockedState != nil || value
        blockedState = value
        return changed
    }
}

extension DefaultNetworkChanges: Sendable where T: Sendable {}

/// Coalesces default-network callbacks into one worker-owned recovery action (Kotlin `NetworkHandoff`,
/// `NetworkHandoff.kt:31-50`).
///
/// Thread-safe (`NSLock`): `changed` comes from the network observer's queue, `arm`/`take`/`waiting`
/// from the worker, `stop` from `close()`. A burst of changes becomes one action 300 ms after the
/// last change; changes before `arm()` are discarded; after `stop()` nothing ever fires again.
public final class NetworkHandoff: @unchecked Sendable {
    /// Quiet period after the last change before `take` fires.
    public static let quietPeriodMs: Int64 = 300

    private let lock = NSLock()
    private var revision: Int64 = 0
    private var handled: Int64 = 0
    private var changedAt: Int64 = 0
    private var armed = false
    private var stopped = false

    public init() {}

    /// Records a change; returns true when armed, i.e. the caller should cancel the in-flight remote `/status` request
    /// (only that request) and poke the worker.
    @discardableResult
    public func changed(now: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        revision += 1
        changedAt = now
        return armed
    }

    /// Arms the handoff once media is established on a remote, restart-capable session (step 1); discards earlier
    /// changes.
    public func arm() {
        lock.lock()
        defer { lock.unlock() }
        if !armed && !stopped {
            handled = revision
            armed = true
        }
    }

    /// True once per coalesced burst, after the 300 ms quiet period.
    public func take(now: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !armed || stopped || revision == handled || now - changedAt < Self.quietPeriodMs { return false }
        handled = revision
        return true
    }

    /// A change is waiting for its quiet period (the status loop then waits 100 ms, step 17).
    public func waiting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed && !stopped && revision != handled
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }

    /// Remote network status line (`StreamReceiver.kt:1554-1566`): `"Network: <X>"` plus `" · Restoring connection"`
    /// while `restoring` (`lanRecovery.active || networkHandoff.waiting()`). `defaultNetwork` is the runtime
    /// `default_network` label. The session publishes it only when the text changes.
    public static func statusText(defaultNetwork: String, restoring: Bool) -> String {
        let network: String
        switch defaultNetwork {
        case "wifi": network = "Wi-Fi"
        case "cellular": network = "Cellular"
        case "ethernet": network = "Ethernet"
        case "vpn": network = "VPN"
        case "none": network = "Unavailable"
        default: network = "Checking"
        }
        return "Network: \(network)" + (restoring ? " · Restoring connection" : "")
    }
}
