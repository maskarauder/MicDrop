import Foundation
import MicDropCore

/// The microphone half of the session worker (`StreamReceiver.kt:301-313`, `:565-593`, `:1234-1505`, `:1518-1552`),
/// owned by `SessionController` for MICROPHONE and DUPLEX.
///
/// Threading: `loopStep`/`apply`/`restoreHeadset`/teardown run synchronously on the dedicated session worker thread and
/// throw; `setMicrophoneMuted`, `inputRouteLost` and the gate helpers may run on any thread. The session's state that
/// Android keeps in `StreamReceiver` (`microphoneDesiredMuted`, `microphoneAppliedMuted`, `microphoneControlDirty`,
/// `closed`, `networkHeld`, the scene activity flag, the audio lock) stays in `SessionController` — it must exist
/// before the worker builds this object — and is reached through `Hooks`; this type keeps only the restoration and
/// keep-alive state.
///
/// Guarantees ported exactly: Mute closes the local gate synchronously, stops capture, then tells Windows; Unmute
/// probes with every gate closed, verifies the actual route (2 s, 5 s Bluetooth, 20 ms polls), gets the host's unmute
/// acknowledgment, re-verifies, and only then opens the local gate under the audio lock against the newest desired
/// value. Never another input.
final class MicrophoneControl: @unchecked Sendable {
    /// constants (`StreamReceiver.kt:1250-1285`, `:1389`, `:1480`). The ordinary `/microphone` request has no fixed
    /// timeout: it uses the configured LAN and rendezvous request budgets (`StreamReceiver.kt:1367,1402`).
    enum Timing {
        /// `routing.activate` budget on Unmute.
        static let unmuteActivationMs: Int64 = 5_000
        /// Unmute route verification, non-Bluetooth.
        static let verificationMs: Int64 = 2_000
        /// Unmute route verification, Bluetooth.
        static let bluetoothVerificationMs: Int64 = 5_000
        /// Muted Bluetooth duplex output verification.
        static let mutedHeadsetOutputMs: Int64 = 5_000
        /// Verification / restoration poll.
        static let pollMs = 20
        /// Restoration `/microphone` timeout = `clamp(remaining, 1, 2000)`.
        static let restorationGateMaxMs: Int64 = 2_000
    }

    let mode: StreamMode
    let selection: MicrophoneSelection
    let routing: MicrophoneRouting
    let capture: MicrophoneCapture
    let probe: MicrophoneInputProbe
    let outputWatch: HeadsetOutputWatch
    /// The session's `headsetRecovery` (shared with `SessionController.close`, which cancels it).
    let recovery: HeadsetRecovery
    private let host: HostGate
    private let hooks: Hooks

    // Restoration state (`StreamReceiver.kt:1363-1505`), worker-confined.
    private var restoringEpisode: Int64?
    private var restorationHostMuted = false
    private var restorationInputUID: String?
    private var restorationRecording = false
    private var restorationReportedMute: Bool?

    /// worker-confined: capture was resumed with every gate closed to keep a muted microphone-only session alive while
    /// the scene is not `.active` (Advanced "Keep microphone active while muted in background",
    /// `hooks.keepMicrophoneActiveWhileMuted`).
    private var keptOpenForBackground = false
    private var backgroundStartAttempted = false
    /// Worker-confined: the last `captureRetainedWhileMuted` sent through `hooks.onCaptureRetainedWhileMuted`.
    /// Starts false, the value the session controller assumes for each new receiver.
    private var lastPublishedRetained = false

    init(
        mode: StreamMode, selection: MicrophoneSelection, routing: MicrophoneRouting, capture: MicrophoneCapture,
        probe: MicrophoneInputProbe, outputWatch: HeadsetOutputWatch, recovery: HeadsetRecovery,
        host: HostGate, hooks: Hooks
    ) {
        self.mode = mode
        self.selection = selection
        self.routing = routing
        self.capture = capture
        self.probe = probe
        self.outputWatch = outputWatch
        self.recovery = recovery
        self.host = host
        self.hooks = hooks
    }

    /// Builds the probe and output watch over `routing`/`capture`.
    convenience init(
        mode: StreamMode, selection: MicrophoneSelection, routing: MicrophoneRouting,
        capture: MicrophoneCapture, recovery: HeadsetRecovery, host: HostGate, hooks: Hooks
    ) {
        self.init(
            mode: mode, selection: selection, routing: routing, capture: capture,
            probe: MicrophoneInputProbe(routing: routing, capture: capture),
            outputWatch: HeadsetOutputWatch(routing: routing), recovery: recovery, host: host, hooks: hooks)
    }

