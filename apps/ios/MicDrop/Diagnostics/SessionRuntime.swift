import AVFoundation
import Foundation
import MicDropCore
import Network

/// Per-session default-network observer and runtime snapshot provider (port of `SessionRuntime.kt`;
/// `SessionRuntimeObserver` is this type).
///
/// One instance per session (`SessionDependencies.runtime` is its factory). The worker calls `start(...)` after
/// acquiring the audio-session permit and before signaling, and `close()` as the first cleanup step (`runtime_close`).
/// Callbacks never perform signaling, never query network state synchronously and never touch audio: they only update
/// counters/evidence and call `onNetworkChanged` (remote-handoff trigger, `NetworkHandoff.changed`).
///
/// iOS mapping (honest equivalents; `nil` where iOS has no concept):
/// - one `NWPathMonitor()` on a private serial queue; path identity
/// `(availableInterfaces.first name, index, type)` while `.satisfied`, else none;
/// - `network` evidence: `available` then the type label on a new identity, `lost` when the observed
/// identity disappears, the type label when the capability key `(type, status == .satisfied, !(isExpensive ||
/// isConstrained))` changes;
/// - `network_blocked` is always `nil` and never emitted; no VPN label;
/// - `foreground_service` is `"unknown"`; screen/idle/wake-lock/validated/light-idle/standby
/// are `nil` (their 12 initial `unknown` evidence events stay,— emitted by `SessionEvidence.connection`, not here);
/// - the copy-text-only "Background audio: active|inactive" comes from
///   `backgroundAudioActive`, by default `systemBackgroundAudioActive`.
///
/// Thread-safe (`NSLock`); `snapshot()`/`networkLabel()` are called from the worker, path updates
/// arrive on the private queue. Lock order: this lock → `SessionEvidence`'s lock (evidence never
/// calls back). Interface names/indices are comparison state only, never serialized.
final class SessionRuntime: @unchecked Sendable {
    /// Saturation bound of `network_changes` (2^53 − 1, Go/JSON safe integer).
    static let maxNetworkChanges: Int64 = 9_007_199_254_740_991

    /// Production "Background audio" source (copy text only): `true` while iOS keeps MicDrop running for audio — the
    /// Info.plist declares the `audio` background mode and the WebRTC audio session is active with audio I/O permitted
    /// (`RTCAudioSession.isActive` and `isAudioEnabled`, read through `AudioSessionArbiter`'s any-thread queries);
    /// otherwise `false`. Never on the wire (`foreground_service` stays `"unknown"`).
    static let systemBackgroundAudioActive: @Sendable () -> Bool? = {
        guard SessionRuntime.declaresAudioBackgroundMode else { return false }
        let arbiter = AudioSessionArbiter.shared
        return arbiter.isActive && arbiter.isAudioEnabled
    }

