import AVFoundation
import Foundation
import MicDropCore
import WebRTC

/// Non-IO media setup failures (`describe` → `SETUP_FAILED`, wire `session_exception`, not retryable). Cases carry no
/// SDP or other private text. Timeouts are `StageTimeoutError` and Stop is `SessionStopped` (thrown by the worker
/// checkpoint), never cases of this enum. `OpusSdpError` from the stereo edit propagates unchanged.
enum MediaEngineError: Error, Equatable, Sendable {
    /// A previous session's factory is still alive in this process (stray reference).
    case previousMediaNotReleased
    /// `RTCPeerConnectionFactory(…audioDeviceModule:)` returned nil.
    case factoryUnavailable
    /// `peerConnection(with:constraints:certificateVerifier:delegate:)` returned nil (Android
    /// `requireNotNull`, `SR:473`), or a peer operation was requested after teardown.
    case peerUnavailable
    /// `addTransceiver(of:init:)` returned nil, or the microphone offer did not produce exactly one
    /// audio transceiver (Android `transceivers.single()` + `check(mediaType == AUDIO)`, `SR:502-503`).
    case transceiverUnavailable
    /// No `opus/48000/2` capability (Android `require(opus.isNotEmpty())`, `SR:496`).
    case opusUnavailable
    /// `setCodecPreferences:error:` returned NO (Android `.throwError()`, `SR:497,507`).
    case codecPreferencesRejected
    /// `sender.track = track` did not take (Android `check(sending.sender.setTrack(...))`, `SR:504`).
    case senderTrackRejected
    /// `setDirection:error:` reported an error (Android `check(setDirection(...))`, `SR:505-506`).
    case directionRejected
    /// `answer(for:)` failed (Android `onCreateFailure` → "SDP creation failed", `SR:1706`).
    case sdpCreationFailed
    /// `setRemoteDescription` / `setLocalDescription` failed ("SDP configuration failed", `SR:1707`).
    case sdpConfigurationFailed
    /// Microphone-mode answer lacks `a=sendrecv` (duplex) / `a=sendonly` (microphone) (`SR:510`).
    case directionMismatch
    /// `setConfiguration` returned false (Android `check(connection.setConfiguration(config))`, `SR:1583`).
    case configurationRejected
}

/// One session's WebRTC media: ADM, factory, peer, transceivers, Opus codec preferences, SDP application, gathering
/// latch, statistics, local sample gates, playout liveness and teardown (Appendix A).
///
/// Threading: every method that touches native objects is called on the session worker thread only; each blocking wait
/// is cancellable (the worker `checkpoint` is polled every 20 ms and re-checked after completion; a native call is
/// started before the wait and never interrupted). Members documented "any thread" never block and never call WebRTC
/// under a lock (gates go through `AudioGateApplier`).
///
/// Setup order (Appendix A, drives it):
/// 1. microphone rows: `MicrophoneCapture.InputInitialization.request()` (`setInputMuted(false)`,
///    `setInitialMicrophoneMute(true)`, `initializeInput`) **before** this engine is created;
/// 2. `init` (stage AUDIO): `WebRTCRuntime.ensureInitialized()`, ADM per `plan.profile`, factory +
///    options, peer (`ICEPeerConfiguration.make`), `isAudioEnabled = true`;
/// 3. `prepareLocalMedia()` (AUDIO), `applyCodecPreferences()` (CODEC), `applyOffer(_:timeoutMs:)` +
///    microphone rows `attachMicrophone()` (OFFER), `createAnswer` → `localAnswer(for:checkDirection: true)`
///    → `setLocalAnswer` (ANSWER), gathering via `waitGathered` / `iceGatheringComplete` /
///    `localDescription` (ROUTES).
///
/// Teardown order: `setSpeakerMutedSynchronously(true)` (local_audio_gates) → microphone rows
/// `setCaptureRunning(false)` (audio_recording_stop) → `/stop` or `/cancel-offer` (session) → `close(onStep:)`
/// (peer_dispose … audio_module_release inside one autorelease pool) → owner permit released by the session.
final class MediaEngine: @unchecked Sendable {

    // MARK: - Constants

    /// Local microphone track id (`SR:486`).
    static let microphoneTrackId = "phone-microphone"
    /// Default SDP operation timeout (`awaitSDP` default, `SR:1701`).
    static let descriptionTimeoutMs = 15_000
    /// Statistics wait (`SR:692`).
    static let statisticsTimeoutMs = 5_000
    /// iOS-only playout watchdog: inbound packets grow but playout is inactive this long → treated as a track start
    /// error.
    static let playoutWatchdogMs: Int64 = 5_000
    /// Capture evidence compares `media-source.totalSamplesDuration` samples at least this far apart.
    static let captureEvidenceMinimumIntervalMs: Int64 = 100
    /// Poll slice of every cancellable wait (Stop latency bound).
    private static let waitSliceMs = 20