    /// Kotlin `mode.playback` (duplex) for a microphone session.
    var duplex: Bool { mode.hasPlayback }

    /// `mode.playback && selection.isBluetooth`: Bluetooth duplex output must be verified too.
    var verifiesHeadsetOutput: Bool { duplex && selection.isBluetooth }

    /// with the Advanced preference: a microphone-only session whose scene is not `.active` may keep a muted capture
    /// running (every gate closed) only while "Keep microphone active while muted in background" is on. Duplex never
    /// needs it: its playout keeps the app running.
    private var mutedBackgroundCaptureAllowed: Bool {
        mode == .microphone && !hooks.applicationActive && hooks.keepMicrophoneActiveWhileMuted
    }

    /// The session's configured Bluetooth route recovery window as status text, e.g. `20` or `7.5`.
    private var recoverySeconds: String { AdvancedAudioPreferences.seconds(recovery.limitMs) }

    /// Android `microphoneCaptureRetained` (`StreamReceiver.kt:139-140,455,1330,1474,1647` on main `87b15af`): a
    /// capture is running while the user's Mute is applied and no headset recovery is pending, so every gate is
    /// closed. Derived from live state, never from `keptOpenForBackground`, so an unexpected unit stop or a
    /// paused restoration can never read true. Any thread (each input is lock-protected). The copy report shows it
    /// beside the saved option; Now Playing receives it through `hooks.onCaptureRetainedWhileMuted`.
    var captureRetainedWhileMuted: Bool {
        capture.captureActive && hooks.desiredMuted && hooks.appliedMuted == true && !recovery.pending()
    }

    /// Worker: sends `captureRetainedWhileMuted` when it differs from the last value sent. Called from `loopStep`,
    /// `apply`, `restoreHeadset`, `applyBackgroundPolicy` (also the held status-loop step), `suspendForNetwork` and
    /// `stopRecording`, so every capture start or stop on the worker is followed by one publication.
    private func publishCaptureRetained() {
        let retained = captureRetainedWhileMuted
        guard retained != lastPublishedRetained else { return }
        lastPublishedRetained = retained
        hooks.onCaptureRetainedWhileMuted(retained)
    }

    // MARK: - Any thread

    /// `setMicrophoneMuted(muted)` (`StreamReceiver.kt:301-313`): under the audio lock, ignored when closed or when
    /// applied and desired already equal `muted`; sets desired and closes the local gate even for Unmute; then
    /// publishes `(muted, pending: true)` and wakes the worker. `SessionController.setMicrophoneMuted` implements the
    /// same algorithm itself (it must work before this object exists); either may be used.
    func setMicrophoneMuted(_ muted: Bool) {
        let changed: Bool = hooks.withAudioLock {
            if hooks.closed { return false }
            if hooks.appliedMuted == muted && hooks.desiredMuted == muted { return false }
            hooks.desiredMuted = muted
            capture.closeSampleGate()
            return true
        }
        guard changed else { return }
        hooks.onMicrophoneState(muted, pending: true)
        hooks.notifyControl()
    }

    /// `microphoneMuteRequested()` = desired mute.
    var microphoneMuteRequested: Bool { hooks.desiredMuted }

    /// Local sample gate closed (callers that already hold the audio lock: `close`, network hold).
    func closeSampleGate() {
        capture.closeSampleGate()
    }

    /// `inputRouteLost()` (`StreamReceiver.kt:1342-1356`): callbacks and worker; never HTTP or native disposal.
    /// Non-Bluetooth, or Bluetooth before the first applied control → immediate full stop (`input_route_changed`);
    /// established Bluetooth session → gates closed, duplex output held, `recovery.request(now)`, worker woken.
    /// `MicrophoneRouting`'s `lost` closure may point here or at `SessionController.inputRouteLost()` (same algorithm).
    func inputRouteLost() {
        if !selection.isBluetooth || hooks.appliedMuted == nil {
            stopForInputRouteChange(MicrophoneStatusText.Messages.inputRouteChanged)
            return
        }
        let requested: Bool = hooks.withAudioLock {
            if hooks.closed { return false }
            capture.closeSampleGate()
            if duplex { hooks.holdOutputForHeadset() }
            _ = recovery.request(nowMs: hooks.nowMs())
            return true
        }
        if requested { hooks.notifyControl() }
    }

