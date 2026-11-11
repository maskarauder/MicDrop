package com.maskarauder.micdrop

internal data class EnvironmentSnapshot(
    val appVersion: String, val revision: String, val manufacturer: String, val model: String,
    val androidRelease: String, val api: Int, val expectedRoutes: List<String>?,
    val audioMode: String, val screenOn: Boolean, val batterySaver: Boolean
) {
    fun fields(): Map<String, Any?> = linkedMapOf(
        "app_version" to appVersion, "revision" to revision, "manufacturer" to manufacturer,
        "model" to model, "android_release" to androidRelease, "api" to api,
        "expected_routes" to expectedRoutes, "audio_mode" to audioMode,
        "screen_on" to screenOn, "battery_saver" to batterySaver)

    fun text(microphone: Boolean = false, desktopPlayback: Boolean = !microphone): String = """
        MicDrop $appVersion · build $revision
        Phone: $manufacturer $model · Android $androidRelease / API $api
        Expected output route: ${expectedRoutes?.joinToString(", ") ?: "unavailable"} (confirm by listening)
        Audio mode: $audioMode · Screen on: $screenOn · Battery saver: $batterySaver
        ${if (microphone) "Microphone return: explicit consent · Playback: ${if (desktopPlayback) "media foreground service" else "off"}" else "Microphone: off · Playback: media foreground service"}
    """.trimIndent()
}

internal data class PlaybackReport(
    val sequence: Long, val capturedAt: String, val uptimeMs: Long,
    val environment: EnvironmentSnapshot?, val state: String, val mediaOutput: String,
    val snapshot: PlaybackSnapshot, val output: OutputSnapshot? = null,
    val recovery: RecoverySnapshot? = null, val localOutput: OutputSnapshot? = null,
    val microphone: MicrophoneSnapshot? = null,
    val mode: StreamMode = StreamMode.PLAYBACK,
    val connection: ConnectionSnapshot? = null,
    val microphoneProcessing: MicrophoneProcessing? = null,
    val lanRecovery: Map<String, Any>? = null,
    val outputControl: OutputControlSnapshot? = null,
    val iceGathering: IceGatheringSnapshot? = null,
    val mediaTransport: MediaTransportSnapshot? = null,
    val routeSelection: RouteSelectionSnapshot? = null,
    val tlsVerification: TurnTlsTrustSnapshot? = null
) {
    // No arbitrary text report, URL, SDP, candidate identifier, or credential is
    // accepted here. JSONObject wraps these nested maps and preserves nulls.
    fun fields(includeOutput: Boolean = false, includeConnection: Boolean = false): Map<String, Any?> = linkedMapOf<String, Any?>(
        "sequence" to sequence, "captured_at" to capturedAt, "uptime_ms" to uptimeMs,
        "environment" to environment?.fields(), "state" to state, "media_output" to mediaOutput,
        "codec" to snapshot.codec, "path" to snapshot.path, "metrics" to snapshot.values).apply {
        if (includeOutput) {
            put("output", output?.fields()); put("recovery", recovery?.fields())
            put("local_output_baseline", localOutput?.fields())
        }
        if (microphone != null) put("microphone", microphone.fields().toMutableMap().apply {
            microphoneProcessing?.let { put("processing", it.fields()) }
        })
        lanRecovery?.let { put("lan_recovery", it) }
        outputControl?.let { put("output_control", it.fields()) }
        iceGathering?.let { put("ice_gathering", it.fields()) }
        mediaTransport?.let { put("media_transport", it.fields()) }
        routeSelection?.let { put("route_selection", it.fields()) }
        tlsVerification?.let { put("tls_certificate_verification", it.fields()) }
        // Keep legacy report fields unchanged; duplex requires a new host that
        // confirmed duplex_version=1, so its direction can be checked explicitly.
        if (mode == StreamMode.DUPLEX) put("audio_direction", mode.direction)
        if (includeConnection) put("connection", connection?.fields())
    }
}

internal class ReportDelivery(version: Int) {
    var enabled = version == 1
        private set
    var text = if (enabled) "Reports: waiting to send to Windows"
        else "Windows logging unavailable; Copy last stream report is available"
        private set

    fun unavailable() {
        enabled = false
        text = "Windows logging unavailable; use Copy last stream report"
    }

    // Report/schema incompatibility must not turn working audio into an error.
    // Authentication, expiry and network errors still follow normal session rules.
    fun reject(status: Int): Boolean {
        if (status !in listOf(400, 404, 405, 409, 413, 422)) return false
        unavailable()
        return true
    }

    fun <T> exchangeStatus(body: Map<String, Any>?, stopped: () -> Boolean,
        exchange: (Map<String, Any>?) -> T): T {
        try {
            return exchange(body)
        } catch (error: HttpFailure) {
            if (body?.containsKey("android") != true || stopped() || !reject(error.status)) throw error
            // Retry once without optional diagnostics, retaining the exact ICE
            // update. A rejected ICE update still fails on this second request;
            // it must never be replaced by a successful GET or acknowledged here.
            return exchange((body - "android").takeUnless { it.keys == setOf("version") })
        }
    }

    fun acknowledge(status: String, sequence: Long, expected: Long) {
        when {
            sequence != expected -> unavailable()
            status == "accepted" -> text = "Reports: sending automatically to Windows"
            status == "busy" -> text = "Windows log is busy; Copy last stream report is available"
            status == "not_recorded" -> text = "Live status shared with Windows; not saved to a log"
            else -> unavailable()
        }
    }
}
