import Foundation

// Fixed labels only (`K:SessionEvidence.kt:6-7`). Never serialize an error message, network/device ID,
// address, candidate or SDP. The host validates the same closed vocabulary
// (`G:internal/diagnostics/session.go:59-94`).

/// Evidence kinds with their wire names (`K:SessionEvidence.kt:72-79`).
public enum EvidenceKind: String, Sendable, CaseIterable {
    case peer
    case ice
    case host
    case network
    case networkBlocked = "network_blocked"
    case screen
    case idle
    case batterySaver = "battery_saver"
    case batteryExempt = "battery_exempt"
    case microphonePermission = "microphone_permission"
    case wakeLock = "wake_lock"
    case networkValidated = "network_validated"
    case networkMetered = "network_metered"
    case lightIdle = "light_idle"
    case lowPowerStandby = "low_power_standby"
    case lowPowerExempt = "low_power_exempt"
    case foregroundService = "foreground_service"

    /// Peer-connection labels (`session.go:75-94`).
    public static let peerValues: Set<String> = ["connecting", "new", "connected", "disconnected", "failed", "closed"]
    /// ICE-connection labels.
    public static let iceValues: Set<String> = [
        "new", "checking", "connected", "completed", "disconnected", "failed", "closed",
    ]
    /// Default-network evidence labels (iOS never produces `vpn`).
    public static let networkValues: Set<String> = [
        "none", "unknown", "wifi", "cellular", "ethernet", "vpn", "other",
        "available", "lost",
    ]
    /// Runtime flag labels.
    public static let flagValues: Set<String> = ["true", "false", "unknown"]
    /// `foreground_service` labels (`session.go:60`); iOS always `unknown`.
    public static let foregroundServiceValues: Set<String> = [
        "none", "unknown", "microphone", "media_playback",
        "microphone_and_playback", "other",
    ]

    /// Values the host accepts for this kind.
    public var allowedValues: Set<String> {
        switch self {
        case .peer:
            return Self.peerValues
        case .ice:
            return Self.iceValues
        case .host:
            return Self.peerValues.union(["unavailable"])
        case .network:
            return Self.networkValues
        case .foregroundService:
            return Self.foregroundServiceValues
        case .networkBlocked, .screen, .idle, .batterySaver, .batteryExempt, .microphonePermission, .wakeLock,
            .networkValidated, .networkMetered, .lightIdle, .lowPowerStandby, .lowPowerExempt:
            return Self.flagValues
        }
    }

    /// Host evidence label from a `/status` response `state` (`K:StreamReceiver.kt:663-665`, step 6): the value if it
    /// is a peer label, else `unavailable`.
    public static func hostValue(_ state: String?) -> String {
        guard let state, peerValues.contains(state) else { return "unavailable" }
        return state
    }

    /// Runtime flag label: `true` / `false` / `unknown` (`K:SessionEvidence.kt:103`).
    public static func flagValue(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "unknown"
    }
}

/// One evidence observation (`K:SessionEvidence.kt:81-83`).
public struct EvidenceEvent: Sendable, Equatable {
    public let uptimeMs: Int64
    public let kind: EvidenceKind
    public let value: String

    public init(uptimeMs: Int64, kind: EvidenceKind, value: String) {
        self.uptimeMs = uptimeMs
        self.kind = kind
        self.value = value
    }

    /// `{"uptime_ms":…,"kind":…,"value":…}`.
    public func json() -> DiagnosticJSON {
        .object([
            (key: "uptime_ms", value: .int(uptimeMs)),
            (key: "kind", value: .string(kind.rawValue)),
            (key: "value", value: .string(value)),
        ])
    }
}

