package com.maskarauder.micdrop

// Written by the session owner before each teardown boundary. Persistence is
// best effort; failure must not prevent local gates, Stop, or media destruction.
internal class StopReportJournal(private val header: String, private val save: (String) -> Unit) {
    private var snapshot = "No periodic stream snapshot was collected."
    private var point = "session_start"
    private var complete = false

    fun snapshot(value: String) {
        if (value.isNotBlank()) snapshot = value.take(48 * 1024)
        persist()
    }

    fun checkpoint(value: String) {
        point = value
        persist()
    }

    fun completed() { complete = true; checkpoint("worker_complete") }

    fun text(): String = "$header\nLast recorded session step: $point\n" +
        "Worker cleanup: ${if (complete) "completed" else "not confirmed complete"}\n\n$snapshot"

    private fun persist() { try { save(text()) } catch (_: Exception) { } }
}