    /// `"audio" ∈ UIBackgroundModes`, read once.
    private static let declaresAudioBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("audio") ?? false
    }()

    /// One path update reduced to the values this type compares. Built from `NWPath` in production;
    /// tests construct it directly to drive `apply(_:)` without a monitor.
    struct PathObservation: Equatable, Sendable {
        /// `path.status == .satisfied` and a primary interface exists.
        var satisfied: Bool
        /// Primary interface name (comparison only; never serialized).
        var interfaceName: String?
        /// Primary interface index (comparison only).
        var interfaceIndex: Int
        /// `wifi`, `cellular`, `ethernet`, `other`, or `none` when not satisfied.
        var type: String
        /// `isExpensive || isConstrained`.
        var metered: Bool

        init(satisfied: Bool, interfaceName: String?, interfaceIndex: Int, type: String, metered: Bool) {
            self.satisfied = satisfied
            self.interfaceName = interfaceName
            self.interfaceIndex = interfaceIndex
            self.type = type
            self.metered = metered
        }

        /// Primary = `availableInterfaces.first` when `.satisfied`; otherwise unsatisfied.
        init(_ path: NWPath) {
            let primary = path.status == .satisfied ? path.availableInterfaces.first : nil
            self.init(
                satisfied: primary != nil,
                interfaceName: primary?.name,
                interfaceIndex: primary?.index ?? 0,
                type: primary.map { SessionRuntime.typeLabel($0.type) } ?? "none",
                metered: path.isExpensive || path.isConstrained)
        }
    }

    /// Default-network identity (replacement for the Android `Network` handle).
    private struct PathIdentity: Equatable {
        let name: String
        let index: Int
        let type: String
    }

    /// Android `Triple(type, validated, notMetered)`.
    private struct CapabilitiesKey: Equatable {
        let type: String
        let validated: Bool
        let notMetered: Bool
    }

    private let lock = NSLock()
    private let clock: MonotonicClock
    private let backgroundAudioProvider: (@Sendable () -> Bool?)?
    private let queue = DispatchQueue(label: "com.maskarauder.micdrop.session-runtime", qos: .utility)
    private var monitor: NWPathMonitor?

    private var evidence: SessionEvidence?
    private var onNetworkChanged: (@Sendable () -> Void)?
    private var registered = false
    private var active = false
    private var started = false
    private var closed = false
    private var observed: PathIdentity?
    private var capabilitiesKey: CapabilitiesKey?
    private var lastObservation: PathObservation?
    private var networkChanges: Int64 = 0
    private var identities = DefaultNetworkChanges<PathIdentity>()

    /// Factory form used by `SessionDependencies.runtime`: evidence and the handoff callback are supplied later by
    /// `start(evidence:onNetworkChanged:)`.
    /// - Parameters:
    ///   - clock: evidence timestamps (`SystemMonotonicClock` in production).
    ///   - backgroundAudioActive: copy-text-only "Background audio: active|inactive" source
    ///     never on the wire. nil → reported as `unknown`.
    init(
        clock: MonotonicClock = SystemMonotonicClock(),
        backgroundAudioActive: (@Sendable () -> Bool?)? = SessionRuntime.systemBackgroundAudioActive
    ) {
        self.clock = clock
        self.backgroundAudioProvider = backgroundAudioActive
    }

    /// form: evidence and callback bound at construction; call `start()`.
    convenience init(
        evidence: SessionEvidence,
        clock: MonotonicClock = SystemMonotonicClock(),
        backgroundAudioActive: (@Sendable () -> Bool?)? = SessionRuntime.systemBackgroundAudioActive,
        onNetworkChanged: @escaping @Sendable () -> Void
    ) {
        self.init(clock: clock, backgroundAudioActive: backgroundAudioActive)
        self.evidence = evidence
        self.onNetworkChanged = onNetworkChanged
    }

    deinit {
        monitor?.cancel()
    }

    // MARK: Lifecycle

    /// Binds the session's evidence and handoff callback, then starts observing.
    func start(evidence: SessionEvidence, onNetworkChanged: @escaping @Sendable () -> Void) {
        lock.lock()
        self.evidence = evidence
        self.onNetworkChanged = onNetworkChanged
        lock.unlock()
        start()
    }

    /// `SessionRuntime.kt:67-71`: active, start the monitor, `registered = true`. Idempotent; a
    /// closed runtime is never (re)started (an `NWPathMonitor` cannot be restarted after `cancel`,
    /// and a session's observer lives exactly between `start` and `close`).
    func start() {
        lock.lock()
        guard !started, !closed else {
            lock.unlock()
            return
        }
        started = true
        active = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.apply(PathObservation(path))
        }
        self.monitor = monitor
        registered = true
        lock.unlock()
        monitor.start(queue: queue)
    }

    /// `SessionRuntime.kt:99-103`: inactive, cancel the monitor, clear the observed network.
    /// The last path observation is kept: Android's `snapshot()` keeps reporting the default network
    /// after `close()` (it queries `ConnectivityManager` directly), with `network_observer_registered`
    /// now `false`. Idempotent.
    func close() {
        lock.lock()
        closed = true
        active = false
        registered = false
        observed = nil
        capabilitiesKey = nil
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    // MARK: Path updates

    /// Applies one path update (monitor queue in production; tests call it directly after `start`).
    /// - new identity: `observed = identity`, reset key, `network=available` (+1 change), then
    ///   `DefaultNetworkChanges.available` → `onNetworkChanged` (the first update never triggers);
    /// - identity lost: `network=lost` (+1), `DefaultNetworkChanges.lost` → `onNetworkChanged`;
    /// - capability key change on the observed identity: `network=<type>` (+1).
    /// A satisfied identity replacing another one is an `available` without a preceding `lost`
    /// (Android: the new default's `onAvailable`; the old network's late `onLost` is ignored).
    /// `onNetworkChanged` is invoked after the lock is released. Updates after `close()` are ignored.
    func apply(_ observation: PathObservation) {
        var notify = false
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        lastObservation = observation
        let now = clock.nowMs()
        if observation.satisfied {
            let identity = PathIdentity(
                name: observation.interfaceName ?? "",
                index: observation.interfaceIndex, type: observation.type)
            if identity != observed {
                observed = identity
                capabilitiesKey = nil
                change("available", now)
                notify = identities.available(identity)
            }
            let key = CapabilitiesKey(type: observation.type, validated: true, notMetered: !observation.metered)
            if key != capabilitiesKey {
                capabilitiesKey = key
                change(key.type, now)
            }
        } else if let previous = observed {
            observed = nil
            capabilitiesKey = nil
            change("lost", now)
            notify = identities.lost(previous)
        }
        let callback = onNetworkChanged
        lock.unlock()
        if notify { callback?() }
    }

    /// Caller holds `lock`. `SessionRuntime.kt:62-65`.
    private func change(_ value: String, _ now: Int64) {
        networkChanges = min(networkChanges + 1, Self.maxNetworkChanges)
        evidence?.observe(.network, value, uptimeMs: now)
    }

    // MARK: Queries

    /// UI/remote-status label (`SessionRuntime.kt:73-74`): not registered → `unknown`; no observed network → `none`;
    /// else `wifi|cellular|ethernet|other` (never `vpn` on iOS).
    func networkLabel() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !registered { return "unknown" }
        guard observed != nil else { return "none" }
        return capabilitiesKey?.type ?? "unknown"
    }

    /// Number of counted default-network changes (saturating at 2^53 − 1).
    func changeCount() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return networkChanges
    }

    /// Copy-text-only background audio state ("iOS power: … · Background audio: …"); nil when no provider was supplied.
    /// Never serialized.
    func backgroundAudioActive() -> Bool? {
        backgroundAudioProvider?()
    }

    /// Runtime snapshot for `connection.runtime`. `default_network` from the last path update: none received →
    /// `unknown`; unsatisfied → `none`; else the type label. `network_metered` is nil without a satisfied path. Every
    /// unavailable query is `nil`, never `false`. `backgroundAudioActive` feeds only `RuntimeSnapshot.text()`.
    func snapshot() -> RuntimeSnapshot {
        lock.lock()
        let observation = lastObservation
        let changes = networkChanges
        let isRegistered = registered
        lock.unlock()
        let defaultNetwork: String
        let metered: Bool?
        if let observation {
            defaultNetwork = observation.satisfied ? observation.type : "none"
            metered = observation.satisfied ? observation.metered : nil
        } else {
            defaultNetwork = "unknown"
            metered = nil
        }
        return RuntimeSnapshot(
            screenOn: nil,
            batterySaver: ProcessInfo.processInfo.isLowPowerModeEnabled,
            deviceIdle: nil,
            batteryExempt: nil,
            microphonePermission: AVAudioApplication.shared.recordPermission == .granted,
            wakeLockHeld: nil,
            defaultNetwork: defaultNetwork,
            networkValidated: nil,
            networkMetered: metered,
            networkBlocked: nil,
            networkChanges: changes,
            lightIdle: nil,
            lowPowerStandby: nil,
            lowPowerStandbyExempt: nil,
            networkObserverRegistered: isRegistered,
            foregroundService: "unknown",
            backgroundAudioActive: backgroundAudioActive())
    }

    /// `NWInterface.InterfaceType` → runtime label: `.wifi` → `wifi`, `.cellular` → `cellular`, `.wiredEthernet` →
    /// `ethernet`, `.other`/`.loopback`/unknown → `other`.
    static func typeLabel(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .other, .loopback: return "other"
        @unknown default: return "other"
        }
    }
}
