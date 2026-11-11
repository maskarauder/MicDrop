import Foundation
import MicDropCore

extension SessionController {

    /// Client constants (Appendix C, a). Every value is the Kotlin value; sources cited per line.
    enum Timing {
        /// `Thread(..., "MicDrop-session")` (`StreamReceiver.kt:157`).
        static let workerThreadName = "MicDrop-session"
        /// `/offer` (`StreamReceiver.kt:1214`).
        static let offerTimeoutMs = 40_000
        /// 423 busy retry spacing (`StreamReceiver.kt:1228`).
        static let busyRetrySpacingMs = 500
        /// Default request timeout (`StreamReceiver.kt:1653`).
        static let defaultRequestTimeoutMs = 8_000
        /// Remote minimum for non-stop, non-recover requests (`StreamReceiver.kt:1656`).
        static let remoteMinimumTimeoutMs = 8_000
        /// Wait after a retryable status failure (`StreamReceiver.kt:654`).
        static let statusRetryWaitMs = 500
        /// Loop waits (`StreamReceiver.kt:769`).
        static let healthyWaitMs = 2_000
        static let handoffWaitMs = 100
        static let heldWaitMs = 500
        static let probingWaitMs = 20
        /// Report throttle while probing (`nextRouteReportAt`, `StreamReceiver.kt:765`).
        static let routeReportIntervalMs: Int64 = 2_000
        /// `getStats` wait (`StreamReceiver.kt:692`).
        static let statsTimeoutMs = 5_000
        /// `awaitSDP` default (`StreamReceiver.kt:1701`).
        static let sdpTimeoutMs = 15_000
        /// Initial gathering deadline / fast-relay poll (`StreamReceiver.kt:518,535`).
        static let gatheringDeadlineMs: Int64 = 15_000
        static let fastRelayPollMs: Int64 = 50
        /// Restoration `/microphone` clamp maximum (`StreamReceiver.kt:1389,1480`); the ordinary
        /// `/microphone` uses the configured LAN/rendezvous request budgets.
        static let restorationGateMaxMs: Int64 = 2_000
        /// Recovery budgets `clamp(remaining, 1, max)` (`StreamReceiver.kt:1586-1618`).
        static let recoverOfferMaxMs: Int64 = 18_000
        static let recoverySdpMaxMs: Int64 = 5_000
        static let recoveryGatheringMaxMs: Int64 = 8_000
        static let recoverAnswerMaxMs: Int64 = 5_000
        /// `/stop` (final and previous-Stop retry) (`StreamReceiver.kt:829,1206-1207`).
        static let stopTimeoutRemoteMs = 5_000
        static let stopTimeoutLanMs = 2_000
        /// `/cancel-offer` (`StreamReceiver.kt:849`).
        static let cancelOfferTimeoutMs = 5_000
        /// Microphone unmute activation / verification / muted BT output verification
        /// (`StreamReceiver.kt:1250,1255,1282`).
        static let unmuteActivationMs: Int64 = 5_000
        static let unmuteVerifyMs: Int64 = 2_000
        static let unmuteVerifyBluetoothMs: Int64 = 5_000
        static let microphonePollMs = 20
        static let mutedBluetoothOutputVerifyMs: Int64 = 5_000
        /// `applicationWillTerminate` wait for the worker's Stop.
        static let terminateWaitLanMs = 2_000
        static let terminateWaitRemoteMs = 3_000
        /// SDP bound (`StreamReceiver.kt:391,1588`).
        static let maxSdpLength = 65_536
        /// Backstop for the bridged `/v1/ice` fetch (URLSession resource timeout 16 s).
        static let remoteICEBackstopMs = 20_000
    }

    /// User-visible and copy-report strings emitted by the worker. Android text verbatim except the iOS substitutions
    /// of (marked).
    enum Messages {
        static let finishingPreviousSession = "Finishing the previous Windows session…"
        static let networkChanged = "Network changed. Restoring audio; microphone and output choices are retained…"
        static let restoringMediaConnection =
            "Restoring the current media connection. Selected devices and mute settings are retained…"

        /// `seconds` is `ConnectionTimeout.seconds(limitMs)` text, e.g. `7.5` (`StreamReceiver.kt:689`).
        static func connectionInterrupted(seconds: String) -> String {
            "Connection interrupted. Trying the current Windows session for up to \(seconds) seconds…"
        }

        static func mediaRecoveryTimeout(seconds: String, action: String) -> String {
            "The audio connection did not recover within \(seconds) seconds. Tap \(action) after Windows finishes the session."
        }

        /// `STATUS_RECOVERY_TIMEOUT` (`StreamReceiver.kt:684`).
        static func controlRecoveryTimeout(seconds: String, action: String) -> String {
            "Connection control did not recover within \(seconds) seconds. "
                + "Tap \(action) after Windows finishes the session."
        }

        static func hostAudioStopped(action: String) -> String {
            "Windows audio stopped. Tap \(action) after Windows finishes the session."
        }

        static func connectionLost(action: String) -> String {
            "Connection lost. Tap \(action) after Windows finishes the session."
        }

        static let modeNotConfirmed =
            "Windows did not confirm the requested audio mode. Update both apps and select a cable endpoint for microphone return."
        /// (`StreamReceiver.kt:1218`).
        static let duplexUnsupported =
            "Windows does not support duplex. Update both apps, then enable Play desktop audio and Send microphone and tap Connect again."
        static let microphoneReturnNotConfigured =
            "Windows microphone return is not configured. Restart Windows with --paired and --microphone-device using the cable render ID from bridge-devices."
        static let hostMicrophoneGateFailed =
            "Windows ended microphone return or could not apply its cable gate. Check the Windows console and the selected render endpoint with bridge-devices before retrying."
        /// (`StreamReceiver.kt:1514`).
        static let cleanupFailed = "Audio cleanup failed [TEARDOWN_FAILED]. Restart MicDrop before retrying."
        /// iOS-only.
        static let backgroundSetupExpired =
            "iOS paused MicDrop in the background before audio started. Open MicDrop and tap Reconnect."

