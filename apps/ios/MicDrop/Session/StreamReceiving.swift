import Foundation
import MicDropCore

/// What the playback and microphone coordinators (`PlaybackSessionController`, 08 `MicrophoneSessionController`) hold
/// for the live session. `SessionController` is the only production conformer; tests may provide fakes.
///
/// Threading: every member may be called from any thread (normally main). None blocks on the network or on native
/// disposal, except `awaitRemoteStop(timeoutMs:)`, which exists for `applicationWillTerminate` only.
protocol StreamReceiving: AnyObject {
    /// Starts the dedicated session worker thread (`StreamReceiver.start`). Idempotent.
    func start()

    /// Stop always wins (`StreamReceiver.kt:315-336`): any thread, idempotent, the first reason wins, applies the local
    /// speaker (and microphone) mute synchronously, wakes registered worker waits and cancels in-flight ordinary
    /// requests. Never blocks and never disposes native objects; the worker's cleanup sends `/stop` (or
    /// `/cancel-offer`) and releases media.
    func close(_ reason: StopReason)

    /// "Play desktop audio" gate (`StreamReceiver.kt:293-299`). Playback modes only.
    func setOutputEnabled(_ enabled: Bool)

    /// Live output choice (`StreamReceiver.kt:278-291`). Ignored unless the session uses media output.
    func setOutputSelection(_ s: OutputSelection)

    /// Output focus pause (`StreamReceiver.kt:182-189`). Never driven on iOS; kept for parity and tests.
    func setOutputFocus(_ p: OutputPause?)

    /// Receiver-side microphone mute request (`StreamReceiver.kt:301-313`): closes the local sample gate immediately
    /// (also for Unmute), publishes `(muted, pending: true)`, wakes the worker.
    func setMicrophoneMuted(_ muted: Bool)

    /// The user's desired microphone mute (`StreamReceiver.microphoneMuteRequested`).
    var microphoneMuteRequested: Bool { get }

    /// `!closed && outputRoute.selection == s` (`StreamReceiver.kt:166-168`).
    func matchesOutputSelection(_ s: OutputSelection) -> Bool

    /// `!closed && pause == current pause && protectedSpeaker == current protection`
    /// (`StreamReceiver.kt:177-180`).
    func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool

    /// Route-change `.oldDeviceUnavailable` hop (`StreamReceiver.kt:193-208`): mutes synchronously on
    /// the calling thread; `false` when the session does not use media output or is closed.
    @discardableResult func mediaOutputBecomingNoisy() -> Bool

    /// `usesMediaOutput && outputRoute.pending && outputRoute.selection.explicit`
    /// (`StreamReceiver.kt:164`).
    func outputSwitchPending() -> Bool

    /// Background-setup lease expiry: if not closed and media is not ready yet, fails with `"iOS paused MicDrop in the
    /// background before audio started. Open MicDrop and tap Reconnect."` / `stage_timeout`; otherwise no-op.
    func expireBackgroundSetup()

    /// iOS addition: blocks the calling thread until the worker's `/stop` or `/cancel-offer` finished (acknowledged or
    /// not) or the timeout elapsed. `nil` uses the shutdown bound (2000 ms LAN / 3000 ms remote). Returns `true` only
    /// if Windows acknowledged the Stop. Call after `close(_:)`; the worker never needs the main thread to send the
    /// request.
    func awaitRemoteStop(timeoutMs: Int?) -> Bool

    /// iOS addition: scene `.active` state for the microphone-only background keep-alive policy. `false` on
    /// `UIApplication.willResignActiveNotification`, `true` on return.
    func setApplicationActive(_ active: Bool)
}

extension StreamReceiving {
    /// `StreamReceiver.close()` default reason `USER`.
    func close() { close(.user) }

    /// Default for conformers that never talk to Windows (fakes): nothing to wait for.
    func awaitRemoteStop(timeoutMs: Int?) -> Bool { false }

    /// Default for conformers without microphone capture: no keep-alive policy.
    func setApplicationActive(_ active: Bool) {}
}
