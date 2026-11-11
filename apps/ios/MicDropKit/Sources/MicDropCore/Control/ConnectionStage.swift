import Foundation

/// Session setup stages (`A/ConnectionFailure.kt:12-24`).
///
/// The raw value is the wire stage of terminal diagnostics (`"stage"`, lowercased Kotlin name,
/// `internal/diagnostics/session.go`), e.g. `input_route`.
public enum ConnectionStage: String, Sendable, Equatable, CaseIterable {
    case waiting
    case pairing
    case audio
    case codec
    case offer
    case answer
    case routes
    case submitting
    case playback
    case inputRoute = "input_route"
    case microphone

    /// User-visible label, shown as `"<label>…"` and in failure text (`describe`). AUDIO uses the iOS wording.
    public var label: String {
        switch self {
        case .waiting: return "Waiting for the previous session to stop"
        case .pairing: return "Connecting securely to Windows"
        case .audio: return "Initializing iPhone audio"
        case .codec: return "Selecting Opus"
        case .offer: return "Applying the Windows offer"
        case .answer: return "Creating the stereo answer"
        case .routes: return "Gathering local network routes"
        case .submitting: return "Sending the answer to Windows"
        case .playback: return "Receiving audio"
        case .inputRoute: return "Selecting microphone input"
        case .microphone: return "Sending phone microphone"
        }
    }

    /// Terminal-diagnostics `stage` value (host vocabulary).
    public var wire: String { rawValue }

    /// Kotlin enum name, used in the log line `"Connection stage: <NAME>"` (`A/StreamReceiver.kt:877-883`).
    public var name: String { rawValue.uppercased() }

    /// Journal checkpoint written by `step(stage)`: `"setup_<stage lowercase>"`.
    public var journalCheckpoint: String { "setup_" + rawValue }

    /// Status text published by `step(stage)`: `"<label>…"`.
    public var statusText: String { label + "…" }
}
