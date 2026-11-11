package com.maskarauder.micdrop

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import java.util.Locale

// Local comparisons only. Android can cache XX:XX:XX:XX:EE:FF audio-port
// addresses from before Nearby Devices permission was granted. After consent,
// resolve that specific format only against the complete paired-device list.
// Empty/opaque addresses and suffix collisions never identify a new headset.
internal object BluetoothAudioIdentity {
    private val addressPattern = Regex("[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")
    private val redactedPattern = Regex("XX:XX:XX:XX:[0-9A-F]{2}:[0-9A-F]{2}", RegexOption.IGNORE_CASE)

    fun stableAddress(value: String): String? {
        if (!addressPattern.matches(value)) return null
        val normalized = value.lowercase(Locale.ROOT)
        return normalized.takeUnless { it == "00:00:00:00:00:00" || it == "02:00:00:00:00:00" }
    }

    fun sameRedactedAddress(redacted: String, visible: String): Boolean =
        redactedPattern.matches(redacted) && stableAddress(visible) != null &&
            redacted.takeLast(5).equals(visible.takeLast(5), ignoreCase = true)

    fun needsPairedLookup(value: String): Boolean = redactedPattern.matches(value)

    fun visibleAddress(value: String, pairedAddresses: Collection<String>): String {
        stableAddress(value)?.let { return it }
        if (!redactedPattern.matches(value)) return value
        val matches = pairedAddresses.mapNotNull { stableAddress(it) }.distinct()
            .filter { sameRedactedAddress(value, it) }
        return matches.singleOrNull() ?: value
    }

    fun permitted(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission") // Permission is checked here; revocation fails closed.
    fun pairedAddresses(context: Context): Set<String> {
        if (!permitted(context)) return emptySet()
        return try {
            context.getSystemService(BluetoothManager::class.java)?.adapter?.bondedDevices.orEmpty()
                .mapNotNull { stableAddress(it.address) }.toSet()
        } catch (_: RuntimeException) { emptySet() }
    }
}
