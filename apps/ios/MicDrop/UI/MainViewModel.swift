// Port of `MainActivity`'s flows, lifecycle and observers (`MainActivity.kt`).
//
// The pure enable/visible/text rules live in `ControlsDeriver` (MicDropCore); this type owns the state they read,
// performs the two pre-derive side effects and runs every user flow. All work is on the main actor; every
// controller/store observer is invoked synchronously from the publishing call.

import Foundation
import MicDropCore
import Observation
import SwiftUI

@MainActor
@Observable
final class MainViewModel {
    // MARK: Published UI state

    /// Every text/enabled/visible value of the screen (`ControlsDeriver.derive`).
    private(set) var render = ControlsRender()
    /// Invitation field text (never persisted; at most `ConnectionLink.maxLinkLength` characters).
    private(set) var invitationText = ""
    /// `scanStatusView` (hidden when empty).
    private(set) var scanStatus = ""
    /// iOS-only `Open Settings` link under the scan status after a camera denial.
    private(set) var scanSettingsVisible = false
    /// Media output list dialog (non-nil = presented).
    var outputChoicesDialog: [OutputChoice]? = nil
    /// Microphone input list dialog (non-nil = presented).
    var inputChoicesDialog: [MicrophoneChoice]? = nil
    /// "Connect to saved Windows?" / "Pair with Windows first".
    var discoveryAlert: DiscoveryAlert? = nil
    /// Change Windows address alert fields (non-nil = presented).
    var addressForm: AddressForm? = nil
    var scannerPresented = false
    var noticesPresented = false
    /// Programmatic expand-and-scroll request (Android `expand(true)`).
    private(set) var sectionRequest: SectionRequest? = nil
    /// Incremented to move focus to the invitation field.
    private(set) var invitationFocusRequest: UInt64 = 0

    let toasts: ToastCenter
    /// **Advanced > Allow Windows to change phone settings** (phone settings exchange v1, D046): saved at once and
    /// changeable at any time, also during a session (`MainActivity.kt:463-468`).
    let phoneControlOptIn: PhoneControlOptIn

    /// Discovered-host dialog state; the tapped host is re-validated on confirmation.
    enum DiscoveryAlert: Identifiable, Equatable {
        case savedHost(DiscoveredHost)
        case unknownHost(DiscoveredHost)

        var id: String {
            switch self {
            case .savedHost(let host): return "saved/" + host.id
            case .unknownHost(let host): return "unknown/" + host.id
            }
        }

        var host: DiscoveredHost {
            switch self {
            case .savedHost(let host), .unknownHost(let host): return host
            }
        }

        var title: String {
            switch self {
            case .savedHost: return Strings.discoveredConnectTitle
            case .unknownHost: return Strings.discoveryPairTitle
            }
        }

        var message: String {
            switch self {
            case .savedHost(let host): return Strings.discoveredConnectMessage(host: host.host, port: host.port)
            case .unknownHost: return Strings.discoveryPairFirst
            }
        }
    }

    /// Change-address fields, prefilled from the saved v3 record (`MainActivity.kt:1058-1066`).
    struct AddressForm: Equatable {
        var host: String
        var port: String
    }

    /// `ConnectionFailure.describe` code of the iOS Local Network row.
    static let localNetworkMarker = "[LOCAL_NETWORK]"

    // MARK: Dependencies

    private let playback: any PlaybackSessionControlling
    private let microphone: any MicrophoneSessionControlling
    private let saved: any SavedConnectionStoring
    private let settings: any AudioSettingsStore
    private let outputs: any OutputRouteProviding
    private let inputs: any MicrophoneRouteProviding
    private let tools: any LocalAudioTools
    private let permissions: any PermissionGateway
    private let volume: any VolumeReading
    private let discovery: LanDiscovery
    private let clearPausedPlayback: () -> Void
    private let storedStreamReport: () -> String?
    private let latestCrashReport: () async -> String
    private let copyToPasteboard: (String) -> Void
    private let setIdleTimerDisabled: (Bool) -> Void
    private let deviceLabel: () -> String
    private let revision: String
    private let versionName: String
    /// Read on every derive, so the Advanced summary follows each save (the Connection settings sheet, a Windows
    /// edit); the store keeps the saved value in memory.
    private let recoveryWindowMs: () -> Int

    // MARK: Model state (Android activity fields)

