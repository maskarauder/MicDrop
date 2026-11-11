import Foundation
import MicDropCore
import Observation
import UIKit

/// Microphone/duplex session owner — the iOS `MicrophoneService` (`A/MicrophoneService.kt`). One app-lifetime instance
/// on the main actor; the UI (10) uses it through `MicrophoneSessionControlling`, `SessionCoordinator` (07) routes
/// interruptions, route events, remote commands and termination to it while `view.ownsSession`.
///
/// iOS deviations (all normative):
/// - No foreground service or wake lock: `UIBackgroundModes=audio` keeps the app alive while the audio
/// unit runs; `BackgroundLease` covers CONNECTING/SWITCHING/PAUSING/STOPPING and its expiry during CONNECTING calls
/// `receiver.expireBackgroundSetup()`.
/// - Audio focus = activation of the plan row of through `AudioSessionArbiter` before the
/// receiver exists; deactivation only in `releaseTransport()` after the worker ended.
/// - Interruptions use Path B for every duplex; mic-only `.began` → `stop(.focus)`;
/// `.routeDisconnected` is route loss, not focus.
/// - Mic-only background keep-alive: scene activity is forwarded to the receiver.
/// - Callbacks are guarded by the session token and `supersededReceiver` exactly like Android; timers are
///   cancellable `Task.sleep` on the continuous clock re-validated by elapsed monotonic time at every entry
///   (`expirePauseIfNeeded`).
@MainActor
@Observable
final class MicrophoneSessionController {
    /// `PendingRouteChange` window (`MicrophoneService.kt:263`).
    static let inputChangeTimeoutMs: Int64 = 20_000
    /// Microphone sessions always reconnect with `Connect` (`StreamMode.reconnectAction`).
    static let reconnectAction = "Connect"

    /// Published state (`lastView`); observers are called synchronously from every publish.
    private(set) var view = MicrophoneView()

    private let dependencies: Dependencies