    /// `onWebRtcAudioTrackStop` in Bluetooth duplex (`StreamReceiver.kt:419-425`, table): playout stopped while a
    /// microphone control was applied → `inputRouteLost()`. iOS never stops playout for restoration, so there is no
    /// "stopped by restoration" exception.
    func playoutStopped() {
        guard verifiesHeadsetOutput, hooks.appliedMuted != nil, !hooks.closed else { return }
        inputRouteLost()
    }

    // MARK: - Worker: status loop

    /// The status loop's microphone block **without** its catch (`StreamReceiver.kt:565-593`); the caller runs it only
    /// while network audio is not held and applies the catch itself (`retrySignaling(error, controlStartedAt)` false →
    /// rethrow/fail; else hold, `suspendForNetwork()`). Order: route health → `apply` (a Bluetooth
    /// `MicrophoneRouteError` after the first applied control becomes `inputRouteLost()`) → probe check while unmuted →
    /// Bluetooth duplex output check → `restoreHeadset` while recovery is pending → keep-alive policy
    /// (`applyBackgroundPolicy`). Returns early when `hooks.closed`. Every exit publishes the actual retained capture
    /// (`publishCaptureRetained`).
    func loopStep(token: String) throws {
        defer { publishCaptureRetained() }
        if !recovery.pending() && !routing.healthy() { inputRouteLost() }
        if !recovery.pending() && !hooks.closed {
            do { try apply(token: token) } catch let error as MicrophoneRouteError {
                guard selection.isBluetooth, hooks.appliedMuted != nil, error.problem != .leStereoUnavailable else {
                    throw error
                }
                inputRouteLost()
            }
        }
        if hooks.closed { return }
        if !recovery.pending() && hooks.appliedMuted == false && !probe.matches() { inputRouteLost() }
        if !recovery.pending() && verifiesHeadsetOutput && hooks.appliedMuted != nil && !outputWatch.matches() {
            inputRouteLost()
        }
        if recovery.pending() { try restoreHeadset(token: token) }
        if !hooks.closed { applyBackgroundPolicy() }
    }

