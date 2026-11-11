package com.maskarauder.micdrop

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

internal object AppPhoneControlSettings {
    fun enabled(context: Context) = context.getSharedPreferences("phone-control", Context.MODE_PRIVATE)
        .getBoolean("allowWindows", false)
    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences("phone-control", Context.MODE_PRIVATE).edit()
            .putBoolean("allowWindows", enabled).apply()
    }
}

internal data class PhoneLiveSettings(val volumeStream: Int, val outputEnabled: Boolean? = null,
    val microphoneMuted: Boolean? = null, val output: OutputSelection? = null, val outputLive: Boolean = false)
internal class PhoneControlBinding(val current: () -> PhoneLiveSettings?,
    val apply: (Map<String, Any>) -> Unit, val changed: () -> Unit,
    val applyOutput: ((OutputSelection) -> Unit)? = null)
internal enum class OutputRoute { NONE, LIVE, SAVE }

// A Windows media-output choice uses the session's own verified switch. A
// Bluetooth headset microphone keeps its coupled route, so its media choice
// waits for a switch to a phone, wired or USB microphone; microphone-only
// sessions save it for the next Connect. Windows never prompts for permission.
internal object PhoneOutputControl {
    fun session(mode: StreamMode, selection: OutputSelection): OutputSelection? = selection.takeIf { mode.playback }
    fun live(mode: StreamMode, input: MicrophoneKind): Boolean = mode.usesMediaOutput(input)
    fun effect(live: PhoneLiveSettings?): String =
        if (live != null && live.output != null && live.outputLive) "live" else "next_connection"
    fun value(live: PhoneLiveSettings?, saved: OutputSelection): OutputSelection = live?.output ?: saved
    // LIVE also covers a headset-microphone duplex session, whose switch holds the choice.
    fun route(live: PhoneLiveSettings, chosen: OutputSelection?): OutputRoute = when {
        chosen == null || chosen == live.output -> OutputRoute.NONE
        live.output != null -> OutputRoute.LIVE
        else -> OutputRoute.SAVE
    }
    fun unlisted(live: PhoneLiveSettings?, kind: OutputKind, available: Boolean): String = kind.label + when {
        live == null || live.output == null -> if (available) " (saved)" else " (saved; unavailable)"
        live.outputLive -> " (in use)"
        else -> " (after headset mic)"
    }
    fun accepts(phase: SessionPhase, kind: OutputKind, granted: (String) -> Boolean): Boolean =
        phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING) &&
            OutputPermissions.denial(kind, granted) == null
}

