package com.maskarauder.micdrop

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.InetAddress
import java.net.URL
import java.net.URLConnection

internal object LanAddress {
    fun bytes(host: String): ByteArray? {
        val parts = host.split('.').map { it.toIntOrNull() ?: return null }
        if (parts.size != 4 || parts.any { it !in 0..255 }) return null
        val local = parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) ||
            (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
        return if (local) parts.map { it.toByte() }.toByteArray() else null
    }
}

// Per-request signaling routing only. Never bind the whole process, request a
// new Wi-Fi connection, require internet validation, or retain network IDs.
internal class LanNetwork(context: Context, host: String, private val changed: () -> Unit) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val destination = LanAddress.bytes(host)?.let { InetAddress.getByAddress(it) }
    val local get() = destination != null
    private var registered = false
    @Volatile private var active = false
    @Volatile private var route = "default"
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { if (active) changed() }
        override fun onLost(network: Network) { if (active) changed() }
        override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) { if (active) changed() }
    }
    fun start() {
        if (!local) return
        active = true
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET).build()
        registered = runCatching { connectivity.registerNetworkCallback(request, callback); true }.getOrDefault(false)
    }
    private fun selected(): Network? {
        val address = destination ?: return null
        val default = connectivity.activeNetwork
        // Respect an existing VPN rather than routing around its policy.
        if (default != null && connectivity.getNetworkCapabilities(default)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true) {
            route = "vpn"; return default
        }
        @Suppress("DEPRECATION")
        val networks = connectivity.allNetworks
        val candidates = networks.mapNotNull { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return@mapNotNull null
            val prefix = connectivity.getLinkProperties(network)?.routes?.filter { it.matches(address) }
                ?.maxOfOrNull { it.destination.prefixLength } ?: return@mapNotNull null
            Triple(network, prefix, capabilities)
        }
        val best = candidates.maxWithOrNull(compareBy<Triple<Network, Int, NetworkCapabilities>> { it.second }
            .thenBy { if (it.first == default) 1 else 0 }) ?: run { route = "unavailable"; return null }
        route = if (best.third.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) "wifi" else "ethernet"
        return best.first
    }
    fun open(url: URL): URLConnection {
        if (!local) return url.openConnection()
        val network = selected() ?: throw java.io.IOException("LAN network unavailable")
        return network.openConnection(url)
    }
    fun socket(): java.net.Socket = (selected() ?: throw java.io.IOException("LAN network unavailable"))
        .socketFactory.createSocket()
    fun text() = "LAN signaling route: $route · Cellular media candidates: ${if (local) "excluded" else "allowed"}"
    fun routeLabel() = route
    fun close() {
        active = false
        if (registered) runCatching { connectivity.unregisterNetworkCallback(callback) }
        registered = false
    }
}