    // Android `MicrophoneService` fields (`:51-98`).
    private var lifecycle = SessionLifecycle()
    private var observers: [(id: Int, callback: (MicrophoneView) -> Void)] = []
    private var nextObserverID = 0
    private var receiver: (any StreamReceiving)?
    private var muted = true
    private var outputEnabled = true
    private var outputSelection = OutputSelection()
    private var outputPause: OutputPause?
    /// The effective Bluetooth route recovery window of the latest configured session (pause text).
    private var bluetoothRecoveryMs: Int64?
    private var protectedDefaultSpeaker = false
    private var fastRecovery = true
    private var changing = false
    /// Android `destroyed` (app termination).
    private var terminating = false
    private var mode: StreamMode = .microphone
    private var input = MicrophoneSelection()
    /// 20 000 ms window (the `PendingRouteChange` default equals `inputChangeTimeoutMs`).
    private let inputChange = PendingRouteChange<MicrophoneSelection>()
    private var inputChangeTimedOut = false
    private var inputChangeTimer: Task<Void, Never>?
    private var supersededReceiver: String?
    private var inputSwitchActionOrigin: String?
    private var requestedStop: StreamEnd?
    private var retainedLink: String?
    private var resumable = false
    private var pauseWindow = DuplexPauseWindow()
    private var pauseExpiryTimer: Task<Void, Never>?
    /// Route `.oldDeviceUnavailable` handled only between transport start and release.
    private var noisyArmed = false
    /// The arbiter activated the plan for this controller.
    private var audioActive = false
    /// Token of a connection waiting for `activateAudio`'s completion.
    private var pendingActivation: String?
    /// Parsed link and plan of the pending activation (consumed by `startTransport`).
    private var pendingLink: ConnectionLink?
    private var pendingPlan: AudioSessionPlan?
    private var pendingKeepFocus = false
    /// The pending connection's resume cause (`SessionConfiguration.resume`, `MicrophoneService.kt:200`).
    private var pendingResume: SessionResume.Reason?
    /// Token whose first PLAYING already saved the connection (`remembered`, `:189`).
    private var rememberedToken: String?
    private var lease: (any BackgroundLease)?
    /// scene is `.active`.
    private var applicationActive = true
    /// The live receiver's actual retained muted capture (`SessionCallbacks.onMicrophoneCaptureRetained`), for
    /// Now Playing. False for each new receiver, on Stop and after the session ended.
    private(set) var captureRetainedWhileMuted = false
    /// The phone itself enabled capture in this session (Android's `MicrophoneService` gets the same flag): set only
    /// when a live worker confirms verified capture opened its sample gate (`onMicrophoneCaptureEnabled`). Windows can
    /// unmute only after that, so a Mute while connecting leaves it no capture to start. Kept across duplex and focus
    /// resumes and the input-switch replacement (one authorized session); cleared by an explicit `connect`, the final
    /// cleanup of `finish` (every Stop and end) and termination.
    private var phoneEnabledCapture = false
    private var activityObservers: [NSObjectProtocol] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        let preferences = dependencies.loadPreferences()
        outputEnabled = preferences.outputEnabled
        // The remembered pin (or the kind-only restore); Connect passes the UI's selection anyway.
        let restoredOutput = dependencies.restoredOutput()
        outputSelection = restoredOutput
        view = MicrophoneView(
            session: SessionView(outputEnabled: preferences.outputEnabled, outputSelection: restoredOutput))
        if dependencies.observesApplicationState {
            applicationActive = UIApplication.shared.applicationState == .active
            startObservingApplicationState()
        }
    }

    // MARK: - Observation

    /// `observe(observer)` (`:99-101`): expires a lapsed pause first, then calls `observer` immediately
    /// with the current view and synchronously from every later publish until the token is cancelled.
    /// Returns app-ui's shared top-level `ObservationToken` (`UI/MainViewServices.swift`).
    func observe(_ observer: @escaping (MicrophoneView) -> Void) -> ObservationToken {
        expirePauseIfNeeded()
        nextObserverID += 1
        let id = nextObserverID
        observers.append((id: id, callback: observer))
        let token = ObservationToken { [weak self] in
            self?.observers.removeAll { $0.id == id }
        }
        observer(view)
        return token
    }

    /// `view.ownsSession`: while true the playback controller refuses to begin.
    var ownsSession: Bool { view.ownsSession }

    /// `view.canResume`.
    var canResume: Bool { view.canResume }

    // MARK: - Tokens

    /// `inputActionToken()` (`:243-245`): the session token iff not terminating, the pause window has
    /// not expired, and `canChooseInput`.
    func inputActionToken() -> String? {
        guard let token = lifecycle.token, !terminating, !expirePauseIfNeeded(), shownView().canChooseInput else {
            return nil
        }
        return token
    }

    /// `outputActionToken()` (`:103-105`): the token iff not terminating, retained and not STOPPING.
    func outputActionToken() -> String? {
        guard let token = lifecycle.token, !terminating, lifecycle.view.retained,
            lifecycle.view.phase != .stopping
        else { return nil }
        return token
    }

    // MARK: - Connect

    /// `connectFromActivity(...)` (`:107-118`): ignored while a session is retained; resets the switch origin, output
    /// pause and speaker protection, then `beginConnection(initiallyMuted: false, keepFocus: false)`. Throws the
    /// preflight errors (`MicrophoneRouteError`, `PreflightError`) before any state change; the UI shows
    /// `problem.detail` or its generic start text (step 7). Only this explicit Connect makes the saved background
    /// keep-alive live (`reloadKeepAlive`), so a Windows edit of it applies from the next Connect, never from an
    /// input-switch replacement or a duplex resume of the session it was made in. It also starts a new authorization
    /// for a Windows unmute (`phoneEnabledCapture`).
    func connect(
        text: String, mode: StreamMode, input: MicrophoneSelection, outputEnabled: Bool,
        fastRecovery: Bool, outputSelection: OutputSelection
    ) throws {
        if lifecycle.view.retained { return }
        dependencies.reloadKeepAlive()
        phoneEnabledCapture = false
        inputSwitchActionOrigin = nil
        self.outputEnabled = outputEnabled && mode != .microphone
        self.fastRecovery = fastRecovery
        self.outputSelection = outputSelection
        outputPause = nil
        protectedDefaultSpeaker = false
        try beginConnection(text: text, mode: mode, input: input, initiallyMuted: false, keepFocus: false)
    }

    /// `beginConnection(text, mode, input, initiallyMuted, keepFocus)` (`:119-241`) on iOS. Preflight (throws, no state
    /// change): `mode != .playback`; `ConnectionLink.parse` v3 (`.paired`) and not expired (else
    /// `PreflightError.linkUnavailable`); record permission granted (else `.permissionDenied`);
    /// `dependencies.inputAvailable(input)` (else `MicrophoneRouteError(.unavailable)`); duplex with a non-Bluetooth
    /// input: `needsOutputSelection`/`outputAvailable` (else `.outputUnavailable`) and `refreshOutput` into
    /// `outputSelection`. Then: new UUID token; `lifecycle.begin(id, "Windows: <host>:<port>")`; mode/input/retained
    /// link (trimmed); `resumable = false`; `muted = initiallyMuted`; `changing = true`; switch/supersede/
    /// requestedStop cleared; pause expiry cancelled; `pauseWindow.clear()`; plan =
    /// `AudioSessionPlan.make(mode:input:processing:)` with the preference processing made effective;
    /// `pendingActivation = id` (+ link/plan/keepFocus); `publish()` (begins the lease);
    /// `dependencies.activateAudio(plan) { audioPrepared(id, $0) }`. Any non-preflight error → `finish(id,
    /// StreamEnd(.failure, Messages.startFailed))`. `resume` is set for `resumeConnection`
    /// (`SessionResume.resumed(userRequested:)`, `MicrophoneService.kt:389`) and the input-switch replacement
    /// (`SessionResume.inputSwitch`, `:483`); Connect keeps `nil`.
    func beginConnection(
        text: String, mode: StreamMode, input: MicrophoneSelection, initiallyMuted: Bool,
        keepFocus: Bool, resume: SessionResume.Reason? = nil
    ) throws {
        guard !terminating, mode != .playback, let link = try? ConnectionLink.parse(text),
            link.version == .paired, !link.isExpired()
        else { throw PreflightError.linkUnavailable }
        guard dependencies.permission.status == .granted else { throw PreflightError.permissionDenied }
        guard dependencies.inputAvailable(input) else { throw MicrophoneRouteError(.unavailable) }
        let preferences = dependencies.loadPreferences()
        var selectedOutput = outputSelection
        if mode == .duplex && !input.isBluetooth {
            guard !preferences.needsOutputSelection(outputSelection),
                dependencies.outputAvailable(outputSelection, input),
                let refreshed = dependencies.refreshOutput(outputSelection, input)
            else { throw PreflightError.outputUnavailable }
            selectedOutput = refreshed
        }
        let id = UUID().uuidString
        guard lifecycle.begin(id, destination: "Windows: \(link.endpoint.host):\(link.endpoint.port)") else { return }
        self.mode = mode
        self.input = input
        outputSelection = selectedOutput
        retainedLink = ConnectionLink.trimmed(text)
        resumable = false
        muted = initiallyMuted
        changing = true
        supersededReceiver = nil
        requestedStop = nil
        inputChangeTimedOut = false
        cancelInputChange()
        cancelPauseExpiry()
        pauseWindow.clear()
        let processing = MicrophoneProcessing(
            echoCancellation: preferences.echoCancellation, noiseReduction: preferences.noiseReduction
        )
        .effective(mode: mode, input: input.kind)
        let plan = AudioSessionPlan.make(mode: mode, input: input.kind, processing: processing)
        pendingActivation = id
        pendingLink = link
        pendingPlan = plan
        pendingKeepFocus = keepFocus
        pendingResume = resume
        publish()
        dependencies.activateAudio(plan) { [weak self] result in self?.audioPrepared(id, result) }
    }

    /// Activation completion (`audioPrepared` analogue). Stale (terminating, other token, not CONNECTING): deactivate
    /// again if it succeeded and return. `.success` → `audioActive = true`, `startTransport(id)`; `.busy` → `finish(id,
    /// StreamEnd(.failure, Messages.focusDenied))`; `.backgroundStart`/`.failed` → `finish(id, StreamEnd(.failure,
    /// keepFocus ? duplexResumeFailed : startFailed))`.
    private func audioPrepared(_ id: String, _ result: ActivationResult) {
        guard !terminating, lifecycle.token == id, lifecycle.view.phase == .connecting, pendingActivation == id else {
            if result == .success { dependencies.deactivateAudio() }
            return
        }
        pendingActivation = nil
        switch result {
        case .success:
            audioActive = true
            startTransport(id)
        case .busy:
            finish(id, StreamEnd(reason: .failure, message: MicrophoneStatusText.Messages.focusDenied))
        case .backgroundStart, .failed:
            finish(
                id,
                StreamEnd(
                    reason: .failure,
                    message: pendingKeepFocus
                        ? MicrophoneStatusText.Messages.duplexResumeFailed : MicrophoneStatusText.Messages.startFailed))
        }
    }

    /// Receiver creation (`:156-240` after focus): `noisyArmed = duplex && !input.isBluetooth`;
    /// `outputPause = usesMediaOutput ? (followsDefaultMedia ? .route : nil) : nil` (focus pause never on
    /// iOS); `SessionConfiguration(link:, linkText: retainedLink, mode:, reconnect: true, fastRecovery:,
    /// baseline: nil, initiallyOutputEnabled: outputEnabled, outputSelection:, protectedDefaultSpeaker:,
    /// initialOutputFocus: nil, microphoneSelection: input, initiallyMicrophoneMuted: muted, processing:
    /// effective preference processing, plan:, resuming: pendingResuming, phoneControl: this session's
    /// binding)`; `receiver = try makeReceiver(config, makeCallbacks(id))`; `publish()`;
    /// `receiver.setApplicationActive(applicationActive)`; `receiver.start()`. Any error →
    /// `finish(id, StreamEnd(.failure, Messages.startFailed))`. The background keep-alive is made live only by
    /// `connect` (an explicit Connect), not here.
    private func startTransport(_ id: String) {
        guard lifecycle.token == id, let link = pendingLink, let plan = pendingPlan, let text = retainedLink else {
            return
        }
        pendingLink = nil
        pendingPlan = nil
        noisyArmed = mode == .duplex && !input.isBluetooth
        outputPause = usesMediaOutput && followsDefaultMedia ? .route : nil
        let configuration = SessionConfiguration(
            link: link, linkText: text, mode: mode, reconnect: true, fastRecovery: fastRecovery,
            baseline: nil, initiallyOutputEnabled: outputEnabled, outputSelection: outputSelection,
            protectedDefaultSpeaker: protectedDefaultSpeaker, initialOutputFocus: nil,
            microphoneSelection: input, initiallyMicrophoneMuted: muted, processing: plan.processing, plan: plan,
            connectionPreferences: ConnectionPreferencesStore.shared.load(),
            bluetoothRecoveryMs: dependencies.advancedAudio().bluetoothRecoveryWindowMs, resume: pendingResume,
            phoneControl: phoneControlBinding(for: id))
        bluetoothRecoveryMs = configuration.bluetoothRecoveryMs
        captureRetainedWhileMuted = false
        do {
            let session = try dependencies.makeReceiver(configuration, makeCallbacks(id, text: text))
            receiver = session
            publish()
            session.setApplicationActive(applicationActive)
            session.start()
        } catch {
            finish(id, StreamEnd(reason: .failure, message: MicrophoneStatusText.Messages.startFailed))
        }
    }

    /// Receiver callbacks (`:184-239`). Each hops through `DispatchQueue.main.async` (the session already posts that
    /// way) and is dropped unless `!terminating && supersededReceiver != id`: status/diagnostics/network →
    /// `lifecycle.update`; `onPhase(.playing)` → switch origin cleared, `resumable = (mode == .duplex)`, first time
    /// `rememberConnection(text)`; `onEnded` → `finish(id, end)`; `onOutputSelection` (token, active, phase ∉
    /// {stopping, pausing}, `outputSelection.acceptsUpdate`, `receiver.matchesOutputSelection`) → store, plus
    /// `rememberOutput` (identity, `preferenceKind`) only while the saved output is the session's previous or new
    /// endpoint; `onOutputState` (same guards, `receiver.matchesOutputState`) → `outputPause`,
    /// `protectedDefaultSpeaker`; `onMicrophoneSelection` (token, retained, not STOPPING) → `input`;
    /// `onMicrophoneState(value, pending)` (token, phase ∉ {stopping, pausing}, `receiver.microphoneMuteRequested ==
    /// value`) → `muted`, `changing`; `onMicrophoneCaptureEnabled` (same live guard) sets `phoneEnabledCapture`;
    /// `onMicrophoneCaptureRetained` (same live guard) → `captureRetainedWhileMuted` (Now Playing). Each accepted
    /// update publishes.
    private func makeCallbacks(_ id: String, text: String) -> SessionCallbacks {
        SessionCallbacks(
            onStatus: { [weak self] value in MainActor.assumeIsolated { self?.receiverUpdate(id, message: value) } },
            onDiagnostics: { [weak self] value in
                MainActor.assumeIsolated { self?.receiverUpdate(id, diagnostics: value) }
            },
            onPhase: { [weak self] phase in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsCallback(id), self.lifecycle.update(id, phase: phase) else { return }
                    if phase == .playing {
                        self.inputSwitchActionOrigin = nil
                        self.resumable = self.mode == .duplex
                        if self.rememberedToken != id {
                            self.rememberedToken = id
                            self.dependencies.rememberConnection(text)
                        }
                    }
                    self.publish()
                }
            },
            onEnded: { [weak self] end in
                MainActor.assumeIsolated {
                    guard let self, !self.terminating else { return }
                    // A superseded worker must still finish so its input replacement can begin.
                    self.finish(id, end)
                }
            },
            onNetworkStatus: { [weak self] value in
                MainActor.assumeIsolated { self?.receiverUpdate(id, network: value) }
            },
            onOutputSelection: { [weak self] selection in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsLiveCallback(id), self.outputSelection.acceptsUpdate(selection),
                        self.receiver?.matchesOutputSelection(selection) == true
                    else { return }
                    // Never overwrite an output saved for the next connection outside this session
                    // (`MicrophoneService.kt:216-221`); a Windows choice in this session is saved like a local one.
                    let persists = OutputSelection.persistsSessionUpdate(
                        saved: self.dependencies.restoredOutput(), previous: self.outputSelection, update: selection)
                    self.outputSelection = selection
                    if persists { self.dependencies.rememberOutput(selection) }
                    self.publish()
                }
            },
            onOutputState: { [weak self] pause, protected in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsLiveCallback(id),
                        self.receiver?.matchesOutputState(pause: pause, protectedSpeaker: protected) == true
                    else { return }
                    self.outputPause = pause
                    self.protectedDefaultSpeaker = protected
                    self.publish()
                }
            },
            onMicrophoneState: { [weak self] value, pending in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsLiveCallback(id), self.receiver?.microphoneMuteRequested == value else {
                        return
                    }
                    self.muted = value
                    self.changing = pending
                    self.publish()
                }
            },
            onMicrophoneSelection: { [weak self] selection in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsCallback(id), self.lifecycle.view.retained,
                        self.lifecycle.view.phase != .stopping
                    else { return }
                    self.input = selection
                    self.publish()
                }
            },
            onMicrophoneCaptureRetained: { [weak self] retained in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsLiveCallback(id) else { return }
                    self.captureRetainedWhileMuted = retained
                    self.publish()
                }
            },
            onMicrophoneCaptureEnabled: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.acceptsLiveCallback(id) else { return }
                    // Capture authorization needs actual capture evidence. Network/headset holds can report an
                    // unapplied Unmute with pending=false; muted keep-alive capture is not the phone enabling its
                    // microphone.
                    self.phoneEnabledCapture = true
                    self.publish()
                }
            })
    }

    private func acceptsCallback(_ id: String) -> Bool {
        !terminating && lifecycle.token == id && supersededReceiver != id
    }

    private func acceptsLiveCallback(_ id: String) -> Bool {
        acceptsCallback(id) && lifecycle.view.active && lifecycle.view.phase != .stopping
            && lifecycle.view.phase != .pausing
    }

    // MARK: - Phone settings exchange v1 (D046)

    /// This session's live settings for Windows (`MicrophoneService.kt:201-210`): `current` is nil unless
    /// `acceptsLiveCallback(id)` (not terminating, the current and not superseded token, active, neither PAUSING nor
    /// STOPPING); `apply` goes through `setOutputEnabled` and `setMuted` with their own guards, saving only a mute;
    /// `applyOutput` goes through `setOutputSelection`; `changed` republishes. None starts a session, requests
    /// permission or bypasses Connect consent: an unmute runs the worker's gated verify-and-open flow of this already
    /// authorized session (`MicrophoneControl.apply`), and only after the phone itself opened capture in it while
    /// permission is still granted.
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

    /// Duplex advertises "Play desktop audio" and its media output (`audio.output`, live only while the session uses
    /// the media output, `usesMediaOutput`; a Bluetooth headset microphone keeps the choice for a later switch to a
    /// phone, wired or USB microphone); microphone-only has no output. Both modes advertise the mute per
    /// `MicrophoneView.offersPhoneControlMute` (no change in flight, `canSetMuted(!muted)`, and while muted only with
    /// record permission granted now, capture the phone itself enabled in this session, and the scene active or a muted
    /// capture already running). Permission is read here at every snapshot and apply, not only at Connect. Adding or
    /// removing the field changes the revision, so an unmute from a stale Windows editor is rejected.
    private func phoneLiveSettings(_ id: String) -> PhoneLiveSettings? {
        guard acceptsLiveCallback(id) else { return nil }
        let mutable = shownView().offersPhoneControlMute(
            applicationActive: applicationActive, captureRetainedWhileMuted: captureRetainedWhileMuted,
            permissionGranted: dependencies.permission.status == .granted,
            captureEnabledThisSession: phoneEnabledCapture)
        return PhoneLiveSettings(
            outputEnabled: mode == .duplex ? outputEnabled : nil, microphoneMuted: mutable ? muted : nil,
            output: mode == .duplex ? outputSelection : nil, outputAppliesLive: usesMediaOutput)
    }

    /// Applies the advertised live values, output first (`MicrophoneService.kt:207-209`), each through the
    /// controller's own path, then requires the result to equal the request; a field this session does not
    /// advertise right now is refused (so an unmute before the phone enabled capture, or without permission, changes
    /// nothing). Unlike Android, a Windows edit changes only this session: "Play desktop audio" and an unmute are not
    /// saved, so neither switches the next Connect's mode or starts it unmuted. A Windows mute is saved like the
    /// phone's own Mute, because that direction only withholds the microphone.
    private func applyPhoneLiveSettings(_ id: String, _ requested: PhoneLiveSettings) throws {
        guard let live = phoneLiveSettings(id), requested.output == nil else {
            throw PhoneControlAdapter.ApplyFailure("live session unavailable")
        }
        if let enabled = requested.outputEnabled {
            guard live.outputEnabled != nil else { throw PhoneControlAdapter.ApplyFailure("output unavailable") }
            setOutputEnabled(enabled, saves: false)
            guard outputEnabled == enabled else { throw PhoneControlAdapter.ApplyFailure("output unchanged") }
        }
        if let value = requested.microphoneMuted {
            guard live.microphoneMuted != nil else { throw PhoneControlAdapter.ApplyFailure("mute unavailable") }
            setMuted(value, saves: value)
            guard muted == value else { throw PhoneControlAdapter.ApplyFailure("mute unchanged") }
        }
    }

    /// A Windows `audio.output` choice of a duplex session (Android's chooser path is `MicrophoneService.kt:291-304`):
    /// exactly the phone's own `setOutputSelection`, so the same phases accept it (`acceptsOutputChoice`: CONNECTING,
    /// including an input-switch replacement, and SWITCHING refuse), the refresh for this input allows the iPhone
    /// speaker only while it can be pinned, and the choice is saved like a local one, so a duplex resume and an input
    /// switch pass their output preflight. With a phone, wired or USB microphone the worker switches now, keeping
    /// desktop audio gated until the new route verifies and ending the session if it never does; a Bluetooth headset
    /// microphone keeps its coupled route and holds the choice for a later switch to a non-Bluetooth input. Nothing
    /// reconnects or reloads the keep-alive, and mute, "Play desktop audio", capture and permission are untouched.
    /// Throws unless the session then uses exactly that endpoint.
    private func applyPhoneOutput(_ id: String, _ requested: OutputSelection) throws {
        guard phoneLiveSettings(id)?.output != nil else {
            throw PhoneControlAdapter.ApplyFailure("output unavailable")
        }
        guard setOutputSelection(requested), outputSelection.sameEndpoint(requested) else {
            throw PhoneControlAdapter.ApplyFailure("output unchanged")
        }
    }

    private func receiverUpdate(
        _ id: String, message: String? = nil, diagnostics: String? = nil, network: String? = nil
    ) {
        guard acceptsCallback(id),
            lifecycle.update(id, message: message, diagnostics: diagnostics, networkStatus: network)
        else { return }
        publish()
    }

    // MARK: - Live input change

    /// `switchInputFromActivity(selected, expected)` (`:246-272`): token must equal `inputActionToken()`,
    /// `inputAvailable(selected)` and permission granted; duplex with a non-Bluetooth target also needs a valid media
    /// output; iOS also refuses a Bluetooth target while a non-Bluetooth session runs (limitation). Same selection →
    /// true. PAUSED/INTERRUPTED → retain only. Otherwise `inputChange.begin(expected, selected, now)`,
    /// `lifecycle.switchRoute(expected)` (else cancel, false), `supersededReceiver = inputSwitchActionOrigin =
    /// expected`, `input = selected`, `changing = true`, `receiver.close(.pause)`, 20 s timeout (`inputChangeTimedOut =
    /// true; inputChange.cancel(); stop(.failure)`). Persist the identity and `preferredInputKind` (`rememberInput`);
    /// publish; true.
    func switchInput(_ selection: MicrophoneSelection, expectedToken: String) -> Bool {
        guard inputActionToken() == expectedToken, dependencies.permission.status == .granted,
            dependencies.inputAvailable(selection)
        else { return false }
        if mode == .duplex && !selection.isBluetooth {
            guard !dependencies.loadPreferences().needsOutputSelection(outputSelection),
                dependencies.outputAvailable(outputSelection, selection)
            else { return false }
        }
        let paused = lifecycle.view.phase == .paused || lifecycle.view.phase == .interrupted
        if !paused && selection.isBluetooth && !input.isBluetooth { return false }
        if input.sameDevice(selection) { return true }
        if paused {
            input = selection
        } else {
            guard inputChange.begin(expectedToken, selection, nowMs: dependencies.clock.nowMs()) else { return false }
            guard lifecycle.switchRoute(expectedToken) else {
                inputChange.cancel()
                return false
            }
            supersededReceiver = expectedToken
            inputSwitchActionOrigin = expectedToken
            input = selection
            changing = true
            receiver?.close(.pause)
            scheduleInputChangeTimeout()
        }
        dependencies.rememberInput(selection)
        publish()
        return true
    }

    // MARK: - Mute and output

    /// `setMuted(value)` (`:288-298`): expired → return; requires `canSetMuted(value)`; `muted = value`;
    /// preference `microphoneEnabled = !value`; while PAUSED/INTERRUPTED/PAUSING only the retained
    /// preference changes (`changing = phase == .pausing`), else `changing = true` and
    /// `receiver.setMicrophoneMuted(value)`; publish.
    func setMuted(_ muted: Bool) {
        setMuted(muted, saves: true)
    }

    /// `saves: false` (a Windows unmute) leaves `microphoneEnabled` as the phone last saved it, so the change ends
    /// with this session and a later Connect never starts the microphone because of it.
    private func setMuted(_ muted: Bool, saves: Bool) {
        if expirePauseIfNeeded() { return }
        guard shownView().canSetMuted(muted) else { return }
        self.muted = muted
        if saves {
            dependencies.updatePreferences { preferences in
                var updated = preferences
                updated.microphoneEnabled = !muted
                return updated
            }
        }
        let phase = lifecycle.view.phase
        if phase == .paused || phase == .interrupted || phase == .pausing {
            changing = phase == .pausing
        } else {
            changing = true
            receiver?.setMicrophoneMuted(muted)
        }
        publish()
    }

    /// `setOutputEnabled(enabled)` (`:299-306`): duplex only, `canSetOutput`; persists and forwards. iOS never holds a
    /// FOCUS_MANUAL output pause, so no focus re-request.
    func setOutputEnabled(_ enabled: Bool) {
        setOutputEnabled(enabled, saves: true)
    }

    /// `saves: false` (a Windows edit) changes only this session; the saved `outputEnabled` that picks the next
    /// Connect's mode stays the phone's.
    private func setOutputEnabled(_ enabled: Bool, saves: Bool) {
        if expirePauseIfNeeded() || terminating || mode == .microphone || !lifecycle.view.canSetOutput { return }
        outputEnabled = enabled
        if saves {
            dependencies.updatePreferences { preferences in
                var updated = preferences
                updated.outputEnabled = enabled
                return updated
            }
        }
        receiver?.setOutputEnabled(enabled)
        publish()
    }

    /// `setOutputSelection(selected)` (`:273-287`): duplex only, `phase.acceptsOutputChoice` (playing, recovering,
    /// routeRecovering, paused, interrupted — the UI's rule); `refreshOutput` (computes `speakerPinnable` from the plan
    /// and input) else false; PHONE clears speaker protection; persists the identity and `preferenceKind`
    /// (`rememberOutput`); forwarded to the receiver **only for non-Bluetooth inputs**; publish; true. A Windows
    /// `audio.output` choice takes this same path (`applyPhoneOutput`).
    func setOutputSelection(_ selection: OutputSelection) -> Bool {
        if expirePauseIfNeeded() || terminating || mode == .microphone { return false }
        guard lifecycle.view.phase.acceptsOutputChoice,
            let refreshed = dependencies.refreshOutput(selection, input)
        else { return false }
        outputSelection = refreshed
        if selection.kind == .phone { protectedDefaultSpeaker = false }
        dependencies.rememberOutput(refreshed)
        if !input.isBluetooth { receiver?.setOutputSelection(refreshed) }
        publish()
        return true
    }

    // MARK: - Resume / stop

    /// `resumeFromActivity()` (`:360-366`): expired → return; requires `canResume`; PAUSING → `queuePlay`;
    /// else `resumeConnection(userRequested: true)`.
    func resume() {
        if expirePauseIfNeeded() { return }
        guard let id = lifecycle.token, shownView().canResume else { return }
        if lifecycle.queuePlay(id) {
            publish()
            return
        }
        resumeConnection(userRequested: true)
    }

    /// spelling of `resume()` (lock-screen Play while `canResume`).
    func resumeFromApp() { resume() }

    /// `stopFromActivity()` = `stop(.user)`.
    func stop() { stop(.user) }

    /// `stop(reason, message?)` (`:387-400`): requires `lifecycle.stopping(id)`; an explicit Stop's message
    /// wins over the worker's; clears switch origin, input change, pause timer/window, retained link and
    /// `resumable`; view `changing = true, muted = true` (preference untouched); `receiver.close(reason)`;
    /// publish; no receiver → `finish` immediately.
    func stop(_ reason: StopReason, message: String? = nil) {
        guard let id = lifecycle.token, lifecycle.stopping(id) else { return }
        let end = StreamEnd(reason: reason, message: message ?? endedMessage(reason))
        requestedStop = end
        inputSwitchActionOrigin = nil
        cancelInputChange()
        cancelPauseExpiry()
        pauseWindow.clear()
        retainedLink = nil
        resumable = false
        changing = true
        muted = true
        captureRetainedWhileMuted = false
        receiver?.close(reason)
        publish()
        if receiver == nil { finish(id, end) }
    }

    /// `finish(id, end)` (`:418-462`): ignores other tokens; `result = requestedStop ?? end`; `switchExpired =
    /// inputChangeTimedOut || (inputChange.matches(id) && expired)`; `nextInput = inputChange.take(id, now)` when
    /// SWITCHING and not FAILURE; cancel the switch timer; `failed`; `pausing = phase == .pausing && !failed`; message
    /// = switch timeout / `SessionLifecycle.Messages. duplexPaused(automatic: resumeOnFocus)` / result;
    /// `lifecycle.finish(id, message, failed, end.diagnostics)`; `receiver = nil`, `changing = false`. Replacement
    /// (`nextInput`, not failed): keep the audio session active and `beginConnection(retainedLink, mode, nextInput,
    /// muted, keepFocus: false)` (failure → `restorePause`, `stopping`, `finish(…, switchReconnectFailed, failed:
    /// true)`). Pausing: `releaseTransport()`, publish, then `playAfterPause` → `resumeConnection(true)` or
    /// `resumeOnFocus && focusReturned` → `resumeConnection(false)`. The replacement and the pause keep
    /// `phoneEnabledCapture` (the same authorized session). Otherwise clear pause
    /// window/link/resumable/muted/`phoneEnabledCapture`/output pause/protection/switch origin, `releaseTransport()`,
    /// publish.
    private func finish(_ id: String, _ end: StreamEnd) {
        guard lifecycle.token == id else { return }
        let result = requestedStop ?? end
        let now = dependencies.clock.nowMs()
        let switchExpired = inputChangeTimedOut || (inputChange.matches(id) && inputChange.expired(nowMs: now))
        let nextInput =
            lifecycle.view.phase == .switching && result.reason != .failure
            ? inputChange.take(id, nowMs: now) : nil
        cancelInputChange()
        let failed = result.reason == .failure || switchExpired
        let pausing = lifecycle.view.phase == .pausing && !failed
        let message =
            switchExpired
            ? MicrophoneStatusText.Messages.switchTimedOut
            : (pausing ? SessionLifecycle.Messages.duplexPaused(automatic: lifecycle.resumeOnFocus) : result.message)
        guard lifecycle.finish(id, message: message, failed: failed, diagnostics: end.diagnostics) else { return }
        receiver = nil
        captureRetainedWhileMuted = false
        pendingActivation = nil
        pendingLink = nil
        pendingPlan = nil
        changing = false
        if let nextInput, !failed, let text = retainedLink {
            do {
                try beginConnection(
                    text: text, mode: mode, input: nextInput, initiallyMuted: muted, keepFocus: false,
                    resume: SessionResume.inputSwitch)
                return
            } catch {
                lifecycle.restorePause(id)
                lifecycle.stopping(id)
                finish(id, StreamEnd(reason: .failure, message: MicrophoneStatusText.Messages.switchReconnectFailed))
                return
            }
        }
        if pausing {
            releaseTransport()
            publish()
            if expirePauseIfNeeded() { return }
            if lifecycle.playAfterPause {
                resumeConnection(userRequested: true)
            } else if lifecycle.resumeOnFocus && lifecycle.focusReturned {
                resumeConnection(userRequested: false)
            }
            return
        }
        cancelPauseExpiry()
        pauseWindow.clear()
        retainedLink = nil
        resumable = false
        muted = true
        phoneEnabledCapture = false
        outputPause = nil
        protectedDefaultSpeaker = false
        inputSwitchActionOrigin = nil
        supersededReceiver = nil
        requestedStop = nil
        releaseTransport()
        publish()
    }

    // MARK: - Interruptions and system events

    /// `AVAudioSession.interruptionNotification` routed by `SessionCoordinator` while this controller owns the session
    /// (the coordinator already drops `.appWasSuspended` and non-focus reasons; the flags stay for direct callers).
    /// `.began`: `suspended` → ignore; `routeDisconnected` → ignore here (route loss reaches
    /// `MicrophoneRouting.routeDidChange()` through the session's route fan-out); duplex → `pauseForFocus(id,
    /// automatic: true, .focusTransient)` (which stops when not resumable); mic-only busy → `stop(.focus)`. `.ended` +
    /// `shouldResume` → `lifecycle.focusGained()` → `resumeConnection(userRequested: false)` else publish; `.ended`
    /// without it while armed and PAUSING/INTERRUPTED → `pauseForFocus(id, automatic: false, .focusPermanent)`.
    func handleInterruption(began: Bool, shouldResume: Bool, suspended: Bool = false, routeDisconnected: Bool = false) {
        if expirePauseIfNeeded() { return }
        guard let id = lifecycle.token else { return }
        if began {
            if suspended || routeDisconnected { return }
            if mode == .duplex {
                pauseForFocus(id, automatic: true, reason: .focusTransient)
            } else if lifecycle.view.busy {
                stop(.focus)
            }
            return
        }
        if shouldResume {
            if lifecycle.focusGained() {
                resumeConnection(userRequested: false)
            } else {
                publish()
            }
        } else if lifecycle.resumeOnFocus && (lifecycle.view.phase == .pausing || lifecycle.view.phase == .interrupted)
        {
            pauseForFocus(id, automatic: false, reason: .focusPermanent)
        }
    }

    /// Route change `.oldDeviceUnavailable` with a non-built-in previous output (Android `ACTION_AUDIO_BECOMING_NOISY`,
    /// `:83-97`), only while `noisyArmed`:
    /// 1. `receiver.mediaOutputBecomingNoisy()` → handled; 2. following the default media route →
    /// `protectedDefaultSpeaker = true`, call it anyway; 3. media-output duplex → ignore; 4. duplex not
    /// SWITCHING and not CONNECTING for an input switch → `stop(.output)`.
    func outputDeviceUnavailable() {
        guard noisyArmed else { return }
        if receiver?.mediaOutputBecomingNoisy() == true { return }
        if followsDefaultMedia {
            protectedDefaultSpeaker = true
            receiver?.mediaOutputBecomingNoisy()
            return
        }
        if usesMediaOutput { return }
        let phase = lifecycle.view.phase
        if mode == .duplex && phase != .switching && !(phase == .connecting && inputSwitchActionOrigin != nil) {
            stop(.output)
        }
    }

    /// `mediaServicesWereResetNotification`: a live receiver fails itself (`microphone_runtime` when capture was
    /// active, else `.failure`); without a receiver (PAUSED, INTERRUPTED, activation pending) → `stop(.failure)`.
    /// Nothing is re-applied until the next Connect.
    func mediaServicesWereReset() {
        guard lifecycle.view.retained, receiver == nil else { return }
        stop(.failure)
    }

    /// `applicationWillTerminate` (Android `onDestroy` `:516-529`): `terminating = true`; `receiver.close(.service)`;
    /// block up to the shutdown bound in `receiver.awaitRemoteStop(timeoutMs: nil)`; clear link/resumable/input
    /// change/pause window/timers; if retained, the last view becomes ENDED with `Messages.serviceEnded`; observers
    /// cleared.
    func applicationWillTerminate() {
        guard !terminating else { return }
        terminating = true
        receiver?.close(.service)
        _ = receiver?.awaitRemoteStop(timeoutMs: nil)
        cancelInputChange()
        cancelPauseExpiry()
        pauseWindow.clear()
        retainedLink = nil
        resumable = false
        pendingActivation = nil
        pendingLink = nil
        pendingPlan = nil
        changing = false
        muted = true
        phoneEnabledCapture = false
        if let id = lifecycle.token {
            lifecycle.stopping(id)
            lifecycle.finish(id, message: MicrophoneStatusText.Messages.serviceEnded)
        }
        lease?.end()
        view = shownView()
        observers.removeAll()
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
        activityObservers.removeAll()
    }

    /// scene `.active` changes (`UIApplication.willResignActiveNotification` / `didBecomeActiveNotification`),
    /// forwarded to the live receiver.
    func applicationActiveChanged(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        receiver?.setApplicationActive(active)
        publish()
    }

    /// Out-of-app action carrying a session generation (`onStartCommand`, `:401-417`): filtered by
    /// `RouteActionScope.accepts(current:requested:replacing:phase:safetyOnly:)` with `safetyOnly` for
    /// Stop and Mute (an old action may only Stop or Mute its own in-flight replacement).
    func handleOutOfAppAction(_ action: MicrophoneStatusText.Action, generation: String?) {
        if expirePauseIfNeeded() { return }
        let safetyOnly = action == .stop || action == .mute
        guard
            RouteActionScope.accepts(
                current: lifecycle.token, requested: generation,
                replacing: inputSwitchActionOrigin, phase: lifecycle.view.phase,
                safetyOnly: safetyOnly)
        else { return }
        switch action {
        case .stop: stop(.user)
        case .mute: setMuted(true)
        case .unmute: setMuted(false)
        case .resumeDuplex: resume()
        case .resumeAudio: setOutputEnabled(true)
        }
    }

    /// Now Playing title.
    var nowPlayingTitle: String { MicrophoneStatusText.title(mode: view.mode) }

    /// Now Playing artist / in-app status detail; a muted microphone-only session in the background reports kept-open
    /// capture only while the worker reports one actually running (`captureRetainedWhileMuted`), not merely because the
    /// Advanced keep-alive setting is on: iOS may refuse the background start, and headset recovery pauses capture.
    var nowPlayingDetail: String {
        MicrophoneStatusText.detail(
            view, keptOpenForBackground: !applicationActive && view.mode == .microphone && captureRetainedWhileMuted)
    }

    // MARK: - Internals

    /// `pauseForFocus(id, automatic, reason)` (`:345-359`): not duplex / not resumable / no retained link →
    /// `stop(.focus)`; PAUSED → nothing; `firstPause`; `lifecycle.pause`; cancel input change; `changing =
    /// receiver != nil`; `receiver.close(reason)`; `pauseWindow.retain(now)`; first pause → expiry timer;
    /// publish. Deactivation waits for the worker's end (`finish` → `releaseTransport`).
    private func pauseForFocus(_ id: String, automatic: Bool, reason: StopReason) {
        if mode != .duplex || !resumable || retainedLink == nil {
            stop(.focus)
            return
        }
        if lifecycle.view.phase == .paused { return }
        let firstPause = lifecycle.view.phase != .pausing && lifecycle.view.phase != .interrupted
        guard lifecycle.pause(id, automatic: automatic) else { return }
        cancelInputChange()
        changing = receiver != nil
        receiver?.close(reason)
        pauseWindow.retain(nowMs: dependencies.clock.nowMs())
        if firstPause { schedulePauseExpiry() }
        publish()
    }

    /// `resumeConnection(userRequested)` (`:367-375`): expired → return; only from PAUSED/INTERRUPTED with
    /// a retained link; `beginConnection(link, mode, input, muted, keepFocus: !userRequested, resume: SessionResume.resumed(userRequested:))`
    /// (`MicrophoneService.kt:389`: in-app Resume, lock-screen Play, `.resumeDuplex`, a queued Play and focus
    /// return); failure → `stop(.failure, Messages.duplexResumeFailed)`.
    private func resumeConnection(userRequested: Bool) {
        if expirePauseIfNeeded() { return }
        let phase = lifecycle.view.phase
        guard phase == .paused || phase == .interrupted, let text = retainedLink else { return }
        do {
            try beginConnection(
                text: text, mode: mode, input: input, initiallyMuted: muted, keepFocus: !userRequested,
                resume: SessionResume.resumed(userRequested: userRequested))
        } catch {
            stop(.failure, message: MicrophoneStatusText.Messages.duplexResumeFailed)
        }
    }

    /// `expirePauseIfNeeded()` (`:379-383`): the 5-minute window lapsed → `stop(.focus, duplexPauseExpired)`.
    @discardableResult
    private func expirePauseIfNeeded() -> Bool {
        guard pauseWindow.expired(nowMs: dependencies.clock.nowMs()) else { return false }
        stop(.focus, message: MicrophoneStatusText.Messages.duplexPauseExpired)
        return true
    }

    /// First pause of an episode: wake at the window's deadline (the entry checks remain authoritative).
    private func schedulePauseExpiry() {
        pauseExpiryTimer?.cancel()
        guard let remaining = pauseWindow.remainingMs(nowMs: dependencies.clock.nowMs()) else { return }
        pauseExpiryTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(remaining))
            guard !Task.isCancelled else { return }
            self?.expirePauseIfNeeded()
        }
    }

    private func cancelPauseExpiry() {
        pauseExpiryTimer?.cancel()
        pauseExpiryTimer = nil
    }

    /// 20 s input-change timeout (`inputChangeTimeout`, `:263-266`).
    private func scheduleInputChangeTimeout() {
        inputChangeTimer?.cancel()
        inputChangeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(MicrophoneSessionController.inputChangeTimeoutMs))
            guard !Task.isCancelled, let self else { return }
            self.inputChangeTimedOut = true
            self.inputChange.cancel()
            self.stop(.failure)
        }
    }

    private func cancelInputChange() {
        inputChange.cancel()
        inputChangeTimer?.cancel()
        inputChangeTimer = nil
    }

    /// `releaseTransport()`: noisy disarmed; deactivate the arbiter if this controller activated it.
    private func releaseTransport() {
        noisyArmed = false
        if audioActive {
            dependencies.deactivateAudio()
            audioActive = false
        }
    }

    /// Lease policy evaluated on every publish: needed while CONNECTING/SWITCHING/PAUSING/ STOPPING, while a duplex
    /// media output recovers in ROUTE_RECOVERING (iOS, `SessionPhase.leasesOutputRecovery(pause:)`), during
    /// microphone-only ROUTE_RECOVERING (headset recovery pauses capture and there is no playout, so a locked phone
    /// would otherwise be suspended before the configured window ends; duplex playout keeps running silenced), or while
    /// an activation is pending. iOS bounds the lease (typically about 30 s), so a longer window on a locked phone is a
    /// device risk.
    private func updateLease() {
        let phase = lifecycle.view.phase
        let needed =
            phase == .connecting || phase == .switching || phase == .pausing || phase == .stopping
            || phase.leasesOutputRecovery(pause: outputPause) || (mode == .microphone && phase == .routeRecovering)
            || pendingActivation != nil
        if needed {
            if lease == nil {
                lease = dependencies.makeLease { [weak self] in self?.backgroundLeaseExpired() }
            }
            if let lease, !lease.isHeld { lease.begin() }
        } else if let lease, lease.isHeld {
            lease.end()
        }
    }

    /// Lease expiry: ends the lease; still CONNECTING → `receiver.expireBackgroundSetup()`, or without a receiver
    /// `finish(id, StreamEnd(.failure, backgroundSetupExpired))`.
    private func backgroundLeaseExpired() {
        lease?.end()
        guard let id = lifecycle.token, lifecycle.view.phase == .connecting else { return }
        if let receiver {
            receiver.expireBackgroundSetup()
        } else {
            pendingActivation = nil
            finish(id, StreamEnd(reason: .failure, message: SessionLifecycle.Messages.backgroundSetupExpired))
        }
    }

    /// `publish()` (`:463-467`): `view = shownView()`, observers in order, lease policy.
    private func publish() {
        view = shownView()
        let current = view
        for observer in observers { observer.callback(current) }
        updateLease()
    }

    /// `MicrophoneView(state.view.copy(outputEnabled, outputSelection, outputPause), muted, changing, mode, input)`,
    /// plus the session's Bluetooth route recovery window (iOS pause text).
    private func shownView() -> MicrophoneView {
        var session = lifecycle.view
        session.outputEnabled = outputEnabled
        session.outputSelection = outputSelection
        session.outputPause = outputPause
        session.bluetoothRecoveryMs = bluetoothRecoveryMs
        return MicrophoneView(session: session, muted: muted, changing: changing, mode: mode, input: input)
    }

    /// `mode.endedMessage(reason)` for microphone modes.
    private func endedMessage(_ reason: StopReason) -> String {
        reason.endedMessage(microphone: true, reconnectAction: MicrophoneSessionController.reconnectAction)
    }

    /// `mode.usesMediaOutput(input.kind)`: duplex with a non-Bluetooth input.
    private var usesMediaOutput: Bool { mode == .duplex && !input.isBluetooth }

    /// `usesMediaOutput && !outputSelection.explicit`.
    private var followsDefaultMedia: Bool { usesMediaOutput && !outputSelection.explicit }

    /// scene observation (main queue).
    private func startObservingApplicationState() {
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applicationActiveChanged(false) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applicationActiveChanged(true) }
            },
        ]
    }
}

