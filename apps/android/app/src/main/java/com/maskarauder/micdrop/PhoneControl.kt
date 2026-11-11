package com.maskarauder.micdrop

import java.security.MessageDigest

internal data class PhoneSetting(val key: String, val label: String, val group: String,
    val kind: String, val value: Any, val effect: String = "next_connection",
    val minimum: Int? = null, val maximum: Int? = null,
    val choices: List<Pair<String, String>> = emptyList()) {
    fun fields(): Map<String, Any> = linkedMapOf<String, Any>("key" to key, "label" to label,
        "group" to group, "kind" to kind, "value" to value, "effect" to effect).apply {
        minimum?.let { put("minimum", it) }; maximum?.let { put("maximum", it) }
        if (choices.isNotEmpty()) put("choices", choices.map { mapOf("value" to it.first, "label" to it.second) })
    }
    fun accepts(value: Any?): Boolean = when (kind) {
        "bool" -> value is Boolean
        "int" -> value is Int && minimum != null && maximum != null && value in minimum..maximum
        "choice" -> value is String && choices.any { it.first == value }
        else -> false
    }
}

internal data class PhoneSettingsSnapshot(val enabled: Boolean, val settings: List<PhoneSetting>) {
    // Length-delimited canonical descriptors include availability/choice changes,
    // so a stale picker cannot select a newly rebound Android device port.
    val revision: String get() {
        fun part(value: Any?) = value.toString().let { "${it.length}:$it" }
        val canonical = part(enabled) + settings.sortedBy { it.key }.joinToString("") { field ->
            listOf(field.key, field.kind, field.value, field.effect, field.minimum, field.maximum).joinToString("") { part(it) } +
                field.choices.joinToString("") { part(it.first) + part(it.second) }
        }
        return sha256(canonical)
    }
    fun fields(ack: PhoneControlAck? = null): Map<String, Any> = linkedMapOf<String, Any>(
        "version" to 1, "revision" to revision, "enabled" to enabled,
        "fields" to settings.map { it.fields() }).apply { ack?.let { put("ack", it.fields()) } }
}

internal data class PhoneControlAck(val id: String, val status: String, val message: String) {
    fun fields() = mapOf("id" to id, "status" to status, "message" to message)
}

// Owned by one receiver and used only on Android's main thread. Never executes
// arbitrary keys, performs I/O, changes consent, or starts a microphone/session.
internal class PhoneControlSession {
    private val history = linkedMapOf<String, PhoneControlAck>()
    var acknowledgment: PhoneControlAck? = null
        private set

    fun receive(command: Map<String, Any?>, current: () -> PhoneSettingsSnapshot,
        apply: (Map<String, Any>) -> Unit): PhoneControlAck? {
        val id = command["id"] as? String ?: return null
        if (!id.matches(Regex("[a-f0-9]{32}"))) return null
        history[id]?.let { acknowledgment = it; return it }
        fun remember(ack: PhoneControlAck): PhoneControlAck {
            acknowledgment = ack
            if (history.size < 1024) history[id] = ack
            return ack
        }
        fun reject(message: String) = remember(PhoneControlAck(id, "rejected", message))
        // Keep a bounded complete history for this receiver; never evict an ID
        // and accidentally apply a delayed earlier update after a later edit.
        if (history.size >= 1024) return reject("Settings update limit reached. Stop and Connect to make more changes.")
        if (command.keys != setOf("id", "base_revision", "changes")) return reject("Unsupported settings command.")
        val snapshot = current()
        if (!snapshot.enabled) return reject("Allow Windows settings changes on the phone first.")
        if (command["base_revision"] != snapshot.revision) return reject("Phone settings changed. Reload and try again.")
        val changes = command["changes"] as? Map<*, *> ?: return reject("Invalid settings changes.")
        if (changes.isEmpty() || changes.size > 64) return reject("Invalid settings changes.")
        val schema = snapshot.settings.associateBy { it.key }
        if (changes.any { (key, value) -> key !is String || schema[key]?.accepts(value) != true })
            return reject("A setting is unavailable or its value is invalid.")
        val patch = changes.entries.associate { (key, value) -> key as String to requireNotNull(value) }
        return try {
            apply(patch)
            remember(PhoneControlAck(id, "applied", if (patch.keys.any { schema[it]?.effect == "next_connection" })
                "Saved. Next-connection settings apply after Stop and Connect." else "Live settings requested."))
        } catch (_: Exception) { reject("Some settings could not be applied. Reload the phone settings.") }
    }

    companion object {
        const val HEADER = "X-MicDrop-Phone-Control"
        const val DEFAULT_BODY_LIMIT = 96 * 1024
        const val CONTROL_BODY_LIMIT = DEFAULT_BODY_LIMIT + 64 * 1024
        fun offerHeader(version: Int, path: String) = if (version == 3 && path == "/offer") "1" else null
        fun bodyLimit(path: String, negotiated: Boolean): Int =
            if (negotiated && path == "/status") CONTROL_BODY_LIMIT else DEFAULT_BODY_LIMIT
    }
}

internal fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
