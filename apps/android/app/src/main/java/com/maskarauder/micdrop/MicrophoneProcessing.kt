package com.maskarauder.micdrop

internal data class MicrophoneProcessing(val echoCancellation: Boolean = false, val noiseReduction: Boolean = false) {
    fun effective(mode: StreamMode, input: MicrophoneKind) = MicrophoneProcessing(
        echoCancellation && mode == StreamMode.DUPLEX && !input.bluetooth,
        noiseReduction && mode.microphone && !input.bluetooth)
    fun constraints(): Map<String, String> = mapOf("googEchoCancellation" to echoCancellation.toString(),
        "googNoiseSuppression" to noiseReduction.toString(), "googAutoGainControl" to "false", "googHighpassFilter" to "false")
    fun fields(): Map<String, Boolean> = mapOf("echo_cancellation_requested" to echoCancellation,
        "noise_reduction_requested" to noiseReduction)
    fun text() = "Microphone processing: WebRTC echo cancellation ${if (echoCancellation) "requested" else "off"} · Noise reduction ${if (noiseReduction) "requested" else "off"}. Acoustic effectiveness is unmeasured."
}
