package com.maskarauder.micdrop

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import java.net.Inet4Address
import java.util.concurrent.Executor

internal data class DiscoveryView(val searching: Boolean = false, val message: String = "",
    val hosts: List<DiscoveredHost> = emptyList())

// One process-wide NSD owner bounds legacy (API 31–33) uncancellable resolution
// even across rotation. UI callbacks are detached as soon as the activity stops.
internal class LanDiscovery private constructor(context: Context) {
    private val manager = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executor { main.post(it) }
    private val index = DiscoveryIndex()
    private var update: ((DiscoveryView) -> Unit)? = null
    private var generation = 0L
    private var searching = false
    private var browser: Browse? = null
    private val watches = mutableMapOf<DiscoveryIndex.Ticket, () -> Unit>()
    private val queue = ArrayDeque<Pair<DiscoveryIndex.Ticket, NsdServiceInfo>>()
    private var legacyBusy = false
    private val timeout = Runnable { finish("Search finished. Tap Find again to refresh. QR or paste also work.") }

    fun start(onUpdate: (DiscoveryView) -> Unit) {
        update = onUpdate
        if (browser != null) {
            browser?.requestStop()
            emit("The previous search is stopping. Tap Find again in a moment.")
            return
        }
        ++generation
        index.clear()
        searching = true
        val task = Browse(generation)
        browser = task
        emit("Looking for Windows hosts on your LAN…")
        main.postDelayed(timeout, 30_000)
        try { manager.discoverServices(DiscoveryRecord.TYPE, NsdManager.PROTOCOL_DNS_SD, task) }
        catch (_: SecurityException) {
            browser = null
            finish("Android blocked LAN discovery. Check network access in Settings, or use QR/paste.")
        } catch (_: RuntimeException) {
            browser = null
            finish("LAN discovery could not start. Try again, or use QR/paste.")
        }
    }

    fun stop() { finish("Search stopped. Tap Find again to refresh.") }

    fun detach() {
        update = null
        finish("")
        index.clear()
    }

    private fun emit(message: String) { update?.invoke(DiscoveryView(searching, message, index.hosts())) }

    private fun finish(message: String) {
        searching = false
        ++generation
        main.removeCallbacks(timeout)
        browser?.requestStop()
        val closing = watches.values.toList()
        watches.clear(); queue.clear()
        closing.forEach { it() }
        emit(if (message.startsWith("Search finished") && index.hosts().isEmpty())
            "No Windows hosts found. Check the same LAN and Windows Private-network firewall access. QR or paste still work."
            else message)
    }

    private fun key(info: NsdServiceInfo): String = info.serviceName +
        if (Build.VERSION.SDK_INT >= 33) "/${info.network?.networkHandle}" else ""

    private inner class Browse(private val epoch: Long) : NsdManager.DiscoveryListener {
        private var started = false
        private var stopping = false
        private var stopRequested = false
        private val stopFallback = Runnable {
            stopping = false
            if (browser === this) browser = null
        }
        fun requestStop() {
            stopRequested = true
            if (!started) {
                main.removeCallbacks(stopFallback)
                main.postDelayed(stopFallback, 2_000)
                return
            }
            if (stopping) return
            stopping = true
            main.removeCallbacks(stopFallback)
            try {
                manager.stopServiceDiscovery(this)
                main.postDelayed(stopFallback, 2_000)
            } catch (_: IllegalArgumentException) {
                stopping = false
                if (browser === this) browser = null
            } catch (_: RuntimeException) {
                stopping = false
                main.postDelayed(stopFallback, 2_000)
            }
        }
        private fun current() = generation == epoch && searching && browser === this
        override fun onDiscoveryStarted(type: String) { main.post {
            started = true
            if (stopRequested || !current()) requestStop()
        } }
        override fun onStartDiscoveryFailed(type: String, code: Int) { main.post {
            main.removeCallbacks(stopFallback)
            if (browser === this) {
                browser = null
                finish("Android could not start LAN discovery. Check network access, or use QR/paste.")
            }
        } }
        override fun onDiscoveryStopped(type: String) { main.post {
            main.removeCallbacks(stopFallback)
            if (browser === this) {
                val wasCurrent = current()
                browser = null
                if (wasCurrent) finish("Discovery stopped. Tap Find to try again.")
            }
        } }
        override fun onStopDiscoveryFailed(type: String, code: Int) { main.post {
            main.removeCallbacks(stopFallback)
            stopping = false
            if (Build.VERSION.SDK_INT >= 34 && code == NsdManager.FAILURE_OPERATION_NOT_RUNNING) {
                if (browser === this) browser = null
                return@post
            }
            if (browser === this) {
                emit("Android could not stop discovery yet. Leave this screen and try again.")
                main.postDelayed(stopFallback, 2_000)
            }
        } }
        override fun onServiceFound(info: NsdServiceInfo) { main.post {
            if (!current() || !DiscoveryRecord.acceptsType(info.serviceType ?: "") || info.serviceName.isNullOrBlank()) return@post
            val ticket = index.claim(key(info)) ?: return@post
            if (Build.VERSION.SDK_INT >= 34) watch(ticket, info, epoch)
            else { queue.addLast(ticket to info); resolveNext(epoch) }
        } }
        override fun onServiceLost(info: NsdServiceInfo) { main.post {
            if (!current()) return@post
            index.remove(key(info))?.let { watches.remove(it)?.invoke() }
            emit("Looking for Windows hosts on your LAN…")
        } }
    }

