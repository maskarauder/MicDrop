package com.maskarauder.micdrop

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Build
import android.media.AudioFocusRequest
import android.media.AudioManager
import java.util.UUID

internal data class MicrophoneView(val session: SessionView = SessionView(),
    val muted: Boolean = true, val changing: Boolean = false,
    val mode: StreamMode = StreamMode.MICROPHONE,
    val input: MicrophoneSelection = MicrophoneSelection()) {
    val ownsSession: Boolean get() = session.retained
    val canChooseInput: Boolean get() = mode.microphone && session.phase in listOf(SessionPhase.PLAYING,
        SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING, SessionPhase.PAUSED, SessionPhase.INTERRUPTED)
    val canResume: Boolean get() = mode == StreamMode.DUPLEX &&
        session.phase in listOf(SessionPhase.PAUSING, SessionPhase.PAUSED, SessionPhase.INTERRUPTED)
    fun canSetMuted(value: Boolean): Boolean = mode.microphone && value != muted &&
        ((!changing && session.phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)) ||
            (value && session.phase in listOf(SessionPhase.CONNECTING, SessionPhase.ROUTE_RECOVERING, SessionPhase.SWITCHING)) ||
            (canResume && (!changing || value)))
    // Windows may unmute only capture this phone enabled in the session, while
    // permission is granted. It never grants permission or starts first capture.
    fun offersPhoneControlMute(permissionGranted: Boolean, phoneEnabledCapture: Boolean): Boolean =
        !changing && canSetMuted(!muted) && (!muted || (permissionGranted && phoneEnabledCapture))
}

// Use elapsed realtime at each resume/control entry, not just Handler uptime:
// deep sleep can delay the cleanup timer but cannot extend microphone consent.
internal class DuplexPauseWindow(private val limitMs: Long = 5 * 60 * 1000L) {
    private var deadlineMs: Long? = null
    fun retain(nowMs: Long) { if (deadlineMs == null) deadlineMs = nowMs + limitMs }
    fun expired(nowMs: Long): Boolean = deadlineMs?.let { nowMs >= it } ?: false
    fun clear() { deadlineMs = null }
}