    @ObservationIgnored private var prefs = AudioPreferences()
    @ObservationIgnored private var sessionView = SessionView()
    @ObservationIgnored private var micView = MicrophoneView()
    @ObservationIgnored private var savedView = SavedConnectionView()
    @ObservationIgnored private var discoveryView = DiscoveryView()
    /// Saved connection parsed when the discovery view was last rendered (row labels).
    @ObservationIgnored private var savedLink: ConnectionLink?
    /// Android `selectedOutput` / `rememberedOutput`: the model lives for the process, so one value
    /// covers both. iOS restores an explicit external pin across launches (`RememberedAudioDevices`); it
    /// stays unavailable and gated until the current route resolves that identity.
    @ObservationIgnored private var selectedOutput = OutputSelection()
    /// Android `selectedMicrophone` / `rememberedInput`; restored across launches like `selectedOutput`.
    @ObservationIgnored private var selectedMicrophone = MicrophoneSelection()
    /// `settings.selectionGeneration` whose saved selections the idle rows already show (Windows edits, D046).
    @ObservationIgnored private var adoptedSelectionGeneration: UInt64 = 0
    @ObservationIgnored private var idleMessage: String?
    /// The last failure shown needs the iOS `Open Settings` link (denied permission).
    @ObservationIgnored private var failureNeedsSettings = false
    @ObservationIgnored private var latestDiagnostics: String?
    /// Latest local output probe snapshot (the "local output baseline" of later reports).
    @ObservationIgnored private var localBaseline: OutputSnapshot?
    @ObservationIgnored private var pendingConnect = false
    @ObservationIgnored private var showingMicrophone = false
    @ObservationIgnored private var pendingMicrophoneText: String?
    @ObservationIgnored private var pendingMicrophoneMode: StreamMode = .microphone
    @ObservationIgnored private var microphonePermissionReady = false
    @ObservationIgnored private var pendingInputChoice: PendingInputChoice?
    @ObservationIgnored private var inputChoiceReady = false
    @ObservationIgnored private var pendingScan: QRScanResult?
    /// Camera access was granted while the scene was not yet `.active` again.
    @ObservationIgnored private var pendingScannerPresentation = false
    private let pairingIntent = PairingConnectIntent()
    /// `scenePhase != .background`.
    @ObservationIgnored private var screenVisible = false
    /// `scenePhase == .active`.
    @ObservationIgnored private var screenResumed = false
    @ObservationIgnored private var probe: (any LocalOutputProbing)?
    @ObservationIgnored private var localGeneration: UInt64 = 0
    @ObservationIgnored private var localAudioHeld = false
    @ObservationIgnored private var crashReportBuilding = false
    @ObservationIgnored private var sectionSerial: UInt64 = 0
    /// Controller/store observation handles (`ObservationHandle` of each protocol) and the audio-event
    /// subscription; kept for the model's lifetime.
    @ObservationIgnored private var observationTokens: [AnyObject] = []

    private struct PendingInputChoice {
        let token: String
        let selection: MicrophoneSelection
    }

    private enum AddressError: Error {
        case invalidPort
    }

    // MARK: Init (`onCreate`, `MainActivity.kt:250-284`)

    // Default arguments are evaluated outside the main actor, so the default ToastCenter is built here.
    init(dependencies: MainViewDependencies, toasts: ToastCenter? = nil) {
        playback = dependencies.playback
        microphone = dependencies.microphone
        saved = dependencies.saved
        settings = dependencies.settings
        outputs = dependencies.outputs
        inputs = dependencies.inputs
        tools = dependencies.tools
        permissions = dependencies.permissions
        volume = dependencies.volume
        discovery = dependencies.discovery
        clearPausedPlayback = dependencies.clearPausedPlayback
        storedStreamReport = dependencies.storedStreamReport
        latestCrashReport = dependencies.latestCrashReport
        copyToPasteboard = dependencies.copyToPasteboard
        setIdleTimerDisabled = dependencies.setIdleTimerDisabled
        deviceLabel = dependencies.deviceLabel
        revision = dependencies.revision
        versionName = dependencies.versionName
        recoveryWindowMs = dependencies.recoveryWindowMs
        self.toasts = toasts ?? ToastCenter()
        phoneControlOptIn = PhoneControlOptIn(store: dependencies.phoneControlOptIn)

        latestDiagnostics = dependencies.storedStreamReport()
        prefs = dependencies.settings.load()
        sessionView = dependencies.playback.view
        micView = dependencies.microphone.view
        savedView = dependencies.saved.view
        // Remembered devices are only candidates: `derive()` reports them unavailable, and Connect refuses them,
        // until the current route resolves the same identity. Nothing here starts audio or capture.
        var output = micView.ownsSession ? micView.session.outputSelection : sessionView.outputSelection
        if !output.explicit && !sessionView.retained && !micView.ownsSession {
            output = dependencies.settings.restoredOutputSelection()
        }
        selectedOutput = output
        selectedMicrophone = micView.ownsSession ? micView.input : dependencies.settings.restoredMicrophoneSelection()
        adoptedSelectionGeneration = dependencies.settings.selectionGeneration

        // Observers call back immediately with the current value; those first calls never toast
        // (they compare against the values captured above).
        let savedHandle: AnyObject = saved.observe { [weak self] in self?.savedChanged($0) }
        let playbackHandle: AnyObject = playback.observe { [weak self] in self?.playbackChanged($0) }
        let microphoneHandle: AnyObject = microphone.observe { [weak self] in self?.microphoneChanged($0) }
        observationTokens = [savedHandle, playbackHandle, microphoneHandle]
        volume.onChange = { [weak self] in self?.volumeChanged() }
        tools.onReleased = { [weak self] in self?.derive() }
        observationTokens.append(dependencies.subscribeAudioEvents { [weak self] event in self?.audioEvent(event) })
        derive()
    }

    // MARK: Lifecycle

    /// `onStart`/`onResume`/`onPause`/`onStop` mapping. Permission alerts make the scene `.inactive`, which
    /// must not cancel pending flows; their results are consumed on `.active` (Android `onPostResume`).
    func scenePhaseChanged(_ phase: ScenePhase) {
        let visible = phase != .background
        let resumed = phase == .active
        if visible && !screenVisible {
            screenVisible = true
            toasts.setVisible(true)
            // Failure baselines are the last observed views (updated while hidden too), so a failure that
            // happened in the background is never toasted on return (`MainActivity.kt:537`).
        }
        if !resumed && screenResumed {
            screenResumed = false
            stopLocalPlayback()
        }
        if !visible && screenVisible {
            screenVisible = false
            pairingIntent.cancel()
            clearDiscovery()
            toasts.setVisible(false)
            pendingMicrophoneText = nil
            microphonePermissionReady = false
            pendingInputChoice = nil
            inputChoiceReady = false
            pendingScannerPresentation = false
            derive()
        }
        if resumed && !screenResumed {
            screenResumed = true
            derive()
            if pendingScannerPresentation {
                pendingScannerPresentation = false
                if render.scanEnabled { presentScanner() }
            }
            consumeInputChoice()
            consumeScanResult()
            consumeMicrophonePermission()
            consumeApprovedPairing()
        }
    }