/// Power/network runtime observation for `connection.runtime` (`K:SessionEvidence.kt:40-57`). Every boolean is
/// nullable: `nil` means the query is unavailable, never `false`. Produced by the app's `SessionRuntime`
/// (NWPathMonitor).
public struct RuntimeSnapshot: Sendable, Equatable {
    /// `default_network` vocabulary (`session.go:59`).
    public static let defaultNetworkLabels: Set<String> = [
        "none", "unknown", "wifi", "cellular", "ethernet", "vpn", "other",
    ]

    public var screenOn: Bool?
    public var batterySaver: Bool?
    public var deviceIdle: Bool?
    public var batteryExempt: Bool?
    public var microphonePermission: Bool?
    public var wakeLockHeld: Bool?
    public var defaultNetwork: String
    public var networkValidated: Bool?
    public var networkMetered: Bool?
    /// Always `nil` on iOS.
    public var networkBlocked: Bool?
    /// Saturating at 2^53-1.
    public var networkChanges: Int64
    public var lightIdle: Bool?
    public var lowPowerStandby: Bool?
    public var lowPowerStandbyExempt: Bool?
    public var networkObserverRegistered: Bool
    /// Always `unknown` on iOS.
    public var foregroundService: String
    /// Copy text only ("Background audio: active|inactive"); never serialized.
    public var backgroundAudioActive: Bool?

    public init(
        screenOn: Bool? = nil, batterySaver: Bool? = nil, deviceIdle: Bool? = nil, batteryExempt: Bool? = nil,
        microphonePermission: Bool? = nil, wakeLockHeld: Bool? = nil, defaultNetwork: String = "unknown",
        networkValidated: Bool? = nil, networkMetered: Bool? = nil, networkBlocked: Bool? = nil,
        networkChanges: Int64 = 0, lightIdle: Bool? = nil, lowPowerStandby: Bool? = nil,
        lowPowerStandbyExempt: Bool? = nil, networkObserverRegistered: Bool = false,
        foregroundService: String = "unknown", backgroundAudioActive: Bool? = nil
    ) {
        self.screenOn = screenOn
        self.batterySaver = batterySaver
        self.deviceIdle = deviceIdle
        self.batteryExempt = batteryExempt
        self.microphonePermission = microphonePermission
        self.wakeLockHeld = wakeLockHeld
        self.defaultNetwork = defaultNetwork
        self.networkValidated = networkValidated
        self.networkMetered = networkMetered
        self.networkBlocked = networkBlocked
        self.networkChanges = networkChanges
        self.lightIdle = lightIdle
        self.lowPowerStandby = lowPowerStandby
        self.lowPowerStandbyExempt = lowPowerStandbyExempt
        self.networkObserverRegistered = networkObserverRegistered
        self.foregroundService = foregroundService
        self.backgroundAudioActive = backgroundAudioActive
    }

    /// Wire object, Android key order (`K:SessionEvidence.kt:47-55`).
    public func json() -> DiagnosticJSON {
        .object([
            (key: "screen_on", value: .nullable(screenOn)),
            (key: "battery_saver", value: .nullable(batterySaver)),
            (key: "device_idle", value: .nullable(deviceIdle)),
            (key: "battery_optimization_exempt", value: .nullable(batteryExempt)),
            (key: "microphone_permission", value: .nullable(microphonePermission)),
            (key: "wake_lock_held", value: .nullable(wakeLockHeld)),
            (key: "default_network", value: .string(defaultNetwork)),
            (key: "network_validated", value: .nullable(networkValidated)),
            (key: "network_metered", value: .nullable(networkMetered)),
            (key: "network_blocked", value: .nullable(networkBlocked)),
            (key: "network_changes", value: .int(networkChanges)),
            (key: "light_idle", value: .nullable(lightIdle)),
            (key: "low_power_standby_enabled", value: .nullable(lowPowerStandby)),
            (key: "low_power_standby_exempt", value: .nullable(lowPowerStandbyExempt)),
            (key: "network_observer_registered", value: .bool(networkObserverRegistered)),
            (key: "foreground_service", value: .string(foregroundService)),
        ])
    }