    /// `applyMicrophoneControl()` (`StreamReceiver.kt:1234-1329`), step by step: skip unless `appliedMuted != desired
    /// || controlDirty`; publish pending; close gate; `probe.clear()`. Mute: mic-only → `routing.monitor(false)`;
    /// `capture.pause()` (a mic-only session whose scene is not `.active` keeps capture open with every gate closed
    /// while the Advanced keep-alive preference is on; `keptOpenForBackground`). Unmute: `routing.activate(5000)`,
    /// `routing.setPreferredInput`, `validateDuplexOutput`, checkpoint, wait (same deadline as the verification) for
    /// `capture.inputInitialization == .succeeded` (`.failed` → `fail(microphoneInitFailed, .microphoneInit)`),
    /// `capture.resume()` (`startFailed` → `fail(microphoneStartFailed, .microphoneStart)`; a background start refusal
    /// is the probe failure), verify for 2000/5000 ms in 20 ms polls (`probe.matches()` and, Bluetooth duplex,
    /// `outputWatch.matches()`) while not closed / not recovering / desired still unmuted; Mute during the probe wins
    /// (`capture.pause()`, return with applied unchanged); not verified or a watch fails → `capture.pause()`,
    /// `fail(MicrophoneRouteProblem.unverified.detail, .inputUnverified)`; `routing.monitor(true)`. Muted Bluetooth
    /// duplex: verify the headset output (5000 ms) else `fail(headsetOutputUnverified, .inputUnverified)`;
    /// `routing.monitor(true)`. Then `host.setHostMicrophoneGate(token, muted, nil)` (configured LAN/rendezvous request
    /// budgets); unmute: re-verify (else `inputRouteLost()`), open the gate under the audio lock only if `!closed &&
    /// !networkHeld && !recovery.pending && !desired` (+ Bluetooth duplex `verifyOutputForHeadset()`); muted Bluetooth
    /// duplex: output/health re-check (else `inputRouteLost()`), then `verifyOutputForHeadset()` under the lock.
    /// Finally `appliedMuted = muted`, `controlDirty = false`, `onMicrophoneSelection(routing.currentSelection())`,
    /// `onMicrophoneState(desired, pending: false)`. The retained capture is published when a change starts (so an
    /// Unmute withdraws "kept open" before any gate opens) and on every exit.
    func apply(token: String) throws {
        let muted = hooks.desiredMuted
        guard hooks.appliedMuted != muted || hooks.controlDirty else { return }
        defer { publishCaptureRetained() }
        hooks.onMicrophoneState(muted, pending: true)
        capture.closeSampleGate()
        probe.clear()
        publishCaptureRetained()
        if muted {
            if !duplex { routing.monitor(false) }
            if mutedBackgroundCaptureAllowed {
                keptOpenForBackground = capture.captureActive
            } else {
                capture.pause()
                keptOpenForBackground = false
            }
        } else {
            let port = try routing.activate(timeoutMs: Timing.unmuteActivationMs, cancelled: { self.hooks.closed })
            try routing.setPreferredInput(port)
            if duplex { try routing.validateDuplexOutput() }
            try hooks.checkpoint()
            let started = hooks.nowMs()
            let budget = selection.isBluetooth ? Timing.bluetoothVerificationMs : Timing.verificationMs
            while capture.inputInitialization == .pending || capture.inputInitialization == .notRequested {
                if hooks.closed || recovery.pending() || hooks.desiredMuted { return }
                if hooks.nowMs() &- started >= budget { break }
                try hooks.sleep(ms: Timing.pollMs)
            }
            guard capture.inputInitialization == .succeeded else {
                hooks.fail(MicrophoneStatusText.Messages.microphoneInitFailed, .microphoneInit)
                return
            }
            do { try capture.resume() } catch {
                hooks.fail(MicrophoneStatusText.Messages.microphoneStartFailed, .microphoneStart)
                return
            }
            keptOpenForBackground = false
            while !hooks.closed && !recovery.pending() && !hooks.desiredMuted
                && !verifiedInputAndOutput() && hooks.nowMs() &- started < budget
            {
                try hooks.sleep(ms: Timing.pollMs)
            }
            if hooks.closed || recovery.pending() { return }
            if hooks.desiredMuted {
                capture.pause()
                return
            }
            if !verifiedInputAndOutput()
                || !probe.watch(invalid: { [weak self] in self?.inputRouteLost() })
                || (verifiesHeadsetOutput && !outputWatch.watch(invalid: { [weak self] in self?.inputRouteLost() }))
            {
                capture.pause()
                hooks.fail(MicrophoneRouteProblem.unverified.detail, .inputUnverified)
                return
            }
            routing.monitor(true)
        }
        if muted && verifiesHeadsetOutput {
            let started = hooks.nowMs()
            while !hooks.closed && !recovery.pending() && hooks.desiredMuted && !outputWatch.matches()
                && hooks.nowMs() &- started < Timing.mutedHeadsetOutputMs
            {
                try hooks.sleep(ms: Timing.pollMs)
            }
            if hooks.closed || recovery.pending() || !hooks.desiredMuted { return }
            guard outputWatch.matches(), outputWatch.watch(invalid: { [weak self] in self?.inputRouteLost() }) else {
                hooks.fail(MicrophoneStatusText.Messages.headsetOutputUnverified, .inputUnverified)
                return
            }
            routing.monitor(true)
        }
        if hooks.closed || hooks.networkHeld || recovery.pending() { return }
        try host.setHostMicrophoneGate(token: token, muted: muted, timeoutMs: nil)
        if hooks.closed || recovery.pending() { return }
        if !muted && !hooks.desiredMuted {
            guard verifiedInputAndOutput() else {
                inputRouteLost()
                return
            }
            let captureEnabled: Bool = hooks.withAudioLock {
                if !hooks.closed && !hooks.networkHeld && !recovery.pending() && !hooks.desiredMuted {
                    capture.openSampleGate()
                    if verifiesHeadsetOutput { hooks.verifyOutputForHeadset() }
                    return true
                }
                return false
            }
            if captureEnabled { hooks.onCaptureEnabled() }
        }
        if muted && verifiesHeadsetOutput {
            guard outputWatch.matches(), routing.healthy() else {
                inputRouteLost()
                return
            }
            hooks.withAudioLock {
                if !hooks.closed && !hooks.networkHeld && !recovery.pending() && hooks.desiredMuted {
                    hooks.verifyOutputForHeadset()
                }
            }
        }
        hooks.appliedMuted = muted
        hooks.controlDirty = false
        hooks.onMicrophoneSelection(routing.currentSelection())
        hooks.onMicrophoneState(hooks.desiredMuted, pending: hooks.desiredMuted != muted)
    }

    private func verifiedInputAndOutput() -> Bool {
        probe.matches() && (!verifiesHeadsetOutput || outputWatch.matches())
    }

