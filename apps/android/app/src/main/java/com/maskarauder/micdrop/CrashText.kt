package com.maskarauder.micdrop

internal object CrashText {
    fun symbol(value: String, limit: Int = 512): String = value.take(limit)
        .replace(Regex("(?:https?|micdrop)://[^\\s]+", RegexOption.IGNORE_CASE), "[link excluded]")
        .replace(Regex("[\\p{Cntrl}&&[^\\n\\t]]"), " ")

    fun safe(value: String, limit: Int = 1024): String = symbol(value, limit)
        .replace(Regex("\\b[A-Za-z0-9_-]{43,}\\b"), "[long identifier excluded]")

    // Exception messages can contain invitations or URLs. Class names and
    // source locations are sufficient for a Java crash stack and stay bounded.
    fun javaStack(error: Throwable): String = buildString {
        val seen = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
        var cause: Throwable? = error
        repeat(6) {
            val current = cause ?: return@buildString
            if (!seen.add(current)) return@buildString
            appendLine("Exception type: ${current.javaClass.name}")
            current.stackTrace.take(24).forEach { frame -> appendLine("  at ${symbol(frame.toString())}") }
            cause = current.cause
        }
    }
}
