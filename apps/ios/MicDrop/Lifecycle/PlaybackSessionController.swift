// Playback session owner: the iOS port of `PlaybackService`.
//
// Main-actor, app-lifetime object (one per process). It owns the pure `SessionLifecycle`, at most one `StreamReceiving`
// worker (`SessionController`), the playback `AudioSessionArbiter` activation, the background lease, the 5-minute
// interruption deadline, the media-Play saved-link lookup and the resume ticket. Media controls, interruptions and
// route changes reach it through `SessionCoordinator`.
//
// Invariants: one native audio owner at a time (the worker's `AudioSessionOwner` permit; `beginConnection` never runs
// while `receiver != nil`); local mute is immediate (`receiver.close`), deactivation is deferred to `releaseTransport`
// (after `onEnded`); every callback/command/timer is checked against the per-session token; Stop wins; media controls
// never start a microphone; metadata never connects.
//
// Observation: `@Observable` for SwiftUI plus `observe(_:)`, which delivers the current view immediately and every
// later `publish()` synchronously.

import Foundation
import MicDropCore
import Observation

@MainActor
@Observable
final class PlaybackSessionController {
    /// Builds the worker for one connection attempt (production: `SessionController`).
    typealias ReceiverFactory = @MainActor (SessionConfiguration, SessionCallbacks) throws -> any StreamReceiving
    /// Result of one arbiter activation (`audioPrepared`).
    typealias AudioActivation = Result<AudioSessionArbiter.Activation, AudioSessionArbiter.ActivationError>
    /// `arbiter.prepare(plan)` with the completion on the main actor.
    typealias AudioPreparation =
        @MainActor (_ plan: AudioSessionPlan, _ completion: @escaping @MainActor (AudioActivation) -> Void) -> Void

    /// Collaborators (tests substitute fakes). Production wiring: see `Dependencies.live`.
    struct Dependencies {
        /// Releases activations (`releaseTransport`) and, unless `prepareAudio` is given, takes them.
        var arbiter: AudioSessionArbiter
        /// Activation of one connection attempt: production `arbiter.prepare`; tests substitute an
        /// activation that never touches `RTCAudioSession` (its release through the arbiter is then a no-op).
        var prepareAudio: AudioPreparation
        var preferences: AudioPreferencesStore
        var pausedPlayback: PausedPlaybackStore
        /// Process-wide "Recent controls" log.
        var controlLog: ControlEventLog
        /// Sleep-inclusive monotonic clock for the 5-minute interruption deadline.
        var clock: any MonotonicClock
        var makeReceiver: ReceiverFactory
        /// `OutputRouteProviding.available(_:)` (`OutputChoices`).
        var outputAvailable: @MainActor (OutputSelection) -> Bool
        /// `OutputRouteProviding.refresh(_:)`; nil = unavailable or not pinnable (iOS addition: a permanent PHONE pin
        /// is refused while `speakerPinnable == false`).
        var outputRefresh: @MainActor (OutputSelection) -> OutputSelection?
        /// Media-Play lookup (`loadSaved`): waits until the saved store is not working (timeout 10 000 ms → error),
        /// then returns `connection()` (nil = none/expired/forgotten). Production:
        /// `SavedConnectionStore.shared.awaitLoaded(timeout: .seconds(10))`.
        var loadSavedLink: @MainActor () async throws -> String?
        /// `SavedConnections.remember(text)` at the first PLAYING.
        var rememberLink: @MainActor (String) -> Void
        /// Lease factory; production `BackgroundExecutionLease(name:onExpire:)`.
        var makeLease:
            @MainActor (_ name: String, _ onExpire: @escaping @MainActor () -> Void) -> BackgroundExecutionLease
        /// `AudioSessionPlan.playback(playAndRecordFallback: true)` only on fallback.
        var playbackPlan: AudioSessionPlan
        /// Advanced audio settings read at Connect (the Bluetooth route recovery window); production
        /// `AdvancedAudioPreferencesStore.shared.load()`, tests inject values.
        var advancedAudio: @MainActor () -> AdvancedAudioPreferences

        init(
            arbiter: AudioSessionArbiter,
            preferences: AudioPreferencesStore,
            pausedPlayback: PausedPlaybackStore,
            controlLog: ControlEventLog,
            clock: any MonotonicClock,
            makeReceiver: @escaping ReceiverFactory,
            outputAvailable: @escaping @MainActor (OutputSelection) -> Bool,
            outputRefresh: @escaping @MainActor (OutputSelection) -> OutputSelection?,
            loadSavedLink: @escaping @MainActor () async throws -> String?,
            rememberLink: @escaping @MainActor (String) -> Void,
            makeLease:
                @escaping @MainActor (_ name: String, _ onExpire: @escaping @MainActor () -> Void) ->
                BackgroundExecutionLease = { name, onExpire in BackgroundExecutionLease(name: name, onExpire: onExpire)
                },
            playbackPlan: AudioSessionPlan = .playback(),
            prepareAudio: AudioPreparation? = nil,
            advancedAudio: @escaping @MainActor () -> AdvancedAudioPreferences = {
                AdvancedAudioPreferencesStore.shared.load()
            }
        ) {
            self.arbiter = arbiter
            if let prepareAudio {
                self.prepareAudio = prepareAudio
            } else {
                self.prepareAudio = { plan, completion in arbiter.prepare(plan, completion: completion) }
            }
            self.preferences = preferences
            self.pausedPlayback = pausedPlayback
            self.controlLog = controlLog
            self.clock = clock
            self.makeReceiver = makeReceiver
            self.outputAvailable = outputAvailable
            self.outputRefresh = outputRefresh
            self.loadSavedLink = loadSavedLink
            self.rememberLink = rememberLink
            self.makeLease = makeLease
            self.playbackPlan = playbackPlan
            self.advancedAudio = advancedAudio
        }

