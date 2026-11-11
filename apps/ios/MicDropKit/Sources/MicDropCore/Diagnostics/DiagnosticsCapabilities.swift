import Foundation

/// Diagnostics extensions negotiated by the `POST /offer` response.
///
/// A projection of `OfferCapabilities`: there is exactly one offer parser (lenient Android `optInt` semantics live
/// there); this type only names the diagnostics-relevant flags.
public struct DiagnosticsCapabilities: Sendable, Equatable {
    /// `diagnostics_version`; periodic uploads only when `== 1` (`K:StreamReceiver.kt:375`).
    /// `ReportDelivery(version:)` (core-control) is constructed from this raw value.
    public let diagnosticsVersion: Int
    /// `output_diagnostics_version == 1`: add `output`, `recovery`, `local_output_baseline`.
    public let output: Bool
    /// `connection_diagnostics_version == 1`: periodic `connection` and terminal `/stop` `diagnostics`.
    public let connection: Bool
    /// `output_control_diagnostics_version == 1` (media-output sessions only).
    public let outputControl: Bool
    /// `ice_gathering_diagnostics_version` raw value (0...3).
    public let iceGatheringVersion: Int
    /// `media_transport_diagnostics_version == 1`.
    public let mediaTransport: Bool
    /// `route_selection_diagnostics_version == 1`.
    public let routeSelection: Bool
    /// `microphone_processing_version == 1`: add `microphone.processing` (`K:StreamReceiver.kt:717`).
    public let microphoneProcessing: Bool
    /// `environment_platform_version == 1`. Absent today, so `environment` stays `null`.
    public let platformEnvironment: Bool
    /// `tls_certificate_diagnostics_version == 1`: add `tls_certificate_verification` (`K:StreamReceiver.kt:408`).
    public let tlsVerification: Bool

    public init(
        diagnosticsVersion: Int, output: Bool, connection: Bool, outputControl: Bool,
        iceGatheringVersion: Int, mediaTransport: Bool, routeSelection: Bool,
        microphoneProcessing: Bool, platformEnvironment: Bool, tlsVerification: Bool = false
    ) {
        self.diagnosticsVersion = diagnosticsVersion
        self.output = output
        self.connection = connection
        self.outputControl = outputControl
        self.iceGatheringVersion = iceGatheringVersion
        self.mediaTransport = mediaTransport
        self.routeSelection = routeSelection
        self.microphoneProcessing = microphoneProcessing
        self.platformEnvironment = platformEnvironment
        self.tlsVerification = tlsVerification
    }

    /// Projection of the single offer parser. ASSUMES `OfferCapabilities` members: `diagnostics: Int`, `output: Bool`,
    /// `connection: Bool`, `outputControl: Bool`, `iceGathering: Int`, `mediaTransport: Bool`, `routeSelection: Bool`,
    /// `microphoneProcessing: Bool`, `environmentPlatformVersion: Int`, `tlsVerification: Bool`.
    public init(_ offer: OfferCapabilities) {
        self.init(
            diagnosticsVersion: offer.diagnostics,
            output: offer.output,
            connection: offer.connection,
            outputControl: offer.outputControl,
            iceGatheringVersion: offer.iceGathering,
            mediaTransport: offer.mediaTransport,
            routeSelection: offer.routeSelection,
            microphoneProcessing: offer.microphoneProcessing,
            platformEnvironment: offer.environmentPlatformVersion == 1,
            tlsVerification: offer.tlsVerification)
    }

    /// Nothing negotiated (old host, or no active combined log and no phone-control negotiation).
    public static let notNegotiated = DiagnosticsCapabilities(
        diagnosticsVersion: 0, output: false,
        connection: false, outputControl: false,
        iceGatheringVersion: 0, mediaTransport: false,
        routeSelection: false, microphoneProcessing: false,
        platformEnvironment: false, tlsVerification: false)

    /// Periodic `POST /status` uploads are enabled (`ReportDelivery.enabled` initial value).
    public var periodic: Bool { diagnosticsVersion == 1 }

    /// `includeIceGathering` right after the offer: `(1...3).contains(version)`. After the initial gathering finishes
    /// the worker narrows it with `IceGatheringSnapshot.canReport(to:)`.
    public var iceGatheringOffered: Bool { (1...3).contains(iceGatheringVersion) }

    /// Terminal `/stop` `diagnostics` may be attached (`includeConnection`).
    public var terminalDiagnostics: Bool { connection }
}
