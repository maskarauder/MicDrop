import Foundation

/// `output_control` diagnostics object, version 1 (`OutputControlSnapshot.kt:3-12`, built at
/// `StreamReceiver.kt:1169-1176`; Go `internal/diagnostics/output_control.go:5-26`).
///
/// "Immutable, bounded summary. No device ID/name/address or system route ID." iOS values: `default_matches: null` (no
/// prediction API), `system_route_known: false`, `transfers: 0`, `transfer_result: "none"`, `nearby_permission: null`.
/// All 11 keys are always present in Kotlin key order; nil encodes as JSON `null` (never omitted). Included (periodic
/// and terminal) only when the session uses media output and the host advertised `output_control_diagnostics_version ==
/// 1`; the terminal copy is taken after `closed = true`, so its phase is `stopped`.
public struct OutputControlSnapshot: Equatable, Sendable {
    /// Wire keys in emission order (`OutputControlSnapshot.kt:7-11`).
    public static let keys = [
        "version", "selection", "requested_enabled", "phase", "pause", "default_matches",
        "system_route_known", "transfers", "transfer_result", "playout_recreations",
        "nearby_permission",
    ]

    /// `output_control.phase` (Go: `verifying|restoring|waiting|verified|stopped`).
    public enum Phase: String, CaseIterable, Sendable {
        case verifying, restoring, waiting, verified, stopped

        /// closed -> stopped; recovering -> restoring; pending -> verifying; default policy held ->
        /// waiting; else verified (`StreamReceiver.kt:1171-1172`).
        public static func of(closed: Bool, recovering: Bool, pending: Bool, defaultHeld: Bool) -> Phase {
            if closed { return .stopped }
            if recovering { return .restoring }
            if pending { return .verifying }
            if defaultHeld { return .waiting }
            return .verified
        }
    }

    /// Always 1.
    public var version: Int { 1 }
    /// `OutputKind` wire label of the current selection (temporary speaker -> `phone`; never
    /// `hearing_aid` on iOS).
    public let selection: String
    /// `AudioOutputGate.enabled` (the user's request, not effective audibility).
    public let requestedEnabled: Bool
    public let phase: String
    /// `OutputPause` wire label or `none`.
    public let pause: String
    /// Must be nil unless `selection == "default"`; always nil on iOS.
    public let defaultMatches: Bool?
    /// Non-nullable on the host (`SystemRouteKnown bool`); always false on iOS.
    public let systemRouteKnown: Bool
    /// 0...1_000_000; always 0 on iOS (no transfer API).
    public let transfers: Int
    /// `none|requested|rejected`; always `none` on iOS.
    public let transferResult: String
    /// Count of `restartPlayout()` calls actually made; 0...1_000_000.
    public let playoutRecreations: Int
    /// Always nil on iOS (no Nearby-devices permission).
    public let nearbyPermission: Bool?

    /// Memberwise; the Android-only fields default to the iOS values.
    public init(
        selection: String, requestedEnabled: Bool, phase: String, pause: String,
        defaultMatches: Bool? = nil, systemRouteKnown: Bool = false, transfers: Int = 0,
        transferResult: String = "none", playoutRecreations: Int, nearbyPermission: Bool? = nil
    ) {
        self.selection = selection
        self.requestedEnabled = requestedEnabled
        self.phase = phase
        self.pause = pause
        self.defaultMatches = defaultMatches
        self.systemRouteKnown = systemRouteKnown
        self.transfers = transfers
        self.transferResult = transferResult
        self.playoutRecreations = playoutRecreations
        self.nearbyPermission = nearbyPermission
    }

    /// Host bound of `transfers` and `playout_recreations` (`output_control.go:24`).
    public static let countLimit = 1_000_000

    /// iOS snapshot from typed state (fixed constants for Android-only fields). `playoutRecreations` is clamped to
    /// `0...countLimit`: a value outside the host bound would make the whole report invalid (a 400, session-fatal while
    /// the same `/status` POST carries ICE). Android never reaches the bound (2 recreations per route episode), so the
    /// clamp changes no reachable value.
    public init(
        selection: OutputKind, requestedEnabled: Bool, phase: Phase, pause: OutputPause?,
        playoutRecreations: Int
    ) {
        self.init(
            selection: selection.wireLabel, requestedEnabled: requestedEnabled, phase: phase.rawValue,
            pause: OutputPause.wire(pause),
            playoutRecreations: min(max(playoutRecreations, 0), OutputControlSnapshot.countLimit))
    }

    /// Go `OutputControl.valid()` (`internal/diagnostics/output_control.go:19-26`): the periodic and the
    /// terminal report are rejected unless this holds.
    public var hostValid: Bool {
        let selections = ["default", "phone", "wired", "usb", "bluetooth", "le", "hearing_aid", "other"]
        let phases = ["verifying", "restoring", "waiting", "verified", "stopped"]
        let pauses = ["none", "route", "bluetooth", "unavailable", "selected_bluetooth", "focus", "focus_manual"]
        let limit = OutputControlSnapshot.countLimit
        return version == 1 && selections.contains(selection) && phases.contains(phase)
            && pauses.contains(pause) && ["none", "requested", "rejected"].contains(transferResult)
            && (0...limit).contains(transfers) && (0...limit).contains(playoutRecreations)
            && (selection == "default" || defaultMatches == nil)
    }

    /// Ordered wire object (11 keys, explicit nulls).
    public func json() -> DiagnosticJSON {
        .object([
            (key: "version", value: .int(Int64(version))),
            (key: "selection", value: .string(selection)),
            (key: "requested_enabled", value: .bool(requestedEnabled)),
            (key: "phase", value: .string(phase)),
            (key: "pause", value: .string(pause)),
            (key: "default_matches", value: defaultMatches.map { DiagnosticJSON.bool($0) } ?? .null),
            (key: "system_route_known", value: .bool(systemRouteKnown)),
            (key: "transfers", value: .int(Int64(transfers))),
            (key: "transfer_result", value: .string(transferResult)),
            (key: "playout_recreations", value: .int(Int64(playoutRecreations))),
            (key: "nearby_permission", value: nearbyPermission.map { DiagnosticJSON.bool($0) } ?? .null),
        ])
    }
}

/// Manual encoding so nil fields are written as `null` (synthesized `encodeIfPresent` would omit them; encoding note).
/// Key order matches `keys`.
extension OutputControlSnapshot: Encodable {
    private enum CodingKeys: String, CodingKey {
        case version
        case selection
        case requestedEnabled = "requested_enabled"
        case phase
        case pause
        case defaultMatches = "default_matches"
        case systemRouteKnown = "system_route_known"
        case transfers
        case transferResult = "transfer_result"
        case playoutRecreations = "playout_recreations"
        case nearbyPermission = "nearby_permission"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(selection, forKey: .selection)
        try container.encode(requestedEnabled, forKey: .requestedEnabled)
        try container.encode(phase, forKey: .phase)
        try container.encode(pause, forKey: .pause)
        if let defaultMatches {
            try container.encode(defaultMatches, forKey: .defaultMatches)
        } else {
            try container.encodeNil(forKey: .defaultMatches)
        }
        try container.encode(systemRouteKnown, forKey: .systemRouteKnown)
        try container.encode(transfers, forKey: .transfers)
        try container.encode(transferResult, forKey: .transferResult)
        try container.encode(playoutRecreations, forKey: .playoutRecreations)
        if let nearbyPermission {
            try container.encode(nearbyPermission, forKey: .nearbyPermission)
        } else {
            try container.encodeNil(forKey: .nearbyPermission)
        }
    }
}