    // MARK: Action bar

    /// `connectSelected` (`MainActivity.kt:674-690`).
    func connectTapped() {
        guard screenResumed, render.connectEnabled else { return }
        if micView.canResume {
            microphone.resume()
            derive()
            return
        }
        let entered = ConnectionLink.trimmed(invitationText)
        if !entered.isEmpty {
            connect(entered, reconnect: false)
            return
        }
        if let text = saved.connection() {
            connect(text, reconnect: true)
            return
        }
        expand(.connection)
        showConnectionFailure(savedView.message)
        focusInvitation()
    }

    /// `stopPlayback` (`MainActivity.kt:1110-1118`).
    func stopTapped() {
        guard render.stopEnabled else { return }
        stopPlayback()
    }

    /// `playback.pause()`; "Keep paused" while INTERRUPTED.
    func pauseTapped() {
        guard render.pauseEnabled, !micView.ownsSession else { return }
        playback.pause()
        derive()
    }

    // MARK: Connection setup section

    /// Every text change re-derives (`MainActivity.kt:375-381`); truncated to 4096 characters.
    func invitationChanged(_ text: String) {
        let limited =
            text.count > ConnectionLink.maxLinkLength ? String(text.prefix(ConnectionLink.maxLinkLength)) : text
        if limited != invitationText { invitationText = limited }
        derive()
    }

    /// `scanPairing` (`MainActivity.kt:607-628`).
    func scanTapped() {
        guard render.scanEnabled else { return }
        clearDiscovery()
        scanStatus = ""
        scanSettingsVisible = false
        guard permissions.cameraAvailable else {
            scanStatus = Strings.scanCameraUnavailable
            showConnectionNotice(Strings.scanCameraUnavailable)
            derive()
            return
        }
        switch permissions.cameraAuthorization {
        case .authorized:
            presentScanner()
        case .notDetermined:
            permissions.requestCameraAccess { [weak self] granted in
                guard let self else { return }
                if !granted {
                    self.cameraDenied()
                } else if self.screenResumed {
                    if self.render.scanEnabled { self.presentScanner() }
                } else {
                    self.pendingScannerPresentation = true
                }
            }
        case .denied:
            cameraDenied()
        }
        derive()
    }

    /// The scanner screen finished; the result is consumed after the cover is dismissed.
    func scannerFinished(_ result: QRScanResult) {
        pendingScan = result
        scannerPresented = false
    }

    /// `.fullScreenCover(onDismiss:)`.
    func scannerDismissed() {
        consumeScanResult()
    }

    /// `Find Windows on LAN` / `Stop searching` (`MainActivity.kt:352-354`).
    func findTapped() {
        guard render.discoveryEnabled else { return }
        if discoveryView.searching {
            discovery.stop()
        } else {
            discovery.start { [weak self] view in self?.renderDiscovery(view) }
        }
    }

    /// `selectDiscoveredHost` (`MainActivity.kt:1026-1056`).
    func discoveredHostTapped(_ host: DiscoveredHost) {
        guard !discoveryActionBlocked, discoveryView.hosts.contains(host) else { return }
        let current = saved.connection().flatMap { try? ConnectionLink.parse($0) }
        discoveryAlert = host.matches(current) ? .savedHost(host) : .unknownHost(host)
    }

    /// "Connect" in "Connect to saved Windows?": re-checks the guard and the saved pairing.
    func confirmDiscoveredConnect(_ host: DiscoveredHost) {
        discoveryAlert = nil
        guard !discoveryActionBlocked else { return }
        guard let current = saved.connection().flatMap({ try? ConnectionLink.parse($0) }),
            host.matches(current),
            let record = try? host.connection(for: current).pairedRecord()
        else {
            showConnectionFailure(Strings.discoveryPairFirst)
            return
        }
        connect(record, reconnect: true)
    }

    /// "Paste invitation" in "Pair with Windows first".
    func pasteFromDiscoveryDialog() {
        discoveryAlert = nil
        clearDiscovery()
        focusInvitation()
    }

    /// "Scan pairing QR" in "Pair with Windows first".
    func scanFromDiscoveryDialog() {
        discoveryAlert = nil
        scanTapped()
    }

    /// `Cancel pairing` (`MainActivity.kt:383`).
    func cancelPairingTapped() {
        pairingIntent.cancel()
        saved.cancelPairing()
        derive()
    }

    /// `Change Windows address` (`MainActivity.kt:1058-1066`): prefill from the saved v3 record.
    func changeAddressTapped() {
        guard render.addressEnabled,
            let text = saved.connection(),
            let link = try? ConnectionLink.parse(text),
            link.version == .paired
        else { return }
        addressForm = AddressForm(host: link.endpoint.host.description, port: String(link.endpoint.port))
    }

    /// `Save address` (`MainActivity.kt:1067-1082`). `pendingConnect` is not checked (parity).
    func saveAddress(host: String, port: String) {
        addressForm = nil
        guard !sessionView.busy, !micView.ownsSession, pendingMicrophoneText == nil, !savedView.working else { return }
        do {
            let trimmedHost = ConnectionLink.trimmed(host)
            guard let portNumber = Int(port) else { throw AddressError.invalidPort }
            _ = try ConnectionLink.validateEndpoint(host: trimmedHost, port: portNumber)
            if sessionView.phase == .paused { playback.stop() }
            clearPausedPlayback()
            try saved.updateAddress(host: trimmedHost, port: portNumber)
            derive()
        } catch {
            showConnectionFailure(Strings.addressInvalid)
        }
    }

