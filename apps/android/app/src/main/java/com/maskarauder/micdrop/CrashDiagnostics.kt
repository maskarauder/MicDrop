package com.maskarauder.micdrop

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context

internal object CrashDiagnostics {
    // Explicit Diagnostics action, on a background thread. Only this package's
    // recent crashes are queried; report contents never enter host telemetry.
    fun latest(context: Context): String {
        val records = runCatching {
            context.getSystemService(ActivityManager::class.java)
                .getHistoricalProcessExitReasons(context.packageName, 0, 16)
        }.getOrNull() ?: return "Android crash history is unavailable."
        val crash = records.filter { it.reason in listOf(ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR) }.maxByOrNull { it.timestamp }
        val javaRecord = StoredReports.javaCrash(context)
        if (crash == null) return javaRecord ?: "Android has no retained MicDrop crash record."
        return buildString {
            appendLine("MicDrop Android process exit report")
            appendLine("Reader build: ${BuildConfig.REVISION}; this is not proof of the crashed APK's build.")
            appendLine("Exit recorded at: ${java.time.Instant.ofEpochMilli(crash.timestamp)}")
            appendLine("Exit reason: ${when (crash.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
                ApplicationExitInfo.REASON_CRASH -> "Java crash"
                else -> "application not responding"
            }} · Status/signal: ${crash.status}")
            if (crash.reason == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                val trace = runCatching { crash.traceInputStream?.use {
                    NativeCrashTrace.decode(StoredReports.readBounded(it, NativeCrashTrace.MAX_BYTES))
                } }.getOrNull()
                appendLine(trace ?: "Native stack unavailable (not retained, oversized, or unsupported trace).")
            } else if (crash.reason == ApplicationExitInfo.REASON_CRASH) {
                appendLine("Android exit history does not provide the Java exception stack.")
            } else appendLine("ANR trace is not copied by this action.")
            if (javaRecord != null) {
                appendLine("\nSaved Java exception record; compare its timestamp with the exit above:")
                appendLine(javaRecord)
            }
            StoredReports.stream(context)?.let {
                appendLine("\nLast saved stream report; it may belong to a different session or process:")
                appendLine(it)
            }
        }.take(96 * 1024)
    }
}
