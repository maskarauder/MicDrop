package com.maskarauder.micdrop

import java.io.IOException
import java.util.concurrent.TimeoutException
import javax.net.ssl.SSLException

// Fixed labels only. Never serialize an exception message, network/device ID,
// address, candidate, or SDP. The host validates the same closed vocabulary.
internal enum class SessionFailure(val wire: String) {
    NONE("none"), PEER_FAILED("peer_failed"), MEDIA_RECOVERY_TIMEOUT("media_recovery_timeout"),
    STATUS_RECOVERY_TIMEOUT("status_recovery_timeout"), HOST_AUDIO_STOPPED("host_audio_stopped"),
    MICROPHONE_INIT("microphone_init"), MICROPHONE_START("microphone_start"),
    MICROPHONE_RUNTIME("microphone_runtime"), OUTPUT_INIT("output_init"),
    OUTPUT_START("output_start"), OUTPUT_RUNTIME("output_runtime"),
    INPUT_ROUTE_CHANGED("input_route_changed"), INPUT_UNVERIFIED("input_unverified"),
    LE_STEREO_UNAVAILABLE("le_stereo_unavailable"), HOST_MICROPHONE_GATE("host_microphone_gate"),
    MODE_NOT_CONFIRMED("mode_not_confirmed"), HTTP_REJECTED("http_rejected"),
    TLS_FAILURE("tls_failure"), PERMISSION_DENIED("permission_denied"),
    NETWORK_IO("network_io"), STAGE_TIMEOUT("stage_timeout"), NATIVE_LOAD("native_load"),
    SESSION_EXCEPTION("session_exception");

    companion object {
        fun from(error: Throwable): SessionFailure {
            val causes = generateSequence(error) { it.cause }.take(8).toList()
            return when {
                causes.any { it is MicrophoneRouteException && it.problem == MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE } -> LE_STEREO_UNAVAILABLE
                causes.any { it is MicrophoneRouteException } -> INPUT_UNVERIFIED
                causes.any { it is HttpFailure } -> HTTP_REJECTED
                causes.any { it is SSLException || it is java.security.cert.CertificateException } -> TLS_FAILURE
                causes.any { it is SecurityException } -> PERMISSION_DENIED
                causes.any { it is java.net.SocketTimeoutException || it is TimeoutException } -> STAGE_TIMEOUT
                causes.any { it is LinkageError } -> NATIVE_LOAD
                causes.any { it is IOException } -> NETWORK_IO
                else -> SESSION_EXCEPTION
            }
        }
    }
}

internal data class RuntimeSnapshot(
    val screenOn: Boolean?, val batterySaver: Boolean?, val deviceIdle: Boolean?,
    val batteryExempt: Boolean?, val microphonePermission: Boolean?, val wakeLockHeld: Boolean?,
    val defaultNetwork: String, val networkValidated: Boolean?, val networkMetered: Boolean?,
    val networkBlocked: Boolean?, val networkChanges: Long,
    val lightIdle: Boolean? = null, val lowPowerStandby: Boolean? = null,
    val lowPowerStandbyExempt: Boolean? = null, val networkObserverRegistered: Boolean = false,
    val foregroundService: String = "unknown"
) {
    fun fields(): Map<String, Any?> = linkedMapOf(
        "screen_on" to screenOn, "battery_saver" to batterySaver, "device_idle" to deviceIdle,
        "battery_optimization_exempt" to batteryExempt, "microphone_permission" to microphonePermission,
        "wake_lock_held" to wakeLockHeld, "default_network" to defaultNetwork,
        "network_validated" to networkValidated, "network_metered" to networkMetered,
        "network_blocked" to networkBlocked, "network_changes" to networkChanges,
        "light_idle" to lightIdle, "low_power_standby_enabled" to lowPowerStandby,
        "low_power_standby_exempt" to lowPowerStandbyExempt, "network_observer_registered" to networkObserverRegistered,
        "foreground_service" to foregroundService)

    fun text(): String = "Android power: idle=${deviceIdle ?: "unknown"}, light idle=${lightIdle ?: "unknown"}, battery exemption=${batteryExempt ?: "unknown"}, CPU wake lock=${wakeLockHeld ?: "unknown"}\n" +
        "Low Power Standby: enabled=${lowPowerStandby ?: "unknown"}, exempt=${lowPowerStandbyExempt ?: "unknown"}\n" +
        "Microphone permission: ${microphonePermission ?: "unknown"} · Foreground service: $foregroundService\n" +
        "Default network: $defaultNetwork · Blocked: ${networkBlocked ?: "unknown"} · Changes: $networkChanges · Observer registered: $networkObserverRegistered\n" +
        "Default-network state is not proof of the WebRTC media route; internet validation is not required for LAN audio."
}

