package com.maskarauder.micdrop

internal enum class SessionPhase(val label: String) {
    IDLE("Ready"), CONNECTING("Connecting"), PLAYING("Playing"),
    RECOVERING("Recovering connection"), ROUTE_RECOVERING("Restoring selected headset"), PAUSING("Pausing"), PAUSED("Paused"),
    INTERRUPTED("Waiting for audio focus"), SWITCHING("Changing audio device"), STOPPING("Stopping"), ENDED("Stopped")
}

internal enum class StopReason(val wire: String, val message: String) {
    USER("user_stop", "Stopped."),
    PAUSE("user_pause", "Paused."),
    FOCUS("focus_loss", "Stopped after audio focus changed. Use Reconnect when ready."),
    FOCUS_TRANSIENT("focus_loss_transient", "Temporarily interrupted by audio focus."),
    FOCUS_PERMANENT("focus_loss_permanent", "Another app took audio focus. Tap Play to resume."),
    OUTPUT("output_lost", "Stopped because the audio output was disconnected. Choose an output and reconnect."),
    SERVICE("service_stopped", "Playback service stopped. Use Reconnect when ready."),
    FAILURE("connection_failed", "Connection ended. Use Reconnect when ready.");

    fun wireFor(lifecycleVersion: Int): String = if (lifecycleVersion >= 2) wire else when (this) {
        PAUSE -> USER.wire
        FOCUS_TRANSIENT, FOCUS_PERMANENT -> FOCUS.wire
        else -> wire
    }
}

internal data class StreamEnd(val reason: StopReason, val message: String, val diagnostics: String? = null)

internal data class SessionView(val phase: SessionPhase = SessionPhase.IDLE,
    val message: String = "Ready. Choose your output in Android’s media controls.",
    val diagnostics: String? = null, val destination: String = "", val failureId: String? = null,
    val outputEnabled: Boolean = true, val outputSelection: OutputSelection = OutputSelection(),
    val outputPause: OutputPause? = null, val networkStatus: String = "") {
    val active: Boolean get() = phase in listOf(SessionPhase.CONNECTING, SessionPhase.PLAYING,
        SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING, SessionPhase.SWITCHING, SessionPhase.PAUSING, SessionPhase.STOPPING)
    val busy: Boolean get() = active || phase == SessionPhase.INTERRUPTED
    val retained: Boolean get() = busy || phase == SessionPhase.PAUSED
    val canSetOutput: Boolean get() = retained && phase != SessionPhase.STOPPING
    val outputPaused: Boolean get() = outputEnabled && outputPause != null
    // Speaker fallback is a temporary hold, not a change to the user's audio
    // request. Only an explicit choice on a live default-output session may
    // override it; a stale button cannot resume a stopped or paused session.
    val canUsePhoneSpeaker: Boolean get() = outputEnabled && !outputSelection.explicit &&
        outputPause == OutputPause.BLUETOOTH && phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING)
    val canFollowAndroidOutput: Boolean get() = outputEnabled && outputSelection.kind == OutputKind.PHONE &&
        phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING)
}

