package com.maskarauder.micdrop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.FutureCallback
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import java.util.UUID

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class PlaybackService : MediaLibraryService() {
    private val handler = Handler(Looper.getMainLooper())
    private val sessionState = SessionLifecycle(lastView)
    private val observers = mutableSetOf<(SessionView) -> Unit>()
    private val lookups = mutableSetOf<SettableFuture<String>>()
    private var playLookup: ListenableFuture<String>? = null
    private var receiver: StreamReceiver? = null
    private lateinit var player: LiveMediaPlayer
    private lateinit var mediaSession: MediaLibrarySession
    private var pending: PendingConnection? = null
    private var focus: AudioFocusRequest? = null
    private var focusGeneration: String? = null
    @Volatile private var wakeLock: PowerManager.WakeLock? = null
    private var noisyRegistered = false
    private var destroyed = false
    private var link: String? = null
    private var fast = true
    private var outputEnabled = true
    private var outputSelection = lastView.outputSelection
    private var outputPause: OutputPause? = null
    private var protectedDefaultSpeaker = false
    private var resumable = false
    private lateinit var audio: AudioManager
    private val saved get() = SavedConnections.get(applicationContext)
    private data class PendingConnection(val id: String, val text: String, val fast: Boolean,
        val baseline: OutputSnapshot?, val keepFocus: Boolean, val reconnect: Boolean, val resume: SessionResume.Reason?)

    internal inner class LocalBinder : Binder() { val service get() = this@PlaybackService }
    override fun onBind(intent: Intent?): IBinder? {
        val mediaBinder = super.onBind(intent)
        return if (intent?.action == ACTION_LOCAL_BIND) LocalBinder() else mediaBinder
    }
    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession = mediaSession
    internal fun observe(observer: (SessionView) -> Unit) { observers.add(observer); observer(shownView()) }
    internal fun removeObserver(observer: (SessionView) -> Unit) { observers.remove(observer) }
    internal fun outputActionToken(): String? = sessionState.token.takeIf {
        !destroyed && sessionState.view.retained && sessionState.view.phase != SessionPhase.STOPPING
    }
    internal fun stopFromActivity() { sessionState.token?.let { stopSession(it, StopReason.USER) } }
    internal fun pauseFromActivity() { sessionState.token?.let { pauseSession(it, false, StopReason.PAUSE) } }
    internal fun setOutputEnabled(enabled: Boolean, fromWindows: Boolean = false) {
        if (destroyed || !sessionState.view.canSetOutput) return
        outputEnabled = enabled
        AppAudioSettings.update(this) { it.afterOutput(enabled, fromWindows) }
        receiver?.setOutputEnabled(enabled)
        publish()
    }
    internal fun setOutputSelection(selected: OutputSelection): Boolean {
        if (destroyed || sessionState.view.phase !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING,
                SessionPhase.PAUSED, SessionPhase.INTERRUPTED)) return false
        val refreshed = OutputDevices.refresh(this, selected) ?: return false
        outputSelection = refreshed
        if (selected.kind == OutputKind.PHONE) protectedDefaultSpeaker = false
        if (selected.explicit) outputPause = null
        AppAudioSettings.selectOutput(this, refreshed)
        record("output_selected_${selected.kind.name.lowercase()}")
        receiver?.setOutputSelection(refreshed)
        publish()
        return true
    }

    override fun onCreate() {
        super.onCreate()
        audio = getSystemService(AudioManager::class.java)
        outputEnabled = AppAudioSettings.load(this).outputEnabled
        if (!outputSelection.explicit) outputSelection = AppAudioSettings.output(this)
        // Allow cleanup a short foreground grace period after local mute. The
        // paused MediaSession/card survives this; no idle wake lock is retained.
        setForegroundServiceTimeoutMs(5000)
        setShowNotificationForIdlePlayer(SHOW_NOTIFICATION_FOR_IDLE_PLAYER_NEVER)
        val provider = DefaultMediaNotificationProvider.Builder(this)
            .setNotificationId(PausedPlayback.NOTIFICATION).setChannelId(PausedPlayback.CHANNEL)
            .setChannelName(R.string.playback_channel).build()
        provider.setSmallIcon(R.drawable.ic_playback)
        setMediaNotificationProvider(provider)
        player = LiveMediaPlayer(::playFromMediaControls, ::pauseFromActivity, ::stopFromActivity)
        mediaSession = MediaLibrarySession.Builder(this, player, PlaybackLibraryCallback(this))
            .setSessionActivity(PausedPlayback.open(this))
            .setMediaButtonPreferences(PlaybackLibraryCallback.buttons)
            .setShowPlayButtonIfPlaybackIsSuppressed(false).build()
        addSession(mediaSession)
        setListener(object : MediaSessionService.Listener {
            override fun onForegroundServiceStartNotAllowedException() {
                record("foreground_start_denied")
                sessionState.token?.let { stopSession(it, StopReason.FAILURE) }
            }
        })
        PausedPlayback.ticket(this)?.let { sessionState.restorePause(it.id) }
        publish()
    }

    // No exported raw-link Connect intent. The activity uses its in-process
    // binder; external controllers are authenticated by Media3's callback.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        return START_NOT_STICKY
    }

    override fun onUpdateNotificationAsync(session: MediaSession, startInForegroundRequired: Boolean): ListenableFuture<Void?> {
        val updated = super.onUpdateNotificationAsync(session, startInForegroundRequired)
        // Media3 completes this after promotion. Never request focus/start the
        // audio module while still a background-only service (Android 15/17).
        Futures.addCallback(updated, object : FutureCallback<Void?> {
            override fun onSuccess(result: Void?) {
                if (destroyed || !startInForegroundRequired) return
                val next = pending ?: return
                if (sessionState.token != next.id || sessionState.view.phase != SessionPhase.CONNECTING) return
                pending = null; handler.removeCallbacks(startTimeout)
                startTransport(next)
            }
            override fun onFailure(error: Throwable) {
                if (!destroyed) pending?.let { finish(it.id, "Android could not start background playback. Open MicDrop and try Play.", true) }
            }
        }, mainExecutor)
        return updated
    }

    internal fun connectFromActivity(text: String, fastRecovery: Boolean, baseline: OutputSnapshot?, reconnect: Boolean,
        enabledOutput: Boolean = true, selectedOutput: OutputSelection = outputSelection) {
        if (sessionState.view.busy) return
        outputPause = null; protectedDefaultSpeaker = false
        record("app_connect")
        beginConnection(text, fastRecovery, baseline, false, reconnect, enabledOutput, selectedOutput)
    }

    private fun beginConnection(text: String, fastRecovery: Boolean, baseline: OutputSnapshot?, keepFocus: Boolean, reconnect: Boolean,
        enabledOutput: Boolean = outputEnabled, selectedOutput: OutputSelection = outputSelection, resume: SessionResume.Reason? = null) {
        // A retained playback card or delayed saved-link lookup cannot compete
        // with an explicit microphone/duplex session for focus or the audio ADM.
        if (MicrophoneService.lastView.ownsSession) return
        val id = UUID.randomUUID().toString()
        if (!sessionState.begin(id, "")) return
        link = null; resumable = false
        try {
            val invitation = LanInvitation.parse(text)
            require(!invitation.expired())
            outputSelection = selectedOutput
            outputPause = if (selectedOutput.explicit) null else OutputPause.ROUTE
            OutputPermissions.denial(outputSelection.kind) { checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED }?.let {
                finish(id, it, true); return
            }
            if (AppAudioSettings.load(this).needsOutputSelection(outputSelection) || !OutputDevices.available(this, outputSelection)) {
                finish(id, getString(R.string.output_reselect), true)
                return
            }
            outputSelection = OutputDevices.refresh(this, outputSelection) ?: run {
                finish(id, getString(R.string.output_reselect), true); return
            }
            PausedPlayback.clear(this)
            link = text.trim(); fast = fastRecovery
            outputEnabled = enabledOutput
            sessionState.setDestination(id, "Windows: ${invitation.host}:${invitation.port}")
            pending = PendingConnection(id, text, fastRecovery, baseline, keepFocus, reconnect, resume)
            handler.removeCallbacks(startTimeout); handler.postDelayed(startTimeout, 10000)
            publish()
            triggerNotificationUpdate()
        } catch (_: Exception) {
            finish(id, "The Windows connection is unavailable or expired. Paste its current link.", true)
        }
    }

    private fun startTransport(connection: PendingConnection) {
        val id = connection.id
        try {
            val invitation = LanInvitation.parse(connection.text)
            require(!invitation.expired())
            if (!connection.keepFocus) {
                abandonFocus()
                val generation = UUID.randomUUID().toString()
                focusGeneration = generation
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(PlaybackEnvironment.attributes())
                    .setOnAudioFocusChangeListener({ change ->
                        if (!destroyed && focusGeneration == generation) focusChanged(change)
                    }, handler).build()
                focus = request
                if (audio.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                    record("focus_request_denied"); finish(id, getString(R.string.focus_denied), true); return
                }
            }
            if (!noisyRegistered) {
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                if (Build.VERSION.SDK_INT >= 33) registerReceiver(noisy, filter, RECEIVER_NOT_EXPORTED) else registerReceiver(noisy, filter)
                noisyRegistered = true
            }
            if (wakeLock == null) wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MicDrop:playback").apply { setReferenceCounted(false) }
            handler.removeCallbacks(renewWakeLock); renewWakeLock.run()
            var remembered = false
            receiver = StreamReceiver(applicationContext, invitation, connection.fast, connection.baseline,
                { message -> handler.post { if (!destroyed && sessionState.update(id, message = message)) publish() } },
                { report -> handler.post { if (!destroyed && sessionState.update(id, diagnostics = report)) publish() } },
                { phase -> handler.post {
                    if (!destroyed && sessionState.update(id, phase = phase)) {
                        if (phase == SessionPhase.PLAYING && !remembered) {
                            remembered = true; resumable = invitation.version >= 2
                            saved.remember(connection.text)
                            if (resumable) saveTicket(id)
                            record("stream_playing")
                        }
                        publish()
                    }
                } },
                { end -> handler.post { if (!destroyed) finish(id, end.message, end.reason == StopReason.FAILURE, end.diagnostics) } }, connection.reconnect,
                resume = connection.resume,
                phoneControlBinding = PhoneControlBinding(current = {
                    if (destroyed || sessionState.token != id || !sessionState.view.active ||
                        sessionState.view.phase in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) null
                    else PhoneLiveSettings(AudioManager.STREAM_MUSIC, outputEnabled = outputEnabled,
                        output = outputSelection, outputLive = true)
                }, apply = { changes ->
                    (changes["live.output_enabled"] as? Boolean)?.let { setOutputEnabled(it, fromWindows = true); check(outputEnabled == it) }
                }, changed = { publish() }, applyOutput = { selected ->
                    // Windows never prompts: a missing Nearby devices permission rejects.
                    check(PhoneOutputControl.accepts(sessionState.view.phase, selected.kind) {
                        checkSelfPermission(it) == android.content.pm.PackageManager.PERMISSION_GRANTED
                    } && setOutputSelection(selected) && outputSelection.sameEndpoint(selected))
                }),
                initiallyOutputEnabled = outputEnabled,
                outputSelection = outputSelection,
                onOutputSelection = { selected -> handler.post {
                    if (!destroyed && sessionState.token == id && sessionState.view.active &&
                        sessionState.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING) &&
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
                onOutputState = { pause, protectedSpeaker -> handler.post {
                    if (!destroyed && sessionState.token == id && sessionState.view.active &&
                        receiver?.matchesOutputState(pause, protectedSpeaker) == true &&
                        sessionState.view.phase !in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) {
                        outputPause = pause; protectedDefaultSpeaker = protectedSpeaker; publish()
                    }
                } },
                wakeLockHeld = { wakeLock?.isHeld ?: false }, foregroundTypes = { foregroundServiceType },
                onNetworkStatus = { message -> handler.post {
                    if (!destroyed && sessionState.update(id, networkStatus = message)) publish()
                } })
            publish(); receiver?.start()
        } catch (_: Exception) {
            finish(id, "Playback could not start. Open MicDrop and check the Windows link.", true)
        }
    }

    internal fun currentMediaItem(): MediaItem? = sessionState.token?.takeIf {
        MediaPresentation.of(sessionState.view.phase, sessionState.resumeOnFocus, sessionState.playAfterPause).visible
    }?.let { LiveMediaPlayer.liveItem(it) }

    // Used by System UI's recent-media browser and playback resumption. Looking
    // up metadata never starts foreground work, requests focus or connects.
    internal fun resumptionItem(): ListenableFuture<MediaItem> {
        val ticket = PausedPlayback.ticket(this)
            ?: return Futures.immediateFailedFuture(IllegalStateException("No resumable connection."))
        return Futures.transform(loadSaved(ticket), { LiveMediaPlayer.liveItem(ticket.id) }, mainExecutor)
    }

    private fun loadSaved(ticket: ResumeTicket): ListenableFuture<String> {
        val result = SettableFuture.create<String>()
        lookups.add(result)
        lateinit var observer: (SavedConnectionView) -> Unit
        val timeout = Runnable { result.setException(IllegalStateException("Saved connection could not be loaded.")) }
        observer = observer@{ state ->
            if (state.working || result.isDone) return@observer
            // connection() can publish an expiry update. Unsubscribe first.
            saved.removeObserver(observer)
            val text = saved.connection()
            if (destroyed || PausedPlayback.ticket(this)?.id != ticket.id || text == null || !ticket.matches(text))
                result.setException(IllegalStateException("The saved connection expired, changed or was forgotten."))
            else result.set(text)
        }
        result.addListener({ saved.removeObserver(observer); handler.removeCallbacks(timeout); lookups.remove(result) }, mainExecutor)
        handler.postDelayed(timeout, 10000)
        saved.observe(observer)
        return result
    }

    internal fun playFromMediaControls() {
        if (MicrophoneService.lastView.ownsSession) return
        val id = sessionState.token ?: return
        record("media_play")
        if (sessionState.queuePlay(id)) {
            handler.removeCallbacks(interruptionTimeout)
            publish(); return
        }
        if (sessionState.view.phase == SessionPhase.INTERRUPTED) { resumeInterrupted(true); return }
        if (sessionState.view.phase != SessionPhase.PAUSED) return
        val ticket = PausedPlayback.ticket(this) ?: run {
            stopSession(id, StopReason.FAILURE); return
        }
        if (playLookup != null) return
        val loading = loadSaved(ticket)
        playLookup = loading
        Futures.addCallback(loading, object : FutureCallback<String> {
            override fun onSuccess(text: String?) {
                if (playLookup === loading) playLookup = null
                if (!destroyed && sessionState.token == id && sessionState.view.phase == SessionPhase.PAUSED && text != null)
                    beginConnection(text, ticket.fast, null, false, true, resume = SessionResume.Reason.MANUAL)
            }
            override fun onFailure(error: Throwable) {
                if (playLookup === loading) playLookup = null
                if (error !is java.util.concurrent.CancellationException && !destroyed && sessionState.token == id && sessionState.view.phase == SessionPhase.PAUSED)
                    stopSession(id, StopReason.FAILURE)
            }
        }, mainExecutor)
    }

    private fun focusChanged(change: Int) {
        val id = sessionState.token ?: return
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                record("focus_gain")
                if (sessionState.focusGained()) resumeInterrupted(false) else publish()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                record(if (change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) "focus_loss_transient" else "focus_loss_transient_can_duck")
                pauseSession(id, true, StopReason.FOCUS_TRANSIENT)
            }
            AudioManager.AUDIOFOCUS_LOSS -> { record("focus_loss_permanent"); pauseSession(id, false, StopReason.FOCUS_PERMANENT) }
        }
    }

    private fun pauseSession(id: String, automatic: Boolean, reason: StopReason) {
        if (sessionState.token != id) return
        if (sessionState.view.phase == SessionPhase.PAUSED) { cancelLookups(); return }
        if (!resumable || link == null) { stopSession(id, reason); return }
        val wasWaiting = sessionState.resumeOnFocus
        if (!sessionState.pause(id, automatic)) return
        record(if (automatic) "automatic_resume_armed" else "manual_pause")
        receiver?.close(reason) // mute locally before publishing Play
        if (sessionState.resumeOnFocus && !wasWaiting) handler.postDelayed(interruptionTimeout, 5 * 60 * 1000L)
        if (!sessionState.resumeOnFocus) {
            handler.removeCallbacks(interruptionTimeout)
            abandonFocus()
        }
        publish()
        if (receiver == null) completePause(id)
    }

    private fun resumeInterrupted(userRequested: Boolean) {
        if (sessionState.view.phase != SessionPhase.INTERRUPTED) return
        val text = link ?: return
        record(if (userRequested) "manual_resume" else "focus_resume")
        handler.removeCallbacks(interruptionTimeout)
        beginConnection(text, fast, null, !userRequested, true, resume = SessionResume.resumed(userRequested))
    }

    private fun stopSession(id: String, reason: StopReason) {
        if (!sessionState.stopping(id)) return
        record("stop_${reason.wire}")
        pending = null; cancelLookups(); handler.removeCallbacks(interruptionTimeout); handler.removeCallbacks(startTimeout)
        PausedPlayback.clear(this)
        receiver?.close(reason)
        publish()
        if (receiver == null) finish(id, reason.message, reason == StopReason.FAILURE)
    }

    private fun finish(id: String, message: String, failed: Boolean = false, diagnostics: String? = null) {
        val pausing = sessionState.view.phase == SessionPhase.PAUSING && !failed
        val result = if (pausing) sessionState.view.message + message.substringAfter('\n', "").let { if (it.isEmpty()) "" else "\n$it" } else message
        if (!sessionState.finish(id, result, failed, diagnostics)) return
        receiver = null; pending = null; handler.removeCallbacks(startTimeout)
        record(if (failed) "stream_failed" else "stream_closed")
        if (pausing) { completePause(id); return }
        releaseTransport(); link = null; resumable = false
        PausedPlayback.clear(this)
        publish(); triggerNotificationUpdate(); stopSelf()
    }

    private fun completePause(id: String) {
        if (sessionState.view.phase == SessionPhase.INTERRUPTED) {
            publish()
            if (sessionState.focusReturned) resumeInterrupted(false)
            return
        }
        if (sessionState.view.phase != SessionPhase.PAUSED) return
        val text = link ?: return
        val recovery = fast
        saveTicket(id)
        val queued = sessionState.playAfterPause
        releaseTransport(); link = null; resumable = false
        if (queued) beginConnection(text, recovery, null, false, true, resume = SessionResume.Reason.MANUAL)
        else publish() // Retain the same MediaSession, playlist and MediaStyle card.
    }

    private fun saveTicket(id: String) {
        link?.let { PausedPlayback.save(this, ResumeTicket(id, ResumeTicket.fingerprint(it), fast)) }
    }
    private val interruptionTimeout = Runnable {
        record("focus_resume_timeout")
        sessionState.token?.let { pauseSession(it, false, StopReason.FOCUS_TRANSIENT) }
    }
    private val startTimeout = Runnable {
        pending?.let { finish(it.id, "Android did not make playback ready. Open MicDrop and try Reconnect.", true) }
    }
    private fun cancelLookups() { playLookup = null; lookups.toList().forEach { it.cancel(false) } }
    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && receiver?.mediaOutputBecomingNoisy() == true) {
                record("media_output_checking")
                return
            }
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && !outputSelection.explicit && sessionState.view.retained) {
                protectedDefaultSpeaker = true
                receiver?.mediaOutputBecomingNoisy()
                record("default_output_waiting")
                return
            }
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && outputSelection.kind == OutputKind.PHONE) return
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY && receiver?.outputSwitchPending() != true) {
                // A requested change is already gated and verifies its target;
                // transition noise must not cancel it as an unexpected removal.
                record("output_disconnected")
                sessionState.token?.let { stopSession(it, StopReason.OUTPUT) }
            }
        }
    }
    private val renewWakeLock = object : Runnable {
        override fun run() {
            if (destroyed || !sessionState.view.busy || sessionState.view.phase == SessionPhase.STOPPING) return
            wakeLock?.acquire(10 * 60 * 1000L)
            handler.postDelayed(this, 5 * 60 * 1000L)
        }
    }
    private fun abandonFocus() {
        focusGeneration = null
        focus?.let { audio.abandonAudioFocusRequest(it) }; focus = null
    }
    private fun releaseTransport() {
        cancelLookups(); handler.removeCallbacks(interruptionTimeout); handler.removeCallbacks(renewWakeLock)
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        if (noisyRegistered) { unregisterReceiver(noisy); noisyRegistered = false }
        abandonFocus()
    }
    private fun record(event: String) {
        controls.addLast("${SystemClock.elapsedRealtime()} ms: $event")
        while (controls.size > 32) controls.removeFirst()
    }
    private fun shownView(): SessionView = sessionState.view.copy(outputEnabled = outputEnabled, outputSelection = outputSelection,
        outputPause = outputPause, diagnostics =
        listOfNotNull(sessionState.view.diagnostics, controls.takeIf { it.isNotEmpty() }?.joinToString("\n", "Recent controls (phone uptime):\n"))
            .takeIf { it.isNotEmpty() }?.joinToString("\n"))
    private fun publish() {
        val view = shownView()
        lastView = view
        observers.toList().forEach { it(view) }
        player.update(view, sessionState.token, sessionState.resumeOnFocus, sessionState.playAfterPause)
    }
    override fun onTaskRemoved(rootIntent: Intent?) {
        // A transient interruption still has explicit bounded playback intent.
        if (!sessionState.view.busy) super.onTaskRemoved(rootIntent)
    }
    override fun onDestroy() {
        destroyed = true
        if (sessionState.view.busy) sessionState.token?.let { id ->
            receiver?.close(StopReason.SERVICE); sessionState.stopping(id)
            sessionState.finish(id, "Playback service ended. Use Reconnect after Windows finishes the stream.")
        }
        receiver = null; pending = null; link = null
        handler.removeCallbacksAndMessages(null)
        releaseTransport(); lastView = sessionState.view.copy(outputEnabled = outputEnabled, outputSelection = outputSelection); observers.clear()
        mediaSession.release(); player.release()
        super.onDestroy()
    }
    companion object {
        internal const val ACTION_LOCAL_BIND = "com.maskarauder.micdrop.LOCAL_BIND"
        private val controls = java.util.ArrayDeque<String>()
        internal var lastView = SessionView()
            private set
    }
}