    /// `restoreHeadset()` (`StreamReceiver.kt:1363-1505`), one 20 ms-cadence step while `recovery.pending()`: expiry of
    /// the configured window (`recovery.limitMs`, Advanced, default 20 s) →
    /// `stopForInputRouteChange(headsetNotRestored(seconds:))`; first step of an episode → `.routeRecovering` phase,
    /// `Messages.restoringHeadset(playback:seconds:)`, clear probe/watch, monitor off, gate closed, capture paused,
    /// restoration fields reset; host gate muted once (`clamp(remaining, 1, 2000)`, `appliedMuted = true`); report the
    /// user's mute; endpoint check + `recovery.observe`; reselection budget; `routing.restoreInput(reselect:)` (throw →
    /// `stopForInputRouteChange(headsetNotReselected)`); preferred input on a new uid; gated probe when unmuted;
    /// verification (`Check.waitingVerifiedMicrophone` / `.waitingVerifiedOutput`); watches; `routing.monitor(duplex ||
    /// !muted)`; unmute → host gate open (clamped); completion under the audio lock (`recovery.complete(ticket, now)`,
    /// `appliedMuted`, `controlDirty = false`, gate open when unmuted and not held, duplex `verifyOutputForHeadset()`);
    /// success → selection/state/ `Messages.headsetRestored(muted:)`, else `stopProbe()`. iOS: no route release, no SCO
    /// profile request; playout keeps running silenced so the app stays alive. The first step also ends a keep-alive:
    /// when it pauses a running capture (kept open while muted, or the user's unmuted capture), one background start
    /// may run again after the episode completes muted (`applyBackgroundPolicy`), so the outcome never depends on
    /// earlier starts in the same background stay; a start refused before recovery (no capture running at the loss)
    /// stays refused.
    func restoreHeadset(token: String) throws {
        defer { publishCaptureRetained() }
        guard let ticket = recovery.current() else { return }
        func remaining() -> Int64 { recovery.remaining(nowMs: hooks.nowMs()) }
        func timeout() -> Int { Int(max(1, min(remaining(), Timing.restorationGateMaxMs))) }
        if remaining() == 0 {
            stopForInputRouteChange(MicrophoneStatusText.Messages.headsetNotRestored(seconds: recoverySeconds))
            return
        }
        if restoringEpisode != ticket.episode {
            hooks.onPhase(.routeRecovering)
            hooks.onStatus(MicrophoneStatusText.Messages.restoringHeadset(playback: duplex, seconds: recoverySeconds))
            probe.clear()
            outputWatch.clear()
            routing.monitor(false)
            capture.closeSampleGate()
            if capture.captureActive { backgroundStartAttempted = false }
            keptOpenForBackground = false
            capture.pause()
            restorationRecording = false
            restorationInputUID = nil
            restorationHostMuted = false
            restorationReportedMute = nil
            restoringEpisode = ticket.episode
        }
        if hooks.closed { return }
        if hooks.desiredMuted && restorationRecording {
            probe.clear()
            capture.pause()
            restorationRecording = false
        }
        if !restorationHostMuted {
            try host.setHostMicrophoneGate(token: token, muted: true, timeoutMs: timeout())
            restorationHostMuted = true
            hooks.appliedMuted = true
        }
        if hooks.closed || remaining() == 0 { return }
        let requested = hooks.desiredMuted
        if restorationReportedMute != requested {
            restorationReportedMute = requested
            hooks.onMicrophoneState(requested, pending: false)
        }
        let available = routing.recoveryEndpointAvailable()
        recovery.observe(routing.recoveryCheck())
        let reselect = recovery.reselectionDue(nowMs: hooks.nowMs(), endpointAvailable: available)
        if !available {
            stopProbe()
            return
        }
        if reselect && restorationRecording { stopProbe() }
        let chosen: AudioPortDescriptor?
        do { chosen = try routing.restoreInput(reselect: reselect) } catch {
            stopForInputRouteChange(MicrophoneStatusText.Messages.headsetNotReselected)
            return
        }
        guard let chosen else {
            recovery.observe(routing.recoveryCheck())
            stopProbe()
            return
        }
        recovery.observe(routing.recoveryCheck())
        if chosen.uid != restorationInputUID {
            if restorationRecording {
                capture.pause()
                restorationRecording = false
            }
            try routing.setPreferredInput(chosen)
            restorationInputUID = chosen.uid
        }
        let muted = hooks.desiredMuted
        if muted && restorationRecording {
            probe.clear()
            capture.pause()
            restorationRecording = false
        } else if !muted && !restorationRecording {
            try capture.resume()
            restorationRecording = true
        }
        func verified() -> Bool { (muted || probe.matches()) && (!duplex || outputWatch.matches()) }
        if hooks.closed || remaining() == 0 { return }
        if !verified() {
            recovery.observe(
                !muted && !probe.matches()
                    ? HeadsetRecovery.Check.waitingVerifiedMicrophone : HeadsetRecovery.Check.waitingVerifiedOutput)
            return
        }
        if (!muted && !probe.watch(invalid: { [weak self] in self?.inputRouteLost() }))
            || (duplex && !outputWatch.watch(invalid: { [weak self] in self?.inputRouteLost() }))
        {
            stopProbe()
            return
        }
        routing.monitor(duplex || !muted)
        if !muted {
            if hooks.networkHeld {
                stopProbe()
                return
            }
            try host.setHostMicrophoneGate(token: token, muted: false, timeoutMs: timeout())
            restorationHostMuted = false
        }
        let restored: Bool = hooks.withAudioLock {
            guard !hooks.closed, !hooks.networkHeld, hooks.desiredMuted == muted, verified(), routing.healthy(),
                recovery.complete(ticket, nowMs: hooks.nowMs())
            else { return false }
            hooks.appliedMuted = muted
            hooks.controlDirty = false
            if !muted { capture.openSampleGate() }
            if duplex { hooks.verifyOutputForHeadset() }
            return true
        }
        if restored {
            if !muted { hooks.onCaptureEnabled() }
            hooks.onMicrophoneSelection(routing.currentSelection())
            hooks.onMicrophoneState(hooks.desiredMuted, pending: false)
            hooks.onStatus(MicrophoneStatusText.Messages.headsetRestored(muted: muted))
        } else {
            stopProbe()
        }
    }

