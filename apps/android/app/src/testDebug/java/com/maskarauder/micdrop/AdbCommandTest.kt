package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class AdbCommandTest {
    @Test fun savedConnectAndExplicitModesNeedNoInvitation() {
        assertEquals("launch", AdbCommand.parse(emptyMap<String, Any>()).name)
        assertNull(AdbCommand.parse(mapOf("command" to "connect")).mode)
        for (mode in listOf("playback", "microphone", "duplex")) {
            assertEquals(mode, AdbCommand.parse(mapOf("command" to "connect", "mode" to mode)).mode)
        }
    }
    @Test fun controlsRequireBooleanValuesAndRejectExtrasForOtherCommands() {
        for (command in listOf("microphone", "output")) {
            for (value in listOf(true, false))
                assertEquals(value, AdbCommand.parse(mapOf("command" to command, "enabled" to value)).enabled)
            for (value in listOf(null, "false", 1)) assertThrows(IllegalArgumentException::class.java) {
                AdbCommand.parse(mapOf("command" to command, "enabled" to value))
            }
        }
        for (extras in listOf(mapOf("command" to "stop", "enabled" to false),
            mapOf("command" to "stop", "mode" to "duplex"), mapOf("command" to "connect", "mode" to "invalid"),
            mapOf("command" to "erase"), mapOf("command" to 42), mapOf("token" to "private"))) {
            assertThrows(IllegalArgumentException::class.java) { AdbCommand.parse(extras) }
        }
    }
    @Test fun invitationsAreAcceptedOnlyForExplicitPairingAndAreBounded() {
        val text = "micdrop://remote/v1/synthetic"
        assertEquals(text, AdbCommand.parse(mapOf("command" to "pair", "invitation" to text)).invitation)
        assertThrows(IllegalArgumentException::class.java) {
            AdbCommand.parse(mapOf("command" to "connect", "invitation" to text))
        }
        for (invalid in listOf("", "https://example.invalid", "$text\n", text + "x".repeat(16384))) {
            assertThrows(IllegalArgumentException::class.java) {
                AdbCommand.parse(mapOf("command" to "pair", "invitation" to invalid))
            }
        }
    }
}