    /// Copy text with the iOS substitutions of (Android `K:SessionEvidence.kt:59-63`); the default-network line and its
    /// disclaimer stay verbatim.
    public func text() -> String {
        func flag(_ value: Bool?) -> String { value.map { String($0) } ?? "unknown" }
        let background = backgroundAudioActive.map { $0 ? "active" : "inactive" } ?? "unknown"
        var lines: [String] = []
        lines.append("iOS power: Low Power Mode=\(flag(batterySaver)) · Background audio: \(background)")
        lines.append("Microphone permission: \(flag(microphonePermission))")
        lines.append(
            "Default network: \(defaultNetwork) · Blocked: \(flag(networkBlocked)) · Changes: \(networkChanges) · Observer registered: \(networkObserverRegistered)"
        )
        lines.append(
            "Default-network state is not proof of the WebRTC media route; internet validation is not required for LAN audio."
        )
        return lines.joined(separator: "\n")
    }
}

/// Latest peer/ICE/host labels plus runtime (`K:SessionEvidence.kt:66-70`).
public struct ConnectionSnapshot: Sendable, Equatable {
    public let peer: String
    public let ice: String
    public let host: String
    public let runtime: RuntimeSnapshot?

    public init(peer: String, ice: String, host: String, runtime: RuntimeSnapshot?) {
        self.peer = peer
        self.ice = ice
        self.host = host
        self.runtime = runtime
    }

    /// `{"peer","ice","host","runtime": object|null}`.
    public func json() -> DiagnosticJSON {
        .object([
            (key: "peer", value: .string(peer)),
            (key: "ice", value: .string(ice)),
            (key: "host", value: .string(host)),
            (key: "runtime", value: runtime?.json() ?? .null),
        ])
    }

    /// `Connection: peer=… · ICE=… · Windows=…` plus the runtime text (iOS fallback line).
    public func text() -> String {
        "Connection: peer=\(peer) · ICE=\(ice) · Windows=\(host)\n"
            + (runtime?.text() ?? "iOS power/network state: unavailable")
    }
}

/// Thread-safe bounded evidence tail shared by delegate callbacks and the worker (`K:SessionEvidence.kt:87-119`).
/// Synchronous (no `async`); callable from any thread.
public final class SessionEvidence: @unchecked Sendable {
    /// Ring-buffer capacity.
    public static let capacity = 24
    /// Saturation bound of the observation total (2^53 - 1).
    public static let maxTotal: Int64 = 9_007_199_254_740_991
    /// Runtime flags observed by `connection(runtime:uptimeMs:)`, in Android order (`K:SessionEvidence.kt:104-110`).
    public static let runtimeFlagOrder: [EvidenceKind] = [
        .screen, .idle, .batterySaver, .batteryExempt, .microphonePermission, .wakeLock,
        .networkValidated, .networkMetered, .lightIdle, .lowPowerStandby, .lowPowerExempt,
    ]

    private let lock = NSLock()
    private var values: [EvidenceKind: String] = [:]
    private var events: [EvidenceEvent] = []
    private var total: Int64 = 0

    public init() {}

    /// Records a change. Duplicates of the current value are not events; receipt times are kept monotonic.
    public func observe(_ kind: EvidenceKind, _ value: String, uptimeMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        observeLocked(kind, value, uptimeMs)
    }

