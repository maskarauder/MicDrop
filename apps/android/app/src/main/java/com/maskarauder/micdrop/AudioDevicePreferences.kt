package com.maskarauder.micdrop

// Private local preferences, deliberately separate from AudioPreferences.fields()
// (ADB/exportable options). Never store port IDs or names, or print these maps.
internal object AudioDevicePreferences {
    private const val INPUT_ADDRESS = "inputBluetoothAddress"
    private const val INPUT_TYPE = "inputBluetoothType"
    private const val OUTPUT_ADDRESS = "outputBluetoothAddress"
    private const val OUTPUT_TYPE = "outputBluetoothType"
    val inputKeys = setOf(INPUT_ADDRESS, INPUT_TYPE)
    val outputKeys = setOf(OUTPUT_ADDRESS, OUTPUT_TYPE)

    fun inputFields(selection: MicrophoneSelection): Map<String, Any?> {
        val address = if (selection.kind.bluetooth && MicrophoneKind.forType(selection.deviceType) == selection.kind)
            selection.headsetEndpoint?.addressForStorage(selection.deviceType) else null
        return mapOf(INPUT_ADDRESS to address, INPUT_TYPE to selection.deviceType.takeIf { address != null })
    }

    fun outputFields(selection: OutputSelection): Map<String, Any?> {
        val address = if (selection.kind.bluetooth && OutputKind.forType(selection.deviceType) == selection.kind)
            BluetoothAudioIdentity.stableAddress(selection.address) else null
        return mapOf(OUTPUT_ADDRESS to address, OUTPUT_TYPE to selection.deviceType.takeIf { address != null })
    }

    fun input(fields: Map<String, *>, preferences: AudioPreferences): MicrophoneSelection {
        val kind = preferences.preferredInputKind ?: return MicrophoneSelection(leStereo = preferences.leStereo)
        if (kind == MicrophoneKind.BUILT_IN) return MicrophoneSelection(leStereo = preferences.leStereo)
        val type = fields[INPUT_TYPE] as? Int
        val address = (fields[INPUT_ADDRESS] as? String)?.let(BluetoothAudioIdentity::stableAddress)
        if (kind.bluetooth && type != null && MicrophoneKind.forType(type) == kind && address != null)
            return MicrophoneSelection(kind, -1, type, preferences.leStereo,
                HeadsetEndpoint(MicrophoneDevice(-1, type, false, address)))
        // Keep the chosen kind visibly unavailable. Never substitute the phone
        // or learn identity from an unrelated port after process death.
        return MicrophoneSelection(kind, -1, 0, preferences.leStereo)
    }

    fun output(fields: Map<String, *>, preferences: AudioPreferences): OutputSelection {
        val kind = preferences.preferredOutputKind ?: return OutputSelection()
        if (kind == OutputKind.DEFAULT || kind == OutputKind.PHONE) return OutputSelection.restored(kind)
        val type = fields[OUTPUT_TYPE] as? Int
        val address = (fields[OUTPUT_ADDRESS] as? String)?.let(BluetoothAudioIdentity::stableAddress)
        if (kind.bluetooth && type != null && OutputKind.forType(type) == kind && address != null)
            return OutputSelection(kind, -1, type, address)
        return OutputSelection(kind, -1)
    }
}
