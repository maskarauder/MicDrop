import Foundation

/// The typed periodic snapshot sent under the legacy key `"android"` of `POST /status` (`K:PlaybackReport.kt:23-61`).
/// Built once per stats cycle by the session worker and kept as an immutable value in the single pending slot; a retry
/// re-encodes the same value.
///
/// iOS rules: `environment` is `null` unless platform environment v1 was negotiated; with `includeOutput`, `output` and
/// `local_output_baseline` are always `null` and `recovery` is an object for playback modes or `null`; `connection` is
/// present (possibly `null`) iff `includeConnection`.
public struct PlaybackReport: Sendable, Equatable {
    /// `media_output` labels (`report.go:127`).
    public static let mediaOutputRunning = "running"
    public static let mediaOutputWaiting = "waiting"
    /// `state` labels (`report.go:126`); initial value `Connecting` (`K:StreamReceiver.kt:154`).
    public static let stateLabels: Set<String> = ["Connecting", "New", "Connected", "Disconnected", "Failed", "Closed"]

    /// 1 ... 2^53-1, starts at 1 per session and increments for every built report.
    public let sequence: Int64
    /// RFC 3339 UTC (`DiagnosticTime`).
    public let capturedAt: String
    /// `MonotonicClock.nowMs()` taken after the recovery/microphone/connection snapshots.
    public let uptimeMs: Int64
    public let environment: EnvironmentSnapshot?
    /// Report peer state label (`stateLabel(peer:)`).
    public let state: String
    /// `running` or `waiting`.
    public let mediaOutput: String
    public let snapshot: PlaybackSnapshot
    /// Playback modes only (core-output `RecoverySnapshot.json()`).
    public let recovery: RecoverySnapshot?
    /// Present iff microphone return was negotiated (core-mic `MicrophoneSnapshot.json()`).
    public let microphone: MicrophoneSnapshot?
    /// Added as `microphone.processing` (via `MicrophoneSnapshot.with(processing:)`) when
    /// `microphone_processing_version == 1`; already `effective(mode:input:)`. `nil` keeps the snapshot's own.
    public let microphoneProcessing: MicrophoneProcessing?
    public let mode: StreamMode
    public let connection: ConnectionSnapshot?
    /// Pre-encoded `lan_recovery` object `{"phase","restarts","signaling_route"}` (core-ice
    /// `LanRecovery.fields(route:)`, as `DiagnosticJSON` via its `json()` or `DiagnosticJSON(encoding:)`);
    /// `nil` unless `ice_restart_version == 1`. Pre-encoded so the report does not depend on that wire type.
    public let lanRecovery: DiagnosticJSON?
    /// Media-output sessions with `output_control` negotiated (core-output `OutputControlSnapshot.json()`).
    public let outputControl: OutputControlSnapshot?
    /// Frozen initial gathering when `includeIceGathering` (core-ice `IceGatheringSnapshot.json()`).
    public let iceGathering: IceGatheringSnapshot?
    /// When `media_transport` was negotiated (core-ice `MediaTransportSnapshot.json()`, `version` first).
    public let mediaTransport: MediaTransportSnapshot?
    /// When `route_selection` was negotiated (core-ice `RouteSelectionSnapshot.json()`).
    public let routeSelection: RouteSelectionSnapshot?
    /// The cycle's TURN/TLS trust counters when `tls_certificate_diagnostics_version == 1` (core-ice
    /// `TurnTLSTrustSnapshot.json()`, `K:PlaybackReport.kt:37,57`). Stored here, so a retry re-encodes the same
    /// counters. `nil` otherwise: the host rejects an unadvertised member (`G:internal/session/server.go:295-299`).
    public let tlsVerification: TurnTLSTrustSnapshot?

    public init(
        sequence: Int64, capturedAt: String, uptimeMs: Int64, environment: EnvironmentSnapshot?,
        state: String, mediaOutput: String, snapshot: PlaybackSnapshot, recovery: RecoverySnapshot?,
        microphone: MicrophoneSnapshot?, microphoneProcessing: MicrophoneProcessing?, mode: StreamMode,
        connection: ConnectionSnapshot?, lanRecovery: DiagnosticJSON?, outputControl: OutputControlSnapshot?,
        iceGathering: IceGatheringSnapshot?, mediaTransport: MediaTransportSnapshot?,
        routeSelection: RouteSelectionSnapshot?, tlsVerification: TurnTLSTrustSnapshot? = nil
    ) {
        self.sequence = sequence
        self.capturedAt = capturedAt
        self.uptimeMs = uptimeMs
        self.environment = environment
        self.state = state
        self.mediaOutput = mediaOutput
        self.snapshot = snapshot
        self.recovery = recovery
        self.microphone = microphone
        self.microphoneProcessing = microphoneProcessing
        self.mode = mode
        self.connection = connection
        self.lanRecovery = lanRecovery
        self.outputControl = outputControl
        self.iceGathering = iceGathering
        self.mediaTransport = mediaTransport
        self.routeSelection = routeSelection
        self.tlsVerification = tlsVerification
    }

