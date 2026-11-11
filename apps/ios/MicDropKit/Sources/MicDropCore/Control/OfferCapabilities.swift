import Foundation

/// The parsed `/offer` 200 reply and every capability flag derived from it (`A/StreamReceiver.kt:372-396`). The single
/// capability parser: `DiagnosticsCapabilities` is a projection of it, 05 reads the trickle/continuous/gathering
/// versions, 08 reads `includeMicrophoneProcessing`, 04/02 use `confirms(_:)`.
///
/// `init` validates only what Android validates **before** it stores the session token (`version` == link version,
/// 43-char `session`), so a mode mismatch or an oversized SDP is detected afterwards and cleanup still sends `/stop`
/// with the new token ("Order after a 200"). Optional ints use org.json `optInt` (missing/non-numeric → 0).
public struct OfferCapabilities: Sendable, Equatable {
    /// SDP bound in UTF-16 code units (Kotlin `String.length`, `:391`).
    public static let maxSDPLength = 65_536

    /// Link protocol version the session was started with (1, 2 or 3).
    public let invitationVersion: Int
    /// `version` (required, equals `invitationVersion`).
    public let version: Int
    /// `session`: the fresh 43-char session bearer (required, `^[A-Za-z0-9_-]{43}$`).
    public let session: String
    /// `sdp` when it is a JSON string; validate with `validatedSDP()` after the mode check.
    public let sdp: String?
    /// `session_lifecycle_version`, default 1 (`StopReason.wire(forLifecycleVersion:)`).
    public let lifecycleVersion: Int
    /// `ice_restart_version`.
    public let iceRestartVersion: Int
    /// `diagnostics_version` (`ReportDelivery`).
    public let diagnosticsVersion: Int
    public let outputDiagnosticsVersion: Int
    public let connectionDiagnosticsVersion: Int
    public let outputControlDiagnosticsVersion: Int
    /// `ice_gathering_diagnostics_version` (2, or 3 with trickle/continuous; 0 without a log unless phone control
    /// was negotiated).
    public let iceGatheringDiagnosticsVersion: Int
    public let mediaTransportDiagnosticsVersion: Int
    public let routeSelectionDiagnosticsVersion: Int
    /// `tls_certificate_diagnostics_version` (1 only with an active combined log or when phone control was
    /// negotiated, `server.go:169-198`).
    public let tlsCertificateDiagnosticsVersion: Int
    /// `phone_control_version` (`server.go:202`): 1 when the host accepted `X-MicDrop-Phone-Control: 1`. A
    /// negotiating host also advertises every diagnostics version without a log (`server.go:169-172`).
    public let phoneControlVersion: Int
    /// `trickle_ice_version`.
    public let trickleICEVersion: Int
    /// `continuous_ice_version`.
    public let continuousICEVersion: Int
    /// `audio_direction` (`""` for legacy hosts).
    public let audioDirection: String
    public let microphoneReturnVersion: Int
    public let duplexVersion: Int
    /// `microphone_processing_version`.
    public let microphoneProcessingVersion: Int
    /// `environment_platform_version` (0 on current hosts).
    public let environmentPlatformVersion: Int
    /// The whole reply, for consumers that need another lenient field.
    public let json: ControlJSON

    /// Throws `ControlResponseError(.invalidReply)` when `version` is missing or differs from
    /// `invitationVersion`, or `session` is missing or not a 43-char base64url credential.
    public init(_ json: ControlJSON, invitationVersion: Int) throws {
        let version = try json.requireInt("version")
        guard version == invitationVersion else { throw ControlResponseError(.invalidReply) }
        let session = try json.requireString("session")
        guard ControlRequest.credentialIsValid(session) else { throw ControlResponseError(.invalidReply) }
        self.invitationVersion = invitationVersion
        self.version = version
        self.session = session
        self.sdp = json["sdp"]?.text
        lifecycleVersion = json.int("session_lifecycle_version", default: 1)
        iceRestartVersion = json.int("ice_restart_version")
        diagnosticsVersion = json.int("diagnostics_version")
        outputDiagnosticsVersion = json.int("output_diagnostics_version")
        connectionDiagnosticsVersion = json.int("connection_diagnostics_version")
        outputControlDiagnosticsVersion = json.int("output_control_diagnostics_version")
        iceGatheringDiagnosticsVersion = json.int("ice_gathering_diagnostics_version")
        mediaTransportDiagnosticsVersion = json.int("media_transport_diagnostics_version")
        routeSelectionDiagnosticsVersion = json.int("route_selection_diagnostics_version")
        tlsCertificateDiagnosticsVersion = json.int("tls_certificate_diagnostics_version")
        phoneControlVersion = json.int("phone_control_version")
        trickleICEVersion = json.int("trickle_ice_version")
        continuousICEVersion = json.int("continuous_ice_version")
        audioDirection = json.string("audio_direction")
        microphoneReturnVersion = json.int("microphone_return_version")
        duplexVersion = json.int("duplex_version")
        microphoneProcessingVersion = json.int("microphone_processing_version")
        environmentPlatformVersion = json.int("environment_platform_version")
        self.json = json
    }

