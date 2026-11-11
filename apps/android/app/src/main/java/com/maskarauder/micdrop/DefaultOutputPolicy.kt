package com.maskarauder.micdrop

internal enum class OutputPause(val detail: String) {
    ROUTE("Playback paused while Android changes the media output."),
    BLUETOOTH("Playback paused to avoid the phone speaker. Connect a Bluetooth output, or choose phone speaker explicitly."),
    UNAVAILABLE("Playback paused because Android audio output is unavailable. Reconnect an output or choose it again."),
    SELECTED_BLUETOOTH("Playback paused while restoring the selected Bluetooth output (up to 20 seconds)."),
    FOCUS("Playback paused for another app. The microphone keeps its current setting."),
    FOCUS_MANUAL("Playback paused after another app took audio focus. Toggle Play desktop audio off and on to resume.")
}

// Worker and route callbacks serialize this with the receiver's audio lock.
// This hold never changes user silence, microphone consent/mute, or the peer.
internal class DefaultOutputPolicy(initial: OutputSelection, protectedSpeaker: Boolean = false) {
    private var followsDefault = !initial.explicit
    private var protectSpeaker = protectedSpeaker
    private var stopped = false
    var pause: OutputPause? = if (followsDefault) OutputPause.ROUTE else null
        private set
    val speakerProtected get() = followsDefault && protectSpeaker
    val held get() = stopped || pause != null

    // Radio shutdown can leave Android's track/prediction unavailable while
    // the last Bluetooth media port has already disappeared. Inventory only
    // explains this existing hold; it never verifies a route or releases audio.
    fun pauseForInventory(bluetoothAvailable: Boolean): OutputPause? =
        if (speakerProtected && !bluetoothAvailable &&
            (pause == OutputPause.ROUTE || pause == OutputPause.UNAVAILABLE)) OutputPause.BLUETOOTH else pause

    fun select(selection: OutputSelection, protectSpeakerOnReturn: Boolean = false) {
        if (stopped) return
        followsDefault = !selection.explicit
        // Choosing phone speaker is an explicit override. Switching back to
        // default later starts a fresh routing choice, without storing ports.
        if (selection.kind == OutputKind.PHONE) protectSpeaker = false
        if (followsDefault && protectSpeakerOnReturn) protectSpeaker = true
        pause = if (followsDefault) OutputPause.ROUTE else null
    }
    fun changing() { if (!stopped && followsDefault) pause = OutputPause.ROUTE }
    fun noisy() {
        if (!stopped && followsDefault) { protectSpeaker = true; pause = OutputPause.ROUTE }
    }
    fun unavailable() { if (!stopped && followsDefault) pause = OutputPause.UNAVAILABLE }
    fun observe(kinds: List<OutputKind>?) {
        if (stopped || !followsDefault) return
        if (kinds.isNullOrEmpty()) { pause = OutputPause.ROUTE; return }
        if (kinds.any { it.bluetooth }) protectSpeaker = true
        pause = if (protectSpeaker && OutputKind.PHONE in kinds) OutputPause.BLUETOOTH else null
    }
    fun stop() { stopped = true }
}

// Android may invalidate its AudioTrack during a Bluetooth handover. Recreate
// playout only, on the existing peer/worker, with a finite budget per device
// change. A broken output cannot trap the heartbeat in an endless retry loop.
internal class OutputRestartBudget(private val maximum: Int = 2, private val intervalMs: Long = 1000) {
    private var attempts = 0
    private var nextAt = 0L
    private var requested = false
    private var stopped = false
    fun newRoute() { if (!stopped) { attempts = 0; nextAt = 0; requested = false } }
    fun request() { if (!stopped && attempts < maximum) requested = true }
    fun settled() { requested = false }
    fun take(nowMs: Long): Boolean {
        if (stopped || !requested || attempts >= maximum || nowMs < nextAt) return false
        requested = false; attempts++; nextAt = nowMs + intervalMs
        return true
    }
    fun stop() { stopped = true; requested = false }
}

internal class MediaOutputFocus {
    var pause: OutputPause? = null
        private set
    fun lose(automatic: Boolean) {
        if (!automatic) pause = OutputPause.FOCUS_MANUAL
        else if (pause != OutputPause.FOCUS_MANUAL) pause = OutputPause.FOCUS
    }
    fun gain(): Boolean {
        if (pause != OutputPause.FOCUS) return false
        pause = null
        return true
    }
    fun granted() { pause = null }
}
