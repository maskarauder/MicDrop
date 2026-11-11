package com.maskarauder.micdrop

internal class BusyOfferRetry(private val enabled: Boolean, private val startedMs: Long, private val timeoutMs: Long = 5000) {
    fun allow(status: Int, nowMs: Long): Boolean = enabled && status == 423 && nowMs - startedMs in 0L until timeoutMs
}