    /// Report `state` from a lowercase peer label (`new` → `New`, `K:StreamReceiver.kt:1729`).
    public static func stateLabel(peer: String) -> String {
        guard let first = peer.first else { return peer }
        return String(first).uppercased() + peer.dropFirst()
    }

    /// The `"android"` object (`K:PlaybackReport.kt:40-60`), Android key order. Throws `DiagnosticJSON.EncodingFailure`
    /// (the worker then calls `ReportDelivery.unavailable()`); the current composition never throws, the signature
    /// keeps Android's "construction can fail" path (step 2) for pass-2 pre-upload validation.
    public func json(includeOutput: Bool, includeConnection: Bool, platformEnvironment: Bool) throws -> DiagnosticJSON {
        var members: [(key: String, value: DiagnosticJSON)] = [
            (key: "sequence", value: .int(sequence)),
            (key: "captured_at", value: .string(capturedAt)),
            (key: "uptime_ms", value: .int(uptimeMs)),
            (key: "environment", value: platformEnvironment ? (environment?.json() ?? .null) : .null),
            (key: "state", value: .string(state)),
            (key: "media_output", value: .string(mediaOutput)),
            (key: "codec", value: .string(snapshot.codec)),
            (key: "path", value: .string(snapshot.path)),
            (key: "metrics", value: snapshot.metricsJSON()),
        ]
        if includeOutput {
            members.append((key: "output", value: .null))
            members.append((key: "recovery", value: recovery?.json() ?? .null))
            members.append((key: "local_output_baseline", value: .null))
        }
        if let microphone {
            // `processing` is nested inside `microphone` (`K:PlaybackReport.kt:49-51`).
            let withProcessing = microphoneProcessing.map { microphone.with(processing: $0) } ?? microphone
            members.append((key: "microphone", value: withProcessing.json()))
        }
        if let lanRecovery {
            members.append((key: "lan_recovery", value: lanRecovery))
        }
        if let outputControl {
            members.append((key: "output_control", value: outputControl.json()))
        }
        if let iceGathering {
            members.append((key: "ice_gathering", value: iceGathering.json()))
        }
        if let mediaTransport {
            members.append((key: "media_transport", value: mediaTransport.json()))
        }
        if let routeSelection {
            members.append((key: "route_selection", value: routeSelection.json()))
        }
        if let tlsVerification {
            members.append((key: "tls_certificate_verification", value: tlsVerification.json()))
        }
        // Duplex requires a host that confirmed duplex_version=1 (`K:PlaybackReport.kt:55-57`).
        if mode == .duplex {
            members.append((key: "audio_direction", value: .string(mode.direction)))
        }
        if includeConnection {
            members.append((key: "connection", value: connection?.json() ?? .null))
        }
        return .object(members)
    }

    /// Same as `json(includeOutput:includeConnection:platformEnvironment:)` with the negotiated flags.
    public func json(_ capabilities: DiagnosticsCapabilities) throws -> DiagnosticJSON {
        try json(
            includeOutput: capabilities.output, includeConnection: capabilities.connection,
            platformEnvironment: capabilities.platformEnvironment)
    }
}

/// `POST /status` body envelope (`K:StreamReceiver.kt:617-640`).
public enum StatusBody {
    /// Legacy wire key for the phone report; not a platform claim (`G:internal/session/server.go:257`).
    public static let reportKey = "android"
    /// The phone settings snapshot member (`G:server.go:292`, Go `phonecontrol.Snapshot`).
    public static let phoneControlKey = "phone_control"
    /// Client-side body size precondition of an unnegotiated session (`K:StreamReceiver.kt:1683`). Nothing consults
    /// it before sending: the request encoder enforces `ControlRequest.bodyBudget`, which is 163 840 bytes only for
    /// the `/status` of a session that negotiated phone control (`ControlRequest.bodyLimit(path:negotiated:)`).
    public static let maxBytes = 96 * 1024

    /// `{"version":v, "phone_control"?:…, "android"?:…, "ice"?:…, "continuous_ice"?:…}` in Android's member order
    /// (`K:StreamReceiver.kt:688-693`), or `nil` when only `version` would remain (the heartbeat is then a
    /// body-less `GET /status`). A settings snapshot alone is a POST (`G:server.go:302`). `phoneControl` is passed
    /// only in a session that negotiated phone control: other hosts answer the member with 400.
    public static func make(
        version: Int, phoneControl: DiagnosticJSON? = nil, report: DiagnosticJSON?, ice: DiagnosticJSON? = nil,
        continuousIce: DiagnosticJSON? = nil
    ) -> DiagnosticJSON? {
        guard phoneControl != nil || report != nil || ice != nil || continuousIce != nil else { return nil }
        var members: [(key: String, value: DiagnosticJSON)] = [(key: "version", value: .int(Int64(version)))]
        if let phoneControl { members.append((key: phoneControlKey, value: phoneControl)) }
        if let report { members.append((key: reportKey, value: report)) }
        if let ice { members.append((key: "ice", value: ice)) }
        if let continuousIce { members.append((key: "continuous_ice", value: continuousIce)) }
        return .object(members)
    }
}
