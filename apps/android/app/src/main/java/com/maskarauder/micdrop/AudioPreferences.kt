package com.maskarauder.micdrop

// Preferences describe the next explicit app connection, not permission to
// start capture in the background. Private device identities are stored separately.
internal data class AudioPreferences(
    val outputEnabled: Boolean = true,
    val microphoneEnabled: Boolean = false,
    val fastRecovery: Boolean = true,
    val leStereo: Boolean = true,
    val preferredInputKind: MicrophoneKind? = MicrophoneKind.BUILT_IN,
    val preferredOutputKind: OutputKind? = OutputKind.DEFAULT,
    val echoCancellation: Boolean = false,
    val noiseReduction: Boolean = false,
    val keepMicrophoneActive: Boolean = false
) {
    val connectionMode: StreamMode get() = when {
        microphoneEnabled && outputEnabled -> StreamMode.DUPLEX
        microphoneEnabled -> StreamMode.MICROPHONE
        else -> StreamMode.PLAYBACK // Both off keeps a silent, microphone-free stream.
    }

    fun needsInputSelection(selection: MicrophoneSelection): Boolean =
        microphoneEnabled && preferredInputKind != selection.kind

    fun needsOutputSelection(selection: OutputSelection): Boolean = preferredOutputKind != selection.preferenceKind

    // A phone toggle is remembered for the next explicit Connect. Windows Unmute
    // and Play desktop audio edits last only for the running session; a Windows
    // Mute is saved like the phone's own Mute.
    fun afterMute(muted: Boolean, fromWindows: Boolean): AudioPreferences =
        if (fromWindows && !muted) this else copy(microphoneEnabled = !muted)
    fun afterOutput(enabled: Boolean, fromWindows: Boolean): AudioPreferences =
        if (fromWindows) this else copy(outputEnabled = enabled)

    fun fields(): Map<String, Any> = mapOf(
        "outputEnabled" to outputEnabled, "microphoneEnabled" to microphoneEnabled,
        "fastRecovery" to fastRecovery, "leStereo" to leStereo,
        "preferredInputKind" to (preferredInputKind?.name ?: ""),
        "preferredOutputKind" to (preferredOutputKind?.name ?: ""),
        "echoCancellation" to echoCancellation, "noiseReduction" to noiseReduction,
        "keepMicrophoneActive" to keepMicrophoneActive)

    companion object {
        fun from(fields: Map<String, *>): AudioPreferences = AudioPreferences(
            outputEnabled = fields["outputEnabled"] as? Boolean ?: true,
            microphoneEnabled = fields["microphoneEnabled"] as? Boolean ?: false,
            fastRecovery = fields["fastRecovery"] as? Boolean ?: true,
            leStereo = fields["leStereo"] as? Boolean ?: true,
            preferredInputKind = if ("preferredInputKind" !in fields) MicrophoneKind.BUILT_IN
                else MicrophoneKind.entries.firstOrNull { it.name == fields["preferredInputKind"] },
            preferredOutputKind = if ("preferredOutputKind" !in fields) OutputKind.DEFAULT
                else OutputKind.entries.firstOrNull { it.name == fields["preferredOutputKind"] },
            echoCancellation = fields["echoCancellation"] as? Boolean ?: false,
            noiseReduction = fields["noiseReduction"] as? Boolean ?: false,
            keepMicrophoneActive = fields["keepMicrophoneActive"] as? Boolean ?: false)
    }
}

// Captured at an explicit microphone Connect. Input-switch replacements and
// duplex resumes reuse it; a later edit waits for the next explicit Connect.
internal data class MicrophoneSessionOptions(val keepMicrophoneActive: Boolean = false) {
    companion object {
        fun forConnect(preferences: AudioPreferences) = MicrophoneSessionOptions(preferences.keepMicrophoneActive)
    }
}