        // Confirmation suffixes (`StreamReceiver.kt:865-868`).
        static let stopAcknowledged = "\nWindows acknowledged Stop."
        static let stopNotConfirmedRetry =
            "\nStopped locally; Windows Stop was not confirmed. Connect will retry it, or Windows will end the session after its timeout."
        static let stopNotConfirmedWatchdog =
            "\nStopped locally; Windows Stop was not confirmed. Its watchdog will end the session."

        // Terminal diagnostics delivery.
        static let terminalNotConfirmed = "not confirmed"
        static let terminalUnavailable = "unavailable on this Windows build"
        /// (`StreamReceiver.kt:837`).
        static let terminalRejected = "rejected; retained in iPhone copy report"
        static let cancellationUnconfirmed = "not sent; pending offer cancellation unconfirmed"
        static let cancellationAcknowledged = "not sent; pending offer cancellation acknowledged"
        static let terminalDiagnosticsUnavailable = "Terminal connection diagnostics unavailable."

        // Microphone route (iOS wording).
        static let inputRouteChanged = "The selected microphone or Bluetooth audio route changed."
        /// `seconds`: the session's configured Bluetooth route recovery window (Advanced, default `20`).
        static func headsetNotRestored(seconds: String) -> String {
            MicrophoneStatusText.Messages.headsetNotRestored(seconds: seconds)
        }
        static let headsetNotReselected = "iOS could not reselect the original headset."
        static let headsetOutputUnverified =
            "The selected headset output could not be verified. Stop and select the input again."

        static func stopForInputRouteChange(detail: String, playback: Bool, action: String) -> String {
            "\(detail) \(playback ? "Playback and microphone return stopped." : "Microphone return stopped.") "
                + "Choose an available input and tap \(action) again."
        }

        static func restoringHeadset(playback: Bool, seconds: String) -> String {
            MicrophoneStatusText.Messages.restoringHeadset(playback: playback, seconds: seconds)
        }

        static func headsetRestored(muted: Bool) -> String {
            "Selected headset restored.\(muted ? " Microphone remains muted." : "")"
        }

        // Capture / playout failures ([08], [09]).
        static let microphoneInitFailed =
            "The selected microphone could not start. Check microphone permission in Settings."
        static let microphoneStartFailed = "The selected microphone failed to start."
        static let microphoneRuntimeFailed = "The selected microphone stopped unexpectedly."
        static let outputInitFailed = "iOS audio output could not start."
        static let outputStartFailed = "iOS audio playback failed to start."
        static let outputRuntimeFailed = "iOS audio output stopped unexpectedly."

        /// .
        static let mutedKeepAlive = "Muted · microphone kept open so iOS keeps MicDrop running"

        /// Remote-only network status (`StreamReceiver.kt:1554-1566`).
        static func networkStatus(label: String, restoring: Bool) -> String {
            let network: String
            switch label {
            case "wifi": network = "Wi-Fi"
            case "cellular": network = "Cellular"
            case "ethernet": network = "Ethernet"
            case "vpn": network = "VPN"
            case "none": network = "Unavailable"
            default: network = "Checking"
            }
            return "Network: \(network)" + (restoring ? " · Restoring connection" : "")
        }

        /// Copy-report signalling line for remote sessions (`StreamReceiver.kt:742`).
        static func remoteSignaling(forceRelay: Bool) -> String {
            "Remote signaling: HTTPS rendezvous · Cellular media candidates: allowed · Force TURN relay: \(forceRelay)"
        }

        /// Copy-report handoff line for remote sessions (`StreamReceiver.kt:761`).
        static func networkHandoffs(_ count: Int, defaultNetwork: String) -> String {
            "Network handoffs detected: \(count) · Signaling: rendezvous · Default network: \(defaultNetwork)"
        }

        /// `"App audio output: enabled|silenced"` (`StreamReceiver.kt:741`).
        static func appAudioOutput(enabled: Bool) -> String {
            "App audio output: \(enabled ? "enabled" : "silenced")"
        }
    }

    /// Flat JSON values for the small control bodies the worker sends (`/offer`, `/cancel-offer`, `/answer`,
    /// `/microphone`, `/recover-offer`, `/recover-answer`, `/stop` without diagnostics). Integers are encoded as JSON
    /// integers.
    enum WireValue {
        case int(Int)
        case int64(Int64)
        case bool(Bool)
        case string(String)
    }

    /// Compact UTF-8 JSON object encoder for flat control bodies. Key order is irrelevant to the host
    /// (`DisallowUnknownFields` only rejects unknown keys); slashes are not escaped.
    enum WireBody {
        static func object(_ fields: [(String, WireValue)]) -> Data {
            var object: [String: Any] = [:]
            for (key, value) in fields {
                switch value {
                case .int(let number): object[key] = number
                case .int64(let number): object[key] = number
                case .bool(let flag): object[key] = flag
                case .string(let text): object[key] = text
                }
            }
            return (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
                ?? Data("{}".utf8)
        }

        /// `{"version":V}` (`/cancel-offer`, and the base of an ICE-only `/status` body).
        static func version(_ version: Int) -> Data { object([("version", .int(version))]) }

        /// `{"reason":"<wire>"}` (`/stop` without diagnostics, previous-Stop retry).
        static func stop(reason: String) -> Data { object([("reason", .string(reason))]) }
    }
}
