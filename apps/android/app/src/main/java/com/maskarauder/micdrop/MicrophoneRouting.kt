package com.maskarauder.micdrop

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean

internal data class MicrophoneChoice(val selection: MicrophoneSelection, val title: String)

// Owned by the session worker under AudioSessionOwner, not by the activity.
// Stop releases the route after WebRTC audio teardown and before another owner
// can start. Physical input removal is watched even while capture is muted.
internal class MicrophoneRouting(private val context: Context, private val selection: MicrophoneSelection,
    private val lost: () -> Unit) {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val armed = AtomicBoolean(false)
    @Volatile private var monitorCommunication = false
    @Volatile private var input: MicrophoneDevice? = null
    @Volatile private var boundSink: MicrophoneDevice? = null
    @Volatile private var headsetEndpoint: HeadsetEndpoint? = selection.headsetEndpoint
    @Volatile private var lastRecoveryCheck = "not checked"
    private var ownsCommunication = false
    private var devicesRegistered = false
    private var communicationRegistered = false
    private var scoProfile: BluetoothHeadsetRoute? = null
    private var scoRecovery: ScoProfileRecovery? = null
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) { checkRoute() }
    }
    private val communication = AudioManager.OnCommunicationDeviceChangedListener { checkRoute() }

    private fun checkRoute() {
        // Query current state, rather than trust an older callback queued during
        // route setup. Disarmed callbacks cannot affect a later session.
        if (armed.get() && !healthy()) lost()
    }
    fun healthy(): Boolean = (if (selection.kind.bluetooth) recoveryEndpointAvailable() else available(context, selection)) &&
        (!monitorCommunication || communicationMatches())
    private fun communicationMatches(): Boolean = runCatching {
        manager.mode == AudioManager.MODE_IN_COMMUNICATION && BluetoothAudioIdentity.permitted(context) &&
            sinkMatches(describe(manager.communicationDevice))
    }.getOrDefault(false)
    fun matchesInput(device: AudioDeviceInfo?): Boolean = selection.matchesInput(device?.descriptor(emptySet()), input) &&
        (!selection.kind.bluetooth || communicationMatches())
    fun matchesOutput(device: AudioDeviceInfo?): Boolean = sinkMatches(describe(device)) && communicationMatches()
    fun acceptsOutputChannels(channels: Int): Boolean = selection.acceptsOutputChannels(channels)

    fun currentSelection(): MicrophoneSelection = boundSink?.let {
        selection.copy(deviceId = it.id, deviceType = it.type, headsetEndpoint = headsetEndpoint)
    } ?: selection

    private fun sinkMatches(device: MicrophoneDevice?): Boolean =
        headsetEndpoint?.matches(device, boundSink) ?: selection.matchesOutput(device)

    private fun describe(device: AudioDeviceInfo?): MicrophoneDevice? =
        device?.let { describe(listOf(it)).single() }

    private fun describe(devices: List<AudioDeviceInfo>): List<MicrophoneDevice> {
        val addresses = pairedAddresses(context, devices)
        return devices.map { it.descriptor(addresses) }
    }

    private fun selectedSink(): AudioDeviceInfo? {
        if (!BluetoothAudioIdentity.permitted(context)) {
            lastRecoveryCheck = "Nearby devices permission unavailable"
            return null
        }
        val devices = manager.availableCommunicationDevices
        val descriptors = describe(devices)
        val endpoint = headsetEndpoint
        val match = endpoint?.inspect(descriptors)
        val chosen = if (endpoint == null) descriptors.singleOrNull { selection.matchesOutput(it) } else match?.device
        lastRecoveryCheck = match?.state?.text ?: if (chosen == null) "selected port unavailable" else "selected port available"
        if (chosen == null) return null
        return devices.singleOrNull { it.id == chosen.id && it.type == chosen.type }
    }

    fun recoveryEndpointAvailable(): Boolean = runCatching { selectedSink() != null }.getOrDefault(false)
    fun recoveryCheck(): String = lastRecoveryCheck
    fun identityText(): String = "Selected headset identity: " +
        (if (headsetEndpoint?.hasStableAddress == true) "stable address" else "original port only") +
        " · Nearby devices permission: " + (if (BluetoothAudioIdentity.permitted(context)) "granted" else "unavailable")

    // The worker has stopped capture and duplex playout with all sample gates
    // closed. Relinquish only this app's request, retaining the pinned identity.
    // This does not expose an inactive headset by force; re-enumerate afterward.
    fun releaseCommunicationForRecovery() {
        if (!selection.kind.bluetooth || !ownsCommunication ||
            manager.mode !in listOf(AudioManager.MODE_NORMAL, AudioManager.MODE_IN_COMMUNICATION))
            throw MicrophoneRouteException(MicrophoneRouteProblem.IN_USE)
        monitorCommunication = false; input = null
        manager.clearCommunicationDevice()
        manager.mode = AudioManager.MODE_NORMAL
    }

    fun validateDuplexOutput() {
        if (!selection.leStereoRequested) return
        val sink = manager.communicationDevice
        if (!matchesOutput(sink)) throw MicrophoneRouteException(MicrophoneRouteProblem.UNVERIFIED)
        // An empty channel-count list means Android did not constrain it.
        // Advertised support is only a preflight; verify the live AudioTrack too.
        if (!selection.supportsOutputChannels(requireNotNull(sink).channelCounts))
            throw MicrophoneRouteException(MicrophoneRouteProblem.LE_STEREO_UNAVAILABLE)
    }

    fun prepare(cancelled: () -> Boolean): AudioDeviceInfo {
        manager.registerAudioDeviceCallback(devices, handler); devicesRegistered = true
        if (selection.kind.bluetooth) {
            if (!BluetoothAudioIdentity.permitted(context))
                throw MicrophoneRouteException(MicrophoneRouteProblem.BLUETOOTH_PERMISSION)
            if (manager.mode != AudioManager.MODE_NORMAL) throw MicrophoneRouteException(MicrophoneRouteProblem.IN_USE)
            manager.addOnCommunicationDeviceChangedListener({ task -> handler.post(task) }, communication)
            communicationRegistered = true
        }
        val chosen = activate(30000, cancelled)
        if (selection.kind == MicrophoneKind.SCO && headsetEndpoint?.hasStableAddress == true) {
            scoRecovery = ScoProfileRecovery(requireNotNull(headsetEndpoint))
            scoProfile = BluetoothHeadsetRoute(context.applicationContext).also { it.open() }
        }
        armed.set(true)
        if (!healthy()) throw MicrophoneRouteException(MicrophoneRouteProblem.UNAVAILABLE)
        return chosen
    }

    fun activate(timeoutMs: Long, cancelled: () -> Boolean): AudioDeviceInfo {
        if (cancelled()) throw InterruptedException()
        if (!(if (selection.kind.bluetooth) recoveryEndpointAvailable() else available(context, selection)))
            throw MicrophoneRouteException(MicrophoneRouteProblem.UNAVAILABLE)
        if (selection.kind.bluetooth) {
            val sink = selectedSink() ?: throw MicrophoneRouteException(MicrophoneRouteProblem.UNAVAILABLE)
            if (headsetEndpoint == null) headsetEndpoint = HeadsetEndpoint(requireNotNull(describe(sink)))
            boundSink = describe(sink)
            if (!communicationMatches()) {
                ownsCommunication = true // Also release mode if route selection subsequently fails.
                manager.mode = AudioManager.MODE_IN_COMMUNICATION
                if (!manager.setCommunicationDevice(sink)) throw MicrophoneRouteException(MicrophoneRouteProblem.UNVERIFIED)
            }
        }
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        do {
            if (cancelled()) throw InterruptedException()
            if (!(if (selection.kind.bluetooth) recoveryEndpointAvailable() else available(context, selection)))
                throw MicrophoneRouteException(MicrophoneRouteProblem.UNAVAILABLE)
            val sources = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            val chosen = currentSelection().resolveInput(describe(sources.toList()), describe(manager.communicationDevice))
            if (chosen != null && (!selection.kind.bluetooth || communicationMatches())) {
                input = chosen
                return sources.single { it.id == chosen.id }
            }
            if (!selection.kind.bluetooth) break
            Thread.sleep(20)
        } while (SystemClock.elapsedRealtime() < deadline)
        throw MicrophoneRouteException(MicrophoneRouteProblem.UNVERIFIED)
    }

    fun monitor(active: Boolean) { monitorCommunication = selection.kind.bluetooth && active }

    // Called only with capture/playout stopped and the Windows gate closed,
    // after releasing our stale communication request. LE uses AudioManager's
    // endpoint recovery directly; it must never enter the classic SCO path.
    fun requestHiddenScoEndpoint(recovery: HeadsetRecovery, cancelled: () -> Boolean) {
        if (selection.kind != MicrophoneKind.SCO) return
        val restore = scoRecovery ?: return
        lastRecoveryCheck = restore.request(scoProfile?.connection(), recovery, SystemClock::elapsedRealtime) {
            !cancelled() && ownsCommunication && BluetoothAudioIdentity.permitted(context) &&
                manager.mode in listOf(AudioManager.MODE_NORMAL, AudioManager.MODE_IN_COMMUNICATION)
        }.text
    }

    // One nonblocking recovery step. Only the original physical headset/profile
    // is eligible. A temporarily absent/rejected endpoint waits within the
    // worker's existing deadline; another audio mode still fails closed.
    // Both directions are silenced; capture is stopped before reselection and
    // may be running as a silenced verification probe between requests.
    fun restoreInput(reselect: Boolean): AudioDeviceInfo? {
        if (!selection.kind.bluetooth || !ownsCommunication ||
            manager.mode !in listOf(AudioManager.MODE_NORMAL, AudioManager.MODE_IN_COMMUNICATION))
            throw MicrophoneRouteException(MicrophoneRouteProblem.IN_USE)
        val sink = selectedSink() ?: return null
        boundSink = describe(sink)
        // Android can idle our mode when a microphone-only probe is stopped.
        // Reassert our existing request; never replace MODE_IN_CALL or another
        // special mode. The service independently stops on audio-focus loss.
        if (manager.mode == AudioManager.MODE_NORMAL) manager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (reselect) {
            // The public device list can change between query and selection.
            val accepted = try { manager.setCommunicationDevice(sink) }
                catch (_: IllegalArgumentException) { false }
            if (!accepted) { lastRecoveryCheck = "Android rejected headset selection"; return null }
        }
        if (!communicationMatches()) { lastRecoveryCheck = "waiting for original communication route"; return null }
        val sources = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        val chosen = currentSelection().resolveInput(describe(sources.toList()), describe(manager.communicationDevice))
            ?: run { lastRecoveryCheck = "waiting for original microphone source"; return null }
        input = chosen
        return sources.singleOrNull { it.id == chosen.id }
    }

    fun close() {
        armed.set(false); monitorCommunication = false; input = null
        var failed = false
        fun release(operation: () -> Unit) { try { operation() } catch (_: RuntimeException) { failed = true } }
        if (devicesRegistered) release { manager.unregisterAudioDeviceCallback(devices) }
        if (communicationRegistered) release { manager.removeOnCommunicationDeviceChangedListener(communication) }
        release { scoRecovery?.close() }
        release { scoProfile?.close() }
        scoRecovery = null; scoProfile = null
        if (ownsCommunication) {
            release { manager.clearCommunicationDevice() }
            // Relinquish this app's mode request; do not restore another app's
            // observed MODE_IN_CALL or communication request as our own.
            release { manager.mode = AudioManager.MODE_NORMAL }
        }
        devicesRegistered = false; communicationRegistered = false; ownsCommunication = false
        if (failed) throw IllegalStateException("Audio route cleanup failed")
    }

    companion object {
        private fun pairedAddresses(context: Context, devices: List<AudioDeviceInfo>): Set<String> =
            if (devices.any { MicrophoneKind.forType(it.type)?.bluetooth == true &&
                BluetoothAudioIdentity.needsPairedLookup(it.address) }) BluetoothAudioIdentity.pairedAddresses(context)
            else emptySet()
        private fun AudioDeviceInfo.descriptor(pairedAddresses: Set<String>) = MicrophoneDevice(id, type, isSource,
            if (MicrophoneKind.forType(type)?.bluetooth == true)
                BluetoothAudioIdentity.visibleAddress(address, pairedAddresses) else address)
        fun attributes(selection: MicrophoneSelection): AudioAttributes = if (selection.kind.bluetooth)
            AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(if (selection.leStereoRequested) AudioAttributes.CONTENT_TYPE_MUSIC
                    else AudioAttributes.CONTENT_TYPE_SPEECH).build() else PlaybackEnvironment.attributes()
        private fun attached(manager: AudioManager, selection: MicrophoneSelection): Boolean =
            selection.resolveInput(manager.getDevices(AudioManager.GET_DEVICES_INPUTS).map { it.descriptor(emptySet()) }) != null
        fun available(context: Context, selection: MicrophoneSelection): Boolean = try {
            if (selection.kind.bluetooth) refresh(context, selection) != null
            else attached(context.getSystemService(AudioManager::class.java), selection)
        } catch (_: RuntimeException) { false }
        fun refresh(context: Context, selection: MicrophoneSelection, revealAddress: Boolean = false): MicrophoneSelection? = try {
            lookup(context, selection, revealAddress)
        } catch (_: RuntimeException) { null }
        // Like refresh, but a failed device query throws instead of reading as a
        // missing port, so AudioSettingsStore does not forget a held port.
        fun lookup(context: Context, selection: MicrophoneSelection, revealAddress: Boolean = false): MicrophoneSelection? {
            val manager = context.getSystemService(AudioManager::class.java)
            return if (selection.kind.bluetooth && !BluetoothAudioIdentity.permitted(context)) null
            else if (selection.kind.bluetooth) {
                val devices = manager.availableCommunicationDevices
                val addresses = pairedAddresses(context, devices)
                selection.refreshBluetooth(devices.map { it.descriptor(addresses) }, revealAddress)
            } else selection.takeIf { attached(manager, it) }
        }
        fun choices(context: Context): List<MicrophoneChoice> {
            val manager = context.getSystemService(AudioManager::class.java)
            val choices = mutableListOf(MicrophoneChoice(MicrophoneSelection(), "Built-in phone microphone"))
            val direct = manager.getDevices(AudioManager.GET_DEVICES_INPUTS).filter {
                it.isSource && MicrophoneKind.forType(it.type) in listOf(MicrophoneKind.WIRED, MicrophoneKind.USB)
            }
            val bluetooth = manager.availableCommunicationDevices.filter {
                it.isSink && MicrophoneKind.forType(it.type)?.bluetooth == true
            }
            val addresses = pairedAddresses(context, bluetooth)
            for (device in direct + bluetooth) {
                val kind = requireNotNull(MicrophoneKind.forType(device.type))
                val name = device.productName.toString().filter { !it.isISOControl() }.take(60)
                val number = choices.count { it.selection.kind == kind } + 1
                choices.add(MicrophoneChoice(MicrophoneSelection(kind, device.id, device.type,
                    headsetEndpoint = if (kind.bluetooth) HeadsetEndpoint(device.descriptor(addresses)) else null),
                    "${kind.label} $number${if (name.isEmpty()) "" else " · $name"}"))
            }
            return choices
        }
    }
}