    /// Observes the 11 runtime flags then `foreground_service` (events from a first all-unknown snapshot) and returns
    /// the latest labels (`peer` default `connecting`, `ice` `new`, `host` `unavailable`).
    public func connection(runtime: RuntimeSnapshot?, uptimeMs: Int64) -> ConnectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if let runtime {
            let flags: [Bool?] = [
                runtime.screenOn, runtime.deviceIdle, runtime.batterySaver, runtime.batteryExempt,
                runtime.microphonePermission, runtime.wakeLockHeld, runtime.networkValidated, runtime.networkMetered,
                runtime.lightIdle, runtime.lowPowerStandby, runtime.lowPowerStandbyExempt,
            ]
            for (kind, flag) in zip(Self.runtimeFlagOrder, flags) {
                observeLocked(kind, EvidenceKind.flagValue(flag), uptimeMs)
            }
            observeLocked(.foregroundService, runtime.foregroundService, uptimeMs)
        }
        return ConnectionSnapshot(
            peer: values[.peer] ?? "connecting", ice: values[.ice] ?? "new",
            host: values[.host] ?? "unavailable", runtime: runtime)
    }

    /// Owned copy of the events at or before `uptimeMs`.
    public func tail(uptimeMs: Int64) -> [EvidenceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return tailLocked(uptimeMs)
    }

    /// Observations not present in `tail(uptimeMs:)`.
    public func omitted(uptimeMs: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(0, total - Int64(tailLocked(uptimeMs).count))
    }

    /// Latest value of `kind`, if observed.
    public func value(_ kind: EvidenceKind) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[kind]
    }

    private func observeLocked(_ kind: EvidenceKind, _ value: String, _ uptimeMs: Int64) {
        if values[kind] == value { return }
        values[kind] = value
        if events.count == Self.capacity { events.removeFirst() }
        // Callback scheduling can reorder observations; keep a monotonic phone timeline.
        events.append(EvidenceEvent(uptimeMs: max(uptimeMs, events.last?.uptimeMs ?? 0), kind: kind, value: value))
        total = min(total + 1, Self.maxTotal)
    }

    private func tailLocked(_ uptimeMs: Int64) -> [EvidenceEvent] {
        events.filter { $0.uptimeMs <= uptimeMs }
    }
}

/// First failure of a session (`K:SessionEvidence.kt:121-122`, `K:StreamReceiver.kt:338-347`).
public struct FailureEvidence: Sendable, Equatable {
    public let code: SessionFailure
    public let stage: ConnectionStage
    public let uptimeMs: Int64
    /// First `HTTPFailure.status` in the error chain, if any.
    public let httpStatus: Int?

    public init(code: SessionFailure, stage: ConnectionStage, uptimeMs: Int64, httpStatus: Int? = nil) {
        self.code = code
        self.stage = stage
        self.uptimeMs = uptimeMs
        self.httpStatus = httpStatus
    }
}

/// Immutable terminal evidence attached to `POST /stop` (`K:SessionEvidence.kt:124-142`). Captured once in the worker's
/// teardown before any native teardown; later callbacks cannot change it.
public struct TerminalEvidence: Sendable, Equatable {
    public let capturedAt: String
    public let uptimeMs: Int64
    public let code: SessionFailure
    public let stage: ConnectionStage
    public let failureUptimeMs: Int64?
    public let connection: ConnectionSnapshot
    public let events: [EvidenceEvent]
    public let omittedEvents: Int64
    public let httpStatus: Int?
    /// Media-output sessions with `output_control` negotiated; phase `stopped` (core-output type).
    public let outputControl: OutputControlSnapshot?
    /// Frozen initial gathering (core-ice type); serialized only with `includeIceGathering`.
    public let iceGathering: IceGatheringSnapshot?

    public init(
        capturedAt: String, uptimeMs: Int64, code: SessionFailure, stage: ConnectionStage,
        failureUptimeMs: Int64?, connection: ConnectionSnapshot, events: [EvidenceEvent],
        omittedEvents: Int64, httpStatus: Int? = nil, outputControl: OutputControlSnapshot? = nil,
        iceGathering: IceGatheringSnapshot? = nil
    ) {
        self.capturedAt = capturedAt
        self.uptimeMs = uptimeMs
        self.code = code
        self.stage = stage
        self.failureUptimeMs = failureUptimeMs
        self.connection = connection
        self.events = events
        self.omittedEvents = omittedEvents
        self.httpStatus = httpStatus
        self.outputControl = outputControl
        self.iceGathering = iceGathering
    }

