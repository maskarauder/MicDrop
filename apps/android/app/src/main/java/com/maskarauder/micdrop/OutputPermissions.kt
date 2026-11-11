package com.maskarauder.micdrop

import android.Manifest

internal object OutputPermissions {
    fun required(kind: OutputKind): List<String> =
        if (kind.bluetooth) listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN) else emptyList()
    fun missing(kind: OutputKind, granted: (String) -> Boolean): List<String> = required(kind).filterNot(granted)
    fun denial(kind: OutputKind, granted: (String) -> Boolean): String? =
        if (missing(kind, granted).isEmpty()) null else
            "Allow Nearby devices permission to identify and restore your selected Bluetooth output. Android media output still works without it."
}

// A visible output choice/Connect may wait for consent, but cannot apply to a
// different service generation. Stop/backgrounding also clears the pending UI
// action. Playback-only permission actions never authorize microphone capture.
internal data class OutputPermissionScope(val mode: StreamMode?, val generation: String?) {
    fun matches(current: OutputPermissionScope) = this == current
}