internal data class ConnectionSnapshot(val peer: String, val ice: String, val host: String,
    val runtime: RuntimeSnapshot?) {
    fun fields(): Map<String, Any?> = linkedMapOf("peer" to peer, "ice" to ice, "host" to host, "runtime" to runtime?.fields())
    fun text(): String = "Connection: peer=$peer · ICE=$ice · Windows=$host\n${runtime?.text() ?: "Android power/network state: unavailable"}"
}

internal enum class EvidenceKind(val wire: String) {
    PEER("peer"), ICE("ice"), HOST("host"), NETWORK("network"), NETWORK_BLOCKED("network_blocked"),
    SCREEN("screen"), IDLE("idle"), BATTERY_SAVER("battery_saver"), BATTERY_EXEMPT("battery_exempt"),
    MICROPHONE_PERMISSION("microphone_permission"), WAKE_LOCK("wake_lock"),
    NETWORK_VALIDATED("network_validated"), NETWORK_METERED("network_metered"),
    LIGHT_IDLE("light_idle"), LOW_POWER_STANDBY("low_power_standby"), LOW_POWER_EXEMPT("low_power_exempt"),
    FOREGROUND_SERVICE("foreground_service")
}

internal data class EvidenceEvent(val uptimeMs: Long, val kind: EvidenceKind, val value: String) {
    fun fields(): Map<String, Any?> = linkedMapOf("uptime_ms" to uptimeMs, "kind" to kind.wire, "value" to value)
}

// Callback and worker observations share one bounded tail. Snapshots own their
// lists, so native teardown cannot mutate an already prepared terminal report.
internal class SessionEvidence {
    private val values = mutableMapOf<EvidenceKind, String>()
    private val events = ArrayDeque<EvidenceEvent>()
    private var total = 0L

    @Synchronized fun observe(kind: EvidenceKind, value: String, uptimeMs: Long) {
        if (values[kind] == value) return
        values[kind] = value
        if (events.size == 24) events.removeFirst()
        // Callback scheduling can reorder observations; preserve a monotonic
        // phone timeline without claiming precision beyond receipt time.
        events.addLast(EvidenceEvent(maxOf(uptimeMs, events.lastOrNull()?.uptimeMs ?: 0), kind, value))
        total = minOf(total + 1, 9007199254740991L)
    }

    @Synchronized fun connection(runtime: RuntimeSnapshot?, uptimeMs: Long): ConnectionSnapshot {
        runtime?.let {
            fun flag(kind: EvidenceKind, value: Boolean?) = observe(kind, value?.toString() ?: "unknown", uptimeMs)
            flag(EvidenceKind.SCREEN, it.screenOn); flag(EvidenceKind.IDLE, it.deviceIdle)
            flag(EvidenceKind.BATTERY_SAVER, it.batterySaver); flag(EvidenceKind.BATTERY_EXEMPT, it.batteryExempt)
            flag(EvidenceKind.MICROPHONE_PERMISSION, it.microphonePermission); flag(EvidenceKind.WAKE_LOCK, it.wakeLockHeld)
            flag(EvidenceKind.NETWORK_VALIDATED, it.networkValidated); flag(EvidenceKind.NETWORK_METERED, it.networkMetered)
            flag(EvidenceKind.LIGHT_IDLE, it.lightIdle); flag(EvidenceKind.LOW_POWER_STANDBY, it.lowPowerStandby)
            flag(EvidenceKind.LOW_POWER_EXEMPT, it.lowPowerStandbyExempt)
            observe(EvidenceKind.FOREGROUND_SERVICE, it.foregroundService, uptimeMs)
        }
        return ConnectionSnapshot(values[EvidenceKind.PEER] ?: "connecting",
            values[EvidenceKind.ICE] ?: "new", values[EvidenceKind.HOST] ?: "unavailable", runtime)
    }

