package com.maskarauder.micdrop

import android.Manifest

internal object MicrophonePermissions {
    fun required(kind: MicrophoneKind): List<String> = listOf(Manifest.permission.RECORD_AUDIO) +
        if (kind.bluetooth) listOf(Manifest.permission.BLUETOOTH_CONNECT) else emptyList()

    fun missing(kind: MicrophoneKind, granted: (String) -> Boolean): List<String> = required(kind).filterNot(granted)

    fun denial(kind: MicrophoneKind, granted: (String) -> Boolean): String? = when {
        !granted(Manifest.permission.RECORD_AUDIO) ->
            "Microphone permission was denied. Desktop playback still works without it."
        kind.bluetooth && !granted(Manifest.permission.BLUETOOTH_CONNECT) ->
            MicrophoneRouteProblem.BLUETOOTH_PERMISSION.detail
        else -> null // Notification permission is optional and does not authorize capture.
    }
}
