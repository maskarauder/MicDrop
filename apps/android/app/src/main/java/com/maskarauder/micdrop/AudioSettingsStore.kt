package com.maskarauder.micdrop

// The Context-free core of AppAudioSettings: `read` returns the saved fields and
// `write` applies changes (a null value removes its key).
//
// Wired, USB and other direct ports save only their kind, because port IDs are
// process-local and are never persisted. A reload of the saved fields alone
// would therefore replace a just-chosen port with an unresolvable one.
// The last saved wired/USB/other output and wired/USB input are also kept in
// process memory, from every writer (the activity, both services and Windows
// phone control). A load returns that exact port while its kind is still the
// saved kind and the port is still attached. Any other save replaces it, a kind
// change clears it, and a vanished port is forgotten, so a replugged device is
// never bound silently; a failed device query is not an unplug. Process death
// leaves only the saved kind.
internal class AudioSettingsStore(private val read: () -> Map<String, *>,
    private val write: (Map<String, Any?>) -> Unit) {
    @Volatile private var heldOutput: OutputSelection? = null
    @Volatile private var heldInput: MicrophoneSelection? = null

    fun load(): AudioPreferences = AudioPreferences.from(read())

    // Activity and notification controls update just their own preference.
    // A delayed service callback must not overwrite another control's change.
    @Synchronized fun update(change: (AudioPreferences) -> AudioPreferences): AudioPreferences {
        val previous = load()
        val next = change(previous)
        val fields = mutableMapOf<String, Any?>().apply { putAll(next.fields()) }
        if (next.preferredInputKind != previous.preferredInputKind) {
            AudioDevicePreferences.inputKeys.forEach { fields[it] = null }
            heldInput = null
        }
        if (next.preferredOutputKind != previous.preferredOutputKind) {
            AudioDevicePreferences.outputKeys.forEach { fields[it] = null }
            heldOutput = null
        }
        write(fields)
        return next
    }

    @Synchronized fun selectInput(selection: MicrophoneSelection): AudioPreferences {
        write(AudioDevicePreferences.inputFields(selection) + mapOf(
            "preferredInputKind" to selection.kind.name, "leStereo" to selection.leStereo))
        heldInput = selection.takeIf { holds(it) }
        return load()
    }

    @Synchronized fun selectOutput(selection: OutputSelection): AudioPreferences {
        write(AudioDevicePreferences.outputFields(selection) +
            ("preferredOutputKind" to selection.preferenceKind.name))
        heldOutput = selection.takeIf { holds(it) }
        return load()
    }

    // `lookup` returns the selection bound to an attached port, or null when no
    // attached port matches. It throws when Android's device list cannot be
    // read; that falls back to the saved selection and keeps the held port.
    fun input(lookup: (MicrophoneSelection) -> MicrophoneSelection?): MicrophoneSelection {
        val fields = read()
        val preferences = AudioPreferences.from(fields)
        val port = heldInput
        if (port != null && port.kind == preferences.preferredInputKind) try {
            // LE stereo is a separate saved option that Windows can edit alone.
            lookup(port.copy(leStereo = preferences.leStereo))?.let { return it }
            forgetInput(port)
        } catch (_: RuntimeException) {}
        val saved = AudioDevicePreferences.input(fields, preferences)
        return attached(saved, lookup) ?: saved
    }

    fun output(lookup: (OutputSelection) -> OutputSelection?): OutputSelection {
        val fields = read()
        val preferences = AudioPreferences.from(fields)
        val port = heldOutput
        if (port != null && port.preferenceKind == preferences.preferredOutputKind) try {
            lookup(port)?.let { return it }
            forgetOutput(port)
        } catch (_: RuntimeException) {}
        val saved = AudioDevicePreferences.output(fields, preferences)
        return attached(saved, lookup) ?: saved
    }

    private fun <T> attached(selection: T, lookup: (T) -> T?): T? =
        try { lookup(selection) } catch (_: RuntimeException) { null }

    // A newer save made during the lookup is kept.
    @Synchronized private fun forgetInput(port: MicrophoneSelection) { if (heldInput === port) heldInput = null }
    @Synchronized private fun forgetOutput(port: OutputSelection) { if (heldOutput === port) heldOutput = null }

    // Bluetooth already restores through its saved stable address; the default
    // output, phone speaker and built-in microphone need no port.
    private fun holds(selection: OutputSelection) = selection.explicit && !selection.kind.bluetooth &&
        selection.kind != OutputKind.PHONE && selection.deviceId > 0
    private fun holds(selection: MicrophoneSelection) = !selection.kind.bluetooth &&
        selection.kind != MicrophoneKind.BUILT_IN && selection.deviceId > 0
}
