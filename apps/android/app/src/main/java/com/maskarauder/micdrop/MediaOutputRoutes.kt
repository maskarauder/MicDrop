package com.maskarauder.micdrop

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRoute2Info
import android.media.MediaRouter2
import android.media.RouteDiscoveryPreference
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor

// Own-app public router only. Passive callbacks also notice default-device
// switches that do not add/remove an AudioManager port. No discovery scan,
// privileged router, hidden getAddress(), or manipulation of WebRTC internals.
internal class MediaOutputRoutes(private val context: Context, private val changed: () -> Unit) {
    private val lock = Any()
    private val target = SelectedMediaTarget()
    private var router: MediaRouter2? = null
    private var registered = false
    private var previous = emptySet<SystemMediaRoute>()
    private val executor = Executor { Handler(Looper.getMainLooper()).post(it) }
    var transfers = 0
        get() = synchronized(lock) { field }
        private set
    var result = "none"
        get() = synchronized(lock) { field }
        private set
    private val routeCallback = object : MediaRouter2.RouteCallback() {
        override fun onRoutesUpdated(routes: List<MediaRoute2Info>) = observe()
    }
    private val controllerCallback = object : MediaRouter2.ControllerCallback() {
        override fun onControllerUpdated(controller: MediaRouter2.RoutingController) = observe()
    }
    private fun routesLocked(): List<MediaRoute2Info> = router?.routes?.filter { it.isSystemRoute } ?: emptyList()
    private fun descriptorsLocked(): List<SystemMediaRoute> {
        if (Build.VERSION.SDK_INT < 34) return emptyList()
        val selected = router?.systemController?.selectedRoutes?.map { it.id }?.toSet() ?: emptySet()
        return routesLocked().map { SystemMediaRoute(it.id, it.type, it.id in selected) }
    }
    private fun observe() {
        val shouldNotify = synchronized(lock) {
            if (!registered) false
            else {
                val current = runCatching { descriptorsLocked().toSet() }.getOrDefault(emptySet())
                if (current != previous) { previous = current; true } else false
            }
        }
        if (shouldNotify) changed()
    }
    fun start() {
        if (Build.VERSION.SDK_INT < 34) return
        try {
            synchronized(lock) {
                router = MediaRouter2.getInstance(context)
                registered = true
                router?.registerRouteCallback(executor, routeCallback,
                    RouteDiscoveryPreference.Builder(listOf(MediaRoute2Info.FEATURE_LIVE_AUDIO), false).build())
                router?.registerControllerCallback(executor, controllerCallback)
                previous = runCatching { descriptorsLocked().toSet() }.getOrDefault(emptySet())
            }
        } catch (_: RuntimeException) { close() }
    }
    fun permitted(): Boolean = OutputPermissions.required(OutputKind.BLUETOOTH).all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
    // Called only under the receiver's cancellation/audio locks.
    fun learn(selection: OutputSelection, actual: List<OutputDevice>?, predicted: List<OutputDevice>?) {
        synchronized(lock) {
            if (!registered || !permitted()) return
            runCatching { target.learn(selection, actual, predicted, descriptorsLocked(), android.os.SystemClock.elapsedRealtime()) }
        }
    }
    fun newEpisode() = synchronized(lock) { target.newEpisode() }
    fun reset() = synchronized(lock) { target.reset() }
    fun restore(selection: OutputSelection, nowMs: Long) {
        synchronized(lock) {
            if (!registered || !permitted()) return
            try {
                val id = target.request(selection, descriptorsLocked(), nowMs) ?: return
                val route = routesLocked().singleOrNull { it.id == id } ?: return
                transfers++; result = "requested"
                router?.transferTo(route)
            } catch (_: RuntimeException) { result = "rejected" }
        }
    }
    fun text(): String = synchronized(lock) {
        val visible = if (registered && permitted()) runCatching {
            descriptorsLocked().count { OutputKind.forType(it.type)?.bluetooth == true }.toString()
        }.getOrDefault("unavailable") else "unavailable"
        "System Bluetooth route: ${if (target.known) "original route identified" else "identity unavailable"}" +
            " · Transfer requests: $transfers · Last request: $result" +
            "\nSystem Bluetooth media routes visible: $visible (does not establish microphone support)"
    }
    val known get() = synchronized(lock) { target.known }
    fun close() = synchronized(lock) {
        registered = false
        router?.let {
            runCatching { it.unregisterRouteCallback(routeCallback) }
            runCatching { it.unregisterControllerCallback(controllerCallback) }
        }
        router = null; target.stop()
    }
}
