import Foundation

/// Copy-report ("last stream report") text builders. Human-readable, never parsed by the host.
///
/// Android strings are kept verbatim (`·` U+00B7, `—` U+2014) except the iOS substitutions. Lines that belong to other
/// subsystems arrive pre-rendered (their owners' `text` APIs), so this type only fixes order, prefixes and the
/// diagnostics-owned lines. Numbers use POSIX formatting.
public enum ReportText {
    /// Host `/status` figures used by the copy text (`K:StreamReceiver.kt:699-700,723-737`). The worker
    /// fills them from core-control's `HostStatus`; `nil` means absent or not a number.
    public struct HostFigures: Sendable, Equatable {
        public var sourceRateHz: Double?
        public var sourceChannels: Double?
        public var encoderChannels: Double?
        public var encoderPacketMsAtCreation: Double?
        public var bridgeMixRateHz: Double?
        public var bridgeMixChannels: Double?
        public var bridgeBufferFrames: Double?
        /// `host.optLong("bridge_frames_submitted")`, default 0.
        public var bridgeFramesSubmitted: Int64
        /// `host.optBoolean("microphone_muted", true)`.
        public var microphoneMuted: Bool

        public init(
            sourceRateHz: Double? = nil, sourceChannels: Double? = nil, encoderChannels: Double? = nil,
            encoderPacketMsAtCreation: Double? = nil, bridgeMixRateHz: Double? = nil,
            bridgeMixChannels: Double? = nil, bridgeBufferFrames: Double? = nil,
            bridgeFramesSubmitted: Int64 = 0, microphoneMuted: Bool = true
        ) {
            self.sourceRateHz = sourceRateHz
            self.sourceChannels = sourceChannels
            self.encoderChannels = encoderChannels
            self.encoderPacketMsAtCreation = encoderPacketMsAtCreation
            self.bridgeMixRateHz = bridgeMixRateHz
            self.bridgeMixChannels = bridgeMixChannels
            self.bridgeBufferFrames = bridgeBufferFrames
            self.bridgeFramesSubmitted = bridgeFramesSubmitted
            self.microphoneMuted = microphoneMuted
        }
    }

    /// Inputs of one periodic snapshot text (`lastDiagnostics`, `K:StreamReceiver.kt:723-764`).
    public struct Periodic: Sendable {
        public var mode: StreamMode
        public var capturedAt: String
        public var environment: EnvironmentSnapshot?
        /// Report `state` label.
        public var state: String
        /// `running` / `waiting`.
        public var mediaOutput: String
        /// `ReportDelivery.text` (core-control).
        public var deliveryText: String
        public var host: HostFigures
        public var snapshot: PlaybackSnapshot
        public var connection: ConnectionSnapshot
        /// LAN: the LAN signaling route line (`LAN signaling route: … · Cellular media candidates: …`);
        /// remote: `ReportText.remoteSignaling(forceRelay:)`.
        public var signalingText: String
        /// `LanRecovery.text` (core-ice); `LAN media recovery` is rewritten to `Media recovery` here.
        public var lanRecoveryText: String
        /// `RouteSelectionSnapshot.text` (core-ice).
        public var routeSelectionText: String
        /// `snapshot.transport.turnText` (phone) and the host-reported transport's `turnText`.
        public var phoneTurnText: String
        public var hostTurnText: String
        /// User "Play desktop audio" gate (`App audio output: enabled|silenced`).
        public var outputEnabled: Bool
        /// `ReportText.audioSession(...)`; `nil` → `iOS audio session: unavailable`. Playback modes.
        public var audioSessionText: String?
        /// `RecoverySnapshot.text` (core-output). Playback modes.
        public var recoveryText: String?
        /// Local output baseline (debug tool) uptime and text, playback mode only.
        public var localBaselineUptimeMs: Int64?
        public var localBaselineText: String?
        /// `MicrophoneSnapshot.text()` (core-mic). Microphone modes.
        public var microphoneText: String?
        /// `AdvancedAudioPreferences.mutedCaptureText(option:retained:)`, the line right after the microphone
        /// lines (`K:StreamReceiver.kt:781-783` on main `87b15af`). Microphone modes; ignored for playback.
        public var mutedCaptureText: String?
        /// `MicrophoneProcessing.text(voiceProcessingActive:)` (core-mic). Microphone modes.
        public var processingText: String?
        /// `OutputPause` detail while playback is paused (core-output).
        public var outputPauseDetail: String?
        /// Playback modes: the value after `App output selection: ` (core-output/app-output wording).
        public var outputSelectionText: String?
        /// Full `Selected output identity: …` line for a Bluetooth output selection, if any.
        public var outputIdentityText: String?
        /// Media-output sessions: `Output recovery: …` text (may contain a second line).
        public var outputRecoveryText: String?
        /// Bluetooth microphone: `HeadsetRecovery` text and the headset identity line.
        public var headsetLines: [String]
        /// `IceGatheringSnapshot.text`, trickle and continuous ICE lines (core-ice), when they exist.
        public var iceGatheringText: String?
        /// `TurnTLSTrustSnapshot.text()` (core-ice). The session always passes it, LAN and hosts without the
        /// report member included (`K:StreamReceiver.kt:810`).
        public var tlsTrustText: String?
        public var trickleText: String?
        public var continuousText: String?
        /// Remote sessions: network handoffs detected so far (adds the handoff line).
        public var remoteNetworkHandoffs: Int?
        /// Latest `signalingFailureText` (core-control), if any.
        public var signalingFailureText: String?

