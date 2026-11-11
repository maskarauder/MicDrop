package com.maskarauder.micdrop

internal enum class HeadsetEndpointState(val text: String) {
    ORIGINAL("original port available"), RECREATED("same headset available on a recreated port"),
    PROFILE_MISSING("selected audio profile unavailable"),
    IDENTITY_MISSING("original headset identity unavailable"),
    ADDRESS_MISSING("original port missing; stable Bluetooth address unavailable"),
    AMBIGUOUS("original headset identity ambiguous")
}

internal data class HeadsetEndpointMatch(val device: MicrophoneDevice?, val state: HeadsetEndpointState)

// Identity from the explicitly selected communication sink. Only a stable
// address/profile may be saved privately; port IDs are process-local.
// A recreated port is eligible only with one matching,
// non-redacted Bluetooth address and the original audio profile.
internal class HeadsetEndpoint(private val original: MicrophoneDevice) {
    private val address = BluetoothAudioIdentity.stableAddress(original.address)
    val hasStableAddress get() = address != null
    fun addressForStorage(type: Int): String? = address.takeIf { original.type == type }

    // A profile connection can expose the original headset even while audio
    // policy exposes only the newly active headset's SCO port.
    fun matchesScoAddress(value: String): Boolean =
        MicrophoneKind.forType(original.type) == MicrophoneKind.SCO &&
            address != null && BluetoothAudioIdentity.stableAddress(value) == address

    // Permission grant can reveal the address of the still-selected exact
    // port. Only a fresh explicit start can upgrade this in-memory pin, before
    // capture. Never learn identity from a different/recreated port or name.
    fun withVisibleAddress(devices: List<MicrophoneDevice>): HeadsetEndpoint {
        if (hasStableAddress) return this
        val exact = devices.singleOrNull { !it.source && it.id == original.id && it.type == original.type }
            ?: return this
        return if (BluetoothAudioIdentity.sameRedactedAddress(original.address, exact.address))
            HeadsetEndpoint(exact) else this
    }

    fun resolve(devices: List<MicrophoneDevice>): MicrophoneDevice? = inspect(devices).device

    fun inspect(devices: List<MicrophoneDevice>): HeadsetEndpointMatch {
        val profile = devices.filter { !it.source && it.type == original.type }
        if (profile.isEmpty()) return HeadsetEndpointMatch(null, HeadsetEndpointState.PROFILE_MISSING)
        val exact = profile.singleOrNull { it.id == original.id }
        if (exact != null && sameAddress(exact)) return HeadsetEndpointMatch(exact, HeadsetEndpointState.ORIGINAL)
        if (address == null) return HeadsetEndpointMatch(null, HeadsetEndpointState.ADDRESS_MISSING)
        val matching = profile.filter { BluetoothAudioIdentity.stableAddress(it.address) == address }
        return when (matching.size) {
            0 -> HeadsetEndpointMatch(null, HeadsetEndpointState.IDENTITY_MISSING)
            1 -> HeadsetEndpointMatch(matching.single(), HeadsetEndpointState.RECREATED)
            else -> HeadsetEndpointMatch(null, HeadsetEndpointState.AMBIGUOUS)
        }
    }

    fun matches(actual: MicrophoneDevice?, bound: MicrophoneDevice?): Boolean =
        actual != null && bound != null && !actual.source && !bound.source &&
            actual.id == bound.id && actual.type == original.type && bound.type == original.type &&
            sameAddress(actual) && sameAddress(bound)

    private fun sameAddress(device: MicrophoneDevice): Boolean = if (address != null)
        BluetoothAudioIdentity.stableAddress(device.address) == address
    else device.id == original.id && device.address == original.address
}