// A separate, nonexported microphone foreground service. Media resumption never
// starts it; only a visible activity with an explicit permission/consent action
// connects. Stop/force-stop destroys capture; the saved pairing is reusable.
class MicrophoneService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val state = SessionLifecycle()
    private val observers = mutableSetOf<(MicrophoneView) -> Unit>()
    private var receiver: StreamReceiver? = null
    @Volatile private var wakeLock: PowerManager.WakeLock? = null
    private var muted = true
    // The worker actually opened verified unmuted capture in this phone session;
    // desired-state reports during a network hold are not evidence. Input
    // switches and duplex resumes keep it. Windows may unmute only after it.
    private var phoneEnabledCapture = false
    private var sessionOptions = MicrophoneSessionOptions() // Captured at explicit Connect.
    private var outputEnabled = true
    private var outputSelection = lastView.session.outputSelection
    private var outputPause: OutputPause? = null
    private val mediaFocus = MediaOutputFocus()
    private val outputFocusPause get() = mediaFocus.pause
    private var protectedDefaultSpeaker = false
    private val usesMediaOutput get() = mode.usesMediaOutput(input.kind)
    private val followsDefaultMedia get() = usesMediaOutput && !outputSelection.explicit
    private var fastRecovery = true
    private var changing = false
    private var destroyed = false
    private var mode = StreamMode.MICROPHONE
    private var input = MicrophoneSelection()
    private val inputChange = PendingRouteChange<MicrophoneSelection>()
    private var inputChangeTimedOut = false
    private var supersededReceiver: String? = null
    private var inputSwitchActionOrigin: String? = null
    private var requestedStop: StreamEnd? = null
    private var focus: AudioFocusRequest? = null
    private var focusGeneration: String? = null
    private var retainedLink: String? = null
    private var resumable = false
    private val pauseWindow = DuplexPauseWindow()
    private var foregroundActive = false
    private var noisyRegistered = false
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && receiver?.mediaOutputBecomingNoisy() == true) return
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && followsDefaultMedia) {
                protectedDefaultSpeaker = true
                receiver?.mediaOutputBecomingNoisy()
                return
            }
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && usesMediaOutput) return
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && mode == StreamMode.DUPLEX &&
                state.view.phase != SessionPhase.SWITCHING &&
                !(state.view.phase == SessionPhase.CONNECTING && inputSwitchActionOrigin != null))
                stop(StopReason.OUTPUT)
        }
    }

    internal inner class LocalBinder : Binder() { val service get() = this@MicrophoneService }
    override fun onBind(intent: Intent?): IBinder = LocalBinder()
    internal fun observe(observer: (MicrophoneView) -> Unit) {
        expirePauseIfNeeded(); observers.add(observer); observer(lastView)
    }
    internal fun removeObserver(observer: (MicrophoneView) -> Unit) { observers.remove(observer) }
    internal fun outputActionToken(): String? = state.token.takeIf {
        !destroyed && state.view.retained && state.view.phase != SessionPhase.STOPPING
    }

    internal fun connectFromActivity(text: String, requestedMode: StreamMode = StreamMode.MICROPHONE,
        requestedInput: MicrophoneSelection = MicrophoneSelection(), enabledOutput: Boolean = requestedMode.playback,
        fast: Boolean = true, selectedOutput: OutputSelection = outputSelection) {
        if (state.view.retained) return
        inputSwitchActionOrigin = null
        phoneEnabledCapture = false
        sessionOptions = MicrophoneSessionOptions.forConnect(AppAudioSettings.load(this))
        outputEnabled = enabledOutput && requestedMode.playback
        fastRecovery = fast
        outputSelection = selectedOutput
        outputPause = null; mediaFocus.granted(); protectedDefaultSpeaker = false
        beginConnection(text, requestedMode, requestedInput, false, false)
    }
    private fun beginConnection(text: String, requestedMode: StreamMode, requestedInput: MicrophoneSelection,
        initiallyMuted: Boolean, keepFocus: Boolean, resume: SessionResume.Reason? = null) {
        require(requestedMode.microphone)
        val invitation = LanInvitation.parse(text)
        require(invitation.version == 3 && !invitation.expired())
        check(checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
        if (requestedInput.kind.bluetooth && !BluetoothAudioIdentity.permitted(this))
            throw MicrophoneRouteException(MicrophoneRouteProblem.BLUETOOTH_PERMISSION)
        if (!MicrophoneRouting.available(this, requestedInput))
            throw MicrophoneRouteException(MicrophoneRouteProblem.UNAVAILABLE)
        if (requestedMode.playback && !requestedInput.kind.bluetooth &&
            (AppAudioSettings.load(this).needsOutputSelection(outputSelection) || !OutputDevices.available(this, outputSelection)))
            throw IllegalStateException("Output selection unavailable")
        if (requestedMode.playback && !requestedInput.kind.bluetooth)
            outputSelection = OutputDevices.refresh(this, outputSelection) ?: throw IllegalStateException("Output selection unavailable")
        val id = UUID.randomUUID().toString()
        check(state.begin(id, "Windows: ${invitation.host}:${invitation.port}"))
        mode = requestedMode
        input = requestedInput
        retainedLink = text; resumable = false
        muted = initiallyMuted; changing = true
        inputChangeTimedOut = false
        supersededReceiver = null
        requestedStop = null
        handler.removeCallbacks(interruptionTimeout)
        pauseWindow.clear()
        try {
            // Initial consent comes from the visible activity. Focus resumption
            // stays inside this existing foreground microphone service; no
            // restart ticket or saved consent survives Stop/process death.
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "MicDrop microphone", NotificationManager.IMPORTANCE_LOW))
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                (if (mode.playback) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK else 0)
            if (!foregroundActive) {
                startService(Intent(this, MicrophoneService::class.java))
                startForeground(NOTIFICATION, notification(id), types)
                foregroundActive = true
            } else {
                startForeground(NOTIFICATION, notification(id), types)
            }
            if ((mode.playback || input.kind.bluetooth) && !keepFocus) {
                // Promotion precedes focus/audio on Android 15+. Duplex retains
                // its existing consent through a bounded focus interruption.
                releasePlaybackFocus()
                val generation = UUID.randomUUID().toString()
                focusGeneration = generation
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(MicrophoneRouting.attributes(input)).setWillPauseWhenDucked(true)
                    .setOnAudioFocusChangeListener({ change ->
                        if (!destroyed && focusGeneration == generation) focusChanged(change)
                    }, handler).build()
                focus = request
                if (getSystemService(AudioManager::class.java).requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    finish(id, StreamEnd(StopReason.FAILURE, "Android did not grant audio focus. Stop other playback, keep MicDrop open and tap ${mode.reconnectAction} again."))
                    return
                }
                mediaFocus.granted()
            }
            if (mode.playback && !input.kind.bluetooth && !noisyRegistered) {
                // Bluetooth transition/disconnect is verified by the
                // session's concrete communication/output route watchers.
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, filter, RECEIVER_NOT_EXPORTED)
                else registerReceiver(noisy, filter)
                noisyRegistered = true
            }
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MicDrop:microphone").apply { setReferenceCounted(false) }
            handler.removeCallbacks(renewWakeLock); renewWakeLock.run()
            outputPause = if (usesMediaOutput) outputFocusPause ?: (if (followsDefaultMedia) OutputPause.ROUTE else null) else null
            var remembered = false
            receiver = StreamReceiver(applicationContext, invitation, fastRecovery, null,
                { message -> handler.post { if (acceptReceiverUpdate(id) && state.update(id, message = message)) publish() } },
                { report -> handler.post { if (acceptReceiverUpdate(id) && state.update(id, diagnostics = report)) publish() } },
                { phase -> handler.post { if (acceptReceiverUpdate(id) && state.update(id, phase = phase)) {
                    if (phase == SessionPhase.PLAYING) {
                        inputSwitchActionOrigin = null
                        resumable = mode == StreamMode.DUPLEX
                        if (!remembered) { remembered = true; SavedConnections.get(applicationContext).remember(text) }
                    }
                    publish()
                } } },
                { end -> handler.post { if (!destroyed) finish(id, end) } },
                reconnect = true, mode = mode, microphoneSelection = input, initiallyMicrophoneMuted = initiallyMuted,
                resume = resume,
                phoneControlBinding = PhoneControlBinding(current = {
                    if (!acceptReceiverUpdate(id) || state.token != id || !state.view.active ||
                        state.view.phase in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) null
                    else PhoneLiveSettings(if (input.kind.bluetooth) AudioManager.STREAM_VOICE_CALL else AudioManager.STREAM_MUSIC,
                        outputEnabled = outputEnabled.takeIf { mode.playback },
                        microphoneMuted = muted.takeIf { phoneControlMuteOffered() },
                        output = PhoneOutputControl.session(mode, outputSelection),
                        outputLive = PhoneOutputControl.live(mode, input.kind))
                }, apply = { changes ->
                    (changes["live.output_enabled"] as? Boolean)?.let { setOutputEnabled(it, fromWindows = true); check(outputEnabled == it) }
                    (changes["live.microphone_muted"] as? Boolean)?.let {
                        check(phoneControlMuteOffered()); setMuted(it, fromWindows = true); check(muted == it)
                    }
                }, changed = { publish() }, applyOutput = { selected ->
                    check(PhoneOutputControl.accepts(state.view.phase, selected.kind) { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } &&
                        setOutputSelection(selected) && outputSelection.sameEndpoint(selected))
                }),
                initiallyOutputEnabled = outputEnabled,
                outputSelection = outputSelection,
                onOutputSelection = { selected -> handler.post {
                    if (acceptReceiverUpdate(id) && state.token == id && state.view.active &&
                        state.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING) &&
                        outputSelection.acceptsUpdate(selected) && receiver?.matchesOutputSelection(selected) == true) {
                        val savedOutput = AppAudioSettings.output(this)
                        val updateSavedOutput = savedOutput.sameEndpoint(outputSelection) || savedOutput.sameEndpoint(selected)
                        outputSelection = selected
                        // Do not overwrite a newer Windows choice saved for the next connection.
                        if (updateSavedOutput) AppAudioSettings.selectOutput(this, selected)
                        publish()
                    }
                } },
                protectedDefaultSpeaker = protectedDefaultSpeaker,
                initiallyOutputFocus = outputFocusPause,
                onOutputState = { pause, protectedSpeaker -> handler.post {
                    if (acceptReceiverUpdate(id) && state.token == id && state.view.active &&
                        receiver?.matchesOutputState(pause, protectedSpeaker) == true &&
                        state.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) {
                        outputPause = pause; protectedDefaultSpeaker = protectedSpeaker; publish()
                    }
                } },
                microphoneProcessing = AppAudioSettings.load(this).let { MicrophoneProcessing(it.echoCancellation, it.noiseReduction) },
                keepMicrophoneActive = sessionOptions.keepMicrophoneActive,
                onMicrophoneSelection = { selected -> handler.post {
                    if (acceptReceiverUpdate(id) && state.token == id && state.view.retained && state.view.phase != SessionPhase.STOPPING) {
                        // Keep a verified replacement port for this service's
                        // retained duplex consent, including a queued focus pause.
                        val savedInput = AppAudioSettings.input(this)
                        val updateSavedInput = savedInput.sameDevice(input) || savedInput.sameDevice(selected)
                        input = selected
                        if (updateSavedInput) AppAudioSettings.selectInput(this, selected.copy(leStereo = AppAudioSettings.load(this).leStereo))
                        publish()
                    }
                } },
                wakeLockHeld = { wakeLock?.isHeld ?: false },
                foregroundTypes = { foregroundServiceType },
                onNetworkStatus = { message -> handler.post {
                    if (acceptReceiverUpdate(id) && state.update(id, networkStatus = message)) publish()
                } },
                onMicrophoneState = { value, pending -> handler.post {
                    if (acceptReceiverUpdate(id) && state.token == id && state.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING) &&
                        receiver?.microphoneMuteRequested() == value) {
                        muted = value; changing = pending
                        publish()
                    }
                } },
                onMicrophoneCaptureEnabled = { handler.post {
                    if (acceptReceiverUpdate(id) && state.token == id && state.view.retained &&
                        state.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) {
                        phoneEnabledCapture = true
                        publish()
                    }
                } })
            publish(); receiver?.start()
        } catch (_: Exception) {
            finish(id, StreamEnd(StopReason.FAILURE, "Microphone return could not start. Keep MicDrop open, grant microphone permission and check Android's microphone privacy setting."))
        }
    }

    private fun acceptReceiverUpdate(id: String) = !destroyed && supersededReceiver != id
    private fun phoneControlMuteOffered() = MicrophoneView(state.view, muted, changing, mode).offersPhoneControlMute(
        MicrophonePermissions.denial(input.kind) { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } == null,
        phoneEnabledCapture)
    internal fun inputActionToken(): String? = state.token.takeIf {
        !destroyed && !expirePauseIfNeeded() && MicrophoneView(state.view, muted, changing, mode).canChooseInput
    }
    internal fun switchInputFromActivity(selected: MicrophoneSelection, expected: String): Boolean {
        if (inputActionToken() != expected || !MicrophoneRouting.available(this, selected) ||
            MicrophonePermissions.denial(selected.kind) { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } != null) return false
        if (mode.playback && !selected.kind.bluetooth &&
            (AppAudioSettings.load(this).needsOutputSelection(outputSelection) || !OutputDevices.available(this, outputSelection))) return false
        if (selected == input) return true
        if (state.view.phase in listOf(SessionPhase.PAUSED, SessionPhase.INTERRUPTED)) {
            input = selected
        } else {
            if (!inputChange.begin(expected, selected, android.os.SystemClock.elapsedRealtime())) return false
            if (!state.switchRoute(expected)) { inputChange.cancel(); return false }
            supersededReceiver = expected; inputSwitchActionOrigin = expected
            input = selected; changing = true
            receiver?.close(StopReason.PAUSE)
            handler.postDelayed(inputChangeTimeout, 20000)
        }
        AppAudioSettings.selectInput(this, selected)
        publish()
        return true
    }
    private val inputChangeTimeout = Runnable {
        inputChangeTimedOut = true; inputChange.cancel()
        stop(StopReason.FAILURE)
    }
    internal fun setOutputSelection(selected: OutputSelection): Boolean {
        if (expirePauseIfNeeded() || destroyed || !mode.playback || state.view.phase !in listOf(SessionPhase.PLAYING,
                SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING, SessionPhase.PAUSED, SessionPhase.INTERRUPTED) ||
            OutputPermissions.denial(selected.kind) { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } != null) return false
        val refreshed = OutputDevices.refresh(this, selected) ?: return false
        outputSelection = refreshed
        if (selected.kind == OutputKind.PHONE) protectedDefaultSpeaker = false
        AppAudioSettings.selectOutput(this, refreshed)
        // Bluetooth microphone playback stays on its coupled communication sink.
        // Keep the media choice for a later switch to a phone/wired/USB input.
        if (!input.kind.bluetooth) receiver?.setOutputSelection(refreshed)
        publish()
        return true
    }

    internal fun setMuted(value: Boolean, fromWindows: Boolean = false) {
        if (expirePauseIfNeeded()) return
        if (!MicrophoneView(state.view, muted, changing, mode).canSetMuted(value)) return
        muted = value
        AppAudioSettings.update(this) { it.afterMute(value, fromWindows) }
        if (state.view.phase in listOf(SessionPhase.PAUSED, SessionPhase.INTERRUPTED, SessionPhase.PAUSING)) {
            // Changing the retained preference cannot start capture while paused.
            changing = state.view.phase == SessionPhase.PAUSING
        } else { changing = true; receiver?.setMicrophoneMuted(value) }
        publish()
    }
    internal fun setOutputEnabled(enabled: Boolean, fromWindows: Boolean = false) {
        if (expirePauseIfNeeded() || destroyed || !mode.playback || !state.view.canSetOutput) return
        outputEnabled = enabled
        AppAudioSettings.update(this) { it.afterOutput(enabled, fromWindows) }
        if (enabled && outputFocusPause != null) resumeOutputFocus()
        receiver?.setOutputEnabled(enabled)
        publish()
    }
    private fun resumeOutputFocus() {
        val request = focus ?: return
        if (getSystemService(AudioManager::class.java).requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            mediaFocus.granted(); receiver?.setOutputFocus(null)
        }
    }
    private fun focusChanged(change: Int) {
        val id = state.token ?: return
        // Media playback is independent of the explicitly selected
        // non-Bluetooth microphone. Honor focus by silencing playback only;
        // never turn a Bluetooth handover into a duplex Stop/new peer.
        if (usesMediaOutput && receiver != null && state.view.active &&
            state.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) {
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> if (mediaFocus.gain()) receiver?.setOutputFocus(null)
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    // Repeated transient loss cannot re-arm a permanent loss.
                    mediaFocus.lose(true)
                    receiver?.setOutputFocus(outputFocusPause)
                }
                AudioManager.AUDIOFOCUS_LOSS -> {
                    mediaFocus.lose(false)
                    receiver?.setOutputFocus(outputFocusPause)
                    focus?.let { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) }
                }
            }
            return
        }
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (mediaFocus.gain()) receiver?.setOutputFocus(null)
                else if (state.focusGained()) resumeConnection(false)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                pauseForFocus(id, true, StopReason.FOCUS_TRANSIENT)
            AudioManager.AUDIOFOCUS_LOSS -> pauseForFocus(id, false, StopReason.FOCUS_PERMANENT)
        }
    }
    private fun pauseForFocus(id: String, automatic: Boolean, reason: StopReason) {
        if (mode != StreamMode.DUPLEX || !resumable || retainedLink == null) { stop(StopReason.FOCUS); return }
        if (state.view.phase == SessionPhase.PAUSED) return
        val firstPause = state.view.phase !in listOf(SessionPhase.PAUSING, SessionPhase.INTERRUPTED)
        if (!state.pause(id, automatic)) return
        inputChange.cancel(); handler.removeCallbacks(inputChangeTimeout)
        changing = receiver != null
        // Immediate sample gates, then worker-owned Stop/teardown releases SCO.
        // Never create the replacement peer until the old worker has finished.
        receiver?.close(reason)
        pauseWindow.retain(android.os.SystemClock.elapsedRealtime())
        if (firstPause) handler.postDelayed(interruptionTimeout, 5 * 60 * 1000L)
        if (!state.resumeOnFocus) releasePlaybackFocus()
        publish()
    }
    internal fun resumeFromActivity() {
        if (expirePauseIfNeeded()) return
        val id = state.token ?: return
        if (!MicrophoneView(state.view, muted, changing, mode).canResume) return
        if (state.queuePlay(id)) { publish(); return }
        resumeConnection(true)
    }
    private fun resumeConnection(userRequested: Boolean) {
        if (expirePauseIfNeeded()) return
        if (state.view.phase !in listOf(SessionPhase.PAUSED, SessionPhase.INTERRUPTED)) return
        val text = retainedLink ?: return
        try { beginConnection(text, mode, input, muted, !userRequested, resume = SessionResume.resumed(userRequested)) }
        catch (_: Exception) {
            stop(StopReason.FAILURE, "Duplex could not resume. Check microphone permission and the selected input, then tap Connect again.")
        }
    }
    private val interruptionTimeout = Runnable {
        stop(StopReason.FOCUS, "Duplex pause ended after 5 minutes. Tap Connect to start again.")
    }
    private fun expirePauseIfNeeded(): Boolean {
        if (!pauseWindow.expired(android.os.SystemClock.elapsedRealtime())) return false
        interruptionTimeout.run()
        return true
    }
    internal fun stopFromActivity() {
        stop(StopReason.USER)
    }
    private fun stop(reason: StopReason, message: String? = null) {
        val id = state.token ?: return
        if (!state.stopping(id)) return
        requestedStop = StreamEnd(reason, message ?: mode.endedMessage(reason))
        inputSwitchActionOrigin = null
        inputChange.cancel(); handler.removeCallbacks(inputChangeTimeout)
        handler.removeCallbacks(interruptionTimeout)
        pauseWindow.clear()
        retainedLink = null; resumable = false
        changing = true; muted = true
        receiver?.close(reason)
        publish()
        if (receiver == null) finish(id, StreamEnd(reason, message ?: mode.endedMessage(reason)))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (expirePauseIfNeeded()) return START_NOT_STICKY
        val id = state.token
        val requested = intent?.getStringExtra("generation")
        if (RouteActionScope.accepts(id, requested, inputSwitchActionOrigin, state.view.phase,
                intent?.action in listOf(ACTION_STOP, ACTION_MUTE))) {
            when (intent?.action) {
                ACTION_STOP -> stopFromActivity()
                ACTION_MUTE -> setMuted(true)
                ACTION_UNMUTE -> setMuted(false)
                ACTION_RESUME -> resumeFromActivity()
                ACTION_RESUME_AUDIO -> setOutputEnabled(true)
            }
        }
        if (id == null) stopSelf()
        return START_NOT_STICKY
    }
    private fun finish(id: String, end: StreamEnd) {
        if (state.token != id) return
        // The old worker may already be closing for a route change. A later
        // explicit Stop cancels replacement and owns the final app message.
        val result = requestedStop ?: end
        val switchExpired = inputChangeTimedOut || (inputChange.matches(id) && inputChange.expired(android.os.SystemClock.elapsedRealtime()))
        val nextInput = if (state.view.phase == SessionPhase.SWITCHING && result.reason != StopReason.FAILURE)
            inputChange.take(id, android.os.SystemClock.elapsedRealtime()) else null
        inputChange.cancel(); handler.removeCallbacks(inputChangeTimeout)
        val failed = result.reason == StopReason.FAILURE || switchExpired
        val pausing = state.view.phase == SessionPhase.PAUSING && !failed
        val message = if (switchExpired) "Microphone change timed out. Capture stayed stopped. Tap Connect when ready."
            else if (pausing) "Duplex paused for phone audio. " +
            (if (state.resumeOnFocus) "Will resume when focus returns (up to 5 minutes)." else "Tap Resume duplex when ready (within 5 minutes).")
            else result.message
        if (!state.finish(id, message, failed, end.diagnostics)) return
        receiver = null; changing = false
        handler.removeCallbacks(renewWakeLock)
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        if (nextInput != null && !failed && !destroyed) {
            releasePlaybackFocus()
            val text = retainedLink
            if (text != null) {
                // Windows sees a phone-initiated (automatic) resume, not a new Connect.
                try { beginConnection(text, mode, nextInput, muted, false, resume = SessionResume.INPUT_SWITCH); return }
                catch (_: Exception) {
                    // Old worker is gone; a failed new preflight ends without capture.
                    state.restorePause(id); state.stopping(id)
                    state.finish(id, "The selected input could not reconnect. Check permission and the media output, then tap Connect.", true)
                }
            }
        }
        if (pausing) {
            publish()
            if (state.playAfterPause) resumeConnection(true)
            else if (state.resumeOnFocus && state.focusReturned) resumeConnection(false)
            return
        }
        handler.removeCallbacks(interruptionTimeout)
        pauseWindow.clear()
        retainedLink = null; resumable = false; muted = true; phoneEnabledCapture = false
        outputPause = null; mediaFocus.granted(); protectedDefaultSpeaker = false
        inputSwitchActionOrigin = null
        releasePlaybackFocus()
        foregroundActive = false
        publish(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    private fun publish() {
        lastView = MicrophoneView(state.view.copy(outputEnabled = outputEnabled, outputSelection = outputSelection,
            outputPause = outputPause), muted, changing, mode, input)
        observers.toList().forEach { it(lastView) }
        state.token?.let { getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(it)) }
    }
    private fun action(id: String, name: String, request: Int): PendingIntent = PendingIntent.getService(this, request,
        Intent(this, MicrophoneService::class.java).setAction(name)
            .setData(android.net.Uri.parse("micdrop-internal://microphone/$id/${name.substringAfterLast('.')}"))
            .putExtra("generation", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    private fun notification(id: String): Notification {
        val open = PendingIntent.getActivity(this, 203, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_microphone)
            .setContentTitle(if (mode.playback) "MicDrop desktop audio + microphone" else "MicDrop microphone")
            .setContentText(when {
                state.view.phase == SessionPhase.STOPPING -> if (mode.playback) "Stopping playback and microphone" else "Stopping microphone return"
                state.view.phase == SessionPhase.SWITCHING -> "Changing audio device · audio gated"
                state.view.phase == SessionPhase.ROUTE_RECOVERING -> "Restoring selected headset · ${if (mode.playback) "audio" else "microphone"} paused"
                state.view.phase == SessionPhase.PAUSING -> "Pausing duplex for phone audio"
                state.view.phase in listOf(SessionPhase.PAUSED, SessionPhase.INTERRUPTED) -> "Duplex paused · microphone capture stopped"
                changing -> if (mode.playback) "Configuring playback and microphone" else "Configuring microphone return"
                mode.playback && outputEnabled && outputPause != null -> "Playback paused · " +
                    (if (muted) "microphone muted" else "sending ${input.kind.label}")
                muted -> if (mode.playback && outputEnabled) "Listening · microphone muted" else "Silenced · microphone capture stopped"
                else -> if (mode.playback && outputEnabled) "Listening · sending ${input.kind.label}" else "Sending ${input.kind.label} to Windows"
            }).setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
        if (MicrophoneView(state.view, muted, changing, mode).canSetMuted(!muted)) {
            val name = if (muted) ACTION_UNMUTE else ACTION_MUTE
            builder.addAction(Notification.Action.Builder(null, if (muted) "Unmute" else "Mute", action(id, name, if (muted) 204 else 205)).build())
        }
        if (MicrophoneView(state.view, muted, changing, mode).canResume)
            builder.addAction(Notification.Action.Builder(null, "Resume duplex", action(id, ACTION_RESUME, 207)).build())
        if (state.view.active && outputFocusPause == OutputPause.FOCUS_MANUAL)
            builder.addAction(Notification.Action.Builder(null, "Resume audio", action(id, ACTION_RESUME_AUDIO, 208)).build())
        builder.addAction(Notification.Action.Builder(null, "Stop", action(id, ACTION_STOP, 206)).build())
        return builder.build()
    }
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (destroyed || !state.view.busy || state.view.phase == SessionPhase.STOPPING) return
            wakeLock?.acquire(10 * 60 * 1000L)
            handler.postDelayed(this, 5 * 60 * 1000L)
        }
    }
    private fun releasePlaybackFocus() {
        focusGeneration = null
        focus?.let { runCatching { getSystemService(AudioManager::class.java).abandonAudioFocusRequest(it) } }; focus = null
        if (noisyRegistered) runCatching { unregisterReceiver(noisy) }
        noisyRegistered = false
    }
    override fun onDestroy() {
        destroyed = true; foregroundActive = false; receiver?.close(StopReason.SERVICE); receiver = null
        retainedLink = null; resumable = false
        inputChange.cancel(); handler.removeCallbacks(inputChangeTimeout)
        pauseWindow.clear()
        handler.removeCallbacks(interruptionTimeout)
        handler.removeCallbacks(renewWakeLock)
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        releasePlaybackFocus()
        if (state.view.retained) lastView = MicrophoneView(SessionView(SessionPhase.ENDED,
            mode.endedMessage(StopReason.SERVICE), state.view.diagnostics, outputEnabled = outputEnabled,
            outputSelection = outputSelection), mode = mode, input = input)
        observers.clear(); super.onDestroy()
    }
    companion object {
        private const val CHANNEL = "micdrop_microphone"
        private const val NOTIFICATION = 2002
        private const val ACTION_MUTE = "com.maskarauder.micdrop.MICROPHONE_MUTE"
        private const val ACTION_UNMUTE = "com.maskarauder.micdrop.MICROPHONE_UNMUTE"
        private const val ACTION_STOP = "com.maskarauder.micdrop.MICROPHONE_STOP"
        private const val ACTION_RESUME = "com.maskarauder.micdrop.DUPLEX_RESUME"
        private const val ACTION_RESUME_AUDIO = "com.maskarauder.micdrop.AUDIO_RESUME"
        internal var lastView = MicrophoneView()
            private set
    }
}
