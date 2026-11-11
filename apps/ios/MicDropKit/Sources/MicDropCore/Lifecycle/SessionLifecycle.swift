// Pure session state machine. Port of `SessionLifecycle.kt:48-136` with iOS automatic-pause wording. Fully
// covered by the port of `SessionLifecycleTest.kt`.

/// Per-session state shared by a controller, its UI and its media controls.
///
/// A value type held by a `@MainActor` controller (`PlaybackSessionController`,
/// `MicrophoneSessionController`); every mutation happens on the main actor. A fresh random `token`
/// per connection attempt rejects delayed worker callbacks, stale media commands and old UI actions.
///
/// Invariants: once STOPPING no late callback changes the view; a pause can only disarm automatic resume, never re-arm
/// it; `finish` requires an active phase, so Stop from PAUSED or INTERRUPTED goes through `stopping(_:)` first.
public struct SessionLifecycle: Equatable, Sendable {
    public private(set) var view: SessionView
    public private(set) var token: String?
    /// Automatic resume is armed (transient interruption).
    public private(set) var resumeOnFocus = false
    /// The interruption ended while the previous worker was still tearing down; resume after `finish`.
    public private(set) var focusReturned = false
    /// A Play arrived during PAUSING; reconnect once the previous worker has ended.
    public private(set) var playAfterPause = false

    public init(initial: SessionView = SessionView()) {
        view = initial
        token = nil
    }

    /// Starts a new attempt (`SessionLifecycle.kt:61-66`). Rejected while a worker is active. Replaces the
    /// view with a fresh CONNECTING view, so diagnostics, `failureId` and `networkStatus` are reset.
    @discardableResult
    public mutating func begin(_ id: String, destination: String) -> Bool {
        if view.active { return false }
        clearIntent()
        token = id
        view = SessionView(phase: .connecting, message: Messages.connecting, destination: destination)
        return true
    }

    /// Applies a worker callback (`SessionLifecycle.kt:67-73`). Ignored for another token, when not active,
    /// and once PAUSING or STOPPING (stop wins). Only non-nil fields are copied.
    @discardableResult
    public mutating func update(
        _ id: String, phase: SessionPhase? = nil, message: String? = nil,
        diagnostics: String? = nil, networkStatus: String? = nil
    ) -> Bool {
        guard token == id, view.active, view.phase != .stopping, view.phase != .pausing else { return false }
        if let phase { view.phase = phase }
        if let message { view.message = message }
        if let diagnostics { view.diagnostics = diagnostics }
        if let networkStatus { view.networkStatus = networkStatus }
        return true
    }

    /// `SessionLifecycle.kt:74-76`.
    public mutating func setDestination(_ id: String, _ destination: String) {
        if token == id { view.destination = destination }
    }

    /// Live microphone change: finish the current stream before reconnecting (`SessionLifecycle.kt:77-82`).
    @discardableResult
    public mutating func switchRoute(_ id: String) -> Bool {
        guard token == id else { return false }
        switch view.phase {
        case .playing, .recovering, .routeRecovering: break
        default: return false
        }
        clearIntent()
        view.phase = .switching
        view.message = Messages.switchingMicrophone
        return true
    }

    /// Enters STOPPING from any retained phase (`SessionLifecycle.kt:83-88`); cancels automatic resume and
    /// queued Play.
    @discardableResult
    public mutating func stopping(_ id: String) -> Bool {
        guard token == id, view.retained, view.phase != .stopping else { return false }
        clearIntent()
        view.phase = .stopping
        view.message = Messages.stopping
        return true
    }

    /// Worker ended (`SessionLifecycle.kt:89-99`). A non-failed end during PAUSING becomes INTERRUPTED
    /// (automatic resume armed) or PAUSED and keeps the token; anything else becomes ENDED, clears the
    /// token and records `failureId` for a failure. `diagnostics` replaces the current text only when
    /// non-nil.
    @discardableResult
    public mutating func finish(
        _ id: String, message: String, failed: Bool = false,
        diagnostics: String? = nil
    ) -> Bool {
        guard token == id, view.active else { return false }
        if let diagnostics { view.diagnostics = diagnostics }
        if view.phase == .pausing && !failed {
            view.phase = resumeOnFocus ? .interrupted : .paused
            view.message = message
        } else {
            view.phase = .ended
            view.message = message
            view.failureId = failed ? id : nil
            token = nil
            clearIntent()
        }
        return true
    }

    /// Pause, automatic (interruption) or manual (`SessionLifecycle.kt:101-114`).
    ///
    /// From a live phase: PAUSING with `resumeOnFocus = automatic`. While PAUSING/INTERRUPTED a repeated
    /// pause can only disarm (manual) or clear a pending `focusReturned` (automatic). INTERRUPTED with a
    /// manual pause goes directly to PAUSED (no worker is running). PAUSED is not busy, so it is rejected.
    @discardableResult
    public mutating func pause(_ id: String, automatic: Bool) -> Bool {
        guard token == id, view.busy, view.phase != .stopping else { return false }
        playAfterPause = false
        if view.phase != .pausing && view.phase != .interrupted {
            resumeOnFocus = automatic
            focusReturned = false
        } else if !automatic {
            resumeOnFocus = false
            focusReturned = false
        } else {
            focusReturned = false
        }
        if view.phase == .interrupted {
            view.phase = automatic ? .interrupted : .paused
        } else {
            view.phase = .pausing
        }
        view.message = resumeOnFocus ? Messages.automaticPause : Messages.paused
        return true
    }