    @RequiresApi(34)
    private fun watch(ticket: DiscoveryIndex.Ticket, info: NsdServiceInfo, epoch: Long) {
        fun registrationFailed() {
            watches.remove(ticket)
            if (generation != epoch || !index.contains(ticket)) return
            index.remove(ticket.service)
            emit("A Windows address could not be resolved. Try Find again, or use QR/paste.")
        }
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceUpdated(resolved: NsdServiceInfo) {
                if (generation != epoch || !index.contains(ticket)) return
                val hosts = resolved.hostAddresses.filterIsInstance<Inet4Address>().take(8).mapNotNull { it.hostAddress }
                index.update(ticket, DiscoveryRecord.parse(hosts, resolved.port, resolved.attributes))
                emit("Select Windows below. Its identity will be checked when connecting.")
            }
            override fun onServiceLost() {
                if (generation != epoch || !index.contains(ticket)) return
                index.update(ticket, emptyList())
                emit("Looking for Windows hosts on your LAN…")
            }
            override fun onServiceInfoCallbackRegistrationFailed(code: Int) {
                registrationFailed()
            }
            override fun onServiceInfoCallbackUnregistered() { watches.remove(ticket) }
        }
        watches[ticket] = { try { manager.unregisterServiceInfoCallback(callback) } catch (_: RuntimeException) { } }
        try { manager.registerServiceInfoCallback(info, executor, callback) }
        catch (_: RuntimeException) { registrationFailed() }
    }

    @Suppress("DEPRECATION")
    private fun resolveNext(epoch: Long) {
        if (legacyBusy || generation != epoch || !searching) return
        while (queue.isNotEmpty()) {
            val (ticket, info) = queue.removeFirst()
            if (!index.contains(ticket)) continue
            legacyBusy = true
            val listener = object : NsdManager.ResolveListener {
                override fun onServiceResolved(resolved: NsdServiceInfo) { main.post {
                    legacyBusy = false
                    if (generation == epoch && index.contains(ticket)) {
                        val addresses = (resolved.host as? Inet4Address)?.hostAddress?.let { listOf(it) } ?: emptyList()
                        index.update(ticket, DiscoveryRecord.parse(addresses, resolved.port, resolved.attributes))
                        emit("Select Windows below. Its identity will be checked when connecting.")
                    }
                    resolveNext(generation)
                } }
                override fun onResolveFailed(service: NsdServiceInfo, code: Int) { main.post {
                    legacyBusy = false
                    if (generation == epoch && index.contains(ticket)) {
                        index.remove(ticket.service)
                        emit("A Windows address could not be resolved. Try Find again, or use QR/paste.")
                    }
                    resolveNext(generation)
                } }
            }
            try { manager.resolveService(info, listener) }
            catch (_: RuntimeException) { listener.onResolveFailed(info, 0) }
            return
        }
    }

    companion object {
        private var instance: LanDiscovery? = null
        fun get(context: Context): LanDiscovery = instance ?: LanDiscovery(context.applicationContext).also { instance = it }
    }
}
