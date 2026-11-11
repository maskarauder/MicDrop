import Foundation
import MicDropCore

/// Setup sequence (Appendix A, `StreamReceiver.kt:349-553`). Every native call is preceded by a checkpoint; a Stop
/// observed at any checkpoint throws `SessionStopped` and goes straight to `cleanup()`.
extension SessionController {

    /// `runSession()` body up to the status loop (`StreamReceiver.kt:349-553`), then the loop.
    func runSession() throws {
        // require(!microphoneReturn || version == 3) (`StreamReceiver.kt:352`).
        guard !microphoneReturn || protocolVersion == 3 else {
            throw ProtocolViolation("microphone return requires a paired link")
        }
        try step(.waiting)
        // blocking FIFO permit, interrupted only through workerWait.cancel.
        try dependencies.owner.acquire(workerWait)
        ownsAudioSession = true
        if isClosed { return }
        journalActive = true
        journal.checkpoint(Self.setupCheckpoint(stage))
        startObservers()
        // Microphone route preparation happens before /offer so a slow Bluetooth transition does not
        // consume the host's 45 s answer budget (`StreamReceiver.kt:361-366`).
        let preferredInput = try prepareMicrophone()
        try step(.pairing)
        tlsSetup = try dependencies.tls(configuration.link)
        try signalingRoute.initial { try self.probeLocal() }
        let offer = try obtainOffer()
        guard try acceptOffer(offer) else { return }
        if isClosed { return }
        try setUpMedia(preferredInput: preferredInput)
        guard let localAnswer = try gatherInitialRoutes() else { return }
        try submitAnswer(localAnswer)
        try statusLoop()
    }

    /// WAITING-stage observers (`StreamReceiver.kt:357-360`): runtime observer (failure ignored —
    /// diagnostics never stop audio), network status line, LAN route monitors, output observers.
    func startObservers() {
        let observer = dependencies.runtime()
        runtime = observer
        observer.start(evidence: evidence, onNetworkChanged: { [weak self] in self?.defaultNetworkChanged() })
        publishNetworkStatus()
        lanRoute.start()
        if usesMediaOutput { outputController.startObservers() }
    }

    /// INPUT_ROUTE (steps 2-3; `StreamReceiver.kt:361-367`). Playback-only sessions return `nil` without a stage
    /// change.
    func prepareMicrophone() throws -> AudioPortDescriptor? {
        guard microphoneReturn else { return nil }
        try step(.inputRoute)
        let routing = MicrophoneRouting(
            selection: configuration.microphoneSelection, arbiter: dependencies.arbiter,
            clock: dependencies.clock, lost: { [weak self] in self?.inputRouteLost() })
        microphoneRouting = routing
        let input = try routing.prepare(cancelled: { self.isClosed })
        if mode.hasPlayback { try routing.validateDuplexOutput() }
        return input
    }

    /// Offer acceptance in Kotlin order ("Order after a 200", `StreamReceiver.kt:372-396`). Returns `false` (after
    /// `fail(modeNotConfirmed, .modeNotConfirmed)`) when the host did not confirm the requested mode; the session token
    /// is already stored so cleanup still sends `/stop`.
    func acceptOffer(_ offer: ControlJSON) throws -> Bool {
        offerReply = .rejected
        connectionDeadlines.state = .rejected
        let capabilities = try OfferCapabilities(offer, invitationVersion: protocolVersion)
        lifecycleVersion = capabilities.lifecycleVersion
        // Retain the token before validating negotiated extensions so rejection still releases the host session.
        sessionToken = capabilities.session
        connectionDeadlines = try configuration.connectionPreferences.negotiated(
            restartSupported: capabilities.iceRestartSupported,
            version: protocolVersion == 3 ? offer.int("connection_timeouts_version") : 0,
            recoveryMs: offer.int("recovery_window_ms"), setupMs: offer.int("setup_window_ms"),
            heartbeatMs: offer.int("heartbeat_timeout_ms"))
        setupStartedMs = nowMs()
        lanRecovery = LanRecovery(
            supported: capabilities.iceRestartSupported, limitMs: Int64(connectionDeadlines.recoveryMs),
            restartDelayMs: Int64(configuration.connectionPreferences[.restartDelay]),
            restartIntervalMs: Int64(configuration.connectionPreferences[.restartInterval]),
            maxRestarts: configuration.connectionPreferences.maxRestarts)
        recoverySupportedFlag.value = capabilities.iceRestartSupported
        delivery = capabilities.makeReportDelivery()
        includeOutput = capabilities.includeOutput
        includeConnection = capabilities.includeConnection
        includeOutputControl = capabilities.includeOutputControl
        includeIceGathering = capabilities.includeIceGathering
        includeMediaTransport = capabilities.includeMediaTransport
        includeRouteSelection = capabilities.includeRouteSelection
        includeTlsVerification = capabilities.includeTlsVerification
        includeMicrophoneProcessing = capabilities.includeMicrophoneProcessing
        gatheringDiagnosticsVersion = capabilities.iceGatheringDiagnosticsVersion
        // Negotiated only with the controller's binding (`StreamReceiver.kt:397`).
        phoneControlEnabled = capabilities.phoneControlNegotiated && phoneControl != nil
        sessionToken = capabilities.session
        offerReply = .accepted
        SessionStopRetry.shared.accepted(destination: stopDestination)
        guard capabilities.confirms(mode) else {
            fail(Messages.modeNotConfirmed, code: .modeNotConfirmed)
            return false
        }
        offerDescription = try capabilities.validatedSDP()
        useTrickle = capabilities.useTrickle(remote: isRemote)
        continuousEnabledFlag.value = capabilities.useContinuous(remote: isRemote)
        if continuousEnabledFlag.value {
            continuous = try ContinuousExchange(
                remoteDescription: offerDescription, relayOnly: configuration.forceRelay, generation: 0)
        } else if useTrickle {
            trickle = try TrickleExchange(remoteDescription: offerDescription, relayOnly: configuration.forceRelay)
        }
        return true
    }