    /// Capture rule of (`K:StreamReceiver.kt:783-794`): observe the final runtime flags, then take the uptime; code
    /// `none` unless `failed` (then the stamp's code or `session_exception`); stage from the stamp or `currentStage`;
    /// failure uptime only when `failed` (stamp's or now); HTTP status from the stamp.
    public static func capture(
        failed: Bool, stamp: FailureEvidence?, currentStage: ConnectionStage,
        evidence: SessionEvidence, runtime: RuntimeSnapshot?, clock: any MonotonicClock,
        now: Date, outputControl: OutputControlSnapshot?,
        iceGathering: IceGatheringSnapshot?
    ) -> TerminalEvidence {
        let connection = evidence.connection(runtime: runtime, uptimeMs: clock.nowMs())
        let uptime = clock.nowMs()
        let code: SessionFailure = failed ? (stamp?.code ?? .sessionException) : .none
        let failureUptime: Int64? = failed ? (stamp?.uptimeMs ?? uptime) : nil
        return TerminalEvidence(
            capturedAt: DiagnosticTime.rfc3339(now), uptimeMs: uptime, code: code,
            stage: stamp?.stage ?? currentStage, failureUptimeMs: failureUptime,
            connection: connection, events: evidence.tail(uptimeMs: uptime),
            omittedEvents: evidence.omitted(uptimeMs: uptime), httpStatus: stamp?.httpStatus,
            outputControl: outputControl, iceGathering: iceGathering)
    }

    /// `diagnostics` object of `/stop` (`K:SessionEvidence.kt:128-135`). `output_control` only when present;
    /// `ice_gathering` only when `includeIceGathering` and present. Throws `DiagnosticJSON.EncodingFailure`
    /// (never with the current composition; the signature is kept for pass-2 pre-send validation).
    public func json(includeIceGathering: Bool) throws -> DiagnosticJSON {
        var members: [(key: String, value: DiagnosticJSON)] = [
            (key: "version", value: .int(1)),
            (key: "captured_at", value: .string(capturedAt)),
            (key: "uptime_ms", value: .int(uptimeMs)),
            (key: "code", value: .string(code.rawValue)),
            (key: "stage", value: .string(stage.rawValue)),
            (key: "failure_uptime_ms", value: .nullable(failureUptimeMs)),
            (key: "connection", value: connection.json()),
            (key: "events", value: .array(events.map { $0.json() })),
            (key: "omitted_events", value: .int(omittedEvents)),
            (key: "http_status", value: .nullable(httpStatus)),
        ]
        if let outputControl {
            members.append((key: "output_control", value: outputControl.json()))
        }
        if includeIceGathering, let iceGathering {
            members.append((key: "ice_gathering", value: iceGathering.json()))
        }
        return .object(members)
    }

    /// Copy text (`K:SessionEvidence.kt:137-141`). The gathering text is printed whenever the snapshot
    /// exists, independent of `includeIceGathering`.
    public func text() -> String {
        var text =
            "Session terminal code: \(code.rawValue) · Stage: \(stage.rawValue) · Phone uptime: \(uptimeMs) ms · HTTP: "
        text += httpStatus.map { String($0) } ?? "unavailable"
        text += "\nFailure observed at: "
        text += failureUptimeMs.map { "\($0) ms" } ?? "no failure"
        text += "\n" + connection.text()
        text += "\nRecent changes (phone uptime; \(omittedEvents) earlier observations omitted):\n"
        text += events.map { "\($0.uptimeMs) ms · \($0.kind.rawValue)=\($0.value)" }.joined(separator: "\n")
        if let iceGathering {
            // core-ice `IceGatheringSnapshot.text()` ("Initial iPhone ICE gathering: …").
            text += "\n" + iceGathering.text()
        }
        return text
    }
}