    /// `Forget saved connection` (`MainActivity.kt:385-390`).
    func forgetTapped() {
        guard render.forgetEnabled else { return }
        pairingIntent.cancel()
        if sessionView.phase == .paused { playback.stop() }
        clearPausedPlayback()
        saved.forget()
        derive()
    }

    // MARK: Audio output section

    /// `changeOutput` (`MainActivity.kt:1132-1140`); a disabled toggle snaps back.
    func changeOutput(_ enabled: Bool) {
        guard render.outputToggleEnabled else {
            derive()
            return
        }
        if micView.ownsSession {
            microphone.setOutputEnabled(enabled)
        } else if sessionView.retained {
            playback.setOutputEnabled(enabled)
        } else {
            settings.update { previous in
                var next = previous
                next.outputEnabled = enabled
                return next
            }
        }
        derive()
    }

    /// `selectOutput` (`MainActivity.kt:794-808`).
    func outputDeviceTapped() {
        guard screenResumed, render.outputDeviceEnabled else { return }
        do {
            outputChoicesDialog = try outputs.choices()
        } catch {
            showConnectionFailure(Strings.outputChangeUnavailable)
        }
    }

    /// A media output was picked from the list.
    func chooseOutput(_ choice: OutputChoice) {
        outputChoicesDialog = nil
        guard screenResumed, render.outputDeviceEnabled else { return }
        applyOutputChoice(choice.selection)
    }

    /// `changeOutputFromStatus` (`MainActivity.kt:882-893`).
    func statusOutputActionTapped() {
        guard screenResumed, screenVisible, render.outputActionEnabled, render.outputDeviceEnabled else {
            derive()
            return
        }
        if ControlsDeriver.canUsePhoneSpeaker(session: sessionView, mic: micView) {
            applyOutputChoice(OutputSelection.fallbackSpeaker())
        } else if ControlsDeriver.canFollowSystemOutput(session: sessionView, mic: micView) {
            applyOutputChoice(OutputSelection())
        }
    }

    // MARK: Microphone section

    /// `changeMicrophone` (`MainActivity.kt:1142-1147`); a disabled toggle snaps back.
    func changeMicrophone(_ enabled: Bool) {
        guard render.micToggleEnabled else {
            derive()
            return
        }
        if micView.ownsSession {
            microphone.setMuted(!enabled)
        } else {
            settings.update { previous in
                var next = previous
                next.microphoneEnabled = enabled
                return next
            }
        }
        derive()
    }

    /// `selectMicrophone` (`MainActivity.kt:729-744`).
    func microphoneInputTapped() {
        guard screenResumed, render.inputButtonEnabled else { return }
        do {
            inputChoicesDialog = try inputs.choices()
        } catch {
            showConnectionFailure(Strings.listInputsFailed)
        }
    }

    /// An input was picked from the list (`chooseMicrophone`, `MainActivity.kt:746-764`).
    func chooseMicrophone(_ choice: MicrophoneChoice) {
        inputChoicesDialog = nil
        chooseMicrophone(selection: choice.selection)
    }

    /// `LE Audio stereo playback` (`MainActivity.kt:447-454`); never visible on iOS (no LE input).
    func setLEStereo(_ checked: Bool) {
        guard render.inputButtonEnabled, selectedMicrophone.kind == .le else {
            derive()
            return
        }
        settings.update { previous in
            var next = previous
            next.leStereo = checked
            return next
        }
        chooseMicrophone(selection: selectedMicrophone)
    }

    /// `Reduce microphone echo` (`MainActivity.kt:434-439`): persisted only while enabled.
    func setEchoCancellation(_ enabled: Bool) {
        if render.echoEnabled {
            settings.update { previous in
                var next = previous
                next.echoCancellation = enabled
                return next
            }
        }
        derive()
    }

    /// `Reduce microphone background noise` (`MainActivity.kt:440-445`): persisted only while enabled.
    func setNoiseReduction(_ enabled: Bool) {
        if render.noiseEnabled {
            settings.update { previous in
                var next = previous
                next.noiseReduction = enabled
                return next
            }
        }
        derive()
    }

    // MARK: Advanced section (`MainActivity.kt:499-511`)

    /// `Faster recovery after audio interruptions` (`MainActivity.kt:451-456`).
    func setFastRecovery(_ enabled: Bool) {
        if render.fastRecoveryEnabled {
            settings.update { previous in
                var next = previous
                next.fastRecovery = enabled
                return next
            }
        }
        derive()
    }

    /// The Connection settings sheet closed (`ConnectionSettingsDialog.show(…) { updateControls() }`,
    /// `MainActivity.kt:506`): re-derive, so the Advanced summary shows the saved recovery window.
    func connectionSettingsDismissed() {
        derive()
    }

    // MARK: Diagnostics section (`MainActivity.kt:512-519`)

    /// `Copy last stream report` (`MainActivity.kt:469-475`).
    func copyReportTapped() {
        let report = localBaseline != nil ? latestDiagnostics : (storedStreamReport() ?? latestDiagnostics)
        guard let report else { return }
        copyToPasteboard(report)
        toasts.show(Strings.diagnosticsCopied, length: .short)
    }