    private func stopProbe() {
        probe.clear()
        outputWatch.clear()
        routing.monitor(false)
        capture.closeSampleGate()
        if restorationRecording { capture.pause() }
        restorationRecording = false
        restorationInputUID = nil
    }

    // MARK: - Worker: network hold

    /// `suspendNetworkAudio()` microphone part (once per hold, `StreamReceiver.kt:1530-1546`): gate closed (under the
    /// audio lock), `probe.clear()`, `outputWatch.clear()`, capture paused — except mic-only while the scene is not
    /// `.active` (gates closed, capture left running so the audio unit keeps iOS from suspending the app and recovery
    /// can finish) when the user has not muted or the Advanced keep-alive preference is on — then `appliedMuted = true`
    /// and `onMicrophoneState(desired, pending: false)`. A later Mute during the hold with the preference off stops
    /// that capture in `applyBackgroundPolicy()`. This is the whole microphone part:
    /// `SessionController.suspendMicrophoneForNetwork()` calls only this while the control exists.
    func suspendForNetwork() {
        hooks.withAudioLock { capture.closeSampleGate() }
        probe.clear()
        outputWatch.clear()
        if mode == .microphone && !hooks.applicationActive
            && (!hooks.desiredMuted || hooks.keepMicrophoneActiveWhileMuted)
        {
            keptOpenForBackground = capture.captureActive
        } else {
            capture.pause()
            keptOpenForBackground = false
        }
        let desired: Bool = hooks.withAudioLock {
            hooks.appliedMuted = true
            return hooks.desiredMuted
        }
        hooks.onMicrophoneState(desired, pending: false)
        publishCaptureRetained()
    }

    /// `releaseNetworkAudio()` microphone part: `controlDirty = true` (the host re-muted the cable on
    /// restart; the next loop re-runs the full mute/unmute flow and `/microphone`).
    func markDirtyAfterNetworkRelease() {
        hooks.controlDirty = true
    }