        /// Production wiring: `SessionController(configuration, callbacks:, dependencies:)` workers whose per-link
        /// collaborators come from `sessionDependencies` (transport and TLS depend on the link), the shared stores,
        /// `SavedConnectionStore.shared` and the given route provider closures (`OutputChoices`). Matches
        /// `MicrophoneSessionController.Dependencies.live(...)`; the composition root may also build
        /// `Dependencies(...)` directly.
        static func live(
            sessionDependencies: @escaping @MainActor (SessionConfiguration) throws -> SessionDependencies,
            arbiter: AudioSessionArbiter = .shared,
            controlLog: ControlEventLog,
            clock: any MonotonicClock,
            outputAvailable: @escaping @MainActor (OutputSelection) -> Bool,
            outputRefresh: @escaping @MainActor (OutputSelection) -> OutputSelection?
        ) -> Dependencies {
            Dependencies(
                arbiter: arbiter,
                preferences: .shared,
                pausedPlayback: .shared,
                controlLog: controlLog,
                clock: clock,
                makeReceiver: { configuration, callbacks in
                    SessionController(
                        configuration, callbacks: callbacks,
                        dependencies: try sessionDependencies(configuration))
                },
                outputAvailable: outputAvailable,
                outputRefresh: outputRefresh,
                loadSavedLink: { try await SavedConnectionStore.shared.awaitLoaded(timeout: .seconds(10)) },
                rememberLink: { SavedConnectionStore.shared.remember($0) })
        }
    }

    /// One connection waiting for the arbiter's activation (Android `PendingConnection`,
    /// `PlaybackService.kt:30-54`).
    private struct PendingConnection {
        let id: String
        let text: String
        let fast: Bool
        let baseline: OutputSnapshot?
        let keepFocus: Bool
        let reconnect: Bool
        /// An intentional Play/focus resume cause (`SessionConfiguration.resume`).
        let resume: SessionResume.Reason?
    }

    /// Media-Play lookup failure (destroyed, ticket replaced, link nil or digest mismatch).
    private struct LookupRejected: Error {}

    // MARK: - Constants

    /// Start (activation) timeout, `PlaybackService.kt:182`.
    static let startTimeoutMs = 10_000
    /// Transient interruption resume window, `PlaybackService.kt:347`.
    static let interruptionWindowMs: Int64 = 300_000

    // MARK: - Published state

    /// `shownView()` of the last `publish()`.
    private(set) var view: SessionView = SessionView()

    /// Set by `SessionCoordinator`: `MicrophoneSessionController.view.ownsSession` (a microphone/duplex session
    /// excludes playback; media Play is ignored).
    @ObservationIgnored var microphoneOwnsSession: @MainActor () -> Bool = { false }

    // MARK: - Private state

    private let dependencies: Dependencies
    @ObservationIgnored private var lifecycle = SessionLifecycle()
    @ObservationIgnored private var pending: PendingConnection?
    @ObservationIgnored private var receiver: (any StreamReceiving)?
    /// Trimmed link of the live/retained session.
    @ObservationIgnored private var link: String?
    @ObservationIgnored private var fast = true
    @ObservationIgnored private var resumable = false
    @ObservationIgnored private var outputEnabled: Bool
    @ObservationIgnored private var outputSelection: OutputSelection
    @ObservationIgnored private var outputPause: OutputPause?
    /// The effective Bluetooth route recovery window of the latest configured session (pause text).
    @ObservationIgnored private var bluetoothRecoveryMs: Int64?
    @ObservationIgnored private var protectedDefaultSpeaker = false
    /// Route `.oldDeviceUnavailable` is handled only between `startTransport` and `releaseTransport`.
    @ObservationIgnored private var noisyArmed = false
    /// The arbiter activation of this controller (`audioActive`).
    @ObservationIgnored private var activation: AudioSessionArbiter.Activation?
    /// Token whose first PLAYING was already handled (Android `remembered`).
    @ObservationIgnored private var rememberedToken: String?
    @ObservationIgnored private var playLookup: UUID?
    @ObservationIgnored private var lookups: [UUID: Task<Void, Never>] = [:]
    /// Monotonic deadline of the automatic resume.
    @ObservationIgnored private var interruptionDeadlineMs: Int64?
    @ObservationIgnored private var interruptionTimer: DispatchWorkItem?
    @ObservationIgnored private var startTimeout: DispatchWorkItem?
    @ObservationIgnored private var lease: BackgroundExecutionLease?
    /// Android `destroyed`.
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var observers: [(id: UInt64, callback: (SessionView) -> Void)] = []
    @ObservationIgnored private var nextObserverID: UInt64 = 0

    // MARK: - Creation