    /// `Copy crash report` (`MainActivity.kt:476-491`): built off the main thread, button disabled meanwhile.
    func copyCrashReportTapped() {
        guard !crashReportBuilding else { return }
        crashReportBuilding = true
        derive()
        let build = latestCrashReport
        Task { @MainActor [weak self] in
            let report = await build()
            guard let self else { return }
            self.crashReportBuilding = false
            self.copyToPasteboard(report)
            self.derive()
            self.toasts.show(Strings.crashDiagnosticsCopied, length: .long)
        }
    }

    /// `startLocalOutput` (`MainActivity.kt:1175-1200`).
    func localOutputTestTapped() {
        guard screenResumed, render.localTestEnabled else { return }
        guard !sessionView.busy, !micView.ownsSession, pendingMicrophoneText == nil else { return }
        if sessionView.phase == .paused { playback.stop() }
        guard tools.acquire() else {
            showConnectionFailure(Strings.focusDenied)
            return
        }
        localAudioHeld = true
        localGeneration &+= 1
        let generation = localGeneration
        localBaseline = nil
        latestDiagnostics = nil
        setIdleTimerDisabled(true)
        idleMessage = nil
        probe = tools.startProbe(
            onSnapshot: { [weak self] snapshot in
                guard let self, self.localGeneration == generation else { return }
                self.localBaseline = snapshot
                self.latestDiagnostics =
                    Strings.localOutputBaselineHeader(uptimeMs: snapshot.capturedUptimeMs) + "\n"
                    + Strings.localOutputInstructions + "\n" + snapshot.text()
                self.derive()
            },
            onEnded: { [weak self] message in
                guard let self, self.localGeneration == generation else { return }
                self.stopPlayback()
                self.showConnectionFailure(message)
            })
        derive()
    }

    /// `Play click` (`MainActivity.kt:493`): one pending chirp.
    func playClickTapped() {
        guard render.clickEnabled else { return }
        probe?.playClick()
    }

    /// `Open-source notices`.
    func noticesTapped() {
        noticesPresented = true
    }

    /// iOS-only `Open Settings` link (status card, scan status, discovery status).
    func openSettingsTapped() {
        permissions.openSettings()
    }

    // MARK: Observers

    /// Saved store observer (`MainActivity.kt:95-103`).
    private func savedChanged(_ view: SavedConnectionView) {
        let newFailure = view.pairingFailureID != 0 && view.pairingFailureID != savedView.pairingFailureID
        savedView = view
        derive()
        consumeApprovedPairing()
        if newFailure { showConnectionNotice() }
    }

    /// Playback observer (`MainActivity.kt:181-195`). Also runs after every Windows phone settings command
    /// (`PhoneControlBinding.changed` republishes), so the derive below refreshes the Advanced summary.
    private func playbackChanged(_ view: SessionView) {
        let newFailure = view.failureId != nil && view.failureId != sessionView.failureId
        sessionView = view
        pendingConnect = false
        if view.retained && !micView.ownsSession { selectedOutput = view.outputSelection }
        if view.busy && !micView.ownsSession { showingMicrophone = false }
        if probe == nil && !micView.ownsSession && !showingMicrophone {
            latestDiagnostics = view.diagnostics ?? latestDiagnostics
        }
        derive()
        if newFailure { showConnectionNotice() }
    }

    /// Microphone observer (`MainActivity.kt:197-213`); like the playback observer, it also follows each Windows
    /// phone settings command.
    private func microphoneChanged(_ view: MicrophoneView) {
        let wasBusy = micView.ownsSession
        let failure = view.session.failureId != nil && view.session.failureId != micView.session.failureId
        micView = view
        if view.ownsSession {
            selectedMicrophone = view.input
            selectedOutput = view.session.outputSelection
        }
        if (view.ownsSession || wasBusy || failure) && !sessionView.busy {
            showingMicrophone = true
            latestDiagnostics = view.session.diagnostics ?? latestDiagnostics
        }
        derive()
        if failure { showConnectionNotice() }
    }

    private func volumeChanged() {
        if screenVisible { derive() }
    }

    /// Audio-session fan-out: local tools stop on interruption and on `.oldDeviceUnavailable`; route changes refresh
    /// the rows while visible.
    private func audioEvent(_ event: MainViewAudioEvent) {
        switch event {
        case .interruptionBegan:
            stopLocalPlayback()
        case .routeChanged(let oldDeviceUnavailable):
            if oldDeviceUnavailable { stopLocalPlayback() }
            if screenVisible { derive() }
        }
    }

    // MARK: Derive (`updateControls`, `MainActivity.kt:1239-1393`)