    // MARK: Derived flags (`A/StreamReceiver.kt:373-393`)

    /// `LanRecovery(supported:)` = v3 and `ice_restart_version == 1` (`:374`).
    public var iceRestartSupported: Bool { invitationVersion == 3 && iceRestartVersion == 1 }
    /// Periodic reports enabled (`ReportDelivery(diagnostics_version)`, `:375`).
    public var reportsEnabled: Bool { diagnosticsVersion == 1 }
    /// Add `output`, `recovery`, `local_output_baseline` to reports (`:376`).
    public var includeOutput: Bool { outputDiagnosticsVersion == 1 }
    /// `connection` in reports and `diagnostics` in `/stop` (`:377`).
    public var includeConnection: Bool { connectionDiagnosticsVersion == 1 }
    /// `output_control` in reports/terminal (`:378`).
    public var includeOutputControl: Bool { outputControlDiagnosticsVersion == 1 }
    /// Candidate for `ice_gathering`: version in 1…3 (`:379-380`).
    public var includeIceGathering: Bool { (1...3).contains(iceGatheringDiagnosticsVersion) }
    public var includeMediaTransport: Bool { mediaTransportDiagnosticsVersion == 1 }
    public var includeRouteSelection: Bool { routeSelectionDiagnosticsVersion == 1 }
    /// `tls_certificate_verification` in reports (`:408`); the host answers 400 when it is sent unadvertised.
    public var includeTlsVerification: Bool { tlsCertificateDiagnosticsVersion == 1 }
    /// `microphone.processing` in microphone reports (`:717`).
    public var includeMicrophoneProcessing: Bool { microphoneProcessingVersion == 1 }
    /// Non-null `environment` only when the host advertises platform environment v1.
    public var platformEnvironment: Bool { environmentPlatformVersion == 1 }
    /// Phone settings exchange v1 for this session: a v3 link and `phone_control_version == 1`
    /// (`A/StreamReceiver.kt:397`, which also requires the controller's binding). Session-scoped; never persisted.
    public var phoneControlNegotiated: Bool { invitationVersion == 3 && phoneControlVersion == 1 }

    // MARK: spellings (used by 03 `DiagnosticsCapabilities.init(_:)`)

    /// `diagnostics_version`.
    public var diagnostics: Int { diagnosticsVersion }
    /// = `includeOutput`.
    public var output: Bool { includeOutput }
    /// = `includeConnection`.
    public var connection: Bool { includeConnection }
    /// = `includeOutputControl`.
    public var outputControl: Bool { includeOutputControl }
    /// `ice_gathering_diagnostics_version`.
    public var iceGathering: Int { iceGatheringDiagnosticsVersion }
    /// = `includeMediaTransport`.
    public var mediaTransport: Bool { includeMediaTransport }
    /// = `includeRouteSelection`.
    public var routeSelection: Bool { includeRouteSelection }
    /// = `includeMicrophoneProcessing`.
    public var microphoneProcessing: Bool { includeMicrophoneProcessing }
    /// = `includeTlsVerification`.
    public var tlsVerification: Bool { includeTlsVerification }
    /// `session_lifecycle_version`.
    public var lifecycle: Int { lifecycleVersion }
    /// = `iceRestartSupported`.
    public var iceRestart: Bool { iceRestartSupported }

    /// `useTrickle = remote && v == 3 && trickle_ice_version == 1` (`:392`).
    public func useTrickle(remote: Bool) -> Bool {
        remote && invitationVersion == 3 && trickleICEVersion == 1
    }

    /// `continuousEnabled = useTrickle && continuous_ice_version == 1` (`:393`).
    public func useContinuous(remote: Bool) -> Bool {
        useTrickle(remote: remote) && continuousICEVersion == 1
    }

    /// Mode confirmation (`A/StreamMode.kt:39-43`); failure → `StreamMode.modeNotConfirmedMessage`,
    /// `.modeNotConfirmed`.
    public func confirms(_ mode: StreamMode) -> Bool {
        mode.acceptsOffer(
            microphoneVersion: microphoneReturnVersion, duplexVersion: duplexVersion,
            direction: audioDirection)
    }

    /// `offer.getString("sdp")` + `require(length <= 65536)` (`:391`), checked after the mode check.
    public func validatedSDP() throws -> String {
        guard let sdp, sdp.utf16.count <= OfferCapabilities.maxSDPLength else {
            throw ControlResponseError(.invalidReply)
        }
        return sdp
    }

    /// `ReportDelivery(offer.optInt("diagnostics_version", 0))`.
    public func makeReportDelivery() -> ReportDelivery {
        ReportDelivery(version: diagnosticsVersion)
    }
}