// MARK: - Nested types

extension MicrophoneSessionController {
    /// Result of `Dependencies.activateAudio` (activation error mapping, reduced).
    enum ActivationResult: Equatable, Sendable {
        case success
        /// `.insufficientPriority` / `.cannotInterruptOthers` / `.siriIsRecording`.
        case busy
        /// `.cannotStartPlaying` / `.cannotStartRecording` (background start refused).
        case backgroundStart
        /// Anything else.
        case failed
    }

    /// Preflight refusals other than `MicrophoneRouteError` (Android `require`/`check` failures; the UI shows its
    /// generic start text for them, step 7).
    enum PreflightError: Error, Equatable, Sendable {
        /// Not a paired v3 link, unparsable, or expired.
        case linkUnavailable
        /// Record permission not granted.
        case permissionDenied
        /// Duplex with a non-Bluetooth input but no available/verified media output.
        case outputUnavailable
    }

    /// `BackgroundExecutionLease`: `beginBackgroundTask` wrapper; the expiration handler is the `onExpire` closure
    /// given to `Dependencies.makeLease`.
    @MainActor
    protocol BackgroundLease: AnyObject {
        var isHeld: Bool { get }
        func begin()
        func end()
    }

    /// Collaborators (built by `Dependencies.live(...)` in `MicrophoneLiveWiring.swift`; fakes in tests).
    struct Dependencies {
        /// Sleep-inclusive monotonic milliseconds for the pause and switch windows.
        var clock: any MonotonicClock
        /// Record permission (re-checked at start, automatic resume and input switch, and by every phone settings
        /// snapshot and apply before a Windows unmute is offered or applied).
        var permission: any MicrophonePermissionProviding
        /// `MicrophoneInventory.available(_:)`.
        var inputAvailable: @MainActor (MicrophoneSelection) -> Bool
        /// `OutputRouteProviding.available(_:)` for the given microphone input (`speakerPinnable`).
        var outputAvailable: @MainActor (OutputSelection, MicrophoneSelection) -> Bool
        /// `OutputRouteProviding.refresh(_:)` for the given microphone input.
        var refreshOutput: @MainActor (OutputSelection, MicrophoneSelection) -> OutputSelection?
        /// `AudioPreferencesStore.load()`.
        var loadPreferences: @MainActor () -> AudioPreferences
        /// `AudioPreferencesStore.update(_:)` (writes all eight keys).
        var updatePreferences: @MainActor (_ change: (AudioPreferences) -> AudioPreferences) -> Void
        /// `AudioPreferencesStore.restoredOutputSelection()`: the idle output of a new process (the remembered
        /// pin while its kind is saved, else the kind-only restore).
        var restoredOutput: @MainActor () -> OutputSelection
        /// `AudioPreferencesStore.rememberOutput(_:)`: identity and `preferredOutputKind` of an output choice.
        var rememberOutput: @MainActor (OutputSelection) -> Void
        /// `AudioPreferencesStore.rememberInput(_:)`: identity and `preferredInputKind` of an input choice.
        var rememberInput: @MainActor (MicrophoneSelection) -> Void
        /// `AudioSessionArbiter.prepare(plan)` with the completion on the main actor.
        var activateAudio:
            @MainActor (_ plan: AudioSessionPlan, _ completion: @escaping @MainActor (ActivationResult) -> Void) -> Void
        /// Releases the activation taken by `activateAudio` (`AudioSessionArbiter.deactivate(_:notifyOthers:)`); no-op
        /// when none is held. Called only from `releaseTransport()` after the worker ended.
        var deactivateAudio: @MainActor () -> Void
        /// `SessionController(configuration, callbacks:, dependencies:)`.
        var makeReceiver: @MainActor (SessionConfiguration, SessionCallbacks) throws -> any StreamReceiving
        /// `SavedConnectionStore.remember(_:)` on the first PLAYING.
        var rememberConnection: @MainActor (String) -> Void
        /// `BackgroundExecutionLease(name:onExpire:)`.
        var makeLease: @MainActor (_ onExpire: @escaping @MainActor () -> Void) -> any BackgroundLease
        /// Observe `UIApplication` activity for (false in tests).
        var observesApplicationState: Bool
        /// Advanced audio settings: the Bluetooth route recovery window read at Connect (the session reads the
        /// keep-alive setting itself, and Now Playing follows its reported state); production
        /// `AdvancedAudioPreferencesStore.shared.load()`, tests inject values.
        var advancedAudio: @MainActor () -> AdvancedAudioPreferences
        /// At each explicit Connect (`connect`, not an input-switch replacement or a duplex resume): the saved
        /// keep-alive becomes the live value the session reads, so a Windows edit held for the next connection
        /// applies from here. Production `AdvancedAudioPreferencesStore.shared.reloadLive()`.
        var reloadKeepAlive: @MainActor () -> Void