    /// Reloads preferences (also the saved recovery window of the Advanced summary, `AppConnectionSettings.load`),
    /// refreshes idle selections (side effects) and re-derives `render`.
    func derive() {
        prefs = settings.load()
        adoptWindowsSelectionsIfIdle()
        if !sessionView.retained && !micView.ownsSession, let refreshed = outputs.refresh(selectedOutput) {
            selectedOutput = refreshed
        }
        if !micView.ownsSession, let refreshed = inputs.refresh(selectedMicrophone) {
            selectedMicrophone = refreshed
        }
        let selection = micView.ownsSession ? micView.input : selectedMicrophone
        let current = (micView.ownsSession || showingMicrophone) ? micView.session : sessionView
        let localNetworkBlocked =
            current.message.contains(Self.localNetworkMarker)
            || savedView.message.contains(Self.localNetworkMarker)
        let capabilities = inputs.processingCapabilities
        let input = ControlsInput(
            prefs: prefs,
            session: sessionView,
            mic: micView,
            localProbeRunning: probe != nil || tools.isReleasing,
            pendingMicrophone: pendingMicrophoneText != nil,
            pendingInputChoice: pendingInputChoice != nil,
            pendingConnect: pendingConnect,
            pairingIntentPending: pairingIntent.pending,
            playbackAvailable: true,
            microphoneAvailable: true,
            saved: ControlsInput.SavedState(
                message: savedView.message, available: savedView.available,
                present: savedView.present, working: savedView.working,
                pairing: savedView.pairing, paired: savedView.paired),
            savedLink: savedLink,
            showingMicrophone: showingMicrophone,
            selectedOutput: selectedOutput,
            selectedMicrophone: selectedMicrophone,
            entered: ConnectionLink.trimmed(invitationText),
            latestDiagnostics: latestDiagnostics,
            idleMessage: idleMessage,
            outputChoices: try? outputs.choices(),
            inputChoices: try? inputs.choices(),
            outputAvailable: outputs.available(selectedOutput),
            inputAvailable: inputs.available(selection),
            discovery: discoveryView,
            revision: revision,
            versionName: versionName,
            recoveryWindowMs: recoveryWindowMs(),
            volumePercent: volume.percent,
            echoCancellationSupported: capabilities.echoCancellation,
            noiseReductionSupported: capabilities.noiseReduction,
            settingsLinkSuggested: (idleMessage != nil && failureNeedsSettings) || localNetworkBlocked,
            crashReportBuilding: crashReportBuilding)
        let next = ControlsDeriver.derive(input)
        if next != render { render = next }
    }

    /// Windows saved an input or output for the next connection during a session (phone settings exchange v1):
    /// once no session is retained and no setup is pending, the idle rows and the next Connect use the saved
    /// selections (`MainActivity.kt:1273-1277`). Only a new `selectionGeneration` re-reads them, so idle-only state
    /// such as the temporary speaker is kept when Windows changed nothing.
    private func adoptWindowsSelectionsIfIdle() {
        let idle =
            !sessionView.retained && !micView.ownsSession && pendingMicrophoneText == nil && pendingInputChoice == nil
            && !pendingConnect && !pairingIntent.pending
        guard
            let adoption = Self.windowsSelectionAdoption(
                idle: idle, adopted: adoptedSelectionGeneration, settings: settings)
        else { return }
        adoptedSelectionGeneration = adoption.generation
        selectedOutput = adoption.output
        selectedMicrophone = adoption.microphone
    }

    /// The saved selections the idle rows adopt, with the generation to record.
    struct WindowsSelectionAdoption: Equatable {
        let generation: UInt64
        let output: OutputSelection
        let microphone: MicrophoneSelection
    }

    /// The rule of `adoptWindowsSelectionsIfIdle` without the view model's state (simulator tests). Nil keeps the
    /// rows: something still uses them (`idle` false: a retained session, a microphone session, or a pending
    /// microphone setup, input choice, Connect or pairing), or Windows saved nothing since `adopted`. Otherwise the
    /// rows take the selections the next Connect restores and record `settings.selectionGeneration`.
    static func windowsSelectionAdoption(
        idle: Bool, adopted: UInt64, settings: any AudioSettingsStore
    ) -> WindowsSelectionAdoption? {
        let generation = settings.selectionGeneration
        guard idle, generation != adopted else { return nil }
        return WindowsSelectionAdoption(
            generation: generation, output: settings.restoredOutputSelection(),
            microphone: settings.restoredMicrophoneSelection())
    }

    // MARK: Connect flows

    /// `connect(text, reconnect)` (`MainActivity.kt:692-727`).
    private func connect(_ text: String, reconnect: Bool) {
        pairingIntent.cancel()
        guard !connectBlocked else {
            derive()
            return
        }
        clearDiscovery()
        scanStatus = ""
        scanSettingsVisible = false
        if PairingInvitation.isPairingLink(text) {
            pairWithWindows(text)
            return
        }
        let link: ConnectionLink
        do {
            link = try ConnectionLink.parse(text)
        } catch {
            showConnectionFailure(Strings.invalidInvitation)
            return
        }
        if link.isExpired() {
            showConnectionFailure(Strings.connectionLinkExpiredDetail, notice: Strings.connectionLinkExpired)
            return
        }
        prefs = settings.load()
        let mode = prefs.connectionMode
        if mode.hasPlayback && (!prefs.microphoneEnabled || !selectedMicrophone.kind.isBluetooth)
            && !checkOutputChoice()
        {
            return
        }
        if prefs.microphoneEnabled {
            requestMicrophone(text, mode: mode)
            return
        }
        idleMessage = nil
        showingMicrophone = false
        pendingConnect = true
        derive()
        invitationText = ""
        latestDiagnostics = nil
        do {
            try playback.connect(
                text: text, fastRecovery: prefs.fastRecovery, baseline: localBaseline,
                reconnect: reconnect, outputEnabled: prefs.outputEnabled,
                outputSelection: selectedOutput)
        } catch {
            pendingConnect = false
            derive()
            showConnectionFailure(Strings.connectStartFailed)
            return
        }
        derive()
    }

    /// `connect` step 2 guard (`MainActivity.kt:694-697`).
    private var connectBlocked: Bool {
        sessionView.busy || micView.ownsSession || pendingMicrophoneText != nil || pendingConnect || savedView.working
    }

    /// `selectDiscoveredHost` guard (`MainActivity.kt:1027-1029`).
    private var discoveryActionBlocked: Bool {
        sessionView.busy || micView.ownsSession || pendingMicrophoneText != nil || pendingConnect || savedView.working
    }