    @Synchronized fun tail(uptimeMs: Long): List<EvidenceEvent> = events.filter { it.uptimeMs <= uptimeMs }
    @Synchronized fun omitted(uptimeMs: Long): Long = maxOf(0, total - tail(uptimeMs).size)
}

internal data class FailureEvidence(val code: SessionFailure, val stage: ConnectionStage, val uptimeMs: Long,
    val httpStatus: Int? = null)

internal data class TerminalEvidence(val capturedAt: String, val uptimeMs: Long, val code: SessionFailure,
    val stage: ConnectionStage, val failureUptimeMs: Long?, val connection: ConnectionSnapshot,
    val events: List<EvidenceEvent>, val omittedEvents: Long, val httpStatus: Int? = null,
    val outputControl: OutputControlSnapshot? = null, val iceGathering: IceGatheringSnapshot? = null) {
    fun fields(includeIceGathering: Boolean = false): Map<String, Any?> = linkedMapOf<String, Any?>(
        "version" to 1, "captured_at" to capturedAt, "uptime_ms" to uptimeMs, "code" to code.wire,
        "stage" to stage.name.lowercase(), "failure_uptime_ms" to failureUptimeMs,
        "connection" to connection.fields(), "events" to events.map { it.fields() }, "omitted_events" to omittedEvents,
        "http_status" to httpStatus).apply {
            outputControl?.let { put("output_control", it.fields()) }
            if (includeIceGathering) iceGathering?.let { put("ice_gathering", it.fields()) }
        }

    fun text(): String = "Session terminal code: ${code.wire} · Stage: ${stage.name.lowercase()} · Phone uptime: $uptimeMs ms · HTTP: ${httpStatus ?: "unavailable"}\n" +
        "Failure observed at: ${failureUptimeMs?.let { "$it ms" } ?: "no failure"}\n${connection.text()}\n" +
        "Recent changes (phone uptime; $omittedEvents earlier observations omitted):\n" +
        events.joinToString("\n") { "${it.uptimeMs} ms · ${it.kind.wire}=${it.value}" } +
        (iceGathering?.let { "\n${it.text()}" } ?: "")
}

// REJECTED: Windows replied to /offer but the reply failed validation.
internal enum class OfferReply { NONE, REJECTED, ACCEPTED }

// Terminal copy-report labels. Until a Windows /offer reply is accepted nothing
// was negotiated, so local defaults must not read as Windows limits or support.
internal object TerminalLabels {
    const val NOT_CONFIRMED = "not confirmed"
    fun delivery(reply: OfferReply, includeConnection: Boolean) = when {
        reply == OfferReply.NONE -> "not sent; no Windows offer reply"
        reply == OfferReply.REJECTED -> "not sent; Windows offer reply rejected"
        includeConnection -> NOT_CONFIRMED
        // Current Windows builds ask only with phone control or an active log.
        else -> "not requested by Windows (older Windows or logging off)"
    }
    fun mediaRecovery(reply: OfferReply, recovery: LanRecovery, now: Long) = when (reply) {
        OfferReply.NONE -> "Media recovery: not negotiated (no Windows offer reply)"
        OfferReply.REJECTED -> "Media recovery: not negotiated (Windows offer reply rejected)"
        OfferReply.ACCEPTED ->
            "${recovery.text().replace("LAN media recovery", "Media recovery")}\nRecovery time remaining: ${recovery.remaining(now)} ms"
    }
}