    /// Native release steps, in order; raw values are the Android `cleanupStep` journal names
    /// (`StreamReceiver.kt:855-859`).
    enum TeardownStep: String, CaseIterable, Sendable {
        case peerDispose = "peer_dispose"
        case microphoneTrackDispose = "microphone_track_dispose"
        case microphoneSourceDispose = "microphone_source_dispose"
        case factoryDispose = "factory_dispose"
        case audioModuleRelease = "audio_module_release"
    }

    /// Optional capture confirmation from `media-source` statistics (step 4).
    struct CaptureEvidence: Sendable, Equatable {
        /// The SDK reported an audio `media-source.totalSamplesDuration`.
        var available: Bool
        /// It increased between the last two samples taken ≥ 100 ms apart.
        var advanced: Bool
        /// Latest value in seconds (never reported on the wire).
        var totalSamplesDuration: Double?

        static let unavailable = CaptureEvidence(available: false, advanced: false, totalSamplesDuration: nil)
    }

    // MARK: - Configuration

    let configuration: MediaEngineConfiguration
    private let checkpoint: () throws -> Void
    private let gates: AudioGateApplier
    private let observer: PeerObserver
    private let playoutTap = PlayoutTap()

    // MARK: - Native objects (session worker only)

    /// The per-session ADM (pause/resume only; never passed to a second factory).
    private(set) var audioDeviceModule: RTCAudioDeviceModule?
    /// The per-session factory.
    private(set) var peerConnectionFactory: RTCPeerConnectionFactory?
    /// The session peer (app-ice drives it through `ICEPeerConfiguration.Peer`).
    private(set) var peerConnection: RTCPeerConnection?
    /// TURN/TLS platform-trust fallback passed to the peer (every peer, LAN included;
    /// `StreamReceiver.kt:499-504`). It references only the session counters; the native peer keeps its own
    /// reference until it is destroyed.
    private(set) var certificateVerifier: TurnTLSTrustVerifier?
    /// Microphone modes: the local audio source with processing constraints.
    private(set) var microphoneSource: RTCAudioSource?
    /// Microphone modes: `phone-microphone`, created disabled.
    private(set) var microphoneTrack: RTCAudioTrack?
    private var receiveTransceiver: RTCRtpTransceiver?
    private var sendTransceiver: RTCRtpTransceiver?
    private var opusCodecs: [RTCRtpCodecCapability] = []
    private var released = false

    // MARK: - Cross-thread state (guarded by `stateLock`)

    private let stateLock = NSLock()
    private var events: MediaEngineEvents?
    private var closing = false
    private var interruptedValue = false
    private var restarting = false
    private var unitRunning = false
    private var trackGenerationValue = 0
    private var routeChangesValue = 0
    private var glitchTotal: Int64 = 0
    private var gathered = GatheredLatch()
    private var subscription: AudioSessionEventMonitor.Subscription?
    private var capturePrevious: (timestampUs: Double, seconds: Double)?
    private var captureEvidenceValue = CaptureEvidence.unavailable
    private var watchdogPackets: Double?
    private var watchdogInactiveSince: ContinuousClock.Instant?
    private var watchdogFired = false

    // MARK: - Creation (stage AUDIO)

    /// `engineFactory` shape (`{ try MediaEngine($0, events: $1, checkpoint: $2) }`). Subscribes to `monitor`
    /// (synchronous sink; default the process-wide `AudioSessionEventMonitor.shared`, `nil` in tests) **before**
    /// enabling audio so the first `playOrRecordStarted` is seen, then creates the ADM, factory and peer and enables
    /// WebRTC audio (`StreamReceiver.kt:398-478`), calling `checkpoint` between native steps. If any step throws (Stop
    /// included), every object created so far is released in the order (and the subscription cancelled) before the
    /// error propagates, so a failed engine never outlives this call.
    init(
        _ configuration: MediaEngineConfiguration, events: MediaEngineEvents,
        checkpoint: @escaping () throws -> Void,
        monitor: AudioSessionEventMonitor? = AudioSessionEventMonitor.shared
    ) throws {
        self.configuration = configuration
        self.checkpoint = checkpoint
        self.events = events
        self.gates = AudioGateApplier(speakerMuted: configuration.initialSpeakerMuted)
        self.observer = PeerObserver(events: events)
        observer.setGatheringCompleteHandler { [weak self] in self?.fireGathered() }
        if let monitor { observe(monitor) }
        do {
            try createNativeObjects()
        } catch {
            close()
            throw error
        }
    }

    private func createNativeObjects() throws {
        try WebRTCRuntime.ensureInitialized()
        try checkpoint()
        let adm = WebRTCRuntime.makeAudioDeviceModule(configuration.plan.profile)
        audioDeviceModule = adm
        try checkpoint()
        let factory = try WebRTCRuntime.makeFactory(audioDeviceModule: adm, lanLocal: configuration.lanLocal)
        peerConnectionFactory = factory
        try checkpoint()
        let rtcConfiguration = ICEPeerConfiguration.make(
            servers: configuration.iceServers, policy: configuration.policy)
        // WebRTC's bundled roots omit Let's Encrypt's ISRG roots and the SDK uses no iOS trust without this
        // callback; WebRTC still checks the TURN hostname afterwards. Restarts keep this peer and verifier.
        let verifier = TurnTLSTrustVerifier(counters: configuration.turnTLSTrust)
        certificateVerifier = verifier
        guard
            let peer = factory.peerConnection(
                with: rtcConfiguration, constraints: MediaEngine.emptyConstraints(),
                certificateVerifier: verifier, delegate: observer)
        else {
            throw MediaEngineError.peerUnavailable
        }
        peerConnection = peer
        try checkpoint()
        // WebRTC may now create the unit lazily (playback/duplex when the receive stream starts, microphone mode when
        // the send stream starts after DTLS). Capture stays off: input was requested initially muted and is resumed
        // only by verified Unmute.
        WebRTCRuntime.setAudioEnabled(true)
    }