    /// `checkOutputChoice` (`MainActivity.kt:782-792`).
    private func checkOutputChoice() -> Bool {
        let refreshed = outputs.refresh(selectedOutput)
        if !prefs.needsOutputSelection(selectedOutput), let refreshed {
            selectedOutput = refreshed
            return true
        }
        expand(.output)
        showConnectionFailure(Strings.outputReselect)
        return false
    }

    /// `pairWithWindows` (`MainActivity.kt:956-973`).
    private func pairWithWindows(_ text: String) {
        guard !connectBlocked else { return }
        do {
            let invitation = try PairingInvitation.parse(text)
            if invitation.isExpired() {
                showConnectionFailure(Strings.pairingInvitationExpired, notice: Strings.connectionLinkExpired)
                return
            }
            if sessionView.phase == .paused { playback.stop() }
            clearPausedPlayback()
            let label = deviceLabel()
            pairingIntent.begin(try saved.pair(text, label: label))
            invitationText = ""
            derive()
        } catch {
            showConnectionFailure(Strings.pairingInvitationInvalid)
        }
    }

    /// `consumeApprovedPairing` (`MainActivity.kt:975-990`).
    private func consumeApprovedPairing() {
        guard pairingIntent.pending else { return }
        prefs = settings.load()
        let ready =
            screenResumed && !sessionView.busy && !micView.ownsSession && !pendingConnect
            && pendingMicrophoneText == nil && pendingInputChoice == nil
        guard
            pairingIntent.take(
                successID: savedView.pairingSuccessID, working: savedView.working,
                available: savedView.available, visibleReady: ready)
        else {
            if !pairingIntent.pending { derive() }
            return
        }
        guard let text = saved.connection() else {
            derive()
            return
        }
        idleMessage = nil
        connect(text, reconnect: true)
    }

    /// `requestMicrophone` (`MainActivity.kt:895-918`).
    private func requestMicrophone(_ text: String, mode: StreamMode) {
        guard screenResumed else { return }
        guard (try? ConnectionLink.parse(text))?.version == .paired else {
            expand(.connection)
            showConnectionFailure(Strings.pairBeforeMicrophone)
            return
        }
        if prefs.needsInputSelection(selectedMicrophone) {
            expand(.microphone)
            showConnectionFailure(Strings.microphoneReselect)
            return
        }
        idleMessage = nil
        showingMicrophone = true
        pendingMicrophoneText = text
        pendingMicrophoneMode = mode
        switch permissions.recordPermission {
        case .granted:
            microphonePermissionReady = true
            consumeMicrophonePermission()
        case .undetermined:
            microphonePermissionReady = false
            derive()
            permissions.requestRecordPermission { [weak self] granted in
                self?.microphonePermissionAnswered(granted)
            }
        case .denied:
            microphonePermissionAnswered(false)
        }
    }

    private func microphonePermissionAnswered(_ granted: Bool) {
        guard pendingMicrophoneText != nil else { return }
        guard granted else {
            pendingMicrophoneText = nil
            microphonePermissionReady = false
            showMicrophonePermissionDenied()
            return
        }
        microphonePermissionReady = true
        consumeMicrophonePermission()
    }

    /// `consumeMicrophonePermission` (`MainActivity.kt:923-954`); also run on `.active`.
    private func consumeMicrophonePermission() {
        guard let text = pendingMicrophoneText else { return }
        guard microphonePermissionReady, screenResumed, screenVisible else { return }
        pendingMicrophoneText = nil
        microphonePermissionReady = false
        let mode = pendingMicrophoneMode
        prefs = settings.load()
        if sessionView.busy || micView.ownsSession || pendingConnect || savedView.working || !prefs.microphoneEnabled {
            derive()
            return
        }
        guard permissions.recordPermission == .granted else {
            showMicrophonePermissionDenied()
            return
        }
        if mode.hasPlayback && !selectedMicrophone.kind.isBluetooth && !checkOutputChoice() { return }
        guard let refreshed = inputs.refresh(selectedMicrophone) else {
            showConnectionFailure(MicrophoneRouteProblem.unavailable.detail)
            return
        }
        selectedMicrophone = refreshed
        clearDiscovery()
        stopLocalPlayback()
        if sessionView.retained { playback.stop() }
        clearPausedPlayback()
        latestDiagnostics = nil
        do {
            try microphone.connect(
                text: text, mode: mode, input: selectedMicrophone,
                outputEnabled: prefs.outputEnabled, fastRecovery: prefs.fastRecovery,
                outputSelection: selectedOutput)
        } catch let error as MicrophoneRouteError {
            showConnectionFailure(error.problem.detail)
            return
        } catch {
            showConnectionFailure(Strings.microphoneStartFailed)
            return
        }
        derive()
    }

    private func showMicrophonePermissionDenied() {
        let text =
            MicrophonePermissions.denial(kind: selectedMicrophone.kind, status: .denied)
            ?? MicrophonePermissions.deniedText
        showConnectionFailure(text, settingsLink: true)
    }

    // MARK: Output / input selection helpers

    /// `applyOutputChoice` (`MainActivity.kt:855-866`).
    private func applyOutputChoice(_ choice: OutputSelection) {
        guard let selected = outputs.refresh(choice) else {
            showConnectionFailure(Strings.outputReselect)
            return
        }
        let accepted: Bool
        if micView.ownsSession {
            accepted = microphone.setOutputSelection(selected)
        } else if sessionView.retained {
            accepted = playback.setOutputSelection(selected)
        } else {
            settings.rememberOutput(selected)
            accepted = true
        }
        if accepted {
            selectedOutput = selected
            idleMessage = nil
            derive()
        } else {
            showConnectionFailure(Strings.outputChangeUnavailable)
        }
    }