        init(
            clock: any MonotonicClock,
            permission: any MicrophonePermissionProviding,
            inputAvailable: @escaping @MainActor (MicrophoneSelection) -> Bool,
            outputAvailable: @escaping @MainActor (OutputSelection, MicrophoneSelection) -> Bool,
            refreshOutput: @escaping @MainActor (OutputSelection, MicrophoneSelection) -> OutputSelection?,
            loadPreferences: @escaping @MainActor () -> AudioPreferences,
            updatePreferences: @escaping @MainActor (_ change: (AudioPreferences) -> AudioPreferences) -> Void,
            activateAudio:
                @escaping @MainActor (
                    _ plan: AudioSessionPlan, _ completion: @escaping @MainActor (ActivationResult) -> Void
                ) -> Void,
            deactivateAudio: @escaping @MainActor () -> Void,
            makeReceiver: @escaping @MainActor (SessionConfiguration, SessionCallbacks) throws -> any StreamReceiving,
            rememberConnection: @escaping @MainActor (String) -> Void,
            makeLease: @escaping @MainActor (_ onExpire: @escaping @MainActor () -> Void) -> any BackgroundLease,
            observesApplicationState: Bool = true,
            restoredOutput: (@MainActor () -> OutputSelection)? = nil,
            rememberOutput: (@MainActor (OutputSelection) -> Void)? = nil,
            rememberInput: (@MainActor (MicrophoneSelection) -> Void)? = nil,
            advancedAudio: @escaping @MainActor () -> AdvancedAudioPreferences = {
                AdvancedAudioPreferencesStore.shared.load()
            },
            reloadKeepAlive: @escaping @MainActor () -> Void = { AdvancedAudioPreferencesStore.shared.reloadLive() }
        ) {
            self.clock = clock
            self.permission = permission
            self.inputAvailable = inputAvailable
            self.outputAvailable = outputAvailable
            self.refreshOutput = refreshOutput
            self.loadPreferences = loadPreferences
            self.updatePreferences = updatePreferences
            // Without the device-memory closures (test fakes) only the kinds are restored and saved.
            self.restoredOutput =
                restoredOutput ?? { @MainActor in OutputSelection.restored(loadPreferences().preferredOutputKind) }
            self.rememberOutput =
                rememberOutput ?? { @MainActor selection in
                    updatePreferences { previous in
                        var next = previous
                        next.preferredOutputKind = selection.preferenceKind
                        return next
                    }
                }
            self.rememberInput =
                rememberInput ?? { @MainActor selection in
                    updatePreferences { previous in
                        var next = previous
                        next.preferredInputKind = selection.kind
                        return next
                    }
                }
            self.activateAudio = activateAudio
            self.deactivateAudio = deactivateAudio
            self.makeReceiver = makeReceiver
            self.rememberConnection = rememberConnection
            self.makeLease = makeLease
            self.observesApplicationState = observesApplicationState
            self.advancedAudio = advancedAudio
            self.reloadKeepAlive = reloadKeepAlive
        }
    }
}

// MARK: - UI protocol

extension MicrophoneSessionController: MicrophoneSessionControlling {}
