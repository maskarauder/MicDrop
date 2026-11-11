import Foundation

/// The `/status` 200 reply: the host `rtc.Status` fields plus extras (`internal/rtc/rtc.go:10-46`,
/// `internal/session/server.go:369-375`; table). Read leniently (org.json `opt*`); `ice` / `continuous_ice` are
/// required only when the request carried the matching update (`requireICE()` / `requireContinuousICE()`, Kotlin
/// `getJSONObject`).
public struct HostStatus: Sendable, Equatable {
    /// Windows peer states accepted as `host` evidence (`A/StreamReceiver.kt:663-665`).
    public static let peerStates: Set<String> = ["new", "connecting", "connected", "disconnected", "failed", "closed"]

    /// `state` (`new|connecting|connected|disconnected|failed|closed`), `""` when absent.
    public let state: String
    public let captureFailed: Bool
    public let bridgeFailed: Bool
    /// `ice_recovery_pending` (omitted when false).
    public let iceRecoveryPending: Bool
    /// `ice_generation_current`.
    public let iceGenerationCurrent: Bool
    /// `ice_restarts` (omitted when 0; diagnostics only).
    public let iceRestarts: Int
    /// `report_log` (`accepted|busy|not_recorded|full|unavailable|closed|disabled`). In a phone-control session the
    /// host acknowledges every report that was neither accepted nor busy as `not_recorded`: no log, or a log that is
    /// full, unavailable or closed (`server.go:410-414`). `full`, `unavailable` and `closed` acknowledge a report
    /// only in unnegotiated sessions. A GET or an ICE-only POST returns the log state instead (`disabled` on a host
    /// without a log), which is never an acknowledgment.
    public let reportLog: String
    /// `report_sequence`, −1 when absent.
    public let reportSequence: Int64
    /// `ice` trickle delta object, present only when an `ice` delta was sent.
    public let ice: ControlJSON?
    /// `continuous_ice` snapshot object, present only when one was sent.
    public let continuousICE: ControlJSON?
    /// `microphone_muted`, default **true** (`A/StreamReceiver.kt:730`).
    public let microphoneMuted: Bool
    /// `media_transport` object (`A/StreamReceiver.kt:755-758`).
    public let mediaTransport: ControlJSON?
    /// `bridge_frames_submitted` (`host.optLong(...)`, default 0; microphone diagnostics text,
    /// `A/StreamReceiver.kt:729`).
    public let bridgeFramesSubmitted: Int64
    /// The whole reply (numeric diagnostics fields are read through `number(_:)`).
    public let json: ControlJSON

    public init(_ json: ControlJSON) {
        state = json.string("state")
        captureFailed = json.bool("capture_failed")
        bridgeFailed = json.bool("bridge_failed")
        iceRecoveryPending = json.bool("ice_recovery_pending")
        iceGenerationCurrent = json.bool("ice_generation_current")
        iceRestarts = json.int("ice_restarts")
        reportLog = json.string("report_log")
        reportSequence = json.int64("report_sequence", default: -1)
        ice = json.object("ice")
        continuousICE = json.object("continuous_ice")
        microphoneMuted = json.bool("microphone_muted", default: true)
        mediaTransport = json.object("media_transport")
        bridgeFramesSubmitted = json.int64("bridge_frames_submitted", default: 0)
        self.json = json
    }

    /// Evidence value `HOST = state` if it is one of the six labels, else `unavailable` (step 5).
    public var evidenceState: String {
        HostStatus.peerStates.contains(state) ? state : "unavailable"
    }

    /// Terminal check (step 6): `capture_failed || bridge_failed || state == "closed" || (state == "failed" &&
    /// !restartSupported)` → `HOST_AUDIO_STOPPED`.
    public func isTerminal(restartSupported: Bool) -> Bool {
        captureFailed || bridgeFailed || state == "closed" || (state == "failed" && !restartSupported)
    }

    /// Health (step 7): `localPeerState == "Connected" && iceConnected && state == "connected" && !ice_recovery_pending
    /// && (!continuous || generation == 0 || ice_generation_current)`.
    public func isHealthy(localPeerState: String, iceConnected: Bool, continuous: Bool, generation: Int64) -> Bool {
        localPeerState == "Connected" && iceConnected && state == "connected" && !iceRecoveryPending
            && (!continuous || generation == 0 || iceGenerationCurrent)
    }

    /// `host.getJSONObject("ice")`; missing → `ControlResponseError(.invalidReply)` (non-retryable).
    public func requireICE() throws -> ControlJSON {
        guard let ice else { throw ControlResponseError(.invalidReply) }
        return ice
    }

    /// `host.getJSONObject("continuous_ice")`; missing → `ControlResponseError(.invalidReply)`.
    public func requireContinuousICE() throws -> ControlJSON {
        guard let continuousICE else { throw ControlResponseError(.invalidReply) }
        return continuousICE
    }

    /// A JSON number member (Kotlin `opt(key) as? Number`), e.g. `source_rate_hz`.
    public func number(_ key: String) -> Double? {
        json[key]?.doubleValue
    }

    /// Diagnostics `hostNumber(key)` (`A/StreamReceiver.kt:699-700`): a finite number > 0
    /// formatted `%.0f`, else `unavailable`.
    public func numberText(_ key: String) -> String {
        guard let value = number(key), value.isFinite, value > 0 else { return "unavailable" }
        return String(format: "%.0f", value)
    }
}
