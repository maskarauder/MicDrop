package com.maskarauder.micdrop

// Only a visible activity can select a microphone mode. Media resumption keeps
// the default playback mode, and a fresh offer must confirm the exact direction.
internal enum class StreamMode(val microphone: Boolean, val playback: Boolean, val direction: String) {
    PLAYBACK(false, true, "desktop_playback"),
    MICROPHONE(true, false, "phone_microphone"),
    DUPLEX(true, true, "duplex");

    // Phone/wired/USB microphone capture is independent of media playback.
    // A Bluetooth microphone instead owns a coupled communication route.
    fun usesMediaOutput(input: MicrophoneKind): Boolean = playback && (!microphone || !input.bluetooth)

    val reconnectAction: String get() = when (this) {
        PLAYBACK -> "Reconnect"
        MICROPHONE, DUPLEX -> "Connect"
    }

    fun endedMessage(reason: StopReason): String {
        if (!microphone) return reason.message
        val detail = when (reason) {
            StopReason.FOCUS -> "Stopped after audio focus changed."
            StopReason.OUTPUT -> "Stopped because the audio output was disconnected. Choose an output."
            StopReason.SERVICE -> "Microphone service stopped."
            StopReason.FAILURE -> "Connection ended."
            else -> return reason.message
        }
        return "$detail Tap $reconnectAction when ready."
    }

    fun offerFields(version: Int): Map<String, Int> {
        require(!microphone || version == 3)
        return linkedMapOf("version" to version).apply {
            if (microphone) put("microphone_return_version", 1)
            if (this@StreamMode == DUPLEX) put("duplex_version", 1)
        }
    }

    fun acceptsOffer(microphoneVersion: Int, duplexVersion: Int, actualDirection: String): Boolean = when (this) {
        PLAYBACK -> microphoneVersion == 0 && duplexVersion == 0 && actualDirection in listOf("", direction)
        MICROPHONE -> microphoneVersion == 1 && duplexVersion == 0 && actualDirection == direction
        DUPLEX -> microphoneVersion == 1 && duplexVersion == 1 && actualDirection == direction
    }
}