    /// AUDIO → CODEC → OFFER → ANSWER (04 Appendix A; `StreamReceiver.kt:397-514`).
    func setUpMedia(preferredInput: AudioPortDescriptor?) throws {
        try step(.audio)
        if microphoneReturn {
            let input = MicrophoneCapture.InputInitialization()
            microphoneCapture = MicrophoneCapture(input: input)
            do { try input.request() } catch {
                handleCaptureFailure(.initialization)
                throw error
            }
        }
        let created = try dependencies.engineFactory(
            MediaEngineConfiguration(
                mode: mode, plan: configuration.plan, lanLocal: !isRemote,
                iceServers: iceConfiguration?.servers ?? [], forceRelay: configuration.forceRelay,
                continualGathering: continuousEnabledFlag.value, fastAccelerate: configuration.fastRecovery,
                processing: configuration.processing, turnTLSTrust: turnTLSTrust),
            engineEvents, { _ = try self.operationBudget(Int.max) })
        publishEngine(created)
        try workerWait.checkpoint()
        if let capture = microphoneCapture {
            capture.attach(created)
            capture.closeSampleGate()
            if let preferredInput { try microphoneRouting?.setPreferredInput(preferredInput) }
        }
        try created.prepareLocalMedia()
        try step(.codec)
        try created.applyCodecPreferences()
        try step(.offer)
        try created.applyOffer(
            offerDescription, timeoutMs: operationBudget(configuration.connectionPreferences[.initialSDP]))
        if microphoneReturn {
            try created.attachMicrophone()
            guard let routing = microphoneRouting, let capture = microphoneCapture else {
                throw ProtocolViolation("microphone setup unavailable")
            }
            microphoneControl = MicrophoneControl(
                mode: mode, selection: configuration.microphoneSelection, routing: routing,
                capture: capture, recovery: headsetRecovery, host: microphoneHooks, hooks: microphoneHooks)
        }
        try step(.answer)
        let answer = try created.createAnswer(
            timeoutMs: operationBudget(configuration.connectionPreferences[.initialSDP]))
        let local = try created.localAnswer(for: answer, checkDirection: true)
        gatheringStartedMs = nowMs()
        try created.setLocalAnswer(local, timeoutMs: operationBudget(configuration.connectionPreferences[.initialSDP]))
    }

    /// ROUTES (`StreamReceiver.kt:515-540`). Returns the exact local answer to submit, or `nil` when Stop arrived.
    /// Throws `StageTimeoutError` when the snapshot cannot submit.
    func gatherInitialRoutes() throws -> String? {
        try step(.routes)
        guard let engine else { throw ProtocolViolation("media engine unavailable") }
        let outcome = try InitialGathering.run(
            peer: engine, clock: dependencies.clock, gatheringStartedMs: gatheringStartedMs,
            isRemote: isRemote, forceRelay: configuration.forceRelay, useTrickle: useTrickle,
            serverURLs: iceConfiguration?.urls ?? [], errors: { self.gatheringErrors.snapshot() },
            checkpoint: { _ = try self.operationBudget(Int.max) },
            timeoutMs: Int64(operationBudget(configuration.connectionPreferences[.initialICE])))
        initialGathering = outcome.snapshot
        if isClosed { return nil }
        includeIceGathering = outcome.includeInReports(diagnosticsVersion: gatheringDiagnosticsVersion)
        try outcome.requireSubmittable()
        return outcome.localAnswer
    }

    /// SUBMITTING (steps 8-9; `StreamReceiver.kt:541-550`): `/answer` with the exact analysed description
    /// (candidate-free for continuous ICE), the trickle network hold, then stage MICROPHONE/PLAYBACK and `mediaReady`.
    func submitAnswer(_ localAnswer: String) throws {
        try step(.submitting)
        let sdp = continuousEnabledFlag.value ? ContinuousExchange.withoutCandidates(localAnswer) : localAnswer
        _ = try request(
            "/answer", token: try requireSessionToken(),
            body: WireBody.object([("version", .int(protocolVersion)), ("sdp", .string(sdp))]))
        setupStartedMs = nil
        // Candidate-free descriptions need the status loop to establish media before routes can be
        // verified; reuse the network hold so microphone setup cannot block the first trickle heartbeats.
        if useTrickle { holdNetworkAudio() }
        try step(microphoneReturn ? .microphone : .playback)
        mediaReadyFlag.value = true
        outputController.markMediaReady()
    }
}