    /// `chooseMicrophone(selection)` (`MainActivity.kt:746-764`). On iOS the record permission is
    /// necessarily granted during a session, so a live change is consumed immediately.
    private func chooseMicrophone(selection: MicrophoneSelection) {
        guard screenResumed, render.inputButtonEnabled else { return }
        if !micView.ownsSession {
            selectedMicrophone = selection
            settings.rememberInput(selection)
            idleMessage = nil
            derive()
            return
        }
        guard let token = microphone.inputActionToken() else {
            derive()
            return
        }
        pendingInputChoice = PendingInputChoice(token: token, selection: selection)
        idleMessage = nil
        inputChoiceReady = true
        consumeInputChoice()
    }

    /// `consumeInputChoice` (`MainActivity.kt:766-780`).
    private func consumeInputChoice() {
        guard inputChoiceReady, screenResumed, screenVisible, let pending = pendingInputChoice else { return }
        pendingInputChoice = nil
        inputChoiceReady = false
        guard microphone.inputActionToken() == pending.token else {
            derive()
            return
        }
        guard permissions.recordPermission == .granted else {
            showMicrophonePermissionDenied()
            return
        }
        guard let selected = inputs.refresh(pending.selection) else {
            showConnectionFailure(MicrophoneRouteProblem.unavailable.detail)
            return
        }
        if micView.mode.hasPlayback && !selected.kind.isBluetooth && !checkOutputChoice() { return }
        guard microphone.switchInput(selected, expectedToken: pending.token) else {
            showConnectionFailure(Strings.inputChangeUnavailable)
            return
        }
        derive()
    }

    // MARK: Stop and local tools

    /// `stopPlayback` (`MainActivity.kt:1110-1118`).
    private func stopPlayback() {
        pairingIntent.cancel()
        if savedView.pairing { saved.cancelPairing() }
        pendingMicrophoneText = nil
        microphonePermissionReady = false
        pendingInputChoice = nil
        inputChoiceReady = false
        if micView.ownsSession {
            microphone.stop()
        } else if sessionView.retained {
            playback.stop()
        } else {
            stopLocalPlayback()
        }
        derive()
    }

    /// `stopLocalPlayback` (`MainActivity.kt:1212-1220`): Stop, scene not active, interruption began,
    /// `.oldDeviceUnavailable`, and before a microphone session starts.
    private func stopLocalPlayback() {
        let hadLocal = probe != nil
        localGeneration &+= 1
        let running = probe
        probe = nil
        running?.close()
        releaseLocalAudio()
        setIdleTimerDisabled(false)
        if hadLocal { idleMessage = nil }
        derive()
    }

    private func releaseLocalAudio() {
        guard localAudioHeld else { return }
        localAudioHeld = false
        tools.release()
    }

    // MARK: Shared helpers

    /// `showConnectionFailure` (`MainActivity.kt:992-997`).
    private func showConnectionFailure(
        _ detail: String, notice: String = Strings.defaultFailureNotice,
        settingsLink: Bool = false
    ) {
        idleMessage = detail
        failureNeedsSettings = settingsLink
        derive()
        showConnectionNotice(notice)
    }

    /// `showConnectionNotice` (`MainActivity.kt:999-1003`): only while visible; replaces the current toast.
    private func showConnectionNotice(_ message: String = Strings.defaultFailureNotice) {
        guard screenVisible else { return }
        toasts.show(message, length: .short)
    }

    /// `clearDiscovery` (`MainActivity.kt:1021-1024`).
    private func clearDiscovery() {
        discovery.detach()
        renderDiscovery(DiscoveryView())
    }

    /// `renderDiscovery` (`MainActivity.kt:1005-1019`).
    private func renderDiscovery(_ view: DiscoveryView) {
        discoveryView = view
        savedLink = saved.connection().flatMap { try? ConnectionLink.parse($0) }
        derive()
    }

    private func cameraDenied() {
        scanStatus = Strings.scanCameraDenied
        scanSettingsVisible = true
        derive()
    }

    private func presentScanner() {
        pendingScan = nil
        scannerPresented = true
    }

    /// `consumeScanResult` (`MainActivity.kt:630-656`). Scanning never connects, opens URLs, imports
    /// records, starts audio or replaces a pairing; Connect stays the explicit network action.
    private func consumeScanResult() {
        guard screenResumed, !scannerPresented, let result = pendingScan else { return }
        pendingScan = nil
        switch result {
        case .cancelled:
            return
        case .cameraUnavailable:
            scanStatus = Strings.scanCameraUnavailable
            showConnectionNotice(Strings.scanCameraUnavailable)
        case .decoded(let payload):
            // A rejected scan must not leave an older link ready to connect.
            invitationText = ""
            let text = ConnectionLink.trimmed(payload)
            do {
                let invitation = try PairingInvitation.parse(text)
                if invitation.isExpired() {
                    scanStatus = Strings.scanExpired
                    showConnectionNotice(Strings.connectionLinkExpired)
                } else {
                    invitationText = text
                    scanStatus = Strings.scanReady(
                        host: invitation.endpoint.host.description,
                        port: Int(invitation.endpoint.port))
                    showConnectionNotice(Strings.scanComplete)
                }
            } catch {
                scanStatus = Strings.scanInvalid
                showConnectionNotice(Strings.scanInvalid)
            }
        }
        derive()
    }

    private func expand(_ section: SettingsSectionID) {
        sectionSerial &+= 1
        sectionRequest = SectionRequest(section: section, serial: sectionSerial)
    }

    private func focusInvitation() {
        invitationFocusRequest &+= 1
    }
}
