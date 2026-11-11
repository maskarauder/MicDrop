import AVFoundation
import Foundation

/// Callbacks from one `MediaEngine` to its session (Kotlin observer and ADM callbacks `StreamReceiver.kt:408-442,
/// 1713-1754`). Implemented by `SessionController.EngineEventsBridge`.
///
/// Threading: peer/ICE callbacks arrive on the WebRTC signalling thread, playout edges on the `PlayoutTap` queue,
/// audio-session derived events on the posting thread of `AudioSessionEventMonitor` (synchronous sink). Implementations
/// must return immediately: update locked/atomic state, gate audio, wake the worker. Never block, never call a blocking
/// WebRTC API, never dispose objects, never perform HTTP (`StreamReceiver.kt:321-322`). The engine holds the
/// implementation strongly until `MediaEngine.close(onStep:)`; no callback is delivered after `close` started.
protocol MediaEngineEvents: AnyObject {
    /// `onConnectionChange`: capitalized label `New|Connecting|Connected|Disconnected|Failed|Closed` (host report
    /// vocabulary `report.go:126`; evidence uses the lowercase form).
    func peerStateChanged(_ label: String)
    /// `onIceConnectionChange` (legacy state, not the standardized variant): lowercase label
    /// `new|checking|connected|completed|failed|disconnected|closed` (`session.go:57`);
    /// `connected` = state ∈ {connected, completed}.
    func iceConnectionChanged(_ label: String, connected: Bool)
    /// `onIceGatheringChange(COMPLETE)`. The engine has already fired its own gathered latch
    /// (`waitGathered`); this is informational (e.g. `ICEDelegateBridge.gatheringCompleted()`).
    func iceGatheringCompleted()
    /// `onIceCandidate`: `sdpMLineIndex` and `sdp` (`candidate:…` without `a=`). Private data.
    func localCandidate(index: Int32, sdp: String)
    /// `onIceCandidatesRemoved`: `(sdpMLineIndex, sdp)` pairs (the SDK reports index −1).
    func localCandidatesRemoved(_ c: [(Int32, String)])
    /// `onIceCandidateError`: only the numeric code (address, URL and text are never read).
    func candidateError(code: Int32)
    /// Playout rising edge (`PlayoutTap`) = Android `onWebRtcAudioTrackStart`.
    func playoutStarted()
    /// Playout falling edge = `onWebRtcAudioTrackStop`. Suppressed by the engine while interrupted, closing or inside
    /// `restartPlayout()`.
    func playoutStopped()
    /// Track init/start/runtime errors: the session first tries `recoverableOutputFailed()`, else fails with
    /// `kind.failureText` / `output_*`. Never used for a media-services reset (`mediaServicesReset()`).
    func outputFailure(_ kind: OutputFailureKind)
    /// Record init/start/runtime errors in microphone modes (table): `microphone_init` / `microphone_start` /
    /// `microphone_runtime` with `kind.failureText`. Never used for a media-services reset (`mediaServicesReset()`).
    func captureFailure(_ kind: CaptureFailureKind)
    /// `mediaServicesWereResetNotification` (which overrides the runtime-error rows): every audio object is invalid, so
    /// the session ends without an output recovery or a playout recreation. Microphone modes fail with
    /// `microphone_runtime` while capture was active; every other case stops with `.failure`. The engine's
    /// `interrupted` flag has already been cleared.
    func mediaServicesReset()
    /// Interruption edges forwarded from `AudioSessionEventMonitor` (not `.appWasSuspended`). The engine's
    /// `interrupted` flag has already been updated.
    func audioInterruption(began: Bool, shouldResume: Bool)
    /// `routeChangeNotification` reason forwarded from the monitor (informational; route policy is driven by
    /// `OutputRouteController` / `MicrophoneRouting`).
    func audioRouteChanged(reason: AVAudioSession.RouteChangeReason)
    /// `didDetectPlayoutGlitch` running total (ADM render gaps; an approximation of underruns).
    func playoutGlitches(total: Int)
}

/// Output-side ADM failure classes (table; Android `AudioTrackErrorCallback`, `StreamReceiver.kt:436-441`). Texts per
/// (owns them; "iOS audio …" wording).
enum OutputFailureKind: String, Sendable, CaseIterable {
    /// `audioSession(_:failedToSetActive:error:)` while activating → `output_init`.
    case initialization
    /// `audioSession(_:audioUnitStartFailedWithError:)`, or the iOS-only 5 s playout watchdog → `output_start`.
    case start
    /// Runtime playout failure → `output_runtime`. A media-services reset is not one: it ends the session with
    /// `.failure` (`MediaEngineEvents.mediaServicesReset()`).
    case runtime

    /// Failure message when the output policy cannot recover (`StreamReceiver.kt:437-441`).
    var failureText: String {
        switch self {
        case .initialization: return "iOS audio output could not start."
        case .start: return "iOS audio playback failed to start."
        case .runtime: return "iOS audio output stopped unexpectedly."
        }
    }
}

/// Capture-side ADM failure classes (Android `AudioRecordErrorCallback`, `StreamReceiver.kt:431-435`; table). Texts per
/// / 08.
enum CaptureFailureKind: String, Sendable, CaseIterable {
    /// Activation failed during setup in a microphone-only session (`failedToSetActive`) →
    /// `microphone_init`. (`initializeInput` errors are reported by app-mic's `MicrophoneCapture`.)
    case initialization
    /// `audioUnitStartFailedWithError` in a microphone-only session → `microphone_start`.
    case start
    /// Capture stopped unexpectedly → `microphone_runtime`; also a media-services reset while capture was active
    /// (`MediaEngineEvents.mediaServicesReset()`).
    case runtime

    /// Failure message (`StreamReceiver.kt:432-434`).
    var failureText: String {
        switch self {
        case .initialization: return "The selected microphone could not start. Check microphone permission in Settings."
        case .start: return "The selected microphone failed to start."
        case .runtime: return "The selected microphone stopped unexpectedly."
        }
    }
}