        public init(
            mode: StreamMode, capturedAt: String, environment: EnvironmentSnapshot?, state: String,
            mediaOutput: String, deliveryText: String, host: HostFigures, snapshot: PlaybackSnapshot,
            connection: ConnectionSnapshot, signalingText: String, lanRecoveryText: String,
            routeSelectionText: String, phoneTurnText: String, hostTurnText: String, outputEnabled: Bool,
            audioSessionText: String? = nil, recoveryText: String? = nil,
            localBaselineUptimeMs: Int64? = nil, localBaselineText: String? = nil,
            microphoneText: String? = nil, mutedCaptureText: String? = nil, processingText: String? = nil,
            outputPauseDetail: String? = nil, outputSelectionText: String? = nil,
            outputIdentityText: String? = nil, outputRecoveryText: String? = nil,
            headsetLines: [String] = [], iceGatheringText: String? = nil, tlsTrustText: String? = nil,
            trickleText: String? = nil, continuousText: String? = nil, remoteNetworkHandoffs: Int? = nil,
            signalingFailureText: String? = nil
        ) {
            self.mode = mode
            self.capturedAt = capturedAt
            self.environment = environment
            self.state = state
            self.mediaOutput = mediaOutput
            self.deliveryText = deliveryText
            self.host = host
            self.snapshot = snapshot
            self.connection = connection
            self.signalingText = signalingText
            self.lanRecoveryText = lanRecoveryText
            self.routeSelectionText = routeSelectionText
            self.phoneTurnText = phoneTurnText
            self.hostTurnText = hostTurnText
            self.outputEnabled = outputEnabled
            self.audioSessionText = audioSessionText
            self.recoveryText = recoveryText
            self.localBaselineUptimeMs = localBaselineUptimeMs
            self.localBaselineText = localBaselineText
            self.microphoneText = microphoneText
            self.mutedCaptureText = mutedCaptureText
            self.processingText = processingText
            self.outputPauseDetail = outputPauseDetail
            self.outputSelectionText = outputSelectionText
            self.outputIdentityText = outputIdentityText
            self.outputRecoveryText = outputRecoveryText
            self.headsetLines = headsetLines
            self.iceGatheringText = iceGatheringText
            self.tlsTrustText = tlsTrustText
            self.trickleText = trickleText
            self.continuousText = continuousText
            self.remoteNetworkHandoffs = remoteNetworkHandoffs
            self.signalingFailureText = signalingFailureText
        }
    }

    /// Confirmation line appended to the UI end message (`K:StreamReceiver.kt:865-868`).
    public enum StopConfirmation: Sendable, Equatable {
        case acknowledged
        case retryOnConnect
        case watchdog
        /// No session token and no pending offer cancellation: nothing to confirm.
        case notSent

