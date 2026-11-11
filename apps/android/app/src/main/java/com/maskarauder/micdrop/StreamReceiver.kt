package com.maskarauder.micdrop

import android.content.Context
import android.media.MediaRecorder
import org.json.JSONObject
import org.webrtc.*
import org.webrtc.audio.JavaAudioDeviceModule
import java.io.ByteArrayOutputStream
import java.net.URL
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocketFactory

// Owns one service-controlled session. PCM stays inside native WebRTC / Android
// audio. Desktop playback uses media attributes; microphone return has a
// separate explicit foreground-service owner. Bluetooth input opts into a
// session-owned communication route; ordinary playback stays in media mode.
internal class StreamReceiver(
    private val context: Context,
    private val invitation: LanInvitation,
    private val fastRecovery: Boolean,
    private val localOutputBaseline: OutputSnapshot?,
    private val onStatus: (String) -> Unit,
    private val onDiagnostics: (String) -> Unit,
    private val onPhase: (SessionPhase) -> Unit,
    private val onEnded: (StreamEnd) -> Unit,
    private val reconnect: Boolean = false,
    private val mode: StreamMode = StreamMode.PLAYBACK,
    private val microphoneSelection: MicrophoneSelection = MicrophoneSelection(),
    initiallyMicrophoneMuted: Boolean = false,
    private val onMicrophoneState: (Boolean, Boolean) -> Unit = { _, _ -> },
    // Evidence of verified unmuted capture, distinct from requested-state updates
    // sent while network audio is held or a headset is being restored.
    private val onMicrophoneCaptureEnabled: () -> Unit = {},
    private val onMicrophoneSelection: (MicrophoneSelection) -> Unit = {},
    initiallyOutputEnabled: Boolean = true,
    private val outputSelection: OutputSelection = OutputSelection(),
    microphoneProcessing: MicrophoneProcessing = MicrophoneProcessing(),
    private val keepMicrophoneActive: Boolean = false,
    private val onOutputSelection: (OutputSelection) -> Unit = {},
    protectedDefaultSpeaker: Boolean = false,
    initiallyOutputFocus: OutputPause? = null,
    private val onOutputState: (OutputPause?, Boolean) -> Unit = { _, _ -> },
    wakeLockHeld: () -> Boolean? = { null },
    foregroundTypes: () -> Int? = { null },
    private val onNetworkStatus: (String) -> Unit = {},
    private val connectionPreferences: ConnectionPreferences = AppConnectionSettings.load(context),
    private val resume: SessionResume.Reason? = null,
    phoneControlBinding: PhoneControlBinding? = null
) {
    private val closed = AtomicBoolean(false)
    private val phoneControl = phoneControlBinding?.let { AppPhoneControl(context, it, closed::get) }
    private var phoneControlEnabled = false
    private val failure = AtomicReference<String?>(null)
    private val failureEvidence = AtomicReference<FailureEvidence?>(null)
    private val stopReason = AtomicReference<StopReason?>(null)
    private val cancelLock = Any()
    private val audioLock = Any()
    private val outputGate = AudioOutputGate(initiallyOutputEnabled && mode.playback,
        held = mode.playback && ((mode.microphone && microphoneSelection.kind.bluetooth) || outputSelection.explicit))
    private val bluetoothRecoveryMs = connectionPreferences[ConnectionTimeout.BLUETOOTH_RECOVERY]
    private val bluetoothRecoverySeconds = ConnectionTimeout.seconds(bluetoothRecoveryMs)
    private val outputRoute = OutputRouteChange(outputSelection, bluetoothRecoveryMs = bluetoothRecoveryMs.toLong())
    private val outputRouting = WebRtcOutputRouting()
    private val usesMediaOutput get() = mode.usesMediaOutput(microphoneSelection.kind)
    private val defaultOutput = DefaultOutputPolicy(outputSelection, protectedDefaultSpeaker)
    private val outputRestarts = OutputRestartBudget()
    private val outputDevices = OutputDeviceWatch(context) { removed -> outputDevicesChanged(removed) }
    private val mediaRoutes = MediaOutputRoutes(context) { outputDevicesChanged(false) }
    private var predictedOutput = emptySet<OutputDevice>()
    private var defaultTargetMatches: Boolean? = null
    private var outputRecreations = 0
    private var outputFocus = initiallyOutputFocus
    private var outputRefresh = false
    private var outputWaitingSince: Long? = null
    private var speakerBluetoothGeneration = 0L
    private var outputProbeUntil = 0L
    private var publishedOutput: Pair<OutputPause?, Boolean>? = null
    @Volatile private var outputRestarting = false
    @Volatile private var mediaReady = false
    private var audio: JavaAudioDeviceModule? = null
    private var factory: PeerConnectionFactory? = null
    private var peer: PeerConnection? = null
    private var sessionToken: String? = null
    private val stopDestination = ResumeTicket.fingerprint(listOf(invitation.version.toString(),
        invitation.host, invitation.port.toString(), PublicIdentity.hex(invitation.fingerprint),
        invitation.clientKey, invitation.token, invitation.expiresAt.toString(),
        invitation.remote?.url.orEmpty(), invitation.remote?.token.orEmpty()).joinToString("\u0000"))
    private var trickle: TrickleIce? = null
    private var continuous: ContinuousIce? = null
    @Volatile private var continuousEnabled = false
    private val continuousCandidates = ContinuousCandidates()
    private val offerAttempt = OfferAttempt(invitation.version >= 2)
    private var lifecycleVersion = 1
    @Volatile private var gathered = CountDownLatch(1)
    private val gatheringErrors = IceGatheringErrors()
    private val turnTlsTrust = TurnTlsTrust()
    private var initialGathering: IceGatheringSnapshot? = null
    private var includeIceGathering = false
    private var includeMediaTransport = false
    private var includeRouteSelection = false
    private var includeTlsVerification = false
    private val routeSelection = RouteSelection()
    private val microphoneReturn get() = mode.microphone
    private val leStereoDuplex get() = mode == StreamMode.DUPLEX && microphoneSelection.leStereoRequested
    private val metrics = SessionMetrics(mode)
    private val microphoneInput = MicrophoneInput()
    private val microphoneRouting = MicrophoneRouting(context, microphoneSelection) { inputRouteLost() }
    private val microphoneDesiredMuted = AtomicBoolean(initiallyMicrophoneMuted)
    private val headsetRecovery = HeadsetRecovery(bluetoothRecoveryMs.toLong())
    private var restoringEpisode: Long? = null
    private var restorationHostMuted = false
    private var restorationInputId: Int? = null
    private var restorationRecording = false
    @Volatile private var restorationPlayoutStopped = false
    private var restorationReportedMute: Boolean? = null
    private val controlSignal = Object()
    private val lanNetwork = LanNetwork(context, invitation.host) { synchronized(controlSignal) { controlSignal.notifyAll() } }
    private val signalingRoute = SignalingRoute(invitation.remote != null, connectionPreferences.initialOrder, connectionPreferences.recoveryOrder)
    private var connectionDeadlines = connectionPreferences.unnegotiated()
    private var offerReply = OfferReply.NONE // Worker-owned. REJECTED when /offer returns, before validation can throw.
    private var setupStartedAt: Long? = null
    @Volatile private var activeProbe: LocalProbe? = null
    private class LocalStatus(val connection: HttpsURLConnection) { val handoff = AtomicBoolean(false) }
    @Volatile private var localStatusRequest: LocalStatus? = null
    private var lanRecovery = LanRecovery(false)
    private val networkHandoff = NetworkHandoff()
    @Volatile private var remoteStatusRequest: RemoteHttp? = null
    private var networkHandoffs = 0
    private var publishedNetworkStatus = ""
    private var lastSignalingFailure: String? = null
    private val signalingRequestFailures = ArrayDeque<String>() // Worker-owned, fixed four-entry history.
    private var recoveryLocalGeneration = 0L
    private var recoveryPreviousLocal = ""
    private val recoveryCandidates = RecoveryCandidates()
    @Volatile private var collectingRecovery = false
    private val networkHeld = AtomicBoolean(false)
    private var networkAudioSuspended = false
    private val processing = microphoneProcessing.effective(mode, microphoneSelection.kind)
    private val speakerMuted get() = outputGate.muted || networkHeld.get() ||
        (usesMediaOutput && (defaultOutput.held || outputFocus != null))
    @Volatile private var microphoneAppliedMuted: Boolean? = null
    private var microphoneControlDirty = false
    @Volatile private var microphoneCaptureRetained = false
    @Volatile private var recordStarted = false
    private var microphoneTrack: AudioTrack? = null
    private var microphoneSource: AudioSource? = null
    private val environment = PlaybackEnvironment(context)
    private val evidence = SessionEvidence()
    private val runtime = SessionRuntime(context, evidence, wakeLockHeld, foregroundTypes) {
        if (invitation.remote != null && !closed.get() && networkHandoff.changed(android.os.SystemClock.elapsedRealtime())) {
            // Only an idempotent heartbeat can be interrupted by a handoff.
            // Never cancel/replay initial offer creation from a network callback.
            remoteStatusRequest?.cancel()
            localStatusRequest?.let { status ->
                status.handoff.set(true)
                Thread({ runCatching { status.connection.disconnect() } }, "MicDrop-status-handoff").start()
            }
            synchronized(controlSignal) { controlSignal.notifyAll() }
        }
    }
    private var includeConnection = false
    private var includeOutputControl = false
    private var lastDiagnostics = ""
    private val journal = StopReportJournal("MicDrop ${BuildConfig.VERSION_NAME} · build ${BuildConfig.REVISION}\n" +
        "Session mode: ${mode.direction}\nSession started at: ${java.time.Instant.now()}") {
        StoredReports.saveStream(context, it)
    }
    private var journalActive = false // Only the worker holding AudioSessionOwner writes.
    private val outputDiagnostics = WebRtcOutputDiagnostics()
    private val recoveryMonitor = RecoveryMonitor(fastRecovery)
    private var tls: SSLSocketFactory? = null
    @Volatile private var stage = ConnectionStage.WAITING
    @Volatile private var remoteRequest: RemoteHttp? = null
    @Volatile private var activeRequest: HttpsURLConnection? = null
    @Volatile private var state = "Connecting"
    @Volatile private var iceConnected = false
    @Volatile private var trackStarted = false
    private val worker = Thread({ runSession() }, "MicDrop-session")
    private val workerWait = SessionWorkerWait(worker) { closed.get() }

    fun start() = worker.start()
    fun microphoneMuteRequested(): Boolean = microphoneDesiredMuted.get()

    fun outputEnabled(): Boolean = synchronized(audioLock) { outputGate.enabled }
    fun outputSwitchPending(): Boolean = usesMediaOutput && synchronized(audioLock) { outputRoute.pending && outputRoute.selection.explicit }
    private fun selectedOutputRecovering(): Boolean = synchronized(audioLock) { outputRoute.recovering }
    fun matchesOutputSelection(selection: OutputSelection): Boolean = synchronized(audioLock) {
        !closed.get() && outputRoute.selection == selection
    }
    private fun outputProbing(): Boolean = usesMediaOutput && synchronized(audioLock) {
        !outputRoute.selection.explicit && android.os.SystemClock.elapsedRealtime() < outputProbeUntil
    }
    private fun outputPauseLocked(): OutputPause? = if (usesMediaOutput)
        outputFocus ?: (if (outputRoute.recovering) {
            if (outputRoute.selection.kind.bluetooth) OutputPause.SELECTED_BLUETOOTH else OutputPause.ROUTE
        } else defaultOutput.pauseForInventory(outputDevices.bluetoothAvailable)) else null
    private fun playbackPaused(): OutputPause? = synchronized(audioLock) { outputPauseLocked() }
    fun matchesOutputState(pause: OutputPause?, protectedSpeaker: Boolean): Boolean = synchronized(audioLock) {
        !closed.get() && outputPauseLocked() == pause &&
            (usesMediaOutput && defaultOutput.speakerProtected) == protectedSpeaker
    }

    fun setOutputFocus(pause: OutputPause?) {
        synchronized(audioLock) {
            if (!usesMediaOutput || closed.get()) return
            outputFocus = pause; audio?.setSpeakerMute(speakerMuted)
        }
        publishOutputState()
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    // The broadcast describes a global media change. It does not establish
    // loss of this app's pinned speaker or authorize stopping independent capture.
    fun mediaOutputBecomingNoisy(): Boolean {
        synchronized(audioLock) {
            if (!usesMediaOutput || closed.get()) return false
            when {
                !outputRoute.selection.explicit -> defaultOutput.noisy()
                outputRoute.selection.kind.bluetooth -> holdSelectedBluetoothOutput(android.os.SystemClock.elapsedRealtime())
                else -> outputGate.hold() // Worker checks the actual pinned output before release/teardown.
            }
            audio?.setSpeakerMute(true)
            outputRefresh = true
            outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
        }
        publishOutputState()
        synchronized(controlSignal) { controlSignal.notifyAll() }
        return true
    }

    // Called under audioLock. Repeated route events keep the first deadline;
    // only a fresh episode renews the finite native-output recreation budget.
    private fun holdSelectedBluetoothOutput(nowMs: Long) {
        if (outputRoute.recoverBluetooth(outputRoute.ticket, nowMs)) {
            outputRestarts.newRoute(); outputWaitingSince = null
            mediaRoutes.newEpisode()
        }
        outputGate.hold(); audio?.setSpeakerMute(true); outputRefresh = true
    }

    private fun holdSelectedSpeakerOutput(nowMs: Long) {
        if (outputRoute.recoverSpeaker(outputRoute.ticket, nowMs)) {
            outputRestarts.newRoute(); outputWaitingSince = null
        }
        outputGate.hold(); audio?.setSpeakerMute(true); outputRefresh = true
    }

    private fun outputDevicesChanged(bluetoothRemoved: Boolean) {
        synchronized(audioLock) {
            if (!usesMediaOutput || closed.get()) return
            if (outputRoute.selection.kind.bluetooth) {
                if (mediaReady) holdSelectedBluetoothOutput(android.os.SystemClock.elapsedRealtime())
                else outputRefresh = true
            } else {
                if (outputRoute.selection.explicit) {
                    if (!outputRoute.selection.temporarySpeaker) return
                    // A temporary speaker choice keeps listening for Bluetooth
                    // return. The worker clears the pin; callbacks do no native work.
                    outputGate.hold()
                } else {
                    if (bluetoothRemoved) defaultOutput.noisy() else defaultOutput.changing()
                    outputRestarts.newRoute()
                }
            }
            audio?.setSpeakerMute(true)
            outputRefresh = true; outputWaitingSince = null
            outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
        }
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    private fun recoverableOutputFailed(): Boolean {
        synchronized(audioLock) {
            if (!usesMediaOutput || closed.get()) return false
            if (outputRoute.selection.kind.bluetooth) holdSelectedBluetoothOutput(android.os.SystemClock.elapsedRealtime())
            else if (outputRoute.selection.kind == OutputKind.PHONE) {
                if (outputRoute.pending && !outputRoute.recovering) return false
                holdSelectedSpeakerOutput(android.os.SystemClock.elapsedRealtime())
            } else {
                if (outputRoute.selection.explicit) return false
                defaultOutput.unavailable(); audio?.setSpeakerMute(true)
            }
            outputRestarts.request(); outputWaitingSince = null
            outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
        }
        synchronized(controlSignal) { controlSignal.notifyAll() }
        return true
    }

    private fun publishOutputState() {
        val value = synchronized(audioLock) {
            val next = outputPauseLocked() to
                (usesMediaOutput && defaultOutput.speakerProtected)
            if (closed.get() || next == publishedOutput) null else next.also { publishedOutput = it }
        } ?: return
        onOutputState(value.first, value.second)
    }

    fun setOutputSelection(selection: OutputSelection) {
        synchronized(audioLock) {
            if (!usesMediaOutput || closed.get() || !outputRoute.request(selection)) return
            speakerBluetoothGeneration = outputDevices.bluetoothGeneration
            defaultOutput.select(selection); outputRestarts.newRoute(); outputWaitingSince = null
            mediaRoutes.reset(); predictedOutput = emptySet(); defaultTargetMatches = null
            outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
            outputGate.hold(); audio?.setSpeakerMute(true)
        }
        if (selection.explicit) onPhase(SessionPhase.SWITCHING)
        publishOutputState()
        onStatus("Changing playback device. Audio stays silenced until Android verifies the route…")
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    fun setOutputEnabled(enabled: Boolean) {
        synchronized(audioLock) {
            if (!mode.playback || closed.get()) return
            outputGate.request(enabled)
            audio?.setSpeakerMute(speakerMuted)
        }
    }

    fun setMicrophoneMuted(muted: Boolean) {
        // Immediate local sample gate; capture ownership/control stays on the
        // session worker. Serialize the desired state with a recovery's final
        // gate so a delayed acknowledgment cannot undo a newer Mute request.
        synchronized(audioLock) {
            if (!microphoneReturn || closed.get()) return
            if (microphoneAppliedMuted == muted && microphoneDesiredMuted.get() == muted) return
            microphoneDesiredMuted.set(muted)
            audio?.setMicrophoneMute(true)
        }
        onMicrophoneState(muted, true)
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    fun close(reason: StopReason = StopReason.USER) {
        val pending = synchronized(cancelLock) {
            stopReason.compareAndSet(null, reason)
            if (!closed.compareAndSet(false, true)) return
            networkHandoff.stop()
            headsetRecovery.cancel()
            // Silence immediately, even if signaling is blocked. Destruction
            // stays on the owning worker; never dispose from a callback.
            synchronized(audioLock) {
                outputGate.stop(); outputRoute.stop(); defaultOutput.stop(); outputRestarts.stop(); audio?.setSpeakerMute(true)
                if (microphoneReturn) audio?.setMicrophoneMute(true)
            }
            workerWait.cancel()
            activeRequest
        }
        remoteRequest?.cancel()
        activeProbe?.close()
        // HttpsURLConnection.disconnect can block. Never run it on the UI or
        // a WebRTC callback thread that native teardown needs to join.
        pending?.let { connection ->
            Thread({ try { connection.disconnect() } catch (_: Exception) { } }, "MicDrop-cancel").start()
        }
    }

    private fun fail(message: String, code: SessionFailure = SessionFailure.SESSION_EXCEPTION, error: Throwable? = null) {
        synchronized(cancelLock) {
            if (closed.get() || !stopReason.compareAndSet(null, StopReason.FAILURE)) return
            val http = error?.let { generateSequence(it) { cause -> cause.cause }.take(8).filterIsInstance<HttpFailure>().firstOrNull()?.status }
            failureEvidence.set(FailureEvidence(code, stage, android.os.SystemClock.elapsedRealtime(), http))
            error?.let { signalingFailureText(it) }?.let { lastSignalingFailure = it }
            failure.compareAndSet(null, message)
            close(StopReason.FAILURE)
        }
    }

    private fun runSession() {
        var ownsSession = false
        try {
            require(!microphoneReturn || invitation.version == 3)
            step(ConnectionStage.WAITING)
            workerWait.await { AudioSessionOwner.lock.acquire(); ownsSession = true }
            if (closed.get()) return
            journalActive = true; journal.checkpoint("setup_${stage.name.lowercase()}")
            runtime.start()
            publishNetworkStatus()
            lanNetwork.start()
            if (usesMediaOutput) {
                outputDevices.start()
                synchronized(audioLock) { speakerBluetoothGeneration = outputDevices.bluetoothGeneration }
                mediaRoutes.start()
            }
            val preferredInput = if (microphoneReturn) {
                // Finish a potentially slow Bluetooth transition before the
                // host allocates its offer/session and starts its watchdog.
                step(ConnectionStage.INPUT_ROUTE)
                microphoneRouting.prepare { closed.get() }
            } else null
            if (microphoneReturn && mode.playback) microphoneRouting.validateDuplexOutput()
            step(ConnectionStage.PAIRING)
            tls = invitation.socketFactory()
            signalingRoute.initial { probeLocal() }
            val (offer, iceServers) = obtainOffer()
            offerReply = OfferReply.REJECTED
            connectionDeadlines = connectionDeadlines.copy(state = DeadlineState.REJECTED)
            require(offer.getInt("version") == invitation.version)
            lifecycleVersion = offer.optInt("session_lifecycle_version", 1)
            phoneControlEnabled = invitation.version == 3 && offer.optInt("phone_control_version") == 1 && phoneControl != null
            val restartSupported = invitation.version == 3 && offer.optInt("ice_restart_version") == 1
            connectionDeadlines = connectionPreferences.negotiated(restartSupported, if (invitation.version == 3) offer.optInt("connection_timeouts_version") else 0,
                offer.optInt("recovery_window_ms"), offer.optInt("setup_window_ms"), offer.optInt("heartbeat_timeout_ms"))
            setupStartedAt = android.os.SystemClock.elapsedRealtime()
            lanRecovery = LanRecovery(restartSupported, connectionDeadlines.recoveryMs.toLong(),
                connectionPreferences[ConnectionTimeout.RESTART_DELAY].toLong(), connectionPreferences[ConnectionTimeout.RESTART_INTERVAL].toLong(),
                connectionPreferences.maxRestarts)
            val delivery = ReportDelivery(offer.optInt("diagnostics_version", 0))
            val includeOutput = offer.optInt("output_diagnostics_version", 0) == 1
            includeConnection = offer.optInt("connection_diagnostics_version", 0) == 1
            includeOutputControl = offer.optInt("output_control_diagnostics_version", 0) == 1
            val gatheringDiagnosticsVersion = offer.optInt("ice_gathering_diagnostics_version", 0)
            includeIceGathering = gatheringDiagnosticsVersion in 1..3
            includeMediaTransport = offer.optInt("media_transport_diagnostics_version", 0) == 1
            includeRouteSelection = offer.optInt("route_selection_diagnostics_version", 0) == 1
            includeTlsVerification = offer.optInt("tls_certificate_diagnostics_version", 0) == 1
            val token = offer.getString("session")
            require(token.matches(Regex("[A-Za-z0-9_-]{43}")))
            sessionToken = token
            offerReply = OfferReply.ACCEPTED
            SessionStopRetry.shared.accepted(stopDestination)
            if (!mode.acceptsOffer(offer.optInt("microphone_return_version"), offer.optInt("duplex_version"), offer.optString("audio_direction"))) {
                fail("Windows did not confirm the requested audio mode. Update both apps and select a cable endpoint for microphone return.", SessionFailure.MODE_NOT_CONFIRMED)
                return
            }
            val description = offer.getString("sdp"); require(description.length <= 65536)
            val useTrickle = invitation.remote != null && invitation.version == 3 && offer.optInt("trickle_ice_version") == 1
            continuousEnabled = useTrickle && offer.optInt("continuous_ice_version") == 1
            if (continuousEnabled) continuous = ContinuousIce(description, invitation.remote?.forceRelay == true, 0)
            else if (useTrickle) trickle = TrickleIce(description, invitation.remote?.forceRelay == true)
            if (closed.get()) return
            step(ConnectionStage.AUDIO)
            initializeWebRTC(context)
            workerWait.checkpoint()
            val module = JavaAudioDeviceModule.builder(context)
                .setInputSampleRate(48000).setUseStereoInput(false)
                .setAudioSource(if (microphoneReturn && microphoneSelection.voiceInput)
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC)
                .setOutputSampleRate(48000).setUseStereoOutput(!microphoneReturn || microphoneSelection.outputChannels == 2).setUseLowLatency(true)
                .setUseHardwareAcousticEchoCanceler(false).setUseHardwareNoiseSuppressor(false)
                .setEnableVolumeLogger(false)
                .setAudioAttributes(if (microphoneReturn) MicrophoneRouting.attributes(microphoneSelection) else PlaybackEnvironment.attributes())
                .setAudioTrackStateCallback(object : JavaAudioDeviceModule.AudioTrackStateCallback {
                    override fun onWebRtcAudioTrackStart() {
                        trackStarted = true
                        synchronized(audioLock) {
                            if (usesMediaOutput && !closed.get()) {
                                outputRoute.trackStarted()
                                defaultOutput.changing()
                                outputGate.hold(); audio?.setSpeakerMute(true)
                            }
                        }
                    }
                    override fun onWebRtcAudioTrackStop() {
                        trackStarted = false
                        if (mediaReady && !outputRestarting) recoverableOutputFailed()
                        if (mode.playback && microphoneSelection.kind.bluetooth && microphoneAppliedMuted != null &&
                            !closed.get() && !restorationPlayoutStopped)
                            inputRouteLost()
                    }
                })
                .setAudioRecordStateCallback(object : JavaAudioDeviceModule.AudioRecordStateCallback {
                    override fun onWebRtcAudioRecordStart() { recordStarted = true }
                    override fun onWebRtcAudioRecordStop() { recordStarted = false; microphoneCaptureRetained = false }
                })
                .setAudioRecordErrorCallback(object : JavaAudioDeviceModule.AudioRecordErrorCallback {
                    override fun onWebRtcAudioRecordInitError(message: String) { fail("The selected microphone could not start. Check microphone permission and privacy settings.", SessionFailure.MICROPHONE_INIT) }
                    override fun onWebRtcAudioRecordStartError(code: JavaAudioDeviceModule.AudioRecordStartErrorCode, message: String) { fail("The selected microphone failed to start.", SessionFailure.MICROPHONE_START) }
                    override fun onWebRtcAudioRecordError(message: String) { fail("The selected microphone stopped unexpectedly.", SessionFailure.MICROPHONE_RUNTIME) }
                })
                .setAudioTrackErrorCallback(object : JavaAudioDeviceModule.AudioTrackErrorCallback {
                    override fun onWebRtcAudioTrackInitError(message: String) { if (!recoverableOutputFailed()) fail(if (leStereoDuplex) MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE.detail else "Android audio output could not start.",
                        if (leStereoDuplex) SessionFailure.LE_STEREO_UNAVAILABLE else SessionFailure.OUTPUT_INIT) }
                    override fun onWebRtcAudioTrackStartError(code: JavaAudioDeviceModule.AudioTrackStartErrorCode, message: String) { if (!recoverableOutputFailed()) fail(if (leStereoDuplex) MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE.detail else "Android audio playback failed to start.",
                        if (leStereoDuplex) SessionFailure.LE_STEREO_UNAVAILABLE else SessionFailure.OUTPUT_START) }
                    override fun onWebRtcAudioTrackError(message: String) { if (!recoverableOutputFailed()) fail("Android audio output stopped unexpectedly.", SessionFailure.OUTPUT_RUNTIME) }
                }).createAudioDeviceModule()
            synchronized(audioLock) {
                audio = module
                if (closed.get()) outputGate.stop()
                module.setSpeakerMute(speakerMuted)
            }
            workerWait.checkpoint() // Published resources stay owned by this worker's finally block.
            if (microphoneReturn) {
                module.setMicrophoneMute(true)
                module.setPreferredInputDevice(requireNotNull(preferredInput))
            }
            val factoryOptions = PeerConnectionFactory.Options().apply {
                if (invitation.remote == null && lanNetwork.local) networkIgnoreMask = PeerConnectionFactory.Options.ADAPTER_TYPE_CELLULAR
            }
            workerWait.checkpoint()
            val rtcFactory = PeerConnectionFactory.builder().setOptions(factoryOptions)
                .setAudioDeviceModule(module).createPeerConnectionFactory()
            factory = rtcFactory
            // Transfer native ownership to the factory while its worker lives.
            // The Java wrapper still provides immediate speaker mute.
            module.release()
            workerWait.checkpoint()
            val config = PeerConnection.RTCConfiguration(iceServers).apply {
                if (invitation.remote?.forceRelay == true) iceTransportsType = PeerConnection.IceTransportsType.RELAY
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                continualGatheringPolicy = if (continuousEnabled) PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                    else PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
                // NetEq's supported catch-up mode addresses the measured transient
                // backlog. Keep its adaptive target and packet capacity unchanged.
                audioJitterBufferFastAccelerate = fastRecovery
            }
            val dependencies = PeerConnectionDependencies.builder(observer)
                .setSSLCertificateVerifier(object : SSLCertificateVerifier {
                    override fun verify(certificate: ByteArray): Boolean = turnTlsTrust.verify(arrayOf(certificate))
                    override fun verifyChain(certificateChain: Array<ByteArray>): Boolean = turnTlsTrust.verify(certificateChain)
                }).createPeerConnectionDependencies()
            val connection = requireNotNull(rtcFactory.createPeerConnection(config, dependencies))
            peer = connection
            connection.setAudioRecording(false)
            workerWait.checkpoint()
            connection.setAudioPlayout(mode.playback)
            workerWait.checkpoint()
            val transceiver = if (microphoneReturn) {
                val constraints = MediaConstraints().apply {
                    for ((name, value) in processing.constraints()) optional.add(MediaConstraints.KeyValuePair(name, value))
                }
                val source = rtcFactory.createAudioSource(constraints)
                microphoneSource = source
                workerWait.checkpoint()
                val track = rtcFactory.createAudioTrack("phone-microphone", source)
                microphoneTrack = track; track.setEnabled(false)
                workerWait.checkpoint()
                null // Attach to the transceiver created by the remote receive-only offer.
            } else connection.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY))
            step(ConnectionStage.CODEC)
            val capabilities = if (microphoneReturn) rtcFactory.getRtpSenderCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO)
                else rtcFactory.getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO)
            val opus = capabilities.codecs
                .filter { it.name.equals("opus", true) && it.clockRate == 48000 && it.numChannels == 2 }
            require(opus.isNotEmpty())
            transceiver?.setCodecPreferences(opus)?.throwError()
            step(ConnectionStage.OFFER)
            awaitSDP { connection.setRemoteDescription(it, SessionDescription(SessionDescription.Type.OFFER, description)) }
            if (microphoneReturn) {
                val sending = connection.transceivers.single()
                check(sending.mediaType == MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO)
                check(sending.sender.setTrack(requireNotNull(microphoneTrack), false))
                check(sending.setDirection(if (mode.playback) RtpTransceiver.RtpTransceiverDirection.SEND_RECV
                    else RtpTransceiver.RtpTransceiverDirection.SEND_ONLY))
                sending.setCodecPreferences(opus).throwError()
            }
            step(ConnectionStage.ANSWER)
            val answer = requireNotNull(awaitSDP { connection.createAnswer(it, MediaConstraints()) })
            if (microphoneReturn) check(answer.description.contains(if (mode.playback) "a=sendrecv" else "a=sendonly"))
            val stereoAnswer = if (mode.playback) SessionDescription(answer.type, OpusSdp.stereoAnswer(answer.description)) else answer
            val gatheringStarted = android.os.SystemClock.elapsedRealtime()
            awaitSDP { connection.setLocalDescription(it, stereoAnswer) }
            step(ConnectionStage.ROUTES)
            val fastRelay = InitialRelayGathering.eligible(invitation.remote?.forceRelay == true, iceServers.flatMap { it.urls })
            val early = InitialRelayGathering(fastRelay)
            val gatheringBudget = operationBudget(connectionPreferences[ConnectionTimeout.INITIAL_ICE].toLong())
            val gatheringDeadline = android.os.SystemClock.elapsedRealtime() + gatheringBudget
            if (!fastRelay && !useTrickle) workerWait.await { gathered.await(gatheringBudget, TimeUnit.MILLISECONDS) }
            var localAnswer: String
            while (true) {
                workerWait.checkpoint()
                // Analyze and send the exact same SDK description; no candidate
                // or transport requirement is relaxed for early submission.
                val complete = connection.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE
                localAnswer = requireNotNull(connection.localDescription).description
                val now = android.os.SystemClock.elapsedRealtime()
                val snapshot = IceGathering.initial(localAnswer, complete, invitation.remote != null,
                    invitation.remote?.forceRelay == true, now - gatheringStarted, gatheringErrors.snapshot())
                val ready = !complete && now < gatheringDeadline && early.ready(snapshot.canSubmit, now)
                if (useTrickle || !fastRelay || complete || now >= gatheringDeadline || ready) {
                    initialGathering = if (useTrickle) snapshot.copy(result = "trickle") else if (ready) snapshot.copy(result = "candidates_ready") else snapshot
                    break
                }
                workerWait.await { gathered.await(if (fastRelay) minOf(50, gatheringDeadline - now)
                    else gatheringDeadline - now, TimeUnit.MILLISECONDS) }
            }
            if (closed.get()) return
            includeIceGathering = requireNotNull(initialGathering).canReportTo(gatheringDiagnosticsVersion)
            if (initialGathering?.canSubmit != true) throw java.util.concurrent.TimeoutException()
            step(ConnectionStage.SUBMITTING)
            request("/answer", token, JSONObject().put("version", invitation.version).put("sdp",
                if (continuousEnabled) ContinuousIce.withoutCandidates(localAnswer) else localAnswer))
            setupStartedAt = null
            // Candidate-free descriptions need the status loop to establish
            // media before AudioRecord/AudioTrack routes can be verified.
            // Reuse the network hold so microphone setup cannot block those
            // first trickle heartbeats; normal healthy status releases it.
            if (useTrickle) holdNetworkAudio()
            step(if (microphoneReturn) ConnectionStage.MICROPHONE else ConnectionStage.PLAYBACK)
            mediaReady = true
            var pendingReport: PlaybackReport? = null
            var reportSequence = 0L
            var nextRouteReportAt = 0L
            while (!closed.get()) {
                if (lanRecovery.established && invitation.remote != null && lanRecovery.supported) networkHandoff.arm()
                val handoffAt = android.os.SystemClock.elapsedRealtime()
                if (networkHandoff.waiting()) {
                    // Start the existing deadline and hold gates immediately,
                    // but do not spend transport attempts between lost/available
                    // callbacks. Repeated changes cannot extend this deadline.
                    lanRecovery.networkChanged(handoffAt)
                    holdNetworkAudio(); suspendNetworkAudio(connection, module)
                    onPhase(SessionPhase.RECOVERING)
                    onStatus("Network changed. Restoring audio; microphone and output choices are retained…")
                    publishNetworkStatus()
                    if (lanRecovery.expired(handoffAt)) {
                        fail("The audio connection did not recover within ${ConnectionTimeout.seconds(lanRecovery.limitMs.toInt())} seconds. Tap ${mode.reconnectAction} after Windows finishes the session.", SessionFailure.MEDIA_RECOVERY_TIMEOUT)
                        break
                    }
                    if (!networkHandoff.take(handoffAt)) {
                        workerWait.await { synchronized(controlSignal) { if (!closed.get()) controlSignal.wait(100) } }
                        continue
                    }
                    signalingRoute.recover { probeLocal() }
                    networkHandoffs++
                }
                publishNetworkStatus()
                if (networkHeld.get()) suspendNetworkAudio(connection, module)
                if (microphoneReturn && !networkHeld.get()) {
                    val controlStartedAt = android.os.SystemClock.elapsedRealtime()
                    try {
                        if (!headsetRecovery.pending() && !microphoneRouting.healthy()) inputRouteLost()
                        if (!headsetRecovery.pending() && !closed.get()) {
                            try { applyMicrophoneControl(connection, module, token) }
                            catch (error: MicrophoneRouteException) {
                                if (microphoneSelection.kind.bluetooth && microphoneAppliedMuted != null &&
                                    error.problem != MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE) inputRouteLost()
                                else throw error
                            }
                        }
                        if (closed.get()) break
                        if (!headsetRecovery.pending() && (microphoneAppliedMuted == false || microphoneCaptureRetained) &&
                            !microphoneInput.matches(module, microphoneRouting)) {
                            inputRouteLost()
                        }
                        if (!headsetRecovery.pending() && mode.playback && microphoneSelection.kind.bluetooth && microphoneAppliedMuted != null &&
                            !outputDiagnostics.matches(module, microphoneRouting)) {
                            inputRouteLost()
                        }
                        if (headsetRecovery.pending()) restoreHeadset(connection, module, token)
                        if (closed.get()) break
                    } catch (error: Exception) {
                        if (!retrySignaling(error, controlStartedAt)) throw error
                        holdNetworkAudio(); suspendNetworkAudio(connection, module)
                    }
                    // Route probing runs in short worker steps while the usual
                    // heartbeat/report cadence continues on this same session.
                }
                updateOutputRoute(module, connection)
                if (closed.get()) break
                if (!networkHeld.get() && (headsetRecovery.pending() || outputSwitchPending() || outputProbing()) &&
                    android.os.SystemClock.elapsedRealtime() < nextRouteReportAt) {
                    workerWait.await { synchronized(controlSignal) { if (!closed.get()) controlSignal.wait(20) } }
                    continue
                }
                // Upload the previous snapshot with the next existing heartbeat.
                // There is only one pending snapshot, never a growing retry queue.
                var uploading: PlaybackReport? = null
                var body: JSONObject? = null
                var iceUpdate: JSONObject? = null
                var continuousUpdate: JSONObject? = null
                val attemptedAt = android.os.SystemClock.elapsedRealtime()
                val host = try {
                    lanRecovery.exchangeStatus(android.os.SystemClock::elapsedRealtime,
                        beforeRestart = {
                            signalingRoute.recover { probeLocal() }
                            trickle = null // Retire old credentials before preparing any later status body.
                            continuous = null; continuousCandidates.clear()
                            holdNetworkAudio(); suspendNetworkAudio(connection, module)
                        }, restore = { restoreLanConnection(connection, token) }) {
                        // Build after recovery: a pre-restart ICE delta must never
                        // accompany the confirmation poll for the new generation.
                        uploading = pendingReport?.takeIf { delivery.enabled }
                        body = try {
                            uploading?.let { JSONObject().put("version", invitation.version).put("android", JSONObject(it.fields(includeOutput, includeConnection))) }
                        } catch (_: Exception) { delivery.unavailable(); null }
                        iceUpdate = trickle?.takeUnless { it.finished || lanRecovery.generation != 0L }?.let {
                            // Read completion before the SDP to avoid acknowledging
                            // completion before the final gathered candidate.
                            val complete = connection.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE
                            it.observe(connection.localDescription.description, complete)
                            JSONObject(it.delta().fields())
                        }
                        continuousUpdate = continuous?.let {
                            check(it.generation == lanRecovery.generation)
                            it.observe(continuousCandidates.description(connection.localDescription.description))
                            JSONObject(it.snapshot().fields())
                        }
                        val phoneSnapshot = if (phoneControlEnabled) phoneControl?.snapshot() else null
                        val statusBody = linkedMapOf<String, Any>("version" to invitation.version).apply {
                            phoneSnapshot?.let { put("phone_control", JSONObject(it)) }
                            body?.let { put("android", it.getJSONObject("android")) }
                            iceUpdate?.let { put("ice", it) }
                            continuousUpdate?.let { put("continuous_ice", it) }
                        }.takeIf { it.size > 1 }
                        delivery.exchangeStatus(statusBody, closed::get) { fields ->
                            request("/status", token, fields?.let { JSONObject(it) }, connectionPreferences[ConnectionTimeout.LAN_STATUS])
                        }
                    }
                } catch (error: Exception) {
                    signalingFailureText(error)?.let { lastSignalingFailure = it }
                    if (!retrySignaling(error, attemptedAt)) throw error
                    holdNetworkAudio(); suspendNetworkAudio(connection, module)
                    publishNetworkStatus()
                    if (lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) {
                        fail("Connection control did not recover within ${ConnectionTimeout.seconds(lanRecovery.limitMs.toInt())} seconds. Tap ${mode.reconnectAction} after Windows finishes the session.",
                            SessionFailure.STATUS_RECOVERY_TIMEOUT, error)
                        break
                    }
                    onPhase(SessionPhase.RECOVERING)
                    onStatus("Connection interrupted. Trying the current Windows session for up to ${ConnectionTimeout.seconds(lanRecovery.limitMs.toInt())} seconds…")
                    workerWait.await { synchronized(controlSignal) { if (!closed.get()) controlSignal.wait(if (networkHandoff.waiting()) 100 else 500) } }
                    continue
                }
                if (closed.get()) break
                if (phoneControlEnabled) host.optJSONObject("phone_control_command")?.let { phoneControl?.receive(it) }
                if (iceUpdate != null) acceptTrickle(host.getJSONObject("ice"), connection)
                if (continuousUpdate != null) acceptContinuous(host.getJSONObject("continuous_ice"), connection)
                if (body != null && delivery.enabled) {
                    delivery.acknowledge(host.optString("report_log"), host.optLong("report_sequence", -1), requireNotNull(uploading).sequence)
                }
                evidence.observe(EvidenceKind.HOST, host.optString("state").takeIf {
                    it in listOf("new", "connecting", "connected", "disconnected", "failed", "closed")
                } ?: "unavailable", android.os.SystemClock.elapsedRealtime())
                if (host.optBoolean("capture_failed") || host.optBoolean("bridge_failed") || host.optString("state") == "closed" ||
                    (host.optString("state") == "failed" && !lanRecovery.supported)) {
                    fail("Windows audio stopped. Tap ${mode.reconnectAction} after Windows finishes the session.", SessionFailure.HOST_AUDIO_STOPPED)
                    break
                }
                val healthy = state == "Connected" && iceConnected && host.optString("state") == "connected" && !host.optBoolean("ice_recovery_pending") &&
                    (!continuousEnabled || lanRecovery.generation == 0L || host.optBoolean("ice_generation_current"))
                if (lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) {
                    fail("The audio connection did not recover within ${ConnectionTimeout.seconds(lanRecovery.limitMs.toInt())} seconds. Tap ${mode.reconnectAction} after Windows finishes the session.", SessionFailure.MEDIA_RECOVERY_TIMEOUT)
                    break
                }
                lanRecovery.observe(healthy, attemptedAt)
                if (lanRecovery.established && invitation.remote != null && lanRecovery.supported) networkHandoff.arm()
                if (!healthy || lanRecovery.pending || lanRecovery.restartRequested) {
                    holdNetworkAudio(); suspendNetworkAudio(connection, module)
                    // A newly detected media failure gets the same priority as a
                    // network callback. Recovery then returns directly to a fresh
                    // status poll, before stats collection or the normal wait.
                    if (lanRecovery.restartDue(android.os.SystemClock.elapsedRealtime())) continue
                } else if (networkHeld.get() && !networkHandoff.waiting()) releaseNetworkAudio(module)
                if (healthy && !networkHeld.get() && !networkHandoff.waiting() &&
                    (!microphoneReturn || microphoneAppliedMuted != null) &&
                    (!mode.playback || trackStarted || speakerMuted)) {
                    // Audio is already running. The bounded check never holds
                    // its gates or delays initial rendezvous setup/recovery.
                    signalingRoute.upgrade { probeLocal() && !networkHandoff.waiting() }
                }
                publishNetworkStatus()
                onPhase(if (outputSwitchPending() && !selectedOutputRecovering()) SessionPhase.SWITCHING
                    else if (headsetRecovery.pending()) SessionPhase.ROUTE_RECOVERING
                    else if (healthy && !networkHeld.get()) SessionPhase.PLAYING else SessionPhase.RECOVERING)
                val stats = CompletableFuture<RTCStatsReport>()
                connection.getStats { stats.complete(it) }
                val report = workerWait.await { stats.get(5, TimeUnit.SECONDS) }
                val samples = report.statsMap.mapValues { (_, stat) ->
                    RtcSample(stat.id, stat.type, stat.timestampUs.toDouble(), stat.members)
                }
                val snapshot = metrics.update(samples)
                val routes = routeSelection.update(samples, lanRecovery.generation,
                    connection.localDescription?.description, connection.remoteDescription?.description)
                fun hostNumber(key: String): String = (host.opt(key) as? Number)?.toDouble()
                    ?.takeIf { it.isFinite() && it > 0 }?.let { String.format(java.util.Locale.US, "%.0f", it) } ?: "unavailable"
                val surroundings = try { environment.snapshot(if (microphoneReturn)
                    MicrophoneRouting.attributes(microphoneSelection) else PlaybackEnvironment.attributes()) } catch (_: RuntimeException) { null }
                val capturedAt = java.time.Instant.now().toString()
                val output = if (trackStarted && !synchronized(audioLock) { speakerMuted } && !headsetRecovery.pending() && !outputSwitchPending()) "running" else "waiting"
                val capturedState = state
                val uptime = android.os.SystemClock.elapsedRealtime()
                val actualOutput = if (mode.playback) outputDiagnostics.snapshot(module) else null
                val bufferRecovery = recoveryMonitor.update(uptime, output == "running" && capturedState == "Connected",
                    actualOutput, snapshot.values["buffer_ms"], snapshot.values["buffer_target_ms"])
                val mic = if (microphoneReturn) microphoneInput.snapshot(module,
                    if (networkHeld.get() || headsetRecovery.pending()) "waiting" else if (microphoneAppliedMuted == true) "muted"
                    else if (recordStarted) "running" else "waiting",
                    microphoneSelection, microphoneRouting, recordStarted) else null
                val connectionSnapshot = evidence.connection(runtime.snapshot(), android.os.SystemClock.elapsedRealtime())
                pendingReport = PlaybackReport(++reportSequence, capturedAt, android.os.SystemClock.elapsedRealtime(),
                    surroundings, capturedState, output, snapshot, actualOutput, if (mode.playback) bufferRecovery else null, localOutputBaseline, mic, mode, connectionSnapshot,
                    microphoneProcessing = processing.takeIf { microphoneReturn && offer.optInt("microphone_processing_version") == 1 },
                    lanRecovery = lanRecovery.fields(signalingRoute.reportRoute(lanNetwork.routeLabel())).takeIf { lanRecovery.supported },
                    outputControl = if (usesMediaOutput && includeOutputControl) outputControlSnapshot() else null,
                    iceGathering = initialGathering.takeIf { includeIceGathering },
                    mediaTransport = snapshot.transport.takeIf { includeMediaTransport },
                    routeSelection = routes.takeIf { includeRouteSelection },
                    tlsVerification = turnTlsTrust.snapshot().takeIf { includeTlsVerification })
                val diagnostic = if (microphoneReturn) {
                    "${if (mode.playback) "Duplex" else "Microphone"} snapshot: $capturedAt\n${surroundings?.text(true, mode.playback) ?: "Phone environment: unavailable"}\n" +
                        "State: $capturedState · Desktop playback: ${if (mode.playback) output else "off"}\n${delivery.text}\n${mic?.text()}\n" +
                        "Muted capture option: $keepMicrophoneActive · Capture retained while muted: $microphoneCaptureRetained\n" +
                        "Codec: ${snapshot.codec} · Media path: ${snapshot.path}\n" +
                        "Sent payload: ${snapshot.values["sent_payload_kbps"] ?: "unavailable"} kb/s · Total sent: ${snapshot.values["sent_bytes_total"] ?: "unavailable"} bytes\n" +
                        "Windows cable: ${hostNumber("bridge_mix_rate_hz")} Hz / ${hostNumber("bridge_mix_channels")} channels\n" +
                        "Windows buffer: ${hostNumber("bridge_buffer_frames")} source frames · Submitted: ${host.optLong("bridge_frames_submitted")} frames\n" +
                        "Host microphone gate: ${if (host.optBoolean("microphone_muted", true)) "muted" else "enabled"}\n" +
                        "Buffer, packet and RTT figures do not measure physical microphone latency." +
                        (if (mode.playback) "\n${snapshot.text()}\n${actualOutput?.text() ?: "Actual AudioTrack diagnostics: unavailable"}\n${bufferRecovery.text()}" else "") + "\n${processing.text()}"
                } else "Playback snapshot: $capturedAt\n${surroundings?.text() ?: "Phone route/environment: unavailable"}\n" +
                    "State: $capturedState · Media output: $output\n${delivery.text}\n" +
                    "Windows source: ${hostNumber("source_rate_hz")} Hz / ${hostNumber("source_channels")} channels\n" +
                    "Encoder: ${hostNumber("encoder_channels")} channels · ${hostNumber("encoder_packet_ms_at_creation")} ms initial packets\n" +
                    snapshot.text() + "\n${actualOutput?.text() ?: "Actual AudioTrack diagnostics: unavailable"}\n" +
                    bufferRecovery.text() + (localOutputBaseline?.let {
                        "\nLast local output baseline (phone uptime ${it.capturedUptimeMs} ms):\n${it.text()}"
                    } ?: "")
                lastDiagnostics = "$diagnostic\nApp audio output: ${if (outputEnabled()) "enabled" else "silenced"}" +
                    (playbackPaused()?.let { "\n${it.detail}" } ?: "") + "\n${connectionSnapshot.text()}\n${signalingText()}\n${lanRecovery.text().replace("LAN media recovery", "Media recovery")}" +
                    (if (mode.playback) "\nApp output selection: " + (if (!usesMediaOutput) "selected headset microphone"
                        else synchronized(audioLock) { "${outputRoute.selection.kind.label} · ${if (outputRoute.recovering) "restoring selected output" else if (outputRoute.pending) "verifying" else if (outputRoute.selection.explicit) "verified" else "Android routing"}" }) else "") +
                    (if (usesMediaOutput && synchronized(audioLock) { outputRoute.selection.kind.bluetooth })
                        synchronized(audioLock) { "\nSelected output identity: ${if (BluetoothAudioIdentity.stableAddress(outputRoute.selection.address) != null) "stable address" else "original port only"}" } +
                            " · Nearby devices permission: ${if (mediaRoutes.permitted()) "granted" else "unavailable"}" else "") +
                    (if (usesMediaOutput) "\n${outputRecoveryText()}" else "") +
                    (if (microphoneReturn && microphoneSelection.kind.bluetooth)
                        "\n${headsetRecovery.text()}\n${microphoneRouting.identityText()}" else "")
                initialGathering?.let { lastDiagnostics += "\n${it.text()}" }
                lastDiagnostics += "\n${turnTlsTrust.snapshot().text()}"
                trickle?.let { lastDiagnostics += "\n${it.text()}" }
                continuous?.let { lastDiagnostics += "\n${it.text()}" }
                lastDiagnostics += "\n${routes.text()}"
                val hostTransport = host.optJSONObject("media_transport")?.let { transport ->
                    MediaTransportSnapshot.reported(listOf("version", "local_candidate_type", "remote_candidate_type",
                        "candidate_protocol", "relay_protocol").associateWith { transport.opt(it) })
                } ?: MediaTransportSnapshot()
                lastDiagnostics += "\nSelected TURN connections — phone: ${snapshot.transport.turnText()} · Windows: ${hostTransport.turnText()}" +
                    "\nTURN connection protocols are separate from the ICE candidate protocol shown in Media path."
                if (invitation.remote != null) lastDiagnostics += "\nNetwork handoffs detected: $networkHandoffs · Default network: ${connectionSnapshot.runtime?.defaultNetwork ?: "unknown"}"
                lastSignalingFailure?.let { lastDiagnostics += "\n$it" }
                journal.snapshot(lastDiagnostics)
                if (!closed.get()) { onDiagnostics(lastDiagnostics); onStatus(lastDiagnostics) }
                nextRouteReportAt = android.os.SystemClock.elapsedRealtime() + 2000
                workerWait.await {
                    synchronized(controlSignal) {
                        if (!closed.get() && (networkHeld.get() || !microphoneReturn || microphoneAppliedMuted == microphoneDesiredMuted.get()))
                            controlSignal.wait(if (networkHandoff.waiting()) 100 else if (networkHeld.get()) 500 else if (headsetRecovery.pending() || outputSwitchPending() || outputProbing()) 20 else 2000)
                    }
                }
            }
        } catch (error: Exception) {
            fail(ConnectionFailure.describe(stage, error, mode.reconnectAction), SessionFailure.from(error), error)
        } catch (error: LinkageError) {
            fail(ConnectionFailure.describe(stage, error, mode.reconnectAction), SessionFailure.from(error), error)
        } finally {
            // No wait is registered during cleanup. A delayed Stop cannot
            // interrupt the acknowledgment or native disposal joins/waits.
            synchronized(cancelLock) { closed.set(true); Thread.interrupted() }
            val reason = stopReason.get() ?: StopReason.FAILURE
            val stamp = failureEvidence.get()
            // Capture before intentional AudioRecord/route teardown. Native
            // cleanup callbacks cannot alter this immutable terminal evidence.
            val terminal = runCatching {
                val connection = evidence.connection(runtime.snapshot(), android.os.SystemClock.elapsedRealtime())
                val uptime = android.os.SystemClock.elapsedRealtime()
                TerminalEvidence(java.time.Instant.now().toString(), uptime,
                    if (reason == StopReason.FAILURE) stamp?.code ?: SessionFailure.SESSION_EXCEPTION else SessionFailure.NONE,
                    stamp?.stage ?: stage, if (reason == StopReason.FAILURE) stamp?.uptimeMs ?: uptime else null,
                    connection, evidence.tail(uptime), evidence.omitted(uptime), stamp?.httpStatus,
                    if (usesMediaOutput && includeOutputControl) outputControlSnapshot() else null,
                    initialGathering)
            }.getOrNull()
            val finalOutputRecovery = if (usesMediaOutput) outputRecoveryText() else null
            var finalSnapshot = if (microphoneReturn && microphoneSelection.kind.bluetooth) {
                lastDiagnostics.lineSequence().filterNot { it.startsWith("Selected headset recovery:") ||
                    it.startsWith("Selected headset identity:") }.joinToString("\n") +
                    "\n${headsetRecovery.text()}\n${microphoneRouting.identityText()}"
            } else lastDiagnostics
            if (finalOutputRecovery != null) finalSnapshot = finalSnapshot.lineSequence().filterNot {
                it.startsWith("Output recovery:") || it.startsWith("System Bluetooth route:")
            }.joinToString("\n") + "\n$finalOutputRecovery"
            lastSignalingFailure?.let { detail ->
                finalSnapshot = finalSnapshot.lineSequence().filterNot { it.startsWith("Secure signaling failure:") }
                    .joinToString("\n") + "\n$detail"
            }
            if (signalingRequestFailures.isNotEmpty()) finalSnapshot +=
                "\nRecent signaling request failures (phone uptime):\n" + signalingRequestFailures.joinToString("\n")
            // A failed heartbeat may prevent another full stats snapshot. Show
            // the worker's terminal recovery state rather than the old settled one.
            finalSnapshot = finalSnapshot.lineSequence().filterNot {
                it.startsWith("Media recovery:") || it.startsWith("LAN media recovery:")
            }.joinToString("\n") + "\n" + TerminalLabels.mediaRecovery(offerReply, lanRecovery, android.os.SystemClock.elapsedRealtime())
            var terminalDelivery = TerminalLabels.delivery(offerReply, includeConnection)
            finalSnapshot = finalSnapshot.lineSequence().filterNot {
                it.startsWith("Signaling:") || it.startsWith("Signaling history:") ||
                    it.startsWith("Cellular media candidates:") || it.startsWith("LAN signaling route:")
            }.joinToString("\n")
            fun terminalReport() = "$finalSnapshot\n${signalingText()}\n\nSession result: ${failure.get() ?: mode.endedMessage(reason)}\n" +
                (terminal?.text() ?: "Terminal connection diagnostics unavailable.") +
                "\nWindows terminal diagnostics: $terminalDelivery"
            // Commit before native teardown. A fatal native exit cannot reach
            // onEnded, but the next activity can still copy this report.
            if (ownsSession) { journalActive = true; journal.snapshot(terminalReport()) }
            cleanupStep("runtime_close") { runtime.close() }
            cleanupStep("local_audio_gates") { synchronized(audioLock) {
                outputGate.stop(); outputRoute.stop(); defaultOutput.stop(); outputRestarts.stop(); audio?.setSpeakerMute(true)
                if (microphoneReturn) audio?.setMicrophoneMute(true)
            } }
            cleanupStep("output_observers_close") { outputDevices.close(); mediaRoutes.close() }
            cleanupStep("input_observers_close") { microphoneInput.clear(); outputDiagnostics.clearRouteWatch(); outputRouting.clear() }
            if (microphoneReturn) cleanupStep("audio_recording_stop") { peer?.setAudioRecording(false) }
            val pendingStop = sessionToken?.let {
                SessionStopRetry.shared.remember(stopDestination, it, reason.wireFor(lifecycleVersion),
                    android.os.SystemClock.elapsedRealtime())
            }
            val acknowledged = SessionShutdown.complete({
                if (journalActive) journal.checkpoint("windows_stop")
                val stopTimeout = connectionPreferences[if (invitation.remote != null) ConnectionTimeout.REMOTE_STOP else ConnectionTimeout.LAN_STOP]
                sessionToken?.let {
                    val body = JSONObject().put("reason", reason.wireFor(lifecycleVersion))
                    if (includeConnection && terminal != null) body.put("diagnostics", JSONObject(terminal.fields(includeIceGathering)))
                    val response = try { request("/stop", it, body, stopTimeout, true) } catch (error: HttpFailure) {
                        // Diagnostics are optional: explicit schema rejection
                        // must not prevent a graceful legacy Stop.
                        if (!body.has("diagnostics") || error.status !in listOf(400, 413, 422)) throw error
                        terminalDelivery = "rejected; retained in Android copy report"
                        request("/stop", it, JSONObject().put("reason", reason.wireFor(lifecycleVersion)), stopTimeout, true)
                    }
                    if (includeConnection && !terminalDelivery.startsWith("rejected"))
                        terminalDelivery = response.optString("receiver_diagnostics", TerminalLabels.NOT_CONFIRMED)
                    true
                } ?: if (offerAttempt.needsCancellation(sessionToken)) {
                    // Stop can abort /offer before its response supplies a
                    // session token. Cancel only this worker's private nonce,
                    // even if the host receives cancellation before the offer.
                    terminalDelivery = "not sent; pending offer cancellation unconfirmed"
                    val response = request("/cancel-offer", invitation.token,
                        JSONObject().put("version", invitation.version), connectionPreferences[ConnectionTimeout.CANCEL_OFFER], true)
                    response.optBoolean("offer_cancelled", false).also { cancelled ->
                        if (cancelled) terminalDelivery = "not sent; pending offer cancellation acknowledged"
                    }
                } else false
            }, {
                if (journalActive) journal.snapshot(terminalReport())
                cleanupStep("peer_dispose") { peer?.dispose() }; peer = null
                cleanupStep("microphone_track_dispose") { microphoneTrack?.dispose() }; microphoneTrack = null
                cleanupStep("microphone_source_dispose") { microphoneSource?.dispose() }; microphoneSource = null
                cleanupStep("factory_dispose") { factory?.dispose() }; factory = null
                cleanupStep("audio_module_release") { synchronized(audioLock) { audio?.release(); audio = null } }
                if (microphoneReturn) cleanupStep("microphone_route_close") { microphoneRouting.close() }
                cleanupStep("lan_network_close") { lanNetwork.close() }
            })
            if (acknowledged && pendingStop != null) SessionStopRetry.shared.acknowledge(pendingStop)
            val confirmation = if (sessionToken == null && !offerAttempt.needsCancellation(null)) "" else if (acknowledged)
                "\nWindows acknowledged Stop." else if (pendingStop != null)
                "\nStopped locally; Windows Stop was not confirmed. Connect will retry it, or Windows will end the session after its timeout."
                else "\nStopped locally; Windows Stop was not confirmed. Its watchdog will end the session."
            if (journalActive) { journal.snapshot(terminalReport()); journal.completed() }
            val finalDiagnostics = journal.text()
            journalActive = false
            if (ownsSession) AudioSessionOwner.lock.release()
            onEnded(StreamEnd(reason, (failure.get() ?: mode.endedMessage(reason)) + confirmation, finalDiagnostics))
        }
    }

    private fun step(value: ConnectionStage) {
        workerWait.checkpoint()
        stage = value
        if (journalActive) journal.checkpoint("setup_${value.name.lowercase()}")
        android.util.Log.i("MicDrop", "Connection stage: ${value.name}")
        onStatus("${value.label}…")
    }

    private fun updateOutputRoute(module: JavaAudioDeviceModule, connection: PeerConnection) {
        if (!usesMediaOutput || closed.get()) return
        returnToDefaultOutput(module)
        if (!synchronized(audioLock) { outputRoute.selection.explicit }) {
            updateDefaultOutput(module, connection)
            return
        }
        if (synchronized(audioLock) { outputRoute.selection.kind.bluetooth }) {
            updateBluetoothOutput(module, connection)
            return
        }
        val request = synchronized(audioLock) { Triple(outputRoute.ticket, outputRoute.selection, outputRoute.pending) }
        val (id, selected, pending) = request
        if (synchronized(audioLock) { outputRoute.ticket == id && outputRoute.invalid }) {
            withCurrentOutput(id) { if (outputRoute.invalid) close(StopReason.OUTPUT) }
            return
        }
        if (!pending) {
            if (runCatching { outputRouting.verifies(module, id, selected, context) }.getOrDefault(false)) {
                // A global noisy broadcast may concern another Bluetooth
                // device. The actual pinned track is sufficient to clear its
                // temporary hold, without changing focus or user silence.
                withCurrentOutput(id) {
                    outputRefresh = false
                    outputGate.verified(); module.setSpeakerMute(speakerMuted)
                }
                publishOutputState()
            } else {
                outputRouteChanged(module, id, selected)
                withCurrentOutput(id) { if (outputRoute.invalid) close(StopReason.OUTPUT) }
            }
            return
        }
        updatePinnedOutput(module, connection)
    }

    private fun returnToDefaultOutput(module: JavaAudioDeviceModule) {
        val returned = synchronized(audioLock) {
            val bluetoothReturned = outputDevices.bluetoothAvailable &&
                outputDevices.bluetoothGeneration > speakerBluetoothGeneration
            if (closed.get() || !outputRoute.returnToDefault(outputRoute.ticket, bluetoothReturned)) return
            val selected = outputRoute.selection
            // Clearing the speaker pin is not permission for another speaker
            // fallback. Android's actual safe default must still be verified.
            defaultOutput.select(selected, protectSpeakerOnReturn = true)
            outputRestarts.newRoute(); outputWaitingSince = null
            mediaRoutes.reset(); predictedOutput = emptySet(); defaultTargetMatches = null
            outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
            outputRefresh = true
            outputGate.hold(); module.setSpeakerMute(true)
            selected
        }
        onOutputSelection(returned)
        publishOutputState()
        onStatus("Bluetooth output returned. Following Android media output…")
    }

    private fun updatePinnedOutput(module: JavaAudioDeviceModule, connection: PeerConnection) {
        val now = android.os.SystemClock.elapsedRealtime()
        val work = synchronized(audioLock) {
            if (closed.get() || !outputRoute.selection.explicit || outputRoute.selection.kind.bluetooth) return
            outputRoute.beginCheck(outputRoute.ticket, now)
            val restart = outputRestarts.take(now)
            val refresh = outputRefresh
            outputRefresh = false
            restart to refresh
        }
        if (work.first) recreateOutput(module, connection) else if (work.second) outputRouting.clear()
        // Recreating playout can replace the track and its ticket. A newer
        // output choice can also supersede this step while native work runs.
        val (id, selected) = synchronized(audioLock) {
            if (closed.get() || !outputRoute.selection.explicit || outputRoute.selection.kind.bluetooth) return
            outputRoute.beginCheck(outputRoute.ticket, now)
            outputRoute.ticket to outputRoute.selection
        }
        val accepted = runCatching {
            outputRouting.bind(module, id, selected, context) { outputRouteChanged(module, id, selected) }
        }.getOrDefault(false)
        if (closed.get()) return
        val speakerRecovery = synchronized(audioLock) {
            outputRoute.ticket == id && selected.kind == OutputKind.PHONE && outputRoute.recovering
        }
        if (accepted == false && !speakerRecovery) {
            withCurrentOutput(id) {
                fail("Android could not select the requested playback device. Choose an available output and Connect again.", SessionFailure.OUTPUT_RUNTIME)
            }
            return
        }
        val verified = accepted == true && trackStarted && runCatching {
            outputRouting.verifies(module, id, selected, context)
        }.getOrDefault(false)
        if (verified) {
            val released = synchronized(audioLock) {
                if (!closed.get() && !outputRoute.expired(android.os.SystemClock.elapsedRealtime()) && outputRoute.verified(id)) {
                    outputRestarts.settled(); outputWaitingSince = null
                    outputGate.verified(); module.setSpeakerMute(speakerMuted); true
                } else false
            }
            if (released) onOutputSelection(selected)
        } else {
            synchronized(audioLock) {
                if (closed.get() || outputRoute.ticket != id) return
                outputGate.hold(); module.setSpeakerMute(true)
                if (speakerRecovery) {
                    if (outputWaitingSince == null) outputWaitingSince = now
                    if (now - requireNotNull(outputWaitingSince) >= 1000) outputRestarts.request()
                }
            }
        }
        publishOutputState()
        withCurrentOutput(id) {
            if (outputRoute.expired(android.os.SystemClock.elapsedRealtime())) {
                val detail = if (speakerRecovery)
                    "Android did not restore the phone speaker within 5 seconds. Audio stayed silenced. Choose an available output and Connect again."
                else "Android did not verify the requested playback device within 5 seconds. Audio stayed silenced. Choose an available output and Connect again."
                fail(detail, SessionFailure.OUTPUT_RUNTIME)
            }
        }
    }

    private fun updateBluetoothOutput(module: JavaAudioDeviceModule, connection: PeerConnection) {
        val now = android.os.SystemClock.elapsedRealtime()
        val initial = synchronized(audioLock) { Triple(outputRoute.ticket, outputRoute.selection, outputRoute.pending) }
        val (previousId, previous, pending) = initial
        if (!previous.kind.bluetooth || closed.get()) return
        OutputPermissions.denial(previous.kind) {
            context.checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }?.let { denial ->
            withCurrentOutput(previousId) { fail(denial, SessionFailure.PERMISSION_DENIED) }
            return
        }
        val available = OutputDevices.refresh(context, previous)
        val actual = runCatching { outputRouting.devices(module, previousId, context) }.getOrNull()
        if (!pending && available == previous && actual?.let(previous::verifies) == true) {
            val predicted = OutputDevices.predictedMedia(context)
            withCurrentOutput(previousId) { mediaRoutes.learn(previous, actual, predicted) }
            return
        }
        val work = synchronized(audioLock) {
            if (closed.get() || outputRoute.ticket != previousId) return
            if (!outputRoute.pending || available == null || !trackStarted) holdSelectedBluetoothOutput(now)
            if (available != null) outputRoute.rebind(outputRoute.ticket, available)
            outputRoute.beginCheck(outputRoute.ticket, now)
            val restart = outputRestarts.take(now)
            val refresh = outputRefresh
            outputRefresh = false
            restart to refresh
        }
        if (work.first) recreateOutput(module, connection) else if (work.second) outputRouting.clear()
        if (closed.get()) return
        val (id, selected) = synchronized(audioLock) { outputRoute.ticket to outputRoute.selection }
        if (!selected.kind.bluetooth) return
        // Inventory is refreshed before binding: a successful preference for
        // a retired port cannot verify a different active Bluetooth headset.
        val currentPort = OutputDevices.refresh(context, selected)
        val accepted = if (currentPort == selected) runCatching {
            outputRouting.bind(module, id, selected, context) { outputRouteChanged(module, id, selected) }
        }.getOrDefault(false) else null
        val verified = accepted == true && trackStarted && runCatching {
            outputRouting.verifies(module, id, selected, context)
        }.getOrDefault(false)
        // Do not change the system route when the pinned track already works.
        // A missing/mismatching port can still retain its selectable system route.
        // Stop and newer output choices have authority over transfer requests.
        if (!verified) withCurrentOutput(id) { if (outputFocus == null) mediaRoutes.restore(selected, now) }
        val released = synchronized(audioLock) {
            if (closed.get() || outputRoute.ticket != id) return
            if (verified && !outputRoute.expired(android.os.SystemClock.elapsedRealtime()) && outputRoute.verified(id)) {
                mediaRoutes.learn(selected, outputRouting.devices(module, id, context), OutputDevices.predictedMedia(context))
                outputGate.verified(); outputRestarts.settled(); outputWaitingSince = null
                module.setSpeakerMute(speakerMuted)
                true
            } else {
                outputGate.hold(); module.setSpeakerMute(true)
                if (outputWaitingSince == null) outputWaitingSince = now
                // Recreate playout even during a missing-port interval. The
                // track stays muted until the original physical output verifies.
                if (now - requireNotNull(outputWaitingSince) >= 2000) outputRestarts.request()
                false
            }
        }
        if (released) onOutputSelection(selected)
        publishOutputState()
        withCurrentOutput(id) {
            if (outputRoute.expired(android.os.SystemClock.elapsedRealtime())) {
                val detail = if (outputRoute.recovering)
                    "Android did not restore the selected Bluetooth output within $bluetoothRecoverySeconds seconds. Playback stayed silenced. Choose an available output and Connect again."
                else "Android did not verify the selected Bluetooth output within 5 seconds. Playback stayed silenced. Choose an available output and Connect again."
                fail(detail, SessionFailure.OUTPUT_RUNTIME)
            }
        }
    }

    private fun recreateOutput(module: JavaAudioDeviceModule, connection: PeerConnection) {
        // The owning worker joins/recreates playout only. Microphone capture,
        // its host gate, the current peer and heartbeat are left in place.
        outputRestarting = true
        try {
            module.setSpeakerMute(true)
            outputRecreations++
            outputRouting.clear()
            connection.setAudioPlayout(false)
            if (!closed.get()) connection.setAudioPlayout(true)
        } catch (_: Exception) {
            synchronized(audioLock) { defaultOutput.unavailable(); outputRestarts.request() }
        } finally { outputRestarting = false }
    }

    private fun updateDefaultOutput(module: JavaAudioDeviceModule, connection: PeerConnection) {
        val now = android.os.SystemClock.elapsedRealtime()
        val predicted = OutputDevices.predictedMedia(context)
        val work = synchronized(audioLock) {
            if (closed.get() || outputRoute.selection.explicit) return
            if (predicted != null && predicted.toSet() != predictedOutput) {
                predictedOutput = predicted.toSet()
                defaultOutput.changing(); outputRestarts.newRoute(); outputWaitingSince = null
                outputProbeUntil = now + 20000
                module.setSpeakerMute(true)
            }
            val restart = outputRestarts.take(now)
            val refresh = outputRefresh
            outputRefresh = false
            restart to refresh
        }
        if (work.first) recreateOutput(module, connection) else if (work.second) outputRouting.clear()
        if (closed.get()) return
        val current = synchronized(audioLock) { outputRoute.ticket to outputRoute.selection }
        val (id, selected) = current
        if (selected.explicit) return
        val accepted = runCatching {
            outputRouting.bind(module, id, selected, context) { outputRouteChanged(module, id, selected) }
        }.getOrDefault(false)
        val devices = if (accepted == true && trackStarted)
            runCatching { outputRouting.devices(module, id, context) }.getOrNull() else null
        val kinds = devices?.takeIf { it.isNotEmpty() && it.all { device ->
            device.sink && OutputKind.forType(device.type) != null
        } }?.map { requireNotNull(OutputKind.forType(it.type)) }
        val acknowledged = synchronized(audioLock) {
            if (closed.get() || outputRoute.ticket != id || outputRoute.selection.explicit) return
            if (accepted == false || !trackStarted) {
                defaultOutput.unavailable(); outputRestarts.request()
            } else defaultOutput.observe(kinds)
            defaultTargetMatches = DefaultMediaTarget.matches(devices, predicted)
            // Type equality is insufficient: two A2DP devices can share a
            // logical port. Only the actual track proves a completed migration.
            if (defaultTargetMatches == false) {
                val expectedKinds = predicted?.mapNotNull { OutputKind.forType(it.type) }
                if (defaultOutput.speakerProtected && expectedKinds?.contains(OutputKind.PHONE) == true)
                    defaultOutput.observe(expectedKinds)
                else defaultOutput.changing()
            }
            if (defaultOutput.pause == null) outputRestarts.settled()
            // Clearing a concrete pin is complete once Android accepts default
            // routing. Speaker protection is an independent, recoverable hold.
            val changed = accepted == true && outputRoute.verified(id)
            if (changed) outputGate.verified()
            if (defaultOutput.pause != null && (kinds == null || outputDevices.bluetoothAvailable)) {
                if (outputWaitingSince == null) outputWaitingSince = now
                if (now - requireNotNull(outputWaitingSince) >= 2000) outputRestarts.request()
            } else outputWaitingSince = null
            val routePause = defaultOutput.pauseForInventory(outputDevices.bluetoothAvailable)
            if (routePause == null || (routePause == OutputPause.BLUETOOTH && !outputDevices.bluetoothAvailable))
                outputProbeUntil = 0
            module.setSpeakerMute(speakerMuted)
            changed
        }
        if (acknowledged) onOutputSelection(selected)
        publishOutputState()
    }

    private fun withCurrentOutput(id: Long, operation: () -> Unit) {
        // Match the cancellation lock order: an old failed request cannot stop
        // a newer choice between checking its ticket and marking the stream closed.
        synchronized(cancelLock) { synchronized(audioLock) {
            if (!closed.get() && outputRoute.ticket == id) operation()
        } }
    }

    private fun outputRecoveryText(): String = synchronized(audioLock) {
        "Output recovery: playout recreations requested=$outputRecreations" +
            (if (!outputRoute.selection.explicit) " · Actual matches Android default: ${defaultTargetMatches?.toString() ?: "unavailable"}"
            else if (outputRoute.selection.kind.bluetooth) "\n${mediaRoutes.text()}" else "")
    }

    private fun outputControlSnapshot() = synchronized(audioLock) {
        OutputControlSnapshot(outputRoute.selection.kind.name.lowercase(), outputGate.enabled,
            if (closed.get()) "stopped" else if (outputRoute.recovering) "restoring"
            else if (outputRoute.pending) "verifying" else if (defaultOutput.held) "waiting" else "verified",
            outputPauseLocked()?.name?.lowercase() ?: "none", defaultTargetMatches.takeIf { !outputRoute.selection.explicit },
            mediaRoutes.known, mediaRoutes.transfers, mediaRoutes.result, outputRecreations,
            if (outputRoute.selection.kind.bluetooth) mediaRoutes.permitted() else null)
    }

    private fun outputRouteChanged(module: JavaAudioDeviceModule, id: Long, selected: OutputSelection) {
        // Callbacks only gate/wake; track changes and teardown remain worker-owned.
        synchronized(audioLock) {
            if (closed.get() || outputRoute.ticket != id) return
            if (!selected.explicit) {
                defaultOutput.changing(); module.setSpeakerMute(true)
                outputProbeUntil = android.os.SystemClock.elapsedRealtime() + 20000
            }
            if (selected.kind.bluetooth) {
                // Android can report the preference change even when the
                // actual output is already correct. Do not start another
                // recovery simply because our own rebind was acknowledged.
                if (!runCatching { outputRouting.verifies(module, id, selected, context) }.getOrDefault(false))
                    holdSelectedBluetoothOutput(android.os.SystemClock.elapsedRealtime())
            } else if (selected.explicit && !runCatching {
                outputRouting.verifies(module, id, selected, context)
            }.getOrDefault(false)) {
                if (selected.kind == OutputKind.PHONE) holdSelectedSpeakerOutput(android.os.SystemClock.elapsedRealtime())
                else if (outputRoute.lost(id)) { outputGate.hold(); module.setSpeakerMute(true) }
            }
        }
        publishOutputState()
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    private fun obtainOffer(): Pair<JSONObject, List<PeerConnection.IceServer>> {
        val previousStop = SessionStopRetry.shared.beforeOffer(stopDestination, android.os.SystemClock.elapsedRealtime()) { stop ->
            onStatus("Finishing the previous Windows session…")
            request("/stop", stop.token, JSONObject().put("reason", stop.reason),
                connectionPreferences[if (invitation.remote != null) ConnectionTimeout.REMOTE_STOP else ConnectionTimeout.LAN_STOP])
        }
        var retry = BusyOfferRetry(reconnect || previousStop, android.os.SystemClock.elapsedRealtime(), connectionPreferences[ConnectionTimeout.BUSY_HOST].toLong())
        var cancelledForFallback = false
        while (!closed.get()) {
            try {
                val iceServers = remoteIceServers()
                val body = JSONObject(mode.offerFields(invitation.version))
                offerAttempt.begin()
                return request("/offer", invitation.token, body, connectionPreferences[ConnectionTimeout.INITIAL_OFFER]) to iceServers
            }
            catch (error: OfferFallbackRequired) {
                check(!cancelledForFallback)
                workerWait.checkpoint()
                // The old offer may still arrive or own native resources. Its
                // cancellation tombstone must be acknowledged on the alternate
                // transport before a fresh nonce can allocate a successor.
                val body = JSONObject().put("version", invitation.version)
                val ack = if (signalingRoute.direct) localRequest("/cancel-offer", invitation.token, body, connectionPreferences[ConnectionTimeout.CANCEL_OFFER], false)
                    else remoteExchange("/cancel-offer", invitation.token, body, connectionPreferences[ConnectionTimeout.CANCEL_OFFER], false)
                offerAttempt.cancelledForFallback(ack.optBoolean("offer_cancelled"))
                cancelledForFallback = true
                retry = BusyOfferRetry(true, android.os.SystemClock.elapsedRealtime(), connectionPreferences[ConnectionTimeout.BUSY_HOST].toLong())
            }
            catch (error: HttpFailure) {
                if (mode == StreamMode.DUPLEX && error.status == 400) {
                    fail("Windows does not support duplex. Update both apps, then tap Listen + send microphone again.", SessionFailure.MODE_NOT_CONFIRMED)
                    throw error
                }
                if (microphoneReturn && error.status == 409) {
                    fail("Windows microphone return is not configured. Restart Windows with --paired and --microphone-device using the cable render ID from bridge-devices.", SessionFailure.HOST_MICROPHONE_GATE)
                    throw error
                }
                // Only an explicit 423 proves no new session was allocated.
                // An ambiguous offer uses the separate acknowledged-cancellation
                // branch above; it cannot enter this ordinary busy retry.
                if (!retry.allow(error.status, android.os.SystemClock.elapsedRealtime())) throw error
                workerWait.await { Thread.sleep(500) }
            }
        }
        throw InterruptedException()
    }

    private fun applyMicrophoneControl(connection: PeerConnection, module: JavaAudioDeviceModule, token: String) {
        val muted = microphoneDesiredMuted.get()
        if (microphoneAppliedMuted == muted && !microphoneControlDirty) return
        onMicrophoneState(muted, true)
        module.setMicrophoneMute(true)
        microphoneTrack?.setEnabled(false)
        val reuseCapture = keepMicrophoneActive && recordStarted &&
            (microphoneAppliedMuted == false || microphoneCaptureRetained) &&
            !networkHeld.get() && !headsetRecovery.pending() && microphoneInput.matches(module, microphoneRouting)
        microphoneCaptureRetained = false
        microphoneInput.clear()
        if (muted) {
            // With no desktop playout, Android may idle its communication mode
            // while capture is stopped. Keep physical-removal monitoring and
            // re-establish/verify the selected route on explicit Unmute.
            if (reuseCapture && microphoneInput.watch(module, microphoneRouting) { inputRouteLost() } &&
                microphoneInput.matches(module, microphoneRouting)) {
                microphoneCaptureRetained = true
                microphoneRouting.monitor(true)
            } else {
                microphoneInput.clear()
                if (!mode.playback) microphoneRouting.monitor(false)
                connection.setAudioRecording(false)
            }
        } else {
            // Probe the requested route with transmission gated. Never send an
            // unverified default input to Windows.
            if (!reuseCapture) module.setPreferredInputDevice(microphoneRouting.activate(5000) { closed.get() })
            if (mode.playback) microphoneRouting.validateDuplexOutput()
            workerWait.checkpoint()
            microphoneTrack?.setEnabled(true) // The ADM still supplies only silence.
            if (!reuseCapture) connection.setAudioRecording(true)
            val deadline = android.os.SystemClock.elapsedRealtime() + (if (microphoneSelection.kind.bluetooth) 5000 else 2000)
            fun verified() = microphoneInput.matches(module, microphoneRouting) &&
                (!mode.playback || !microphoneSelection.kind.bluetooth || outputDiagnostics.matches(module, microphoneRouting))
            while (!closed.get() && !headsetRecovery.pending() && !microphoneDesiredMuted.get() &&
                !verified() &&
                android.os.SystemClock.elapsedRealtime() < deadline) workerWait.await { Thread.sleep(20) }
            if (closed.get()) return
            if (headsetRecovery.pending()) return
            if (microphoneDesiredMuted.get()) { connection.setAudioRecording(false); return }
            if (!verified() || !microphoneInput.watch(module, microphoneRouting) { inputRouteLost() } ||
                (mode.playback && microphoneSelection.kind.bluetooth &&
                    !outputDiagnostics.watchRoute(module, microphoneRouting) { inputRouteLost() })) {
                val problem = if (leStereoDuplex && microphoneInput.matches(module, microphoneRouting) &&
                    microphoneRouting.matchesOutput(outputDiagnostics.routedDevice(module)) &&
                    !outputDiagnostics.matches(module, microphoneRouting)) MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE
                    else MicrophoneRouteProblem.UNVERIFIED
                connection.setAudioRecording(false)
                fail(problem.detail, if (problem == MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE)
                    SessionFailure.LE_STEREO_UNAVAILABLE else SessionFailure.INPUT_UNVERIFIED)
                return
            }
            microphoneRouting.monitor(true)
        }
        if (muted && mode.playback && microphoneSelection.kind.bluetooth) {
            // A focus-resumed duplex can start with the microphone already
            // muted. Verify its new output track before enabling listening;
            // initially muted capture stays stopped throughout this path.
            val deadline = android.os.SystemClock.elapsedRealtime() + 5000
            while (!closed.get() && !headsetRecovery.pending() && microphoneDesiredMuted.get() &&
                !outputDiagnostics.matches(module, microphoneRouting) &&
                android.os.SystemClock.elapsedRealtime() < deadline) workerWait.await { Thread.sleep(20) }
            if (closed.get() || headsetRecovery.pending()) return
            if (!microphoneDesiredMuted.get()) return
            if (!outputDiagnostics.matches(module, microphoneRouting) ||
                !outputDiagnostics.watchRoute(module, microphoneRouting) { inputRouteLost() }) {
                fail("The selected headset output could not be verified. Stop and select the input again.", SessionFailure.INPUT_UNVERIFIED)
                return
            }
            microphoneRouting.monitor(true)
        }
        if (headsetRecovery.pending()) return
        setHostMicrophoneGate(token, muted)
        if (closed.get() || headsetRecovery.pending()) return
        var captureEnabled = false
        if (!muted && !microphoneDesiredMuted.get()) {
            if (!microphoneInput.matches(module, microphoneRouting) ||
                (mode.playback && microphoneSelection.kind.bluetooth && !outputDiagnostics.matches(module, microphoneRouting))) {
                inputRouteLost()
                return
            }
            // Serialize the last local gate with Stop, UI mute and route loss.
            synchronized(audioLock) {
                if (!closed.get() && !networkHeld.get() && !headsetRecovery.pending() && !microphoneDesiredMuted.get()) {
                    module.setMicrophoneMute(false)
                    captureEnabled = true
                    if (mode.playback && microphoneSelection.kind.bluetooth) {
                        outputGate.verified(); module.setSpeakerMute(speakerMuted)
                    }
                }
            }
        }
        // Publish outside audioLock; only a successful gate opening is first-capture
        // evidence. Desired unmute during initial trickle/network hold is not.
        if (captureEnabled) onMicrophoneCaptureEnabled()
        if (muted && mode.playback && microphoneSelection.kind.bluetooth) {
            if (!outputDiagnostics.matches(module, microphoneRouting) || !microphoneRouting.healthy()) {
                inputRouteLost()
                return
            }
            synchronized(audioLock) {
                if (!closed.get() && !headsetRecovery.pending() && microphoneDesiredMuted.get()) {
                    outputGate.verified(); module.setSpeakerMute(speakerMuted)
                }
            }
        }
        microphoneAppliedMuted = muted
        microphoneControlDirty = false
        onMicrophoneSelection(microphoneRouting.currentSelection())
        onMicrophoneState(microphoneDesiredMuted.get(), false)
    }

    private fun setHostMicrophoneGate(token: String, muted: Boolean, timeout: Int? = null) {
        val acknowledgment = try {
            request("/microphone", token, JSONObject().put("version", 3).put("muted", muted), timeout)
        } catch (error: HttpFailure) {
            if (error.status in listOf(410, 500))
                fail("Windows ended microphone return or could not apply its cable gate. Check the Windows console and the selected render endpoint with bridge-devices before retrying.", SessionFailure.HOST_MICROPHONE_GATE)
            throw error
        }
        check(acknowledgment.optBoolean("ok") && acknowledgment.opt("muted") is Boolean && acknowledgment.getBoolean("muted") == muted)
    }

    private fun inputRouteLost() {
        if (!microphoneReturn || !microphoneSelection.kind.bluetooth || microphoneAppliedMuted == null) {
            stopForInputRouteChange("The selected microphone or Bluetooth audio route changed.")
            return
        }
        // Route callbacks never signal HTTP, dispose JNI, or choose a device.
        // Gate the app-owned samples immediately; the owning worker restores.
        synchronized(audioLock) {
            if (closed.get()) return
            audio?.setMicrophoneMute(true)
            if (mode.playback) { outputGate.hold(); audio?.setSpeakerMute(true) }
            headsetRecovery.request(android.os.SystemClock.elapsedRealtime())
        }
        synchronized(controlSignal) { controlSignal.notifyAll() }
    }

    private fun stopForInputRouteChange(detail: String) {
        fail("$detail ${if (mode.playback) "Playback and microphone return stopped." else "Microphone return stopped."} " +
            "Choose an available input and tap ${mode.reconnectAction} again.", SessionFailure.INPUT_ROUTE_CHANGED)
    }

    private fun restoreHeadset(connection: PeerConnection, module: JavaAudioDeviceModule, token: String) {
        val ticket = headsetRecovery.current() ?: return
        fun remaining() = headsetRecovery.remaining(android.os.SystemClock.elapsedRealtime())
        if (remaining() == 0L) {
            stopForInputRouteChange("Android did not restore the selected headset within $bluetoothRecoverySeconds seconds.")
            return
        }
        if (restoringEpisode != ticket.episode) {
            onPhase(SessionPhase.ROUTE_RECOVERING)
            onStatus("Restoring the selected headset for up to $bluetoothRecoverySeconds seconds. ${if (mode.playback) "Playback and microphone" else "Microphone"} temporarily silenced.")
            microphoneInput.clear(); outputDiagnostics.clearRouteWatch()
            microphoneRouting.monitor(false)
            microphoneTrack?.setEnabled(false)
            microphoneCaptureRetained = false
            connection.setAudioRecording(false)
            restorationRecording = false; restorationInputId = null; restorationHostMuted = false
            restorationReportedMute = null
            restoringEpisode = ticket.episode
        }
        if (closed.get()) return
        // Mute must stop a silenced capture probe even while Android has not
        // exposed the original route again. Do not wait for restoreInput.
        if (microphoneDesiredMuted.get() && restorationRecording) {
            microphoneInput.clear(); microphoneTrack?.setEnabled(false)
            connection.setAudioRecording(false); restorationRecording = false
        }
        if (!restorationHostMuted) {
            setHostMicrophoneGate(token, true, remaining().coerceIn(1, 2000).toInt())
            restorationHostMuted = true; microphoneAppliedMuted = true
        }
        if (closed.get() || remaining() == 0L) return
        // Present the user's requested mute, not the temporary sample gate.
        // Mute remains available even while a previous Unmute is pending.
        val requestedMute = microphoneDesiredMuted.get()
        if (restorationReportedMute != requestedMute) {
            restorationReportedMute = requestedMute
            onMicrophoneState(requestedMute, false)
        }
        val endpointAvailable = microphoneRouting.recoveryEndpointAvailable()
        headsetRecovery.observe(microphoneRouting.recoveryCheck())
        val reselect = headsetRecovery.reselectionDue(android.os.SystemClock.elapsedRealtime(), endpointAvailable)
        fun stopProbe() {
            microphoneInput.clear(); outputDiagnostics.clearRouteWatch(); microphoneRouting.monitor(false)
            microphoneTrack?.setEnabled(false)
            if (restorationRecording) connection.setAudioRecording(false)
            restorationRecording = false; restorationInputId = null
        }
        if (!endpointAvailable) {
            stopProbe()
            if (!closed.get() && headsetRecovery.routeReleaseDue(android.os.SystemClock.elapsedRealtime(), false)) {
                // One attempt to release this app's stale communication request.
                // Stop playout too, so an old AudioTrack cannot keep that route
                // active. The same peer/session and original deadline remain.
                if (mode.playback) {
                    restorationPlayoutStopped = true
                    connection.setAudioPlayout(false)
                }
                microphoneRouting.releaseCommunicationForRecovery()
            }
            if (!closed.get() && remaining() > 0L) {
                // A profile-connected headset can be absent from Android's
                // audio-device list after another classic headset activates.
                // Ask only for the original pinned headset, then wait for its
                // real sink/source and the existing live verification path.
                microphoneRouting.requestHiddenScoEndpoint(headsetRecovery) { closed.get() }
                headsetRecovery.observe(microphoneRouting.recoveryCheck())
            }
            return
        }
        if (reselect && restorationRecording) {
            microphoneInput.clear(); outputDiagnostics.clearRouteWatch(); microphoneRouting.monitor(false)
            microphoneTrack?.setEnabled(false); connection.setAudioRecording(false)
            restorationRecording = false; restorationInputId = null
        }
        val chosen = try { microphoneRouting.restoreInput(reselect) }
        catch (_: MicrophoneRouteException) {
            stopForInputRouteChange("Android could not reselect the original headset.")
            return
        } ?: run { headsetRecovery.observe(microphoneRouting.recoveryCheck()); stopProbe(); return }
        headsetRecovery.observe(microphoneRouting.recoveryCheck())
        if (chosen.id != restorationInputId) {
            if (restorationRecording) {
                microphoneTrack?.setEnabled(false); connection.setAudioRecording(false); restorationRecording = false
            }
            module.setPreferredInputDevice(chosen)
            restorationInputId = chosen.id
        }
        if (mode.playback && restorationPlayoutStopped) {
            if (closed.get() || remaining() == 0L) return
            // Recreate a silenced output only after the original communication
            // sink and source are available. Verify its live route below.
            restorationPlayoutStopped = false
            connection.setAudioPlayout(true)
        }
        val muted = microphoneDesiredMuted.get()
        if (muted && restorationRecording) {
            microphoneInput.clear(); microphoneTrack?.setEnabled(false)
            connection.setAudioRecording(false); restorationRecording = false
        } else if (!muted && !restorationRecording) {
            // Probe through a silenced ADM while the Windows cable gate is shut.
            microphoneTrack?.setEnabled(true); connection.setAudioRecording(true)
            restorationRecording = true
        }
        fun verified() = (muted || microphoneInput.matches(module, microphoneRouting)) &&
            (!mode.playback || outputDiagnostics.matches(module, microphoneRouting))
        if (closed.get() || remaining() == 0L) return
        if (!verified()) {
            headsetRecovery.observe(if (!muted && !microphoneInput.matches(module, microphoneRouting))
                "waiting for verified original microphone" else "waiting for verified original output and channel count")
            return
        }
        if ((!muted && !microphoneInput.watch(module, microphoneRouting) { inputRouteLost() }) ||
            (mode.playback && !outputDiagnostics.watchRoute(module, microphoneRouting) { inputRouteLost() })) {
            stopProbe() // A route can disappear between verification and watching.
            return
        }
        microphoneRouting.monitor(mode.playback || !muted)
        if (!muted) {
            setHostMicrophoneGate(token, false, remaining().coerceIn(1, 2000).toInt())
            restorationHostMuted = false
        }
        var restored = false
        var captureEnabled = false
        synchronized(audioLock) {
            if (!closed.get() && microphoneDesiredMuted.get() == muted && verified() && microphoneRouting.healthy() &&
                headsetRecovery.complete(ticket, android.os.SystemClock.elapsedRealtime())) {
                microphoneAppliedMuted = muted
                microphoneControlDirty = false
                if (!muted && !networkHeld.get()) {
                    module.setMicrophoneMute(false)
                    captureEnabled = true
                }
                if (mode.playback) { outputGate.verified(); module.setSpeakerMute(speakerMuted) }
                restored = true
            }
        }
        if (restored) {
            if (captureEnabled) onMicrophoneCaptureEnabled()
            onMicrophoneSelection(microphoneRouting.currentSelection())
            onMicrophoneState(microphoneDesiredMuted.get(), false)
            onStatus("Selected headset restored.${if (muted) " Microphone remains muted." else ""}")
        } else {
            // A late callback, Mute, or Stop invalidates the probe/acknowledgment.
            // Local gates remain shut; the next step also recloses Windows.
            microphoneInput.clear(); outputDiagnostics.clearRouteWatch(); microphoneRouting.monitor(false)
            microphoneTrack?.setEnabled(false); connection.setAudioRecording(false)
            restorationRecording = false; restorationInputId = null
        }
    }

    private fun cleanupStep(name: String, operation: () -> Unit) {
        if (journalActive) journal.checkpoint(name)
        cleanup(operation)
    }

    private fun cleanup(operation: () -> Unit) {
        try { operation() }
        catch (_: Exception) { failure.compareAndSet(null, "Audio cleanup failed [TEARDOWN_FAILED]. Restart the Android app before retrying.") }
        catch (_: LinkageError) { failure.compareAndSet(null, "Audio cleanup failed [NATIVE_LOAD]. Reinstall the latest Android arm64 APK.") }
    }

    private fun retrySignaling(error: Throwable, attemptedAt: Long): Boolean {
        if (!lanRecovery.signalingFailed(error, attemptedAt, closed.get())) return false
        if (lanRecovery.established && !lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) {
            // Every retry restores the selected priority, including retries of
            // a prepared answer after the fallback transport failed.
            holdNetworkAudio() // LAN-first verification must not delay the local mute.
            signalingRoute.recover { probeLocal() }
            RemoteIce.retryAfterInterruption()
        }
        return true
    }

    private fun holdNetworkAudio() {
        synchronized(audioLock) {
            if (closed.get()) return
            networkHeld.set(true)
            // A headset duplex route can change while capture is stopped.
            // Keep listening held until the resumed microphone-control path
            // verifies that same headset output, including a muted resume.
            if (mode.playback && microphoneSelection.kind.bluetooth) outputGate.hold()
            audio?.setSpeakerMute(true)
            if (microphoneReturn) audio?.setMicrophoneMute(true)
        }
    }

    private fun suspendNetworkAudio(connection: PeerConnection, module: JavaAudioDeviceModule) {
        if (networkAudioSuspended || closed.get()) return
        networkAudioSuspended = true
        if (microphoneReturn) {
            module.setMicrophoneMute(true); microphoneTrack?.setEnabled(false)
            microphoneCaptureRetained = false
            microphoneInput.clear(); connection.setAudioRecording(false)
            microphoneAppliedMuted = true
            onMicrophoneState(microphoneDesiredMuted.get(), false)
        }
        // Keep playout consuming live NetEq frames while the ADM writes silence;
        // no application catch-up queue or stale recording is retained.
    }

    private fun releaseNetworkAudio(module: JavaAudioDeviceModule) {
        synchronized(audioLock) {
            if (closed.get() || lanRecovery.pending || state != "Connected" || !iceConnected) return
            networkHeld.set(false)
            if (microphoneReturn) microphoneControlDirty = true
            module.setSpeakerMute(speakerMuted)
            networkAudioSuspended = false
        }
    }

    private fun publishNetworkStatus() {
        if (invitation.remote == null || closed.get()) return
        val network = when (runtime.networkLabel()) {
            "wifi" -> "Wi-Fi"
            "cellular" -> "Mobile data"
            "ethernet" -> "Ethernet"
            "vpn" -> "VPN"
            "none" -> "Unavailable"
            else -> "Checking"
        }
        val message = "Network: $network" + if (lanRecovery.active || networkHandoff.waiting()) " · Restoring connection" else ""
        if (message != publishedNetworkStatus) { publishedNetworkStatus = message; onNetworkStatus(message) }
    }

    private fun restoreLanConnection(connection: PeerConnection, token: String) {
        fun budget(maximum: Long) = lanRecovery.remaining(android.os.SystemClock.elapsedRealtime()).coerceIn(1, maximum)
        if (closed.get() || lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) return
        onPhase(SessionPhase.RECOVERING)
        onStatus("Restoring the current media connection. Selected devices and mute settings are retained…")
        if (lanRecovery.answer == null) {
            if (recoveryLocalGeneration != lanRecovery.generation) {
                if (invitation.remote != null) {
                    val config = PeerConnection.RTCConfiguration(remoteIceServers()).apply {
                        sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                        continualGatheringPolicy = if (continuousEnabled) PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
                            else PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
                        audioJitterBufferFastAccelerate = fastRecovery
                        if (invitation.remote.forceRelay) iceTransportsType = PeerConnection.IceTransportsType.RELAY
                    }
                    check(connection.setConfiguration(config))
                }
                val offer = request("/recover-offer", token,
                    JSONObject().put("version", 3).put("generation", lanRecovery.generation), budget(connectionPreferences[ConnectionTimeout.RECOVERY_OFFER].toLong()).toInt())
                check(offer.getInt("version") == 3 && offer.getLong("generation") == lanRecovery.generation)
                val description = offer.getString("sdp"); require(description.length in 1..65536)
                if (closed.get() || lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) return
                gathered = CountDownLatch(1)
                recoveryPreviousLocal = connection.localDescription.description
                recoveryCandidates.clear(); collectingRecovery = !continuousEnabled
                continuousCandidates.clear()
                if (continuousEnabled) continuous = ContinuousIce(description, invitation.remote?.forceRelay == true, lanRecovery.generation)
                awaitSDP(budget(connectionPreferences[ConnectionTimeout.RECOVERY_ANSWER].toLong())) { connection.setRemoteDescription(it, SessionDescription(SessionDescription.Type.OFFER, description)) }
                if (closed.get()) return
                val answer = requireNotNull(awaitSDP(budget(connectionPreferences[ConnectionTimeout.RECOVERY_ANSWER].toLong())) { connection.createAnswer(it, MediaConstraints()) })
                val local = if (mode.playback) SessionDescription(answer.type, OpusSdp.stereoAnswer(answer.description)) else answer
                awaitSDP(budget(connectionPreferences[ConnectionTimeout.RECOVERY_ANSWER].toLong())) { connection.setLocalDescription(it, local) }
                recoveryLocalGeneration = lanRecovery.generation
            }
            val complete = !continuousEnabled && workerWait.await { gathered.await(budget(connectionPreferences[ConnectionTimeout.RECOVERY_ICE].toLong()), TimeUnit.MILLISECONDS) } &&
                connection.iceGatheringState() == PeerConnection.IceGatheringState.COMPLETE
            val description = connection.localDescription.description
            if (continuousEnabled) {
                check(IceGathering.freshCredentials(description, recoveryPreviousLocal)) { "ICE credentials were not renewed" }
                lanRecovery.answer = ContinuousIce.withoutCandidates(description)
            } else {
                val gathering = IceGathering.recovery(description, recoveryPreviousLocal, complete,
                    invitation.remote != null, invitation.remote?.forceRelay == true, connectionPreferences[ConnectionTimeout.RECOVERY_ICE].toLong(), recoveryCandidates.snapshot())
                if (!gathering.canSubmit) throw java.net.SocketTimeoutException("Recovery candidates unavailable")
                lanRecovery.answer = description
            }
            collectingRecovery = false; recoveryCandidates.clear()
        }
        if (closed.get() || lanRecovery.expired(android.os.SystemClock.elapsedRealtime())) return
        val acknowledgment = request("/recover-answer", token, JSONObject().put("version", 3)
            .put("generation", lanRecovery.generation).put("sdp", requireNotNull(lanRecovery.answer)), budget(connectionPreferences[ConnectionTimeout.RECOVERY_ANSWER].toLong()).toInt())
        check(acknowledgment.optBoolean("ok") && acknowledgment.getLong("generation") == lanRecovery.generation)
        lanRecovery.accepted(android.os.SystemClock.elapsedRealtime())
    }

    private fun acceptTrickle(update: JSONObject, connection: PeerConnection) {
        require(update.getInt("version") == 1 && update.getLong("generation") == 0L) { "Invalid ICE generation" }
        val array = update.optJSONArray("candidates")
        require((array?.length() ?: 0) <= TrickleIce.BATCH_SIZE) { "ICE batch limit" }
        val candidates = (0 until (array?.length() ?: 0)).map { i ->
            val c = requireNotNull(array).getJSONObject(i)
            TrickleCandidate(c.getString("mid"), c.getInt("index"), c.getString("ufrag"), c.getString("candidate"))
        }
        requireNotNull(trickle).accept(TrickleDelta(update.getInt("ack"), update.getInt("offset"), candidates,
            update.getBoolean("complete"))) { c -> connection.addIceCandidate(IceCandidate(c.mid, c.index, c.candidate)) }
    }

    private fun acceptContinuous(update: JSONObject, connection: PeerConnection) {
        val array = update.optJSONArray("candidates")
        require((array?.length() ?: 0) <= ContinuousIce.MAX_CANDIDATES) { "ICE snapshot limit" }
        val candidates = array?.let { values -> (0 until values.length()).map { i ->
            val c = values.getJSONObject(i)
            TrickleCandidate(c.getString("mid"), c.getInt("index"), c.getString("ufrag"), c.getString("candidate"))
        } }
        requireNotNull(continuous).accept(IceSnapshot(update.getLong("generation"), update.getLong("revision"),
            update.getLong("ack"), candidates, update.getInt("version")),
            add = { c -> connection.addIceCandidate(IceCandidate(c.mid, c.index, c.candidate)) },
            remove = { c -> connection.removeIceCandidates(arrayOf(IceCandidate(c.mid, c.index, c.candidate))); true })
    }

    private fun signalingText() = (if (invitation.remote == null) lanNetwork.text()
        else signalingRoute.text(invitation.remote.forceRelay)) + "\n" + connectionPreferences.text(connectionDeadlines)

    private fun probeLocal(stopping: Boolean = false, timeout: Int = connectionPreferences[ConnectionTimeout.LAN_PROBE]): Boolean {
        if (!stopping) workerWait.checkpoint()
        if (!stopping && lanRecovery.expired(android.os.SystemClock.elapsedRealtime()))
            throw java.net.SocketTimeoutException("Media recovery deadline reached")
        val remaining = if (!stopping && lanRecovery.active)
            lanRecovery.remaining(android.os.SystemClock.elapsedRealtime()).coerceAtLeast(1).toInt() else timeout
        val reachable = try {
            LocalProbe(invitation, lanNetwork.socket()).use { probe ->
                if (!stopping) { activeProbe = probe; workerWait.checkpoint() }
                probe.reachable(minOf(timeout, remaining).coerceIn(1, connectionPreferences[ConnectionTimeout.LAN_PROBE]))
            }
        } catch (_: java.io.IOException) { false }
        finally { if (!stopping) activeProbe = null }
        if (!stopping) workerWait.checkpoint()
        return reachable
    }

    private fun remoteIceServers(): List<PeerConnection.IceServer> = invitation.remote?.takeIf {
        signalingRoute.needsRemoteIce(it.forceRelay)
    }?.let {
        fun handoffCheckpoint() {
            workerWait.checkpoint()
            if (networkHandoff.waiting()) throw SignalingNetworkChanged()
        }
        handoffCheckpoint()
        try {
            RemoteIce.fetch(it, { request -> activeRequest = request }, { workerWait.checkpoint() },
                remainingMs = { operationBudget(connectionPreferences[ConnectionTimeout.ICE_SERVICE].toLong()) },
                timeoutMs = connectionPreferences[ConnectionTimeout.ICE_SERVICE])
        } catch (error: java.io.IOException) {
            workerWait.checkpoint()
            if (!ConnectionFailure.retryableStatus(error)) throw error
            if (networkHandoff.waiting()) {
                // A failure on the departed network must not suppress the
                // first credential fetch on the replacement network for 30 s.
                RemoteIce.retryAfterInterruption()
                throw SignalingNetworkChanged()
            }
            if (it.forceRelay) throw error
            val reachable = signalingRoute.localFallback { probeLocal().also { handoffCheckpoint() } }
            handoffCheckpoint()
            if (!reachable) throw SignalingRoutesUnavailable()
            emptyList() // Local non-forced offers need no public ICE service.
        }
    } ?: emptyList()

    private fun request(path: String, token: String, body: JSONObject? = null,
                        timeout: Int? = null, stopping: Boolean = false): JSONObject {
        check(stopping || !closed.get())
        val started = android.os.SystemClock.elapsedRealtime()
        val localTimeout = timeout ?: connectionPreferences[ConnectionTimeout.LAN_REQUEST]
        val cleanup = stopping || path in listOf("/stop", "/cancel-offer")
        val total = when {
            cleanup || path == "/offer" || path.startsWith("/recover-") -> localTimeout
            path == "/status" || timeout == null -> connectionPreferences[ConnectionTimeout.REMOTE_REQUEST]
            else -> maxOf(localTimeout, connectionPreferences[ConnectionTimeout.REMOTE_REQUEST])
        }
        fun budget(requested: Int): Int {
            val remaining = if (cleanup) total - (android.os.SystemClock.elapsedRealtime() - started)
                else operationBudget(requested.toLong())
            if (remaining <= 0) throw java.net.SocketTimeoutException("Control request deadline reached")
            return minOf(requested.toLong(), remaining).toInt()
        }
        return signalingRoute.exchange(path,
            local = { localRequest(path, token, body, budget(if (cleanup) minOf(localTimeout, connectionPreferences[ConnectionTimeout.LAN_STOP] * 3 / 4) else localTimeout), stopping) },
            rendezvous = { remoteExchange(path, token, body, budget(if (cleanup) minOf(total, connectionPreferences[ConnectionTimeout.REMOTE_STOP] * 3 / 5) else total), stopping) },
            probeLocal = { probeLocal(stopping, if (cleanup) minOf(budget(connectionPreferences[ConnectionTimeout.LAN_PROBE]) / 2,
                connectionPreferences[ConnectionTimeout.LAN_PROBE] / 2) else connectionPreferences[ConnectionTimeout.LAN_PROBE]) },
            cancelled = { !stopping && closed.get() },
            networkPending = { !stopping && networkHandoff.waiting() })
    }

    private fun operationBudget(requested: Long): Long {
        val now = android.os.SystemClock.elapsedRealtime()
        val remaining = if (lanRecovery.active) lanRecovery.remaining(now)
            else setupStartedAt?.let { connectionDeadlines.setupMs - (now - it) } ?: requested
        if (remaining <= 0) throw java.net.SocketTimeoutException("Connection deadline reached")
        return minOf(requested, remaining)
    }

    private fun remoteExchange(path: String, token: String, body: JSONObject?, timeout: Int, stopping: Boolean): JSONObject {
        val remaining = if (!stopping && lanRecovery.active)
            lanRecovery.remaining(android.os.SystemClock.elapsedRealtime()).coerceAtLeast(1).toInt() else timeout
        val request = RemoteHttp(invitation, minOf(timeout, remaining), onFailure = { detail ->
            if (!stopping) recordSignalingRequestFailure(detail)
        }, connectionPreferences = connectionPreferences, connectTimeout = connectionPreferences[ConnectionTimeout.REMOTE_REQUEST])
        if (!stopping) { remoteRequest = request; if (path == "/status") remoteStatusRequest = request }
        try {
            check(stopping || !closed.get())
            return request.request(path, token, body, offerAttempt.header(path),
                invitation.version == 3 && path == "/offer", resume = resume,
                phoneControlNegotiated = phoneControlEnabled)
        } finally { request.close(); if (!stopping) { remoteRequest = null; remoteStatusRequest = null } }
    }

    private fun localRequest(path: String, token: String, body: JSONObject?, timeout: Int, stopping: Boolean): JSONObject {
        val started = android.os.SystemClock.elapsedRealtime()
        val bodyLimit = PhoneControlSession.bodyLimit(path, phoneControlEnabled)
        fun remaining(): Int {
            val left = timeout - (android.os.SystemClock.elapsedRealtime() - started)
            if (left <= 0) throw java.net.SocketTimeoutException("LAN request timed out")
            return left.toInt()
        }
        var phase = SignalingPhase.LAN_REQUEST
        val connection = lanNetwork.open(URL("https://${invitation.host}:${invitation.port}$path")) as HttpsURLConnection
        val status = if (!stopping && path == "/status") LocalStatus(connection) else null
        // Cancellation may abort ordinary signaling, never the Stop request
        // that the same cancellation triggered in the worker's finally block.
        if (!stopping) { activeRequest = connection; localStatusRequest = status }
        try {
            check(stopping || !closed.get())
            connection.sslSocketFactory = requireNotNull(tls) // Keep hostname verification: the certificate has an IP SAN.
            connection.instanceFollowRedirects = false
            connection.connectTimeout = minOf(remaining(), connectionPreferences[ConnectionTimeout.LAN_REQUEST]); connection.readTimeout = remaining()
            connection.useCaches = false
            if (token.isNotEmpty()) connection.setRequestProperty("Authorization", "Bearer $token")
            offerAttempt.header(path)?.let { connection.setRequestProperty(OfferAttempt.HEADER, it) }
            PhoneControlSession.offerHeader(invitation.version, path)?.let {
                connection.setRequestProperty(PhoneControlSession.HEADER, it)
            }
            SessionResume.offerHeaders(invitation.version, path, resume).forEach { (name, value) ->
                connection.setRequestProperty(name, value)
            }
            if (invitation.version == 3 && path == "/offer") connectionPreferences.offerHeaders().forEach { (name, value) ->
                connection.setRequestProperty(name, value)
            }
            if (invitation.remote != null && invitation.version == 3 && path == "/offer") {
                connection.setRequestProperty(TrickleIce.HEADER, "1")
                connection.setRequestProperty(ContinuousIce.HEADER, "1")
            }
            if (body != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val bytes = body.toString().toByteArray(Charsets.UTF_8)
                require(bytes.size <= bodyLimit)
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            phase = SignalingPhase.RESPONSE_HEADERS
            connection.readTimeout = remaining()
            val responseCode = connection.responseCode
            if (responseCode != 200) throw HttpFailure(responseCode)
            val output = ByteArrayOutputStream()
            phase = SignalingPhase.RESPONSE_BODY
            connection.inputStream.use { input ->
                val buffer = ByteArray(4096)
                while (true) {
                    connection.readTimeout = remaining()
                    val n = input.read(buffer); if (n < 0) break
                    require(output.size() + n <= bodyLimit); output.write(buffer, 0, n)
                }
            }
            return JSONObject(output.toString("UTF-8"))
        } catch (error: java.io.IOException) {
            // This exact heartbeat was deliberately cancelled by a handoff.
            // Some HTTPS implementations surface socket closure as SSLException.
            // It is transport interruption, not evidence of an invalid peer.
            val observed = if (status?.handoff?.get() == true && error !is HttpFailure) SignalingNetworkChanged() else error
            if (!stopping) recordSignalingRequestFailure(signalingRequestFailureText(SignalingTransport.LAN, path,
                phase, android.os.SystemClock.elapsedRealtime() - started, observed))
            throw observed
        } finally { connection.disconnect(); if (!stopping) { activeRequest = null; localStatusRequest = null } }
    }

    private fun recordSignalingRequestFailure(detail: String) {
        if (signalingRequestFailures.size == 4) signalingRequestFailures.removeFirst()
        signalingRequestFailures.addLast("${android.os.SystemClock.elapsedRealtime()} ms · $detail")
    }

    private fun awaitSDP(timeoutMs: Long = connectionPreferences[ConnectionTimeout.INITIAL_SDP].toLong(), operation: (SdpObserver) -> Unit): SessionDescription? {
        workerWait.checkpoint()
        val result = CompletableFuture<SessionDescription?>()
        operation(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) { result.complete(sdp) }
            override fun onSetSuccess() { result.complete(null) }
            override fun onCreateFailure(message: String) { result.completeExceptionally(IllegalStateException("SDP creation failed")) }
            override fun onSetFailure(message: String) { result.completeExceptionally(IllegalStateException("SDP configuration failed")) }
        })
        return workerWait.await { result.get(operationBudget(timeoutMs), TimeUnit.MILLISECONDS) }
    }

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(value: PeerConnection.SignalingState) { }
        override fun onIceConnectionChange(value: PeerConnection.IceConnectionState) {
            if (closed.get()) return
            iceConnected = value in listOf(PeerConnection.IceConnectionState.CONNECTED, PeerConnection.IceConnectionState.COMPLETED)
            evidence.observe(EvidenceKind.ICE, value.name.lowercase(), android.os.SystemClock.elapsedRealtime())
            if (value in listOf(PeerConnection.IceConnectionState.DISCONNECTED, PeerConnection.IceConnectionState.FAILED) && lanRecovery.supported) {
                holdNetworkAudio(); synchronized(controlSignal) { controlSignal.notifyAll() }
            }
        }
        override fun onIceConnectionReceivingChange(value: Boolean) { }
        override fun onIceGatheringChange(value: PeerConnection.IceGatheringState) {
            if (value == PeerConnection.IceGatheringState.COMPLETE) gathered.countDown()
        }
        override fun onConnectionChange(value: PeerConnection.PeerConnectionState) {
            if (closed.get()) return
            state = value.name.lowercase().replaceFirstChar { it.uppercase() }
            evidence.observe(EvidenceKind.PEER, value.name.lowercase(), android.os.SystemClock.elapsedRealtime())
            if (value in listOf(PeerConnection.PeerConnectionState.DISCONNECTED, PeerConnection.PeerConnectionState.FAILED) && lanRecovery.supported) {
                holdNetworkAudio()
                synchronized(controlSignal) { controlSignal.notifyAll() }
            }
            if (value == PeerConnection.PeerConnectionState.FAILED && !lanRecovery.supported) {
                fail("Connection lost. Tap ${mode.reconnectAction} after Windows finishes the session.", SessionFailure.PEER_FAILED)
            }
        }
        override fun onIceCandidate(candidate: IceCandidate) {
            if (!closed.get() && collectingRecovery) recoveryCandidates.add(candidate.sdpMLineIndex, candidate.sdp)
            if (!closed.get() && continuousEnabled) continuousCandidates.add(candidate.sdpMLineIndex, candidate.sdp)
        }
        override fun onIceCandidateError(event: IceCandidateErrorEvent) {
            if (!closed.get()) gatheringErrors.record(event.errorCode)
        }
        override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) {
            if (!closed.get() && continuousEnabled) for (c in candidates) continuousCandidates.remove(c.sdpMLineIndex, c.sdp)
        }
        override fun onAddStream(stream: MediaStream) { }
        override fun onRemoveStream(stream: MediaStream) { }
        override fun onDataChannel(channel: DataChannel) { }
        override fun onRenegotiationNeeded() { }
        override fun onAddTrack(receiver: RtpReceiver, streams: Array<MediaStream>) { }
    }

    companion object {
        // dispose() also tears down native global state. Serialize full native
        // lifetimes across quick reconnects and activity recreation.
        private var initialized = false
        @Synchronized private fun initializeWebRTC(context: Context) {
            if (initialized) return
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context)
                .setEnableInternalTracer(false)
                // SDP, candidates, and identifiers must not leak into logcat.
                .setInjectableLogger({ _, _, _ -> }, Logging.Severity.LS_VERBOSE).createInitializationOptions())
            initialized = true
        }
    }
}
