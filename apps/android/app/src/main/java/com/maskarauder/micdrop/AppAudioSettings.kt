package com.maskarauder.micdrop

import android.content.Context

// One store per process, so its in-memory wired/USB port (see AudioSettingsStore)
// is shared by the activity, both services and Windows phone control.
internal object AppAudioSettings {
    @Volatile private var opened: AudioSettingsStore? = null

    private fun store(context: Context): AudioSettingsStore = opened ?: synchronized(this) {
        opened ?: open(context.applicationContext ?: context).also { opened = it }
    }

    private fun open(context: Context): AudioSettingsStore {
        val preferences = context.getSharedPreferences("audio-settings", Context.MODE_PRIVATE)
        return AudioSettingsStore({ preferences.all }) { fields ->
            val editor = preferences.edit()
            fields.forEach { (key, value) -> when (value) {
                null -> editor.remove(key)
                is Boolean -> editor.putBoolean(key, value)
                is Int -> editor.putInt(key, value)
                is String -> editor.putString(key, value)
            } }
            editor.apply() // Kind/profile/identity change together, including removal.
        }
    }

    fun load(context: Context): AudioPreferences = store(context).load()

    fun update(context: Context, change: (AudioPreferences) -> AudioPreferences): AudioPreferences =
        store(context).update(change)

    fun selectInput(context: Context, selection: MicrophoneSelection): AudioPreferences =
        store(context).selectInput(selection)

    fun selectOutput(context: Context, selection: OutputSelection): AudioPreferences =
        store(context).selectOutput(selection)

    fun input(context: Context): MicrophoneSelection = store(context).input { MicrophoneRouting.lookup(context, it) }

    fun output(context: Context): OutputSelection = store(context).output { OutputDevices.lookup(context, it) }
}