// A receiver may poll this adapter only while its existing control connection is
// alive. It creates no background service or network connection of its own.
internal class AppPhoneControl(private val context: Context, private val binding: PhoneControlBinding,
    private val closed: () -> Boolean) {
    private val handler = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    private val session = PhoneControlSession()
    private val salt = UUID.randomUUID().toString()
    private var inputs = emptyMap<String, MicrophoneSelection>()
    private var outputs = emptyMap<String, OutputSelection>()
    private var lastSnapshotKey = ""
    private var lastSnapshotAt = 0L

    private fun <T> onMain(action: () -> T): T? {
        if (closed()) return null
        val task = FutureTask<T> { if (closed()) throw IllegalStateException("Session ended"); action() }
        handler.post(task)
        return try { task.get(1500, TimeUnit.MILLISECONDS) }
        catch (_: Exception) { task.cancel(false); null }
    }

    fun snapshot(): Map<String, Any>? = onMain {
        val value = current()
        val key = value.revision + (session.acknowledgment?.id ?: "")
        val now = android.os.SystemClock.elapsedRealtime()
        // Full preference/route descriptors need not accompany every media
        // heartbeat. Changes are immediate; periodic refresh stays well inside
        // Windows' 15-second settings freshness/command deadline.
        if (key == lastSnapshotKey && now - lastSnapshotAt < 5000) null
        else {
            lastSnapshotKey = key; lastSnapshotAt = now
            value.fields(session.acknowledgment)
        }
    }

    fun receive(command: JSONObject) {
        if (command.toString().toByteArray(Charsets.UTF_8).size > 64 * 1024) return
        fun values(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
            when (val item = value.get(key)) { JSONObject.NULL -> null; is JSONObject -> values(item); else -> item }
        }
        val parsed = runCatching { values(command) }.getOrNull() ?: return
        onMain {
            if (binding.current() != null) session.receive(parsed, ::current, ::apply)
            lastSnapshotKey = "" // A repeated command retries its acknowledgment promptly.
            binding.changed()
        }
    }

    private fun label(text: String): String {
        val clean = text.filterNot { it.isISOControl() }
        var end = minOf(clean.length, 160)
        while (end > 0 && clean.substring(0, end).toByteArray(Charsets.UTF_8).size > 160) end--
        if (end > 0 && clean[end - 1].isHighSurrogate()) end--
        return clean.substring(0, end).ifBlank { "Audio device" }
    }
    private fun token(value: Any): String {
        val identity = if (value is MicrophoneSelection) listOf(value.kind.name, value.deviceId,
            value.deviceType, value.leStereo, value.headsetEndpoint?.addressForStorage(value.deviceType)).joinToString("|")
            else value.toString()
        return sha256(salt + identity)
    }

    private fun current(): PhoneSettingsSnapshot {
        val live = binding.current()
        val options = AppAudioSettings.load(context)
        val connection = AppConnectionSettings.load(context)
        val fields = mutableListOf<PhoneSetting>()
        fun bool(key: String, title: String, value: Boolean) {
            fields += PhoneSetting(key, title, "Audio", "bool", value)
        }
        bool("audio.fast_recovery", "Fast buffer recovery", options.fastRecovery)
        bool("audio.echo_cancellation", "Microphone echo reduction (phone / wired input)", options.echoCancellation)
        bool("audio.noise_reduction", "Microphone noise reduction (phone / wired input)", options.noiseReduction)
        bool("audio.keep_microphone_active", "Keep microphone capture active while muted", options.keepMicrophoneActive)
        bool("audio.le_stereo", "LE Audio stereo playback", options.leStereo)

        // Choices expose opaque session-local handles, never Bluetooth addresses.
        // Inputs are saved selections; no choice can start capture or a connection.
        val selectedInput = AppAudioSettings.input(context).copy(leStereo = options.leStereo)
        val inputChoices = runCatching { MicrophoneRouting.choices(context) }.getOrDefault(emptyList())
            .map { it.copy(selection = it.selection.copy(leStereo = options.leStereo)) }.take(31).toMutableList()
        if (inputChoices.none { token(it.selection) == token(selectedInput) })
            inputChoices += MicrophoneChoice(selectedInput, "${selectedInput.kind.label} (saved; unavailable)")
        inputs = inputChoices.associate { token(it.selection) to it.selection }
        fields += PhoneSetting("audio.input", "Microphone input", "Audio", "choice", token(selectedInput),
            choices = inputChoices.map { token(it.selection) to label(it.title) }.distinctBy { it.first })

        // A running playback or duplex session shows its own output, not the saved one.
        val selectedOutput = PhoneOutputControl.value(live, AppAudioSettings.output(context))
        val outputChoices = runCatching { OutputDevices.choices(context) }.getOrDefault(emptyList()).take(31).toMutableList()
        if (outputChoices.none { token(it.selection) == token(selectedOutput) })
            outputChoices += OutputChoice(selectedOutput, PhoneOutputControl.unlisted(live, selectedOutput.kind,
                runCatching { OutputDevices.available(context, selectedOutput) }.getOrDefault(false)))
        outputs = outputChoices.associate { token(it.selection) to it.selection }
        fields += PhoneSetting("audio.output", "Media output", "Audio", "choice", token(selectedOutput),
            PhoneOutputControl.effect(live), choices = outputChoices.map { token(it.selection) to label(it.title) }.distinctBy { it.first })

        val orders = ConnectionOrder.entries.map { it.name to it.label }
        fields += PhoneSetting("advanced.initial_order", "Initial connection order", "Advanced", "choice",
            connection.initialOrder.name, choices = orders)
        fields += PhoneSetting("advanced.recovery_order", "Recovery connection order", "Advanced", "choice",
            connection.recoveryOrder.name, choices = orders)
        fields += PhoneSetting("advanced.max_restarts", "Maximum ICE restarts per interruption", "Advanced", "int",
            connection.maxRestarts, minimum = 1, maximum = 10)
        for (timeout in ConnectionTimeout.entries) fields += PhoneSetting("advanced.${timeout.name.lowercase()}",
            "${timeout.label} (ms)", "Advanced", "int", connection[timeout], minimum = timeout.minimumMs, maximum = timeout.maximumMs)
        if (live != null) {
            live.outputEnabled?.let { fields += PhoneSetting("live.output_enabled", "Audio output enabled", "Live", "bool", it, "live") }
            live.microphoneMuted?.let { fields += PhoneSetting("live.microphone_muted", "Microphone muted", "Live", "bool", it, "live") }
            if (!audio.isVolumeFixed) fields += PhoneSetting("live.volume", if (live.volumeStream == AudioManager.STREAM_VOICE_CALL)
                "Android voice volume" else "Android media volume", "Live", "int", audio.getStreamVolume(live.volumeStream),
                "live", audio.getStreamMinVolume(live.volumeStream), audio.getStreamMaxVolume(live.volumeStream))
        }
        return PhoneSettingsSnapshot(live != null && AppPhoneControlSettings.enabled(context), fields)
    }

    private fun apply(changes: Map<String, Any>) {
        val live = binding.current() ?: throw IllegalStateException("Session ended")
        check(!closed() && AppPhoneControlSettings.enabled(context))
        // Schema/revision was checked immediately before this main-thread call.
        // No local activity/service edit can interleave with the complete patch.
        val input = (changes["audio.input"] as? String)?.let { requireNotNull(inputs[it]) }
        val output = (changes["audio.output"] as? String)?.let { requireNotNull(outputs[it]) }
        val route = PhoneOutputControl.route(live, output)
        val requestedVolume = changes["live.volume"] as? Int
        val previousVolume = if (requestedVolume != null) {
            check(!audio.isVolumeFixed)
            val currentVolume = audio.getStreamVolume(live.volumeStream)
            audio.setStreamVolume(live.volumeStream, requestedVolume, 0)
            if (audio.getStreamVolume(live.volumeStream) != requestedVolume) {
                runCatching { audio.setStreamVolume(live.volumeStream, currentVolume, 0) }
                throw IllegalStateException("Volume change refused")
            }
            currentVolume
        } else null
        try {
            // A refused output switch (setup, a switch in progress, missing
            // permission) rejects the patch and restores any volume change.
            output?.takeIf { route == OutputRoute.LIVE }?.let { requireNotNull(binding.applyOutput)(it) }
            binding.apply(changes.filterKeys { it.startsWith("live.") && it != "live.volume" })
            check(!closed() && binding.current() != null)
        } catch (error: RuntimeException) {
            previousVolume?.let { runCatching { audio.setStreamVolume(live.volumeStream, it, 0) } }
            throw error
        }
        AppAudioSettings.update(context) { previous -> previous.copy(
            fastRecovery = changes["audio.fast_recovery"] as? Boolean ?: previous.fastRecovery,
            echoCancellation = changes["audio.echo_cancellation"] as? Boolean ?: previous.echoCancellation,
            noiseReduction = changes["audio.noise_reduction"] as? Boolean ?: previous.noiseReduction,
            keepMicrophoneActive = changes["audio.keep_microphone_active"] as? Boolean ?: previous.keepMicrophoneActive,
            leStereo = changes["audio.le_stereo"] as? Boolean ?: previous.leStereo) }
        input?.let { AppAudioSettings.selectInput(context, it.copy(leStereo = AppAudioSettings.load(context).leStereo)) }
        // The session's output switch already saved its choice like a local one.
        output?.takeIf { route == OutputRoute.SAVE }?.let { AppAudioSettings.selectOutput(context, it) }
        val previous = AppConnectionSettings.load(context)
        AppConnectionSettings.save(context, previous.copy(
            initialOrder = (changes["advanced.initial_order"] as? String)?.let { ConnectionOrder.valueOf(it) } ?: previous.initialOrder,
            recoveryOrder = (changes["advanced.recovery_order"] as? String)?.let { ConnectionOrder.valueOf(it) } ?: previous.recoveryOrder,
            maxRestarts = changes["advanced.max_restarts"] as? Int ?: previous.maxRestarts,
            timeouts = previous.timeouts + ConnectionTimeout.entries.mapNotNull { timeout ->
                (changes["advanced.${timeout.name.lowercase()}"] as? Int)?.let { timeout to it }
            }.toMap()))
    }
}