// Main-thread state shared by the service, activity and notification controls.
// A per-session nonce rejects delayed callbacks and old notification actions.
internal class SessionLifecycle(initial: SessionView = SessionView()) {
    var view = initial
        private set
    var token: String? = null
        private set
    var resumeOnFocus = false
        private set
    var focusReturned = false
        private set
    var playAfterPause = false
        private set
    fun begin(id: String, destination: String): Boolean {
        if (view.active) return false
        resumeOnFocus = false; focusReturned = false; playAfterPause = false
        token = id; view = SessionView(SessionPhase.CONNECTING, "Connecting securely to Windows…", destination = destination)
        return true
    }
    fun update(id: String, phase: SessionPhase? = null, message: String? = null, diagnostics: String? = null,
        networkStatus: String? = null): Boolean {
        if (token != id || !view.active || view.phase in listOf(SessionPhase.STOPPING, SessionPhase.PAUSING)) return false
        view = view.copy(phase = phase ?: view.phase, message = message ?: view.message,
            diagnostics = diagnostics ?: view.diagnostics, networkStatus = networkStatus ?: view.networkStatus)
        return true
    }
    fun setDestination(id: String, destination: String) {
        if (token == id) view = view.copy(destination = destination)
    }
    fun switchRoute(id: String): Boolean {
        if (token != id || view.phase !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)) return false
        resumeOnFocus = false; focusReturned = false; playAfterPause = false
        view = view.copy(phase = SessionPhase.SWITCHING, message = "Changing microphone. Finishing the current stream before reconnecting…")
        return true
    }
    fun stopping(id: String): Boolean {
        if (token != id || !view.retained || view.phase == SessionPhase.STOPPING) return false
        resumeOnFocus = false; focusReturned = false; playAfterPause = false
        view = view.copy(phase = SessionPhase.STOPPING, message = "Stopping locally and notifying Windows…")
        return true
    }
    fun finish(id: String, message: String, failed: Boolean = false, diagnostics: String? = null): Boolean {
        if (token != id || !view.active) return false
        view = view.copy(diagnostics = diagnostics ?: view.diagnostics)
        if (view.phase == SessionPhase.PAUSING && !failed) {
            view = view.copy(phase = if (resumeOnFocus) SessionPhase.INTERRUPTED else SessionPhase.PAUSED, message = message)
        } else {
            view = view.copy(phase = SessionPhase.ENDED, message = message, failureId = if (failed) id else null)
            token = null; resumeOnFocus = false; focusReturned = false; playAfterPause = false
        }
        return true
    }

    fun pause(id: String, automatic: Boolean): Boolean {
        if (token != id || !view.busy || view.phase == SessionPhase.STOPPING) return false
        playAfterPause = false
        // Repeated loss cannot re-arm resume after a user Pause/permanent loss.
        if (view.phase != SessionPhase.PAUSING && view.phase != SessionPhase.INTERRUPTED) {
            resumeOnFocus = automatic; focusReturned = false
        } else if (!automatic) { resumeOnFocus = false; focusReturned = false }
        else { focusReturned = false }
        view = view.copy(phase = if (view.phase == SessionPhase.INTERRUPTED && !automatic)
            SessionPhase.PAUSED else if (view.phase == SessionPhase.INTERRUPTED) SessionPhase.INTERRUPTED else SessionPhase.PAUSING,
            message = if (resumeOnFocus) "Interrupted. Will resume when Android returns audio focus (up to 5 minutes)."
                else "Paused. Play reconnects to live audio.")
        return true
    }

    // Gain may arrive while /stop or native disposal is still running. Defer
    // reconnect until finish so two peers never share the audio module.
    fun focusGained(): Boolean {
        if (!resumeOnFocus) return false
        focusReturned = true
        return view.phase == SessionPhase.INTERRUPTED
    }

    fun restorePause(id: String) {
        if (view.busy) return
        token = id; resumeOnFocus = false; focusReturned = false; playAfterPause = false
        view = view.copy(phase = SessionPhase.PAUSED, message = "Paused. Play reconnects to live audio.", failureId = null)
    }

    fun queuePlay(id: String): Boolean {
        if (token != id || view.phase != SessionPhase.PAUSING) return false
        playAfterPause = true; resumeOnFocus = false; focusReturned = false
        view = view.copy(message = "Play requested. Finishing the previous stream before reconnecting…")
        return true
    }
}

// Presentation changes at local mute, independently of slow network/JNI cleanup.
internal data class MediaPresentation(val visible: Boolean, val playWhenReady: Boolean,
    val buffering: Boolean, val suppressed: Boolean) {
    companion object {
        fun of(phase: SessionPhase, automatic: Boolean, queued: Boolean): MediaPresentation {
            val visible = phase !in listOf(SessionPhase.IDLE, SessionPhase.ENDED, SessionPhase.STOPPING)
            val interrupted = automatic && phase in listOf(SessionPhase.PAUSING, SessionPhase.INTERRUPTED)
            val playing = phase in listOf(SessionPhase.CONNECTING, SessionPhase.PLAYING, SessionPhase.RECOVERING,
                SessionPhase.ROUTE_RECOVERING, SessionPhase.SWITCHING) || interrupted || queued
            return MediaPresentation(visible, visible && playing,
                phase in listOf(SessionPhase.CONNECTING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING, SessionPhase.SWITCHING) || queued, interrupted)
        }
    }
}

internal object SessionShutdown {
    // Caller has already muted local output. Remote notification must precede
    // peer destruction so a normal Stop does not race the host's ICE watchdog.
    fun complete(notifyRemote: () -> Boolean, releaseMedia: () -> Unit): Boolean {
        var acknowledged = false
        try { acknowledged = notifyRemote() } catch (_: Exception) { }
        finally { releaseMedia() }
        return acknowledged
    }
}