    /// The interruption ended with permission to resume (`SessionLifecycle.kt:116-122`). Returns true only
    /// when resume can start now (INTERRUPTED); during PAUSING teardown the gain is remembered in
    /// `focusReturned` so two peers never share the audio module.
    @discardableResult
    public mutating func focusGained() -> Bool {
        if !resumeOnFocus { return false }
        focusReturned = true
        return view.phase == .interrupted
    }

    /// Restores the retained paused card from a resume ticket at launch (`SessionLifecycle.kt:124-128`).
    public mutating func restorePause(_ id: String) {
        if view.busy { return }
        token = id
        clearIntent()
        view.phase = .paused
        view.message = Messages.paused
        view.failureId = nil
    }

    /// Play during PAUSING: reconnect after the previous worker ended (`SessionLifecycle.kt:130-135`).
    @discardableResult
    public mutating func queuePlay(_ id: String) -> Bool {
        guard token == id, view.phase == .pausing else { return false }
        playAfterPause = true
        resumeOnFocus = false
        focusReturned = false
        view.message = Messages.queuedPlay
        return true
    }

    /// Worker confirmation lines carried into a pausing `finish` (`PlaybackService.kt:376`): the part of the
    /// worker message after its first `"\n"`, prefixed with `"\n"`, or `""` when there is none. A pausing
    /// finish shows `view.message + confirmationSuffix(end.message)`, e.g.
    /// `"Paused. Play reconnects to live audio.\nWindows acknowledged Stop."`.
    public static func confirmationSuffix(_ workerMessage: String) -> String {
        guard let newline = workerMessage.firstIndex(of: "\n") else { return "" }
        let rest = String(workerMessage[workerMessage.index(after: newline)...])
        return rest.isEmpty ? "" : "\n" + rest
    }

    private mutating func clearIntent() {
        resumeOnFocus = false
        focusReturned = false
        playAfterPause = false
    }
}

extension SessionLifecycle {
    /// Lifecycle-owned user-visible strings (rows owned). Strings without an Android reference are verbatim Android
    /// text.
    public enum Messages {
        /// `begin` (`SessionLifecycle.kt:64`).
        public static let connecting = "Connecting securely to Windows…"
        /// `stopping` (`SessionLifecycle.kt:86`).
        public static let stopping = "Stopping locally and notifying Windows…"
        /// Automatic pause (`SessionLifecycle.kt:111`, adapted for iOS).
        public static let automaticPause =
            "Interrupted. Will resume when iOS ends the audio interruption (up to 5 minutes)."
        /// Manual or restored pause (`SessionLifecycle.kt:112,127`).
        public static let paused = "Paused. Play reconnects to live audio."
        /// Queued Play (`SessionLifecycle.kt:133`).
        public static let queuedPlay = "Play requested. Finishing the previous stream before reconnecting…"
        /// Live microphone change (`SessionLifecycle.kt:80`).
        public static let switchingMicrophone = "Changing microphone. Finishing the current stream before reconnecting…"
        /// Invalid or expired link at `beginConnection` (`PlaybackService.kt:186`).
        public static let linkUnavailable = "The Windows connection is unavailable or expired. Paste its current link."
        /// `startTransport` failure and generic activation failure (`PlaybackService.kt:258`).
        public static let playbackStartFailed = "Playback could not start. Open MicDrop and check the Windows link."
        /// Background start denied (`PlaybackService.kt:140`).
        public static let backgroundStartDenied = "iOS could not start background playback. Open MicDrop and try Play."
        /// 10 s start timeout (`PlaybackService.kt:410`).
        public static let startTimeout = "iOS did not make playback ready. Open MicDrop and try Reconnect."
        /// Audio session busy (`strings.xml:89` `focus_denied`).
        public static let audioBusy = "Audio is busy. Try again after other playback stops."
        /// Output must be reselected (`strings.xml:16` `output_reselect` on main `5251e0c`). iOS text: Android's
        /// "Device missing?" becomes the picker row, which a session with a pinned output (Paused included)
        /// keeps disabled until Stop. Shown by the Connect and microphone preflights, a vanished choice during
        /// a session and the session-start check, so it is correct in each.
        public static let outputReselect =
            "The selected media output is unavailable. Reconnect it or choose another output. "
            + "If iOS is hiding a connected device, use AirPlay & Bluetooth output… to make it the iPhone output "
            + "(tap Stop first if a session is running or paused), then choose it."
        /// Controller torn down while busy (`PlaybackService.kt:473`).
        public static let serviceEnded = "Playback service ended. Use Reconnect after Windows finishes the stream."
        /// iOS-only: background lease expired before audio started.
        public static let backgroundSetupExpired =
            "iOS paused MicDrop in the background before audio started. Open MicDrop and tap Reconnect."
        /// Media Play lookup failure/timeout (`PlaybackService.kt:278`).
        public static let savedConnectionUnavailable = "Saved connection could not be loaded."
        /// Duplex pause window expired (`MicrophoneService.kt:377`).
        public static let duplexPauseExpired = "Duplex pause ended after 5 minutes. Tap Connect to start again."
        /// Duplex resume failed (`MicrophoneService.kt:373`).
        public static let duplexResumeFailed =
            "Duplex could not resume. Check microphone permission and the selected input, then tap Connect again."

        /// Duplex pausing finish (`MicrophoneService.kt:430-431`): automatic resume armed or not.
        public static func duplexPaused(automatic: Bool) -> String {
            "Duplex paused for phone audio. "
                + (automatic
                    ? "Will resume when the interruption ends (up to 5 minutes)."
                    : "Tap Resume duplex when ready (within 5 minutes).")
        }
    }
}