        public var suffix: String {
            switch self {
            case .acknowledged:
                return "\nWindows acknowledged Stop."
            case .retryOnConnect:
                return
                    "\nStopped locally; Windows Stop was not confirmed. Connect will retry it, or Windows will end the session after its timeout."
            case .watchdog:
                return "\nStopped locally; Windows Stop was not confirmed. Its watchdog will end the session."
            case .notSent:
                return ""
            }
        }
    }

    /// Whether `/offer` has been answered when the terminal report is assembled (`SessionEvidence.kt:OfferReply`).
    public enum OfferReply: String, Sendable, Equatable {
        case none
        case rejected
        case accepted
    }

    /// `Windows terminal diagnostics:` values (for the iPhone wording, `SessionEvidence.kt`).
    public enum TerminalDelivery {
        public static let notConfirmed = "not confirmed"
        public static let unavailable = "unavailable on this Windows build"
        public static let notSentNoOfferReply = "not sent; no Windows offer reply"
        public static let notSentOfferReplyRejected = "not sent; Windows offer reply rejected"
        public static let notRequestedByWindows = "not requested by Windows (older Windows or logging off)"
        public static let rejected = "rejected; retained in iPhone copy report"
        public static let cancellationUnconfirmed = "not sent; pending offer cancellation unconfirmed"
        public static let cancellationAcknowledged = "not sent; pending offer cancellation acknowledged"

        /// Initial value once `/offer` was accepted: `not confirmed` when connection diagnostics were negotiated, else
        /// `unavailable…`. Prefer `delivery(reply:connectionNegotiated:)` when pre-offer states are possible.
        public static func initial(connectionNegotiated: Bool) -> String {
            connectionNegotiated ? notConfirmed : unavailable
        }

        /// Initial `Windows terminal diagnostics:` label before `/stop` or `/cancel-offer` runs (`TerminalLabels.delivery`).
        public static func delivery(reply: OfferReply, connectionNegotiated: Bool) -> String {
            switch reply {
            case .none:
                return notSentNoOfferReply
            case .rejected:
                return notSentOfferReplyRejected
            case .accepted:
                return connectionNegotiated ? notConfirmed : notRequestedByWindows
            }
        }

        /// Terminal report's `Media recovery:` block (`TerminalLabels.mediaRecovery`): before `/offer` is accepted,
        /// `LanRecovery(supported: false)` is only a local placeholder, not an accepted 10 s host window.
        public static func mediaRecovery(
            reply: OfferReply, recoveryText: String, recoveryRemainingMs: Int64
        ) -> String {
            switch reply {
            case .none:
                return "Media recovery: not negotiated (no Windows offer reply)"
            case .rejected:
                return "Media recovery: not negotiated (Windows offer reply rejected)"
            case .accepted:
                let normalized = recoveryText.replacingOccurrences(of: "LAN media recovery", with: "Media recovery")
                return "\(normalized)\nRecovery time remaining: \(recoveryRemainingMs) ms"
            }
        }
    }

    /// Used when no terminal evidence could be captured.
    public static let terminalUnavailable = "Terminal connection diagnostics unavailable."
    /// Used when the audio-session line cannot be built (playback modes).
    public static let audioSessionUnavailable = "iOS audio session: unavailable"

