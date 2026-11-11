package com.maskarauder.micdrop

// StreamReceiver serializes this with its native audio lock. User silence is
// independent of a temporary route hold; verification cannot undo that silence.
internal class AudioOutputGate(enabled: Boolean = true, held: Boolean = false) {
    var enabled = enabled
        private set
    private var held = held
    private var stopped = false
    val muted get() = stopped || held || !enabled

    fun request(value: Boolean) { if (!stopped) enabled = value }
    fun hold() { held = true }
    fun verified() { held = false }
    fun stop() { stopped = true }
}
