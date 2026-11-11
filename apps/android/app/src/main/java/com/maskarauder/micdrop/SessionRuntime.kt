package com.maskarauder.micdrop

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.PowerManager
import android.os.SystemClock
import android.os.Build

// Diagnostics and lightweight change notifications. Network callbacks never
// perform signaling, query synchronous network state or dispose audio resources.
internal class SessionRuntime(private val context: Context, private val evidence: SessionEvidence,
    private val wakeLockHeld: () -> Boolean?, private val foregroundTypes: () -> Int?,
    private val onNetworkChanged: () -> Unit = {}) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private var registered = false
    private var active = false
    private var observedNetwork: Network? = null // Local comparisons only; never serialized.
    private var blocked: Boolean? = null
    private var networkChanges = 0L
    private var capabilitiesKey: Triple<String, Boolean, Boolean>? = null
    private val networkIdentity = DefaultNetworkChanges<Network>()
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = updateNetwork(network, "available")
        override fun onLost(network: Network) = updateNetwork(network, "lost")
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            synchronized(this@SessionRuntime) {
                if (!active || observedNetwork != network) return
                val key = Triple(networkType(capabilities), capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                if (key != capabilitiesKey) { capabilitiesKey = key; change(key.first) }
            }
        }
        override fun onBlockedStatusChanged(network: Network, value: Boolean) {
            synchronized(this@SessionRuntime) {
                if (!active || observedNetwork != network) return
                if (blocked != value) {
                    blocked = value
                    networkChanges = minOf(networkChanges + 1, 9007199254740991L)
                    evidence.observe(EvidenceKind.NETWORK_BLOCKED, value.toString(), SystemClock.elapsedRealtime())
                }
                if (networkIdentity.blocked(network, value)) onNetworkChanged()
            }
        }
    }

    @Synchronized private fun updateNetwork(network: Network, value: String) {
        if (!active) return
        if (value == "available") { observedNetwork = network; blocked = null; capabilitiesKey = null }
        else if (observedNetwork == network) { observedNetwork = null; blocked = null; capabilitiesKey = null }
        else return // A delayed loss for the previous default is not a new loss.
        change(value)
        val changed = if (value == "available") networkIdentity.available(network) else networkIdentity.lost(network)
        if (changed) onNetworkChanged()
    }

    private fun change(value: String) {
        networkChanges = minOf(networkChanges + 1, 9007199254740991L)
        evidence.observe(EvidenceKind.NETWORK, value, SystemClock.elapsedRealtime())
    }

    @Synchronized fun start() {
        active = true
        try { connectivity.registerDefaultNetworkCallback(callback); registered = true }
        catch (_: RuntimeException) { /* Unknown diagnostics must not stop audio. */ }
    }

    @Synchronized fun networkLabel(): String = if (!registered) "unknown"
        else if (observedNetwork == null) "none" else capabilitiesKey?.first ?: "unknown"

    fun snapshot(): RuntimeSnapshot {
        val networkQuery = runCatching { connectivity.activeNetwork }
        val network = networkQuery.getOrNull()
        val capabilities = network?.let { runCatching { connectivity.getNetworkCapabilities(it) }.getOrNull() }
        val networkState = synchronized(this) {
            Triple(if (network != null && network == observedNetwork) blocked else null, networkChanges, registered)
        }
        return RuntimeSnapshot(
            runCatching { power.isInteractive }.getOrNull(), runCatching { power.isPowerSaveMode }.getOrNull(),
            runCatching { power.isDeviceIdleMode }.getOrNull(),
            runCatching { power.isIgnoringBatteryOptimizations(context.packageName) }.getOrNull(),
            runCatching { context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED }.getOrNull(),
            runCatching { wakeLockHeld() }.getOrNull(),
            if (networkQuery.isFailure) "unknown" else if (network == null) "none" else capabilities?.let { networkType(it) } ?: "unknown",
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            capabilities?.let { !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) },
            networkState.first, networkState.second,
            if (Build.VERSION.SDK_INT >= 33) runCatching { power.isDeviceLightIdleMode }.getOrNull() else null,
            if (Build.VERSION.SDK_INT >= 33) runCatching { power.isLowPowerStandbyEnabled }.getOrNull() else null,
            if (Build.VERSION.SDK_INT >= 34) runCatching { power.isExemptFromLowPowerStandby }.getOrNull() else null,
            networkState.third, foregroundType(runCatching { foregroundTypes() }.getOrNull()))
    }

    @Synchronized fun close() {
        active = false
        if (registered) runCatching { connectivity.unregisterNetworkCallback(callback) }
        registered = false; observedNetwork = null; blocked = null
    }

    companion object {
        private fun foregroundType(types: Int?): String = when (types) {
            null -> "unknown"
            0 -> "none"
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE -> "microphone"
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK -> "media_playback"
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK -> "microphone_and_playback"
            else -> "other"
        }

        private fun networkType(value: NetworkCapabilities): String = when {
            value.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            value.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            value.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            value.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }
}