    /// `hostNumber(key)` (`K:StreamReceiver.kt:699-700`): finite and > 0 → `%.0f`, else `unavailable`.
    public static func hostNumber(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "unavailable" }
        return String(format: "%.0f", value)
    }

    /// Remote signaling line (`K:StreamReceiver.kt:745`).
    public static func remoteSignaling(forceRelay: Bool) -> String {
        "Remote signaling: HTTPS rendezvous · Cellular media candidates: allowed · Force TURN relay: \(forceRelay)"
    }

    /// iOS replacement for `Actual AudioTrack diagnostics`: two lines, not uploaded. Inputs are `AVAudioSession`
    /// `sampleRate`, `outputNumberOfChannels`, `ioBufferDuration`, `outputLatency`.
    public static func audioSession(
        sampleRateHz: Double, outputChannels: Int, ioBufferSeconds: Double,
        outputLatencySeconds: Double
    ) -> String {
        func fixed(_ value: Double, _ format: String) -> String {
            value.isFinite && value >= 0 ? String(format: format, value) : "unavailable"
        }
        var text = "iOS audio session: \(fixed(sampleRateHz, "%.0f")) Hz / \(outputChannels) channels"
        text += " · I/O buffer: \(fixed(ioBufferSeconds * 1000, "%.1f")) ms"
        text += " · Reported output latency: \(fixed(outputLatencySeconds * 1000, "%.1f")) ms"
        text += "\nAudio session values are OS estimates; headset rendering and physical latency remain unmeasured."
        return text
    }

    /// Periodic snapshot text. Published via `onDiagnostics` and `onStatus` and written to the journal by the worker.
    public static func periodic(_ input: Periodic) -> String {
        var lines: [String] = []
        let snapshot = input.snapshot
        if input.mode.hasMicrophone {
            lines.append("\(input.mode.hasPlayback ? "Duplex" : "Microphone") snapshot: \(input.capturedAt)")
            lines.append(
                input.environment?.text(microphone: true, desktopPlayback: input.mode.hasPlayback)
                    ?? "Phone environment: unavailable")
            lines.append(
                "State: \(input.state) · Desktop playback: \(input.mode.hasPlayback ? input.mediaOutput : "off")")
            lines.append(input.deliveryText)
            lines.append(input.microphoneText ?? "Microphone: unavailable")
            if let mutedCapture = input.mutedCaptureText { lines.append(mutedCapture) }
            lines.append("Codec: \(snapshot.codec) · Media path: \(snapshot.path)")
            let sentKbps = snapshot.value("sent_payload_kbps").map { "\($0)" } ?? "unavailable"
            let sentBytes = snapshot.value("sent_bytes_total").map { "\($0)" } ?? "unavailable"
            lines.append("Sent payload: \(sentKbps) kb/s · Total sent: \(sentBytes) bytes")
            lines.append(
                "Windows cable: \(hostNumber(input.host.bridgeMixRateHz)) Hz / \(hostNumber(input.host.bridgeMixChannels)) channels"
            )
            lines.append(
                "Windows buffer: \(hostNumber(input.host.bridgeBufferFrames)) source frames · Submitted: \(input.host.bridgeFramesSubmitted) frames"
            )
            lines.append("Host microphone gate: \(input.host.microphoneMuted ? "muted" : "enabled")")
            lines.append("Buffer, packet and RTT figures do not measure physical microphone latency.")
            if input.mode.hasPlayback {
                lines.append(snapshot.text())
                lines.append(input.audioSessionText ?? audioSessionUnavailable)
                if let recovery = input.recoveryText { lines.append(recovery) }
            }
            if let processing = input.processingText { lines.append(processing) }
        } else {
            lines.append("Playback snapshot: \(input.capturedAt)")
            lines.append(input.environment?.text() ?? "Phone route/environment: unavailable")
            lines.append("State: \(input.state) · Media output: \(input.mediaOutput)")
            lines.append(input.deliveryText)
            lines.append(
                "Windows source: \(hostNumber(input.host.sourceRateHz)) Hz / \(hostNumber(input.host.sourceChannels)) channels"
            )
            lines.append(
                "Encoder: \(hostNumber(input.host.encoderChannels)) channels · \(hostNumber(input.host.encoderPacketMsAtCreation)) ms initial packets"
            )
            lines.append(snapshot.text())
            lines.append(input.audioSessionText ?? audioSessionUnavailable)
            if let recovery = input.recoveryText { lines.append(recovery) }
            if let baseline = input.localBaselineText, let uptime = input.localBaselineUptimeMs {
                lines.append("Last local output baseline (phone uptime \(uptime) ms):")
                lines.append(baseline)
            }
        }

        lines.append("App audio output: \(input.outputEnabled ? "enabled" : "silenced")")
        if let detail = input.outputPauseDetail { lines.append(detail) }
        lines.append(input.connection.text())
        lines.append(input.signalingText)
        lines.append(input.lanRecoveryText.replacingOccurrences(of: "LAN media recovery", with: "Media recovery"))
        if input.mode.hasPlayback, let selection = input.outputSelectionText {
            lines.append("App output selection: \(selection)")
        }
        if let identity = input.outputIdentityText { lines.append(identity) }
        if let recovery = input.outputRecoveryText { lines.append(recovery) }
        lines.append(contentsOf: input.headsetLines)
        if let gathering = input.iceGatheringText { lines.append(gathering) }
        if let trust = input.tlsTrustText { lines.append(trust) }
        if let trickle = input.trickleText { lines.append(trickle) }
        if let continuous = input.continuousText { lines.append(continuous) }
        lines.append(input.routeSelectionText)
        lines.append("Selected TURN connections — phone: \(input.phoneTurnText) · Windows: \(input.hostTurnText)")
        lines.append("TURN connection protocols are separate from the ICE candidate protocol shown in Media path.")
        if let handoffs = input.remoteNetworkHandoffs {
            let network = input.connection.runtime?.defaultNetwork ?? "unknown"
            lines.append("Network handoffs detected: \(handoffs) · Signaling: rendezvous · Default network: \(network)")
        }
        if let failure = input.signalingFailureText { lines.append(failure) }
        return lines.joined(separator: "\n")
    }

    /// Line prefixes the terminal report replaces by the current signaling text (`StreamReceiver.kt:860-863`).
    public static let staleSignalingPrefixes = [
        "Signaling:", "Signaling history:", "Cellular media candidates:", "LAN signaling route:",
    ]

    /// `finalSnapshot` (`K:StreamReceiver.kt:839-863`): replaces stale lines with fresh ones. `headsetLines` (Bluetooth
    /// microphone) replace `Selected headset recovery:`/`Selected headset identity:`; `outputRecoveryText` (media
    /// output) replaces `Output recovery:`/`System Bluetooth route:`; `signalingFailureText` replaces `Secure signaling
    /// failure:`. Each replacement is appended at the end. The request-failure history follows. A failed heartbeat may
    /// prevent another periodic snapshot, so `recoveryText` (`LanRecovery.text`, renamed to `Media recovery`) and
    /// `Recovery time remaining` always replace older recovery lines. The stale signaling lines are removed; `terminal`
    /// appends the current signaling text instead.
    public static func refreshedFinalSnapshot(
        _ last: String, headsetLines: [String]?, outputRecoveryText: String?,
        signalingFailureText: String?, requestFailuresText: String?, recoveryText: String,
        recoveryRemainingMs: Int64, offerReply: OfferReply = .accepted
    ) -> String {
        func kept(_ text: String, dropping prefixes: [String]) -> String {
            text.components(separatedBy: "\n").filter { line in
                !prefixes.contains(where: { line.hasPrefix($0) })
            }.joined(separator: "\n")
        }
        func replacing(_ text: String, prefixes: [String], with fresh: String) -> String {
            kept(text, dropping: prefixes) + "\n" + fresh
        }
        var result = last
        if let headsetLines {
            result = replacing(
                result, prefixes: ["Selected headset recovery:", "Selected headset identity:"],
                with: headsetLines.joined(separator: "\n"))
        }
        if let outputRecoveryText {
            result = replacing(
                result, prefixes: ["Output recovery:", "System Bluetooth route:"], with: outputRecoveryText)
        }
        if let signalingFailureText {
            result = replacing(result, prefixes: ["Secure signaling failure:"], with: signalingFailureText)
        }
        if let requestFailuresText { result += "\n" + requestFailuresText }
        result = replacing(
            result, prefixes: ["Media recovery:", "LAN media recovery:"],
            with: TerminalDelivery.mediaRecovery(
                reply: offerReply, recoveryText: recoveryText, recoveryRemainingMs: recoveryRemainingMs))
        return kept(result, dropping: staleSignalingPrefixes)
    }

    /// Terminal copy report (`K:StreamReceiver.kt:864-866`): `<finalSnapshot>\n<signalingText>\n\nSession result:
    /// <result>\n<terminal text | unavailable>\n` `Windows terminal diagnostics: <delivery>`; `signalingText` is the
    /// current route text plus the connection order and deadlines (omitted when nil).
    public static func terminal(
        finalSnapshot: String, signalingText: String? = nil, result: String, terminal: TerminalEvidence?,
        delivery: String
    ) -> String {
        var text = finalSnapshot
        if let signalingText { text += "\n" + signalingText }
        text += "\n\nSession result: " + result
        text += "\n" + (terminal?.text() ?? terminalUnavailable)
        text += "\nWindows terminal diagnostics: " + delivery
        return text
    }
}