    /// `onCreate`: `outputEnabled` from preferences; `preferences.restoredOutputSelection()`: the iOS
    /// remembered pin (`RememberedAudioDevices`) while `preferredOutputKind` still names its kind, else
    /// `OutputSelection.restored(preferredOutputKind)`, so an external kind without its identity must be
    /// reselected after process death. A restored pin passes the same Connect preflight and route verification
    /// as a fresh choice and never plays elsewhere when its device is missing; restores PAUSED from a stored
    /// resume ticket (the paused card survives process death); publishes. Never connects.
    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        let preferences = dependencies.preferences.load()
        self.outputEnabled = preferences.outputEnabled
        self.outputSelection = dependencies.preferences.restoredOutputSelection()
        if let ticket = dependencies.pausedPlayback.ticket() {
            lifecycle.restorePause(ticket.id)
            fast = ticket.fast
        }
        publish()
    }

    // MARK: - Observation

    /// Registers `observer`, calls it immediately with `view`, then synchronously from every
    /// `publish()` until the token is cancelled or released. `ObservationToken` is app-ui's
    /// main-actor token (`UI/MainViewServices.swift`); this signature satisfies 10's
    /// `PlaybackSessionControlling.observe(_:)`.
    func observe(_ observer: @escaping (SessionView) -> Void) -> ObservationToken {
        nextObserverID += 1
        let id = nextObserverID
        observers.append((id: id, callback: observer))
        let token = ObservationToken { [weak self] in
            self?.removeObserver(id)
        }
        observer(view)
        return token
    }

    private func removeObserver(_ id: UInt64) {
        observers.removeAll { $0.id == id }
    }

    // MARK: - Read-only state for the coordinator

    /// Current session token (nil when IDLE/ENDED).
    var token: String? { lifecycle.token }

    /// Inputs of the playback Now Playing card.
    var nowPlayingState: NowPlayingPublisher.PlaybackState {
        NowPlayingPublisher.PlaybackState(
            view: view, token: lifecycle.token,
            automatic: lifecycle.resumeOnFocus, queued: lifecycle.playAfterPause)
    }

    /// `MediaPresentation.of(view:automatic:queued:)` of the current state (toggle command).
    var presentation: MediaPresentation {
        MediaPresentation.of(view: view, automatic: lifecycle.resumeOnFocus, queued: lifecycle.playAfterPause)
    }

    // MARK: - App-facing API (`PlaybackSessionControlling`)

    /// `connectFromActivity`: only when not busy (allowed from PAUSED: Reconnect simply begins a new connection and
    /// `beginConnection` clears the old ticket). Resets the output pause and the speaker protection, records
    /// `app_connect`, `beginConnection(keepFocus: false)`. Satisfies `connect(...) throws` requirement (it never
    /// throws).
    func connect(
        text: String, fastRecovery: Bool, baseline: OutputSnapshot?, reconnect: Bool,
        outputEnabled: Bool, outputSelection: OutputSelection
    ) {
        _ = expireInterruptionIfNeeded()
        guard !terminating, !lifecycle.view.busy else { return }
        outputPause = nil
        protectedDefaultSpeaker = false
        record(ControlEventLog.Event.appConnect)
        beginConnection(
            text, fastRecovery: fastRecovery, baseline: baseline, keepFocus: false,
            reconnect: reconnect, enabledOutput: outputEnabled, selectedOutput: outputSelection)
    }

    /// `pauseFromActivity` / UI "Pause playback" / "Keep paused" / remote pause: `pauseSession(id, automatic: false,
    /// .pause)`.
    func pause() {
        _ = expireInterruptionIfNeeded()
        guard let id = lifecycle.token else { return }
        pauseSession(id, automatic: false, reason: .pause)
    }

    /// `stopFromActivity` / remote stop: `stopSession(id, .user)`.
    func stop() {
        _ = expireInterruptionIfNeeded()
        guard let id = lifecycle.token else { return }
        stopSession(id, reason: .user)
    }

    /// Media Play: never while the microphone owns audio; PAUSING → queue once; INTERRUPTED → user resume; PAUSED → one
    /// saved-link lookup (s) that must match the ticket, then `beginConnection(reconnect: true, resuming: true)`
    /// (`PlaybackService.kt:325`); failure → `stopSession(.failure)`; other phases ignore.
    func playFromMediaControls() {
        _ = expireInterruptionIfNeeded()
        guard !terminating, !microphoneOwnsSession(), let id = lifecycle.token else { return }
        record(ControlEventLog.Event.mediaPlay)
        if lifecycle.queuePlay(id) {
            cancelInterruptionDeadline()
            publish()
            return
        }
        if lifecycle.view.phase == .interrupted {
            resumeInterrupted(userRequested: true)
            return
        }
        guard lifecycle.view.phase == .paused else { return }
        guard let ticket = dependencies.pausedPlayback.ticket() else {
            stopSession(id, reason: .failure)
            return
        }
        guard playLookup == nil else { return }
        let lookupID = UUID()
        playLookup = lookupID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await self.loadSaved(ticket)
                self.lookupFinished(lookupID)
                guard !self.terminating, self.lifecycle.token == id, self.lifecycle.view.phase == .paused else {
                    return
                }
                self.beginConnection(
                    text, fastRecovery: ticket.fast, baseline: nil, keepFocus: false, reconnect: true,
                    resume: .manual)
            } catch {
                self.lookupFinished(lookupID)
                guard !(error is CancellationError), !Task.isCancelled, !self.terminating,
                    self.lifecycle.token == id, self.lifecycle.view.phase == .paused
                else { return }
                self.stopSession(id, reason: .failure)
            }
        }
        lookups[lookupID] = task
        publish()
    }

    /// "Play desktop audio": requires `canSetOutput`; persists `outputEnabled`; forwards.
    func setOutputEnabled(_ enabled: Bool) {
        setOutputEnabled(enabled, saves: true)
    }

    /// `saves: false` (a Windows edit) changes only this session; the next Connect keeps the phone's saved value.
    private func setOutputEnabled(_ enabled: Bool, saves: Bool) {
        _ = expireInterruptionIfNeeded()
        guard !terminating, lifecycle.view.canSetOutput else { return }
        outputEnabled = enabled
        if saves {
            dependencies.preferences.update { previous in
                var next = previous
                next.outputEnabled = enabled
                return next
            }
        }
        receiver?.setOutputEnabled(enabled)
        publish()
    }

    /// Output choice: `phase.acceptsOutputChoice` (playing, recovering, routeRecovering, paused, interrupted — the UI's
    /// rule; iOS adds routeRecovering, reached while a selected output recovers or the default route is probed) and the
    /// provider refresh succeeds; PHONE clears the speaker protection; an explicit choice clears the output pause;
    /// persists the identity and `preferredOutputKind = preferenceKind` (`rememberOutput`); records
    /// `output_selected_<kind>`; forwards to the receiver, which keeps playback gated until the new route verifies
    /// (PAUSED: used by the next reconnect). A Windows `audio.output` choice takes this same path (`applyPhoneOutput`).
    func setOutputSelection(_ selection: OutputSelection) -> Bool {
        _ = expireInterruptionIfNeeded()
        guard !terminating, lifecycle.view.phase.acceptsOutputChoice,
            let refreshed = dependencies.outputRefresh(selection)
        else { return false }
        outputSelection = refreshed
        if selection.kind == .phone { protectedDefaultSpeaker = false }
        if selection.explicit { outputPause = nil }
        dependencies.preferences.rememberOutput(refreshed)
        record(ControlEventLog.Event.outputSelected(selection.kind))
        receiver?.setOutputSelection(refreshed)
        publish()
        return true
    }

    /// `outputActionToken()`: scopes output permission flows to this session.
    func outputActionToken() -> String? {
        guard !terminating, lifecycle.view.retained, lifecycle.view.phase != .stopping else { return nil }
        return lifecycle.token
    }

    // MARK: - Coordinator entry points

    /// Interruption `.began` (focus loss, row 1): busy → `focus_loss_transient` + `pauseSession(id, automatic: true,
    /// .focusTransient)`; PAUSED/ENDED/IDLE → ignore.
    func interruptionBegan() {
        _ = expireInterruptionIfNeeded()
        guard !terminating, lifecycle.view.busy, let id = lifecycle.token else { return }
        record(ControlEventLog.Event.focusLossTransient)
        pauseSession(id, automatic: true, reason: .focusTransient)
    }

    /// Interruption `.ended` (rows 3-5): with `.shouldResume` → `focus_gain` and resume if INTERRUPTED (else publish; a
    /// gain during PAUSING is remembered by `focusGained`); without it while armed in PAUSING/INTERRUPTED →
    /// `focus_loss_permanent` + `pauseSession(id, automatic: false, .focusPermanent)`; otherwise ignore.
    func interruptionEnded(shouldResume: Bool) {
        _ = expireInterruptionIfNeeded()
        guard !terminating else { return }
        if shouldResume {
            record(ControlEventLog.Event.focusGain)
            if lifecycle.focusGained() {
                resumeInterrupted(userRequested: false)
            } else {
                publish()
            }
            return
        }
        let armedPhases: Set<SessionPhase> = [.pausing, .interrupted]
        guard lifecycle.resumeOnFocus, armedPhases.contains(lifecycle.view.phase),
            let id = lifecycle.token
        else { return }
        record(ControlEventLog.Event.focusLossPermanent)
        pauseSession(id, automatic: false, reason: .focusPermanent)
    }

    /// Noisy route change, decision order 1-4: receiver verifies media output → `media_output_checking`; default
    /// routing while retained → protect the default speaker for the next session, `default_output_waiting`; PHONE →
    /// ignore; else unless an output switch is pending → `output_disconnected` + `stopSession(.output)`. Only while
    /// `noisyArmed`.
    func outputDeviceUnavailable() {
        _ = expireInterruptionIfNeeded()
        guard !terminating, noisyArmed else { return }
        if receiver?.mediaOutputBecomingNoisy() == true {
            record(ControlEventLog.Event.mediaOutputChecking)
            return
        }
        if !outputSelection.explicit && lifecycle.view.retained {
            protectedDefaultSpeaker = true
            receiver?.mediaOutputBecomingNoisy()
            record(ControlEventLog.Event.defaultOutputWaiting)
            return
        }
        if outputSelection.kind == .phone { return }
        if receiver?.outputSwitchPending() != true, let id = lifecycle.token {
            record(ControlEventLog.Event.outputDisconnected)
            stopSession(id, reason: .output)
        }
    }

    /// `mediaServicesWereResetNotification`: busy → `stopSession(.failure)`; the arbiter re-applies nothing until the
    /// next explicit Connect.
    func mediaServicesWereReset() {
        guard !terminating, lifecycle.view.busy, let id = lifecycle.token else { return }
        stopSession(id, reason: .failure)
    }

    /// Scene `.active` transitions (hook on the live receiver; playback ignores it).
    func applicationActiveChanged(_ active: Bool) {
        receiver?.setApplicationActive(active)
    }

    /// Runs the 5-minute timeout action if its monotonic deadline passed (every entry point calls it because timers
    /// cannot fire while suspended). Returns whether it ran: `focus_resume_timeout` + `pauseSession(token, automatic:
    /// false, .focusTransient)`.
    @discardableResult
    func expireInterruptionIfNeeded() -> Bool {
        guard let deadline = interruptionDeadlineMs, dependencies.clock.nowMs() >= deadline else { return false }
        cancelInterruptionDeadline()
        record(ControlEventLog.Event.focusResumeTimeout)
        if let id = lifecycle.token {
            pauseSession(id, automatic: false, reason: .focusTransient)
        }
        return true
    }

    /// `applicationWillTerminate` (`onDestroy`; `SessionCoordinator` records `app_terminating` once before calling the
    /// owners): if busy, `receiver.close(.service)` and block ≤ 2000 ms LAN / 3000 ms remote for the worker's `/stop`
    /// (`awaitRemoteStop(timeoutMs: nil)`), then `stopping` + `finish("Playback service ended. Use Reconnect after
    /// Windows finishes the stream.")` and release everything. The resume ticket is kept (parity with `onDestroy`).
    func applicationWillTerminate() {
        guard !terminating else { return }
        terminating = true
        pending = nil
        cancelStartTimeout()
        cancelLookups()
        cancelInterruptionDeadline()
        guard lifecycle.view.busy, let id = lifecycle.token else { return }
        let live = receiver
        live?.close(.service)
        _ = live?.awaitRemoteStop(timeoutMs: nil)
        lifecycle.stopping(id)
        lifecycle.finish(id, message: SessionLifecycle.Messages.serviceEnded)
        receiver = nil
        link = nil
        releaseTransport()
        publish()
    }

    // MARK: - Connection

    /// `beginConnection`: ignored while the microphone owns audio or a session is active; new token; parse + expiry
    /// check; output preflight (`needsOutputSelection`, availability, refresh) → `output_reselect` failure; clears the
    /// ticket; stores the trimmed link; pending + 10 s start timeout; publish (begins the setup lease);
    /// `arbiter.prepare(playbackPlan)`. `resume` is non-nil only for the media-Play lookup (`.manual`),
    /// `resumeInterrupted` (`SessionResume.resumed(userRequested:)`) and a Play queued during PAUSING (`.manual`,
    /// `PlaybackService.kt:325, 372, 409`); `connect()` (Connect/Reconnect, also while PAUSED) keeps `nil`.
    private func beginConnection(
        _ text: String, fastRecovery: Bool, baseline: OutputSnapshot?, keepFocus: Bool,
        reconnect: Bool, enabledOutput: Bool? = nil, selectedOutput: OutputSelection? = nil,
        resume: SessionResume.Reason? = nil
    ) {
        if microphoneOwnsSession() { return }
        let id = UUID().uuidString
        guard lifecycle.begin(id, destination: "") else { return }
        link = nil
        resumable = false
        let parsed: ConnectionLink
        do {
            parsed = try ConnectionLink.parse(text)
            guard !parsed.isExpired() else {
                finish(id, message: SessionLifecycle.Messages.linkUnavailable, failed: true)
                return
            }
        } catch {
            finish(id, message: SessionLifecycle.Messages.linkUnavailable, failed: true)
            return
        }
        let selected = selectedOutput ?? outputSelection
        outputSelection = selected
        outputPause = selected.explicit ? nil : .route
        // Android Nearby-permission denial has no iOS equivalent.
        if dependencies.preferences.load().needsOutputSelection(outputSelection)
            || !dependencies.outputAvailable(outputSelection)
        {
            finish(id, message: SessionLifecycle.Messages.outputReselect, failed: true)
            return
        }
        guard let refreshed = dependencies.outputRefresh(outputSelection) else {
            finish(id, message: SessionLifecycle.Messages.outputReselect, failed: true)
            return
        }
        outputSelection = refreshed
        dependencies.pausedPlayback.clear()
        link = ConnectionLink.trimmed(text)
        fast = fastRecovery
        if let enabledOutput { outputEnabled = enabledOutput }
        lifecycle.setDestination(id, "Windows: \(parsed.endpoint.host.description):\(parsed.endpoint.port)")
        pending = PendingConnection(
            id: id, text: text, fast: fastRecovery, baseline: baseline,
            keepFocus: keepFocus, reconnect: reconnect, resume: resume)
        scheduleStartTimeout()
        publish()
        // iOS always activates (also for `keepFocus`), because an interruption deactivated the session; activation
        // after `.ended`+`shouldResume` is allowed in background.
        dependencies.prepareAudio(dependencies.playbackPlan) { [weak self] result in
            self?.audioPrepared(id, result)
        }
    }

    /// Arbiter completion (`audioPrepared`): stale results release their activation; success → keep the activation
    /// (releasing an older one held through INTERRUPTED) and `startTransport`; busy → `focus_request_denied` + "Audio
    /// is busy…"; background start → `foreground_start_denied` + "iOS could not start background playback…"; other →
    /// "Playback could not start…". Every failure also records `audio_session_activation_failed_<code>`.
    private func audioPrepared(
        _ id: String, _ result: Result<AudioSessionArbiter.Activation, AudioSessionArbiter.ActivationError>
    ) {
        guard !terminating, let next = pending, next.id == id, lifecycle.token == id,
            lifecycle.view.phase == .connecting
        else {
            if case .success(let stale) = result { dependencies.arbiter.deactivate(stale, notifyOthers: true) }
            return
        }
        pending = nil
        cancelStartTimeout()
        switch result {
        case .success(let granted):
            if let previous = activation { dependencies.arbiter.deactivate(previous, notifyOthers: true) }
            activation = granted
            startTransport(next)
        case .failure(let error):
            record(ControlEventLog.Event.audioSessionActivationFailed(error.codeLabel))
            if error.isBusy {
                record(ControlEventLog.Event.focusRequestDenied)
                finish(id, message: SessionLifecycle.Messages.audioBusy, failed: true)
            } else if error.isBackgroundStart {
                record(ControlEventLog.Event.foregroundStartDenied)
                finish(id, message: SessionLifecycle.Messages.backgroundStartDenied, failed: true)
            } else {
                finish(id, message: SessionLifecycle.Messages.playbackStartFailed, failed: true)
            }
        }
    }

    /// `startTransport` minus focus request and wake lock: arms noisy handling, builds the `SessionConfiguration` (mode
    /// `.playback`, built-in microphone placeholder, input never initialised, the resume hint and this session's phone
    /// settings binding) and the callbacks (main-queue FIFO, token-guarded), starts the worker. Exceptions → "Playback
    /// could not start. Open MicDrop and check the Windows link." (failed).
    private func startTransport(_ connection: PendingConnection) {
        do {
            let parsed = try ConnectionLink.parse(connection.text)
            guard !parsed.isExpired() else {
                finish(connection.id, message: SessionLifecycle.Messages.playbackStartFailed, failed: true)
                return
            }
            noisyArmed = true
            rememberedToken = nil
            let configuration = SessionConfiguration(
                link: parsed,
                linkText: ConnectionLink.trimmed(connection.text),
                mode: .playback,
                reconnect: connection.reconnect,
                fastRecovery: connection.fast,
                baseline: connection.baseline,
                initiallyOutputEnabled: outputEnabled,
                outputSelection: outputSelection,
                protectedDefaultSpeaker: protectedDefaultSpeaker,
                initialOutputFocus: nil,
                microphoneSelection: .builtIn,
                initiallyMicrophoneMuted: true,
                processing: MicrophoneProcessing(),
                plan: dependencies.playbackPlan, connectionPreferences: ConnectionPreferencesStore.shared.load(),
                bluetoothRecoveryMs: dependencies.advancedAudio().bluetoothRecoveryWindowMs,
                resume: connection.resume, phoneControl: phoneControlBinding(for: connection.id))
            bluetoothRecoveryMs = configuration.bluetoothRecoveryMs
            let worker = try dependencies.makeReceiver(
                configuration,
                callbacks(
                    for: connection.id, text: connection.text,
                    version: parsed.version))
            receiver = worker
            publish()
            worker.start()
        } catch {
            finish(connection.id, message: SessionLifecycle.Messages.playbackStartFailed, failed: true)
        }
    }

    /// Receiver callbacks (table). `SessionController` delivers each with `DispatchQueue.main.async` (FIFO); every
    /// handler re-checks `terminating` and the token.
    private func callbacks(for id: String, text: String, version: LinkVersion) -> SessionCallbacks {
        SessionCallbacks(
            onStatus: { [weak self] message in
                MainActor.assumeIsolated { self?.receiverUpdate(id, message: message) }
            },
            onDiagnostics: { [weak self] report in
                MainActor.assumeIsolated { self?.receiverUpdate(id, diagnostics: report) }
            },
            onPhase: { [weak self] phase in
                MainActor.assumeIsolated { self?.receiverPhase(id, phase, text: text, version: version) }
            },
            onEnded: { [weak self] end in
                MainActor.assumeIsolated { self?.receiverEnded(id, end) }
            },
            onNetworkStatus: { [weak self] status in
                MainActor.assumeIsolated { self?.receiverUpdate(id, networkStatus: status) }
            },
            onOutputSelection: { [weak self] selection in
                MainActor.assumeIsolated { self?.receiverOutputSelection(id, selection) }
            },
            onOutputState: { [weak self] pause, protectedSpeaker in
                MainActor.assumeIsolated { self?.receiverOutputState(id, pause, protectedSpeaker) }
            })
    }

    private func receiverUpdate(
        _ id: String, message: String? = nil, diagnostics: String? = nil,
        networkStatus: String? = nil
    ) {
        guard !terminating,
            lifecycle.update(id, message: message, diagnostics: diagnostics, networkStatus: networkStatus)
        else { return }
        publish()
    }

    /// `onPhase`: at the first PLAYING only: `resumable = version >= 2` (v1 single-use links never resume),
    /// `remember(text)`, save the ticket when resumable, `stream_playing`.
    private func receiverPhase(_ id: String, _ phase: SessionPhase, text: String, version: LinkVersion) {
        guard !terminating, lifecycle.update(id, phase: phase) else { return }
        if phase == .playing && rememberedToken != id {
            rememberedToken = id
            resumable = version.rawValue >= 2
            dependencies.rememberLink(text)
            if resumable { saveTicket(id) }
            record(ControlEventLog.Event.streamPlaying)
        }
        publish()
    }

    /// `onEnded` → `finish(id, end.message, end.reason == .failure, end.diagnostics)`.
    private func receiverEnded(_ id: String, _ end: StreamEnd) {
        guard !terminating else { return }
        finish(id, message: end.message, failed: end.reason == .failure, diagnostics: end.diagnostics)
    }

    /// `onOutputSelection`: same token, active, not STOPPING/PAUSING, `acceptsUpdate`,
    /// `receiver.matchesOutputSelection`; then store and publish. The identity and `preferenceKind` are persisted
    /// (`rememberOutput`) only while the saved output is this session's previous or new endpoint
    /// (`PlaybackService.kt:246-251`), so an automatic rebind or return never overwrites an output saved for the next
    /// connection outside this session. A Windows choice in this session is not such an output: it goes through
    /// `setOutputSelection` and is saved like the phone's own.
    private func receiverOutputSelection(_ id: String, _ selection: OutputSelection) {
        let phase = lifecycle.view.phase
        guard !terminating, lifecycle.token == id, lifecycle.view.active, phase != .stopping, phase != .pausing,
            outputSelection.acceptsUpdate(selection),
            receiver?.matchesOutputSelection(selection) == true
        else { return }
        let persists = OutputSelection.persistsSessionUpdate(
            saved: dependencies.preferences.restoredOutputSelection(), previous: outputSelection, update: selection)
        outputSelection = selection
        if persists { dependencies.preferences.rememberOutput(selection) }
        publish()
    }

    /// `onOutputState`: same token, active, `matchesOutputState`, not STOPPING/PAUSING.
    private func receiverOutputState(_ id: String, _ pause: OutputPause?, _ protectedSpeaker: Bool) {
        let phase = lifecycle.view.phase
        guard !terminating, lifecycle.token == id, lifecycle.view.active,
            receiver?.matchesOutputState(pause: pause, protectedSpeaker: protectedSpeaker) == true,
            phase != .stopping, phase != .pausing
        else { return }
        outputPause = pause
        protectedDefaultSpeaker = protectedSpeaker
        publish()
    }

    // MARK: - Phone settings exchange v1 (D046)

    /// This session's live settings for Windows (`PlaybackService.kt:234-241`): `current` is nil unless the controller
    /// is not terminating, `id` is the current token, the session is active and neither PAUSING nor STOPPING; `apply`
    /// goes through `setOutputEnabled` (the `canSetOutput` guard) without saving the preference, unlike Android, so a
    /// Windows edit never changes the next Connect; `applyOutput` goes through `setOutputSelection`; `changed`
    /// republishes.
    private func phoneControlBinding(for id: String) -> PhoneControlBinding {
        PhoneControlBinding(
            current: { [weak self] in self?.phoneLiveSettings(id) },
            apply: { [weak self] requested in
                guard let self else { throw PhoneControlAdapter.ApplyFailure("controller released") }
                try self.applyPhoneLiveSettings(id, requested)
            },
            applyOutput: { [weak self] requested in
                guard let self else { throw PhoneControlAdapter.ApplyFailure("controller released") }
                try self.applyPhoneOutput(id, requested)
            },
            changed: { [weak self] in self?.publish() })
    }

    /// Playback advertises "Play desktop audio" (`live.output_enabled`) and its media output, which a Windows choice
    /// switches live (`audio.output`); it has no microphone.
    private func phoneLiveSettings(_ id: String) -> PhoneLiveSettings? {
        let phase = lifecycle.view.phase
        guard !terminating, lifecycle.token == id, lifecycle.view.active, phase != .stopping, phase != .pausing
        else { return nil }
        return PhoneLiveSettings(outputEnabled: outputEnabled, output: outputSelection, outputAppliesLive: true)
    }

    /// Applies an advertised live value through the controller's own path, then requires the result to equal the
    /// request (`check(outputEnabled == it)`); a field this session does not advertise is refused.
    private func applyPhoneLiveSettings(_ id: String, _ requested: PhoneLiveSettings) throws {
        guard let live = phoneLiveSettings(id), requested.microphoneMuted == nil, requested.output == nil else {
            throw PhoneControlAdapter.ApplyFailure("live setting unavailable")
        }
        if let enabled = requested.outputEnabled {
            guard live.outputEnabled != nil else { throw PhoneControlAdapter.ApplyFailure("output unavailable") }
            setOutputEnabled(enabled, saves: false)
            guard outputEnabled == enabled else { throw PhoneControlAdapter.ApplyFailure("output unchanged") }
        }
    }

    /// A Windows `audio.output` choice (`PlaybackService.kt:76-88` is Android's chooser path): exactly the phone's own
    /// `setOutputSelection`, so the same phases accept it (`acceptsOutputChoice`: CONNECTING and SWITCHING refuse, and
    /// PAUSING, STOPPING, PAUSED and INTERRUPTED have no live binding), the provider refresh allows the iPhone speaker
    /// only while it can be pinned, the worker keeps playback gated until the new route verifies and ends the session
    /// if it never does, and the choice is saved like a local one, so a later Play from PAUSED, a queued Play or an
    /// interruption resume passes the `beginConnection` preflight. Nothing reconnects; "Play desktop audio" stays as it
    /// is. Throws unless the session then uses exactly that endpoint.
    private func applyPhoneOutput(_ id: String, _ requested: OutputSelection) throws {
        guard phoneLiveSettings(id)?.output != nil else {
            throw PhoneControlAdapter.ApplyFailure("output unavailable")
        }
        guard setOutputSelection(requested), outputSelection.sameEndpoint(requested) else {
            throw PhoneControlAdapter.ApplyFailure("output unchanged")
        }
    }

    // MARK: - Pause / resume / stop / finish

    /// `pauseSession`: PAUSED → cancel a pending Play lookup; not resumable (before the first PLAYING, v1, or during a
    /// resume's CONNECTING) → full Stop with `reason`; else `lifecycle.pause`, record, immediate local mute via
    /// `receiver.close(reason)`, arm the 5-minute deadline on the first automatic pause, cancel it when not armed
    /// (deactivation is deferred to `releaseTransport`), publish; INTERRUPTED → PAUSED has no worker: `completePause`
    /// now.
    private func pauseSession(_ id: String, automatic: Bool, reason: StopReason) {
        guard lifecycle.token == id else { return }
        if lifecycle.view.phase == .paused {
            cancelLookups()
            publish()
            return
        }
        guard resumable, link != nil else {
            stopSession(id, reason: reason)
            return
        }
        let wasWaiting = lifecycle.resumeOnFocus
        guard lifecycle.pause(id, automatic: automatic) else { return }
        record(automatic ? ControlEventLog.Event.automaticResumeArmed : ControlEventLog.Event.manualPause)
        receiver?.close(reason)
        if lifecycle.resumeOnFocus && !wasWaiting { armInterruptionDeadline() }
        if !lifecycle.resumeOnFocus { cancelInterruptionDeadline() }
        publish()
        if receiver == nil { completePause(id) }
    }

    /// `resumeInterrupted`: INTERRUPTED only; `manual_resume` / `focus_resume`; `beginConnection(link, fast, keepFocus:
    /// !userRequested, reconnect: true, resume: SessionResume.resumed(userRequested:))` (`PlaybackService.kt:372`).
    private func resumeInterrupted(userRequested: Bool) {
        guard lifecycle.view.phase == .interrupted, let text = link else { return }
        record(userRequested ? ControlEventLog.Event.manualResume : ControlEventLog.Event.focusResume)
        cancelInterruptionDeadline()
        beginConnection(
            text, fastRecovery: fast, baseline: nil, keepFocus: !userRequested, reconnect: true,
            resume: SessionResume.resumed(userRequested: userRequested))
    }

    /// `stopSession`: `stopping`; `stop_<wire>`; cancel pending/lookups/timers; clear the ticket;
    /// `receiver.close(reason)`; publish; no receiver → finish now with `reason.message`.
    private func stopSession(_ id: String, reason: StopReason) {
        guard lifecycle.stopping(id) else { return }
        record(ControlEventLog.Event.stop(reason))
        pending = nil
        cancelLookups()
        cancelInterruptionDeadline()
        cancelStartTimeout()
        dependencies.pausedPlayback.clear()
        receiver?.close(reason)
        publish()
        if receiver == nil {
            finish(id, message: reason.message, failed: reason == .failure)
        }
    }

    /// `finish`: a pausing finish keeps the pause message plus the worker's confirmation line
    /// (`SessionLifecycle.confirmationSuffix`) and completes the pause; otherwise release the transport, drop the link,
    /// clear the ticket and publish.
    private func finish(_ id: String, message: String, failed: Bool, diagnostics: String? = nil) {
        let pausing = lifecycle.view.phase == .pausing && !failed
        let result = pausing ? lifecycle.view.message + SessionLifecycle.confirmationSuffix(message) : message
        guard lifecycle.finish(id, message: result, failed: failed, diagnostics: diagnostics) else { return }
        receiver = nil
        pending = nil
        cancelStartTimeout()
        record(failed ? ControlEventLog.Event.streamFailed : ControlEventLog.Event.streamClosed)
        if pausing {
            completePause(id)
            return
        }
        releaseTransport()
        link = nil
        resumable = false
        dependencies.pausedPlayback.clear()
        publish()
    }

    /// `completePause`: INTERRUPTED keeps link, noisy arming and the activation handle and resumes now if focus already
    /// returned; PAUSED saves the ticket, releases the transport and either starts the queued Play (`reconnect: true,
    /// resuming: true`, `PlaybackService.kt:409`) or publishes the retained card.
    private func completePause(_ id: String) {
        if lifecycle.view.phase == .interrupted {
            publish()
            if lifecycle.focusReturned { resumeInterrupted(userRequested: false) }
            return
        }
        guard lifecycle.view.phase == .paused, let text = link else { return }
        let recovery = fast
        saveTicket(id)
        let queued = lifecycle.playAfterPause
        releaseTransport()
        link = nil
        resumable = false
        if queued {
            beginConnection(
                text, fastRecovery: recovery, baseline: nil, keepFocus: false, reconnect: true, resume: .manual)
        } else {
            publish()
        }
    }

    /// `releaseTransport`: cancel lookups and the deadline, disarm noisy handling and release the arbiter activation
    /// (after `onEnded`).
    private func releaseTransport() {
        cancelLookups()
        cancelInterruptionDeadline()
        noisyArmed = false
        if let held = activation {
            dependencies.arbiter.deactivate(held, notifyOthers: true)
            activation = nil
        }
    }

    // MARK: - Ticket and media-Play lookup

    /// `ResumeTicket(id, fingerprint(link), fast)`.
    private func saveTicket(_ id: String) {
        guard let text = link else { return }
        dependencies.pausedPlayback.save(ResumeTicket(id: id, link: text, fast: fast))
    }

    /// `loadSaved(ticket)`: waits for the saved store (s), then requires the stored ticket id to be unchanged, a saved
    /// link to exist and the digest to match it.
    private func loadSaved(_ ticket: ResumeTicket) async throws -> String {
        let saved = try await dependencies.loadSavedLink()
        try Task.checkCancellation()
        guard !terminating, dependencies.pausedPlayback.ticket()?.id == ticket.id,
            let text = saved, ticket.matches(text)
        else { throw LookupRejected() }
        return text
    }

    private func lookupFinished(_ id: UUID) {
        lookups[id] = nil
        if playLookup == id { playLookup = nil }
    }

    /// `cancelLookups()` (`PlaybackService.kt:412`).
    private func cancelLookups() {
        playLookup = nil
        let running = lookups
        lookups = [:]
        for lookup in running.values {
            lookup.cancel()
        }
    }

    // MARK: - Timers (start timeout, deadline)

    private func scheduleStartTimeout() {
        cancelStartTimeout()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startTimedOut() }
        }
        startTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.startTimeoutMs), execute: item)
    }

    private func cancelStartTimeout() {
        startTimeout?.cancel()
        startTimeout = nil
    }

    /// `finish(pending.id, "iOS did not make playback ready. …", failed: true)`.
    private func startTimedOut() {
        startTimeout = nil
        guard let waiting = pending else { return }
        finish(waiting.id, message: SessionLifecycle.Messages.startTimeout, failed: true)
    }

    /// Sets the monotonic deadline (`now + 300 000 ms`) and a main-queue timer for it.
    private func armInterruptionDeadline() {
        interruptionDeadlineMs = dependencies.clock.nowMs() + Self.interruptionWindowMs
        scheduleInterruptionTimer(afterMs: Self.interruptionWindowMs)
    }

    private func scheduleInterruptionTimer(afterMs delay: Int64) {
        interruptionTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.interruptionTimerFired() }
        }
        interruptionTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, delay))), execute: item)
    }

    /// Timer fire: run the timeout if due, else re-arm for the remaining time.
    private func interruptionTimerFired() {
        interruptionTimer = nil
        guard let deadline = interruptionDeadlineMs else { return }
        if !expireInterruptionIfNeeded() {
            scheduleInterruptionTimer(afterMs: deadline - dependencies.clock.nowMs())
        }
    }

    private func cancelInterruptionDeadline() {
        interruptionDeadlineMs = nil
        interruptionTimer?.cancel()
        interruptionTimer = nil
    }

    // MARK: - Lease

    /// `leaseNeeded = phase ∈ {connecting, switching, pausing, stopping} || playLookup != nil ||
    /// pending != nil`, plus ROUTE_RECOVERING while a media output recovers (iOS,
    /// `SessionPhase.leasesOutputRecovery(pause:)`); one lease per controller, begun/ended in `publish()`.
    private func updateLease() {
        let phase = lifecycle.view.phase
        let leasedPhases: [SessionPhase] = [.connecting, .switching, .pausing, .stopping]
        let needed =
            leasedPhases.contains(phase) || phase.leasesOutputRecovery(pause: outputPause) || playLookup != nil
            || pending != nil
        if needed, lease == nil, !terminating {
            let name =
                (phase == .pausing || phase == .stopping)
                ? BackgroundExecutionLease.Name.teardown : BackgroundExecutionLease.Name.setup
            let created = dependencies.makeLease(name) { [weak self] in self?.leaseExpired() }
            lease = created
            created.begin()
        } else if !needed, let held = lease {
            lease = nil
            held.end()
        }
    }

    /// expiry while still CONNECTING (no audio yet) → `background_setup_expired`; `receiver.expireBackgroundSetup()`
    /// (worker fails with `stage_timeout`), or without a receiver (still pending) finish with the start-timeout text.
    /// Other phases: nothing (the worker keeps going while iOS allows).
    private func leaseExpired() {
        lease = nil
        guard !terminating, lifecycle.view.phase == .connecting else { return }
        record(ControlEventLog.Event.backgroundSetupExpired)
        if let live = receiver {
            live.expireBackgroundSetup()
        } else if let waiting = pending {
            finish(waiting.id, message: SessionLifecycle.Messages.startTimeout, failed: true)
        }
    }

    // MARK: - Publish

    private func record(_ event: String) {
        dependencies.controlLog.record(event)
    }

    /// `shownView()`: the lifecycle view with the controller's output fields and the "Recent controls" block appended
    /// to the diagnostics.
    private func shownView() -> SessionView {
        var shown = lifecycle.view
        shown.outputEnabled = outputEnabled
        shown.outputSelection = outputSelection
        shown.outputPause = outputPause
        shown.bluetoothRecoveryMs = bluetoothRecoveryMs
        shown.diagnostics = dependencies.controlLog.diagnostics(appendingTo: lifecycle.view.diagnostics)
        return shown
    }

    /// `view = shownView()`; lease policy; observers (synchronously; `SessionCoordinator` refreshes
    /// Now Playing and remote-command enablement from here).
    private func publish() {
        let shown = shownView()
        if shown != view { view = shown }
        updateLease()
        for observer in observers { observer.callback(shown) }
    }
}