    /// Background keep-alive with the Advanced "Keep microphone active while muted in background" preference (read
    /// live, so a local Save applies at the next step; a Windows edit is held until the next explicit Connect,
    /// `AppEnvironment.keepMicrophoneActiveWhileMuted`), evaluated every loop iteration by `loopStep` and, while
    /// network audio is held, by the status loop. Mic-only, applied and desired muted, not recovering:
    /// - scene `.active` again while kept open → `capture.pause()`, flag cleared;
    /// - scene not `.active`, preference off → any muted capture is paused (also while held), so iOS may
    ///   suspend the session; nothing is started;
    /// - scene not `.active`, preference on, not held, capture paused → `capture.resume()` with every gate
    /// closed (host cable stays muted, no `/microphone` traffic), `keptOpenForBackground = true`,
    /// `onStatus(Messages.mutedKeptOpen)`. Stop, a return to `.active` or the preference turning off while the unit
    /// started pauses it again at once, so no late capture outlives them. A refused background start
    /// (`cannotStartRecording`, or `CaptureError`) is recorded once and not retried in a loop; `microphone.state` stays
    /// `muted` (never `running` while gated). The preference never opens a gate, starts a session or replaces
    /// microphone permission and consent. A headset recovery that completes muted in the background gets one new start
    /// (its first step paused the kept-open capture). Every exit publishes the actual retained capture.
    func applyBackgroundPolicy() {
        defer { publishCaptureRetained() }
        if hooks.applicationActive { backgroundStartAttempted = false }
        guard mode == .microphone, hooks.appliedMuted == true, hooks.desiredMuted, !hooks.closed, !recovery.pending()
        else { return }
        if hooks.applicationActive {
            if keptOpenForBackground { stopMutedBackgroundCapture() }
            return
        }
        guard hooks.keepMicrophoneActiveWhileMuted else {
            if keptOpenForBackground || capture.captureActive { stopMutedBackgroundCapture() }
            return
        }
        if hooks.networkHeld { return }
        if !capture.captureActive && !backgroundStartAttempted {
            backgroundStartAttempted = true
            capture.closeSampleGate()
            try? capture.resume()
            if hooks.closed || hooks.applicationActive || !hooks.keepMicrophoneActiveWhileMuted {
                stopMutedBackgroundCapture()
                return
            }
            keptOpenForBackground = capture.captureActive
            if keptOpenForBackground { hooks.onStatus(MicrophoneStatusText.Messages.mutedKeptOpen) }
        } else if capture.captureActive {
            keptOpenForBackground = true
        }
    }

    /// Pauses a muted keep-alive capture (no-op when capture is not running) and clears the flag.
    private func stopMutedBackgroundCapture() {
        capture.pause()
        keptOpenForBackground = false
    }

    /// Whether background keep-alive last kept or started a muted mic-only capture (tests). Reports and Now Playing use
    /// `captureRetainedWhileMuted`, the live state.
    var keepsCaptureOpenForBackground: Bool { keptOpenForBackground }

    // MARK: - Reports

    /// `microphone.state` argument (`StreamReceiver.kt:710-713`).
    func reportState(networkHeld: Bool) -> String {
        MicrophoneSnapshot.reportState(
            networkHeld: networkHeld, recoveryPending: recovery.pending(),
            appliedMuted: hooks.appliedMuted, recordStarted: capture.captureActive)
    }

    /// The report's `microphone` object; `processing` only when the offer negotiated `microphone_processing_version ==
    /// 1`. A kept-open capture reports `muted` (applied mute wins), with `route_verified: true` while its live routed
    /// input matches the selection (`A/MicrophoneInput.kt:49`). An unmuted user's capture kept through a background
    /// network hold reports the same in the one report after the hold ends and before the next apply, whatever the
    /// keep-alive preference. Foreground and duplex Mute pause capture (`unavailable`, false) and a hold itself reports
    /// `waiting`, false. Diagnostics never open a gate.
    func snapshot(networkHeld: Bool, processing: MicrophoneProcessing?) -> MicrophoneSnapshot {
        probe.snapshot(state: reportState(networkHeld: networkHeld), selection: selection, processing: processing)
    }

    /// Copy-report lines for Bluetooth sessions (`StreamReceiver.kt:749-750`): `HeadsetRecovery.text()`
    /// and the identity line; empty otherwise. The terminal report replaces earlier lines starting with
    /// `Selected headset recovery:` / `Selected headset identity:` (`:796-800`).
    func copyReportLines() -> [String] {
        selection.isBluetooth ? [recovery.text(), routing.identityText()] : []
    }

    // MARK: - Worker: teardown

    /// `input_observers_close`: probe and output watch cleared (generation++). (app-session's pass-2
    /// note calls this `clearWatches()`.)
    func closeInputObservers() {
        probe.clear()
        outputWatch.clear()
    }

    /// `audio_recording_stop`: `capture.pause()` (no-op when capture never ran) and the input
    /// initialisation discarded (late completions ignored); a retained capture is reported ended.
    func stopRecording() {
        capture.pause()
        keptOpenForBackground = false
        capture.input.discard()
        publishCaptureRetained()
    }

    /// `microphone_route_close`: `routing.close()` (rethrows its cleanup failure after attempting every step) and the
    /// launch hygiene `setInputMuted(false)` in every case.
    func closeRoute() throws {
        defer { MicrophoneCapture.setApplicationInputMuted(false) }
        try routing.close()
    }

    // MARK: - Helpers

    /// `stopForInputRouteChange(detail)`: `fail(<detail> <stopped text> …, .inputRouteChanged)`.
    func stopForInputRouteChange(_ detail: String) {
        hooks.fail(
            MicrophoneStatusText.Messages.inputRouteStopped(detail: detail, playback: duplex),
            .inputRouteChanged)
    }
}