    /// Stage AUDIO (`SR:479-491`): playback → recv-only audio transceiver (the SDK later creates a second,
    /// offer-associated transceiver; keep this order so the answer is identical to Android's); microphone/duplex →
    /// audio source with the processing constraints and the `phone-microphone` track, created disabled. Gates are
    /// applied to the receivers known so far.
    func prepareLocalMedia() throws {
        try checkpoint()
        guard let factory = peerConnectionFactory, let peer = peerConnection else {
            throw MediaEngineError.peerUnavailable
        }
        if configuration.sendsMicrophone {
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: configuration.processing.constraints())
            let source = factory.audioSource(with: constraints)
            microphoneSource = source
            try checkpoint()
            let track = factory.audioTrack(with: source, trackId: MediaEngine.microphoneTrackId)
            track.isEnabled = false
            microphoneTrack = track
            try checkpoint()
        } else {
            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .recvOnly
            guard let transceiver = peer.addTransceiver(of: .audio, init: transceiverInit) else {
                throw MediaEngineError.transceiverUnavailable
            }
            receiveTransceiver = transceiver
        }
        refreshGateTargets()
    }

    /// Stage CODEC (`SR:492-498`): Opus 48000/2 capabilities (sender capabilities in microphone modes, receiver
    /// capabilities for playback; `OpusSdp.isStereoOpusCapability`). Playback applies them to the pre-created recv-only
    /// transceiver before the offer (no effect on the answer, by design); microphone modes apply them in
    /// `attachMicrophone()`.
    func applyCodecPreferences() throws {
        try checkpoint()
        guard let factory = peerConnectionFactory else { throw MediaEngineError.factoryUnavailable }
        let capabilities =
            configuration.sendsMicrophone
            ? factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
            : factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
        let opus = capabilities.codecs.filter {
            OpusSdp.isStereoOpusCapability(
                name: $0.name, clockRate: $0.clockRate?.intValue,
                channels: $0.numChannels?.intValue)
        }
        guard !opus.isEmpty else { throw MediaEngineError.opusUnavailable }
        opusCodecs = opus
        if let transceiver = receiveTransceiver {
            guard MediaEngine.setCodecPreferences(transceiver, opus) else {
                throw MediaEngineError.codecPreferencesRejected
            }
        }
    }

    /// Stage OFFER, microphone modes (`SR:501-508`): the single host-created audio transceiver gets the local track,
    /// direction `.sendRecv` (duplex) / `.sendOnly` (microphone) and the Opus codec preferences.
    func attachMicrophone() throws {
        try checkpoint()
        guard let peer = peerConnection, let track = microphoneTrack else {
            throw MediaEngineError.transceiverUnavailable
        }
        let transceivers = peer.transceivers
        guard transceivers.count == 1, let sending = transceivers.first, sending.mediaType == .audio else {
            throw MediaEngineError.transceiverUnavailable
        }
        sending.sender.track = track
        // The ObjC setter returns nothing; read back the id.
        guard sending.sender.track?.trackId == MediaEngine.microphoneTrackId else {
            throw MediaEngineError.senderTrackRejected
        }
        var directionError: NSError?
        sending.setDirection(configuration.mode == .duplex ? .sendRecv : .sendOnly, error: &directionError)
        guard directionError == nil else { throw MediaEngineError.directionRejected }
        guard MediaEngine.setCodecPreferences(sending, opusCodecs) else {
            throw MediaEngineError.codecPreferencesRejected
        }
        sendTransceiver = sending
        refreshGateTargets()
    }

    // MARK: - Descriptions (ICEPeerConfiguration.Peer)

    /// `setRemoteDescription(offer)` with a cancellable wait; initial offer 15 000 ms, recovery `budget(5000)`. The
    /// caller resets the gathered latch **before** a recovery offer. Afterwards the gates are re-applied to every audio
    /// receiver (a new receiver exists) and, in playback modes, `PlayoutTap` is attached to the offer-associated
    /// receiver once.
    func applyOffer(_ sdp: String, timeoutMs: Int = MediaEngine.descriptionTimeoutMs) throws {
        guard let peer = peerConnection else { throw MediaEngineError.peerUnavailable }
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        try awaitCompletion(timeoutMs: timeoutMs, of: Void.self) { box in
            peer.setRemoteDescription(description) { error in
                box.complete(error == nil ? .success(()) : .failure(MediaEngineError.sdpConfigurationFailed))
            }
        }
        refreshGateTargets()
        attachPlayoutTapIfNeeded()
    }

    /// `answer(for: empty constraints)`: the SDK answer exactly, without the direction check or the
    /// Opus stereo edit (`SR:509`, `:1595`). Initial answers go through `localAnswer(for:checkDirection: true)`.
    func createAnswer(timeoutMs: Int = MediaEngine.descriptionTimeoutMs) throws -> String {
        guard let peer = peerConnection else { throw MediaEngineError.peerUnavailable }
        let constraints = MediaEngine.emptyConstraints()
        return try awaitCompletion(timeoutMs: timeoutMs, of: String.self) { box in
            peer.answer(for: constraints) { description, error in
                if error == nil, let description {
                    box.complete(.success(description.sdp))
                } else {
                    box.complete(.failure(MediaEngineError.sdpCreationFailed))
                }
            }
        }
    }

    /// The description to install (steps 2-3): with `checkDirection` (initial answer only, `SR:510`) a microphone-mode
    /// answer must contain `a=sendrecv`/`a=sendonly` (`MediaEngineError.directionMismatch`); playback and duplex get
    /// `OpusSdp.stereoAnswer`, microphone-only answers are unmodified (`OpusSdp.localAnswer(_:mode:)`; recovery
    /// `SR:1597`).
    func localAnswer(for answer: String, checkDirection: Bool) throws -> String {
        if checkDirection && !OpusSdp.answerHasRequiredDirection(answer, mode: configuration.mode) {
            throw MediaEngineError.directionMismatch
        }
        return try OpusSdp.localAnswer(answer, mode: configuration.mode)
    }

    /// `setLocalDescription(answer)` with a cancellable wait. The caller takes `gatheringStarted` (monotonic)
    /// **before** this call (step 4).
    func setLocalAnswer(_ sdp: String, timeoutMs: Int = MediaEngine.descriptionTimeoutMs) throws {
        guard let peer = peerConnection else { throw MediaEngineError.peerUnavailable }
        let description = RTCSessionDescription(type: .answer, sdp: sdp)
        try awaitCompletion(timeoutMs: timeoutMs, of: Void.self) { box in
            peer.setLocalDescription(description) { error in
                box.complete(error == nil ? .success(()) : .failure(MediaEngineError.sdpConfigurationFailed))
            }
        }
    }

    /// `pc.localDescription?.sdp`: the exact SDK description (with gathered candidates).
    var localDescription: String? { peerConnection?.localDescription?.sdp }

    /// `pc.remoteDescription?.sdp`.
    var remoteDescription: String? { peerConnection?.remoteDescription?.sdp }

    /// `pc.iceGatheringState == .complete`; read before `localDescription` (step 5).
    var iceGatheringComplete: Bool { peerConnection?.iceGatheringState == .complete }

    // MARK: - Gathering latch (Kotlin `gathered`, `SR:519,535,1590,1599`)

    /// `gathered = CountDownLatch(1)`: a fresh latch, created before a recovery offer is applied.
    func resetGatheredLatch() {
        stateLock.lock()
        gathered = GatheredLatch()
        stateLock.unlock()
    }

    /// `workerWait.await { gathered.await(timeoutMs) }`: true once the current latch fired, false when
    /// `timeoutMs` elapsed first; Stop → the checkpoint's `SessionStopped`.
    func waitGathered(timeoutMs: Int) throws -> Bool {
        try checkpoint()
        stateLock.lock()
        let latch = gathered
        stateLock.unlock()
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(max(0, timeoutMs))
        while true {
            let remaining = MediaEngine.milliseconds(deadline - clock.now)
            if remaining <= 0 {
                try checkpoint()
                return latch.isFired
            }
            if latch.wait(milliseconds: min(MediaEngine.waitSliceMs, remaining)) {
                try checkpoint()
                return true
            }
            try checkpoint()
        }
    }

    // MARK: - Configuration and candidates

    /// `pc.setConfiguration(_:)` (remote restart, before each `/recover-offer`). `false` is fatal for
    /// the caller (`SR:1583`). Build `configuration` with `ICEPeerConfiguration.make(servers:policy:)`
    /// and `self.configuration.policy` so only the servers differ.
    func setConfiguration(_ configuration: RTCConfiguration) -> Bool {
        peerConnection?.setConfiguration(configuration) ?? false
    }

    /// Convenience over `setConfiguration(_:)` with this session's policy (spelling).
    func setConfiguration(iceServers: [RemoteICEServer]) -> Bool {
        setConfiguration(ICEPeerConfiguration.make(servers: iceServers, policy: configuration.policy))
    }

    /// `pc.add(RTCIceCandidate(sdp:sdpMLineIndex:sdpMid:), completionHandler:)` waited on the worker: `false` when
    /// WebRTC rejected the candidate, `timeoutMs` elapsed, or Stop interrupted the wait (Android `addIceCandidate`
    /// returns a Boolean, `SR:1636`).
    func addIceCandidate(mid: String, index: Int32, sdp: String, timeoutMs: Int) -> Bool {
        guard let peer = peerConnection else { return false }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        do {
            return try awaitCompletion(timeoutMs: timeoutMs, of: Bool.self) { box in
                peer.add(candidate) { error in box.complete(.success(error == nil)) }
            }
        } catch {
            return false
        }
    }

    /// `pc.remove([RTCIceCandidate])`; idempotent, treated as success (`SR:1646`).
    func removeIceCandidates(_ candidates: [(mid: String, index: Int32, sdp: String)]) {
        guard let peer = peerConnection, !candidates.isEmpty else { return }
        peer.remove(candidates.map { RTCIceCandidate(sdp: $0.sdp, sdpMLineIndex: $0.index, sdpMid: $0.mid) })
    }

    // MARK: - Statistics

    /// `peer.statistics` waited ≤ `timeoutMs` (timeout → `StageTimeoutError`, ends the session as
    /// `stage_timeout`). Also feeds the capture evidence and the playout watchdog.
    func statistics(timeoutMs: Int = MediaEngine.statisticsTimeoutMs) throws -> [String: RtcSample] {
        guard let peer = peerConnection else { throw MediaEngineError.peerUnavailable }
        let samples = try awaitCompletion(timeoutMs: timeoutMs, of: [String: RtcSample].self) { box in
            peer.statistics { report in box.complete(.success(StatsCollector.samples(from: report))) }
        }
        observeStatistics(samples)
        return samples
    }

    /// Latest optional capture confirmation (step 4). Any thread.
    func captureEvidence() -> CaptureEvidence {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureEvidenceValue
    }

    // MARK: - Local gates (any thread unless noted)

    /// Remote playout gate (`setSpeakerMute`): coalesced, applied on the gate queue; never blocks. The owner recomputes
    /// `speakerMuted` and calls this whenever a term changes.
    func setSpeakerMuted(_ muted: Bool) {
        gates.setSpeakerMuted(muted)
    }

    /// Teardown `local_audio_gates` (step 3): `true` makes the speaker mute and the microphone gate closure sticky and
    /// applies them synchronously before `/stop`. Session worker only. (`false` merely requests an unmute and is not
    /// used by teardown.)
    func setSpeakerMutedSynchronously(_ muted: Bool) {
        guard muted else {
            gates.setSpeakerMuted(false)
            return
        }
        gates.applyFinalSynchronously()
    }

    /// Microphone sample gate (`microphoneTrack.isEnabled`): closing is immediate-intent, opening only from the
    /// worker's verified final step. Never blocks.
    func setMicrophoneSampleGate(open: Bool) {
        gates.setMicrophoneOpen(open)
    }

    /// Effective speaker gate (diagnostics).
    var speakerMuted: Bool { gates.speakerMuted }

    // MARK: - Capture

    /// `factory.run(onWorker:) { running ? adm.resumeRecording() : adm.pauseRecording() }` (Shiguredo
    /// `ios_audio_pause_resume.patch`): 0 = success or no-op before audio initialisation, negative = failure, −1 also
    /// when the engine was released. Each call re-initialises the audio unit (brief playout gap in duplex; in
    /// microphone mode a pause with no playout stops the unit). Never call `resume` before the `initializeInput`
    /// completion. Session worker only.
    @discardableResult
    func setCaptureRunning(_ running: Bool) -> Int {
        guard let factory = peerConnectionFactory, let adm = audioDeviceModule else { return -1 }
        return factory.run(onWorker: { running ? adm.resumeRecording() : adm.pauseRecording() })
    }

    // MARK: - Playout (OutputPlayoutEngine)

    /// `PlayoutTap` activity: last decoded-track callback within 200 ms. Any thread.
    var playoutActive: Bool { playoutTap.isActive }

    /// `PlayoutTap` counters. Any thread.
    func playoutSnapshot() -> PlayoutTap.Snapshot { playoutTap.snapshot() }

    /// `didDetectPlayoutGlitch` running total. Any thread.
    var playoutGlitches: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return glitchTotal
    }

    /// true between the monitor's interruption `.began` (not `.appWasSuspended`) and `.ended`, a media-services reset,
    /// or teardown. Any thread.
    var interrupted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return interruptedValue
    }

    /// Audio-unit starts (`audioSessionDidStartPlayOrRecord`, first = 1). Any thread.
    var trackGeneration: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return trackGenerationValue
    }

    /// Output-set route changes observed while the unit ran. Any thread.
    var routeChanges: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return routeChangesValue
    }

    /// Between `audioSessionDidStartPlayOrRecord` and `…DidStopPlayOrRecord`. Any thread.
    var audioUnitRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unitRunning
    }

    /// playout recreation (`recreateOutput`, `SR:1078-1091`): speaker mute, `isAudioEnabled` false → (unless closed)
    /// true. Only in playback-only sessions — a no-op in microphone/duplex (the unit is shared with capture;
    /// `playout_recreations` stays 0 there). Falling playout edges are suppressed while it runs. The owner re-applies
    /// its composite speaker mute after re-verification (rising edge → `trackStarted`). Session worker only.
    func restartPlayout() throws {
        guard configuration.mode == .playback else { return }
        stateLock.lock()
        let skip = closing
        if !skip { restarting = true }
        stateLock.unlock()
        guard !skip else { return }
        defer {
            stateLock.lock()
            restarting = false
            stateLock.unlock()
        }
        gates.setSpeakerMuted(true)
        WebRTCRuntime.setAudioEnabled(false)
        stateLock.lock()
        let stillOpen = !closing
        stateLock.unlock()
        if stillOpen { WebRTCRuntime.setAudioEnabled(true) }
    }

    /// The honest iOS output snapshot (summary text). Any thread.
    func outputSnapshot(capturedUptimeMs: Int64) -> IOSOutputSnapshot {
        let tap = playoutTap.snapshot()
        stateLock.lock()
        let glitches = glitchTotal
        let generation = trackGenerationValue
        let changes = routeChangesValue
        stateLock.unlock()
        return IOSOutputSnapshot.capture(
            capturedUptimeMs: capturedUptimeMs,
            decodedChannels: tap.channels > 0 ? tap.channels : nil,
            playoutGlitches: glitches, trackGeneration: generation,
            routeChanges: changes)
    }

    // MARK: - Audio-session events (synchronous sink; any thread)

    /// Registers this engine as a synchronous sink of the process-wide monitor ("the engine's playout/glitch
    /// tracking"); `init` already does this for its `monitor` argument, so callers only use it to re-bind (tests).
    /// `interrupted` starts from `monitor.isInterrupted`. Replaces a previous subscription; the subscription is
    /// cancelled by `close(onStep:)`.
    func observe(_ monitor: AudioSessionEventMonitor) {
        let added = monitor.addSynchronousSink { [weak self] event in self?.handle(event) }
        let alreadyInterrupted = monitor.isInterrupted
        stateLock.lock()
        let accepted = !closing
        let previous = subscription
        subscription = accepted ? added : nil
        if accepted { interruptedValue = alreadyInterrupted }
        stateLock.unlock()
        previous?.cancel()
        if !accepted { added.cancel() }
    }

    /// Maps one monitor event (table): interruption began (except `.appWasSuspended`) / ended → `interrupted` +
    /// `audioInterruption`; route change → `routeChanges` (output set changed while the unit runs) +
    /// `audioRouteChanged`; media-services reset → `interrupted = false` + `mediaServicesReset()` in every mode (the
    /// session ends; no output/capture failure, no output recovery); play/record started/stopped → unit lifetime and
    /// `trackGeneration`; audio-unit start failure → `outputFailure(.start)` (`captureFailure(.start)` in
    /// microphone-only mode); activation failure → `.initialization` likewise; glitches → total + `playoutGlitches`.
    /// Nothing is forwarded once teardown started.
    func handle(_ event: AudioSessionEventMonitor.Event) {
        stateLock.lock()
        let target = closing ? nil : events
        stateLock.unlock()
        switch event {
        case .interruptionBegan(let reason):
            guard reason != .appWasSuspended else { return }
            setInterrupted(true)
            target?.audioInterruption(began: true, shouldResume: false)
        case .interruptionEnded(let shouldResume):
            setInterrupted(false)
            target?.audioInterruption(began: false, shouldResume: shouldResume)
        case .routeChanged(let change):
            stateLock.lock()
            if unitRunning && change.previousOutputs != change.currentOutputs { routeChangesValue += 1 }
            stateLock.unlock()
            target?.audioRouteChanged(reason: change.reason ?? .unknown)
        case .mediaServicesWereReset:
            setInterrupted(false)
            target?.mediaServicesReset()
        case .playOrRecordStarted:
            stateLock.lock()
            unitRunning = true
            trackGenerationValue += 1
            stateLock.unlock()
        case .playOrRecordStopped:
            stateLock.lock()
            unitRunning = false
            stateLock.unlock()
        case .audioUnitStartFailed:
            if configuration.mode == .microphone {
                target?.captureFailure(.start)
            } else {
                target?.outputFailure(.start)
            }
        case .failedToSetActive(let active, _):
            guard active else { return }
            if configuration.mode == .microphone {
                target?.captureFailure(.initialization)
            } else {
                target?.outputFailure(.initialization)
            }
        case .playoutGlitches(let total):
            stateLock.lock()
            glitchTotal = total
            stateLock.unlock()
            target?.playoutGlitches(total: Int(clamping: total))
        default:
            // mediaServicesWereLost: record only; canPlayOrRecordChanged: informational.
            break
        }
    }

    // MARK: - Teardown

    /// Releases every native object in the order inside one `autoreleasepool`, calling `onStep` before each step (the
    /// session writes the journal checkpoint `step.rawValue`): `peer_dispose` (PlayoutTap sink removed from its exact
    /// track, gate targets dropped, observer closed, `peer.close()`, delegate nil, transceiver and certificate-verifier
    /// references dropped), `microphone_track_dispose`, `microphone_source_dispose`, `factory_dispose` (weak probe
    /// kept), `audio_module_release` (`isAudioEnabled = false`). Returns the failed step names: `factory_dispose` when
    /// the factory is still alive after the pool drained (recorded in `WebRTCRuntime`, which then refuses new sessions
    /// until it deallocates) → the session records `TEARDOWN_FAILED`. Idempotent (a second call returns `[]` without
    /// touching `isAudioEnabled`). Session worker only; never from a WebRTC delegate, completion handler, the main
    /// thread or the gate queue; never under the audio lock.
    @discardableResult
    func close(onStep: (TeardownStep) -> Void = { _ in }) -> [String] {
        guard !released else { return [] }
        released = true
        markClosing()
        stateLock.lock()
        let monitorSubscription = subscription
        subscription = nil
        stateLock.unlock()
        monitorSubscription?.cancel()

        weak var factoryProbe: RTCPeerConnectionFactory?
        autoreleasepool {
            onStep(.peerDispose)
            playoutTap.detach()
            gates.clearTargets()
            observer.close()
            if let peer = peerConnection {
                peer.close()
                peer.delegate = nil
            }
            receiveTransceiver = nil
            sendTransceiver = nil
            opusCodecs = []
            peerConnection = nil
            certificateVerifier = nil

            onStep(.microphoneTrackDispose)
            microphoneTrack = nil

            onStep(.microphoneSourceDispose)
            microphoneSource = nil

            onStep(.factoryDispose)
            factoryProbe = peerConnectionFactory
            peerConnectionFactory = nil

            onStep(.audioModuleRelease)
            audioDeviceModule = nil
            WebRTCRuntime.setAudioEnabled(false)
        }

        stateLock.lock()
        events = nil
        stateLock.unlock()

        var failed: [String] = []
        if let lingering = factoryProbe {
            WebRTCRuntime.recordLingeringFactory(lingering)
            failed.append(TeardownStep.factoryDispose.rawValue)
        }
        return failed
    }

    // MARK: - Private helpers

    private static func emptyConstraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// `setCodecPreferences:error:` called through its IMP (import hazard): the deprecated void `setCodecPreferences:`
    /// and the BOOL/`NSError**` variant import to colliding Swift names, so the selector is invoked directly. `true`
    /// iff it returned YES.
    private static func setCodecPreferences(_ transceiver: RTCRtpTransceiver, _ codecs: [RTCRtpCodecCapability]) -> Bool
    {
        typealias Setter = @convention(c) (AnyObject, Selector, NSArray?, UnsafeMutableRawPointer?) -> ObjCBool
        let selector = NSSelectorFromString("setCodecPreferences:error:")
        guard transceiver.responds(to: selector), let implementation = transceiver.method(for: selector) else {
            return false
        }
        let setter = unsafeBitCast(implementation, to: Setter.self)
        return setter(transceiver, selector, codecs as NSArray, nil).boolValue
    }

    /// Gate targets = the `RTCAudioTrack` of every audio receiver (two in playback) plus the microphone track. Session
    /// worker only.
    private func refreshGateTargets() {
        guard let peer = peerConnection else { return }
        var tracks: [RTCAudioTrack] = []
        for transceiver in peer.transceivers where transceiver.mediaType == .audio {
            if let track = transceiver.receiver.track as? RTCAudioTrack { tracks.append(track) }
        }
        gates.setTargets(receiverTracks: tracks, microphoneTrack: microphoneTrack)
    }

    /// Attaches `PlayoutTap` once to the receiver of the offer-associated transceiver (non-empty `mid`) in
    /// playback/duplex sessions. Session worker only.
    private func attachPlayoutTapIfNeeded() {
        guard configuration.receivesPlayout, !playoutTap.isAttached, let peer = peerConnection else { return }
        for transceiver in peer.transceivers where transceiver.mediaType == .audio && !transceiver.mid.isEmpty {
            guard let track = transceiver.receiver.track as? RTCAudioTrack else { continue }
            playoutTap.attach(to: track) { [weak self] active in self?.playoutEdge(active) }
            return
        }
    }

    /// PlayoutTap edge → `playoutStarted` / `playoutStopped`; falling edges are ignored while interrupted, closing or
    /// inside `restartPlayout()`.
    private func playoutEdge(_ active: Bool) {
        stateLock.lock()
        let target = events
        let suppressed = !active && (closing || interruptedValue || restarting)
        stateLock.unlock()
        guard let target, !suppressed else { return }
        if active { target.playoutStarted() } else { target.playoutStopped() }
    }

    private func setInterrupted(_ value: Bool) {
        stateLock.lock()
        interruptedValue = value && !closing
        stateLock.unlock()
    }

    private func markClosing() {
        stateLock.lock()
        closing = true
        interruptedValue = false
        stateLock.unlock()
    }

    private func fireGathered() {
        stateLock.lock()
        let latch = gathered
        stateLock.unlock()
        latch.fire()
    }

    /// Statistics side effects:
    /// - capture evidence: from `StatsCollector.captureProgress`, keep the previous
    ///   `(timestampUs, seconds)`; once a sample is ≥ `captureEvidenceMinimumIntervalMs` newer, set
    ///   `advanced = seconds > previous.seconds` and replace the previous sample; `available` iff the
    ///   stat exists;
    /// - playout watchdog (receivesPlayout only): while `StatsCollector.inboundPacketsReceived` grows,
    ///   `!playoutTap.isActive`, not interrupted/restarting/closing, start or continue an inactive
    ///   episode (`watchdogInactiveSince`); after `playoutWatchdogMs` emit `outputFailure(.start)` once
    ///   per episode (`watchdogFired`); reset the episode when playout is active or packets stall.
    private func observeStatistics(_ samples: [String: RtcSample]) {
        let progress = StatsCollector.captureProgress(samples)
        let packets = StatsCollector.inboundPacketsReceived(samples)
        let active = playoutTap.isActive
        let now = ContinuousClock.now
        stateLock.lock()
        if let progress {
            var advanced = captureEvidenceValue.advanced
            if let previous = capturePrevious {
                if progress.timestampUs - previous.timestampUs >= Double(Self.captureEvidenceMinimumIntervalMs) * 1000 {
                    advanced = progress.seconds > previous.seconds
                    capturePrevious = progress
                }
            } else {
                capturePrevious = progress
                advanced = false
            }
            captureEvidenceValue = CaptureEvidence(
                available: true, advanced: advanced, totalSamplesDuration: progress.seconds)
        } else {
            capturePrevious = nil
            captureEvidenceValue = .unavailable
        }
        let growing = packets.map { value in watchdogPackets.map { value > $0 } ?? false } ?? false
        watchdogPackets = packets
        var failureTarget: MediaEngineEvents?
        if configuration.receivesPlayout && growing && !active && !closing && !restarting && !interruptedValue {
            if watchdogInactiveSince == nil { watchdogInactiveSince = now }
            if let since = watchdogInactiveSince, now - since >= .milliseconds(Self.playoutWatchdogMs), !watchdogFired {
                watchdogFired = true
                failureTarget = events
            }
        } else {
            watchdogInactiveSince = nil
            watchdogFired = false
        }
        stateLock.unlock()
        failureTarget?.outputFailure(.start)
    }

    /// Polls `checkpoint()` every 20 ms while waiting for a WebRTC completion handler (semantics: the native call is
    /// started before waiting and never interrupted; Stop throws the checkpoint's `SessionStopped`; a completion after
    /// Stop still throws; expiry → `StageTimeoutError`).
    @discardableResult
    private func awaitCompletion<T>(timeoutMs: Int?, of type: T.Type, _ start: (CompletionBox<T>) -> Void) throws -> T {
        try checkpoint()
        let box = CompletionBox<T>()
        start(box)
        let clock = ContinuousClock()
        let deadline = timeoutMs.map { clock.now + .milliseconds(max(0, $0)) }
        while true {
            var slice = MediaEngine.waitSliceMs
            if let deadline {
                let remaining = MediaEngine.milliseconds(deadline - clock.now)
                if remaining <= 0 {
                    if let result = box.current() {
                        try checkpoint()
                        return try result.get()
                    }
                    throw StageTimeoutError("media_engine")
                }
                slice = min(slice, remaining)
            }
            if let result = box.wait(milliseconds: slice) {
                try checkpoint()
                return try result.get()
            }
            try checkpoint()
        }
    }

    /// One-shot completion slot filled from the WebRTC signalling thread (first result wins).
    private final class CompletionBox<T>: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<T, Error>?

        func complete(_ value: Result<T, Error>) {
            condition.lock()
            if result == nil {
                result = value
                condition.broadcast()
            }
            condition.unlock()
        }

        func current() -> Result<T, Error>? {
            condition.lock()
            defer { condition.unlock() }
            return result
        }

        /// Waits up to `milliseconds` for the result.
        func wait(milliseconds: Int) -> Result<T, Error>? {
            condition.lock()
            defer { condition.unlock() }
            if result == nil {
                _ = condition.wait(until: Date(timeIntervalSinceNow: Double(max(milliseconds, 0)) / 1000))
            }
            return result
        }
    }

    /// Kotlin `CountDownLatch(1)` for ICE gathering completion; firing is sticky.
    private final class GatheredLatch: @unchecked Sendable {
        private let condition = NSCondition()
        private var fired = false

        func fire() {
            condition.lock()
            fired = true
            condition.broadcast()
            condition.unlock()
        }

        var isFired: Bool {
            condition.lock()
            defer { condition.unlock() }
            return fired
        }

        /// Waits up to `milliseconds`; true once fired.
        func wait(milliseconds: Int) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            if !fired {
                _ = condition.wait(until: Date(timeIntervalSinceNow: Double(max(milliseconds, 0)) / 1000))
            }
            return fired
        }
    }
}

// MARK: - Conformances

/// drives initial gathering, status ICE steps and remote restarts through this protocol (`ICEPeerConfiguration.swift`).
extension MediaEngine: ICEPeerConfiguration.Peer {}

/// playout interface. The session may still use its own `PlayoutEngineBridge` (available before the engine exists).
extension MediaEngine: OutputPlayoutEngine {
    /// spelling of `setSpeakerMuted(_:)`.
    func setRemotePlayoutMuted(_ muted: Bool) {
        setSpeakerMuted(muted)
    }
}