// MARK: - Collaborators

extension MicrophoneControl {
    /// What `SessionController` provides (`MicrophoneEngineHooks`synchronous). The first thirteen members are the
    /// spelling, already implemented by `SessionController.MicrophoneHooksBridge`; the next five give access to the
    /// worker state that lives in `SessionController` (design note: no second copy here); then the live Advanced
    /// keep-alive preference and the retained-capture notification (default: ignored).
    protocol Hooks: AnyObject {
        /// Kotlin `closed`.
        var closed: Bool { get }
        /// Kotlin `networkHeld`.
        var networkHeld: Bool { get }
        /// Kotlin `synchronized(audioLock)`; lock order `cancelLock → audioLock`. Bodies never throw.
        func withAudioLock<T>(_ body: () -> T) -> T
        /// `fail(message, code)`: first failure wins, then `close(.failure)`.
        func fail(_ message: String, _ code: SessionFailure)
        /// `onPhase` (posted to main by the session).
        func onPhase(_ p: SessionPhase)
        /// `onStatus`.
        func onStatus(_ s: String)
        /// `onMicrophoneState(muted, pending)`.
        func onMicrophoneState(_ muted: Bool, pending: Bool)
        /// `onMicrophoneSelection(selection)`.
        func onMicrophoneSelection(_ s: MicrophoneSelection)
        /// Bluetooth duplex: `outputGate.hold()` + speaker mute.
        func holdOutputForHeadset()
        /// Bluetooth duplex: `outputGate.verified()` + `applySpeakerMute()`.
        func verifyOutputForHeadset()
        /// `SessionWorkerWait.checkpoint()` (throws `SessionStopped`).
        func checkpoint() throws
        /// Cancellable worker sleep (throws `SessionStopped` when closed).
        func sleep(ms: Int) throws
        /// `MonotonicClock.nowMs()`.
        func nowMs() -> Int64

        /// Kotlin `microphoneDesiredMuted` (`SessionController.microphoneDesiredMuted.value`).
        var desiredMuted: Bool { get set }
        /// Kotlin `microphoneAppliedMuted` (`nil` until the first applied control).
        var appliedMuted: Bool? { get set }
        /// Kotlin `microphoneControlDirty` (worker).
        var controlDirty: Bool { get set }
        /// scene state (`SessionController.applicationActiveFlag`, set by `setApplicationActive`).
        var applicationActive: Bool { get }
        /// `controlSignal.notify()`.
        func notifyControl()

        /// Advanced "Keep microphone active while muted in background" (`AdvancedAudioPreferences`), read live
        /// on the worker so a saved change applies at the session's next background/foreground step. It only
        /// decides whether a muted microphone-only capture may keep running with every gate closed.
        var keepMicrophoneActiveWhileMuted: Bool { get }

        /// `captureRetainedWhileMuted` changed (worker, de-duplicated). The session posts it to main for Now
        /// Playing; it carries no identifier.
        func onCaptureRetainedWhileMuted(_ retained: Bool)

        /// Verified unmuted capture opened its sample gate. Called outside the audio lock; never for desired
        /// state alone, a failed/superseded Unmute, or a muted background keep-alive.
        func onCaptureEnabled()
    }

    /// `setHostMicrophoneGate(token, muted, timeout)`, implemented by `SessionController`: `POST /microphone
    /// {"version":3,"muted":…}` with the remote raise; response check `ok == true && muted == requested`; 410/500 →
    /// `fail(hostMicrophoneGateFailed, .hostMicrophoneGate)` then rethrow. `timeoutMs == nil` is the ordinary control
    /// (`LAN_REQUEST` on LAN, `REMOTE_REQUEST` on rendezvous); headset restoration passes `clamp(remaining, 1, 2000)`
    /// (`StreamReceiver.kt:1402,1784-1789`).
    protocol HostGate: AnyObject {
        func setHostMicrophoneGate(token: String, muted: Bool, timeoutMs: Int?) throws
    }
}

extension MicrophoneControl.Hooks {
    /// Hosts that show no retained-capture state (test fakes) ignore it.
    func onCaptureRetainedWhileMuted(_ retained: Bool) {}
    func onCaptureEnabled() {}
}

/// name for `MicrophoneControl.Hooks`.
typealias MicrophoneEngineHooks = MicrophoneControl.Hooks
/// name for `MicrophoneControl.HostGate`.
typealias MicrophoneHostGate = MicrophoneControl.HostGate
