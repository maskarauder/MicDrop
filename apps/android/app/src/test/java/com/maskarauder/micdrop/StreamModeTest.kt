package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class StreamModeTest {
    @Test fun independentMediaOutputDependsOnCaptureRoutingRatherThanTheOutputChoice() {
        for (kind in MicrophoneKind.entries) {
            assertTrue(StreamMode.PLAYBACK.usesMediaOutput(kind))
            assertFalse(StreamMode.MICROPHONE.usesMediaOutput(kind))
            assertEquals(!kind.bluetooth, StreamMode.DUPLEX.usesMediaOutput(kind))
        }
    }

    @Test fun mediaPlaybackNeverRequestsMicrophoneOrDuplex() {
        for (version in 1..3) assertEquals(mapOf("version" to version), StreamMode.PLAYBACK.offerFields(version))
        assertFalse(StreamMode.PLAYBACK.microphone)
        assertTrue(StreamMode.PLAYBACK.playback)
        assertTrue(StreamMode.PLAYBACK.acceptsOffer(0, 0, "")) // legacy host
        assertFalse(StreamMode.PLAYBACK.acceptsOffer(1, 1, "duplex"))
    }

    @Test fun microphoneModesRequirePairedProtocolAndExactConfirmation() {
        assertEquals(mapOf("version" to 3, "microphone_return_version" to 1), StreamMode.MICROPHONE.offerFields(3))
        assertEquals(mapOf("version" to 3, "microphone_return_version" to 1, "duplex_version" to 1), StreamMode.DUPLEX.offerFields(3))
        for (mode in listOf(StreamMode.MICROPHONE, StreamMode.DUPLEX)) {
            for (version in 1..2) {
                try { mode.offerFields(version); fail("legacy microphone offer") } catch (_: IllegalArgumentException) { }
            }
        }
        assertTrue(StreamMode.DUPLEX.acceptsOffer(1, 1, "duplex"))
        for (wrong in listOf(Triple(1, 0, "phone_microphone"), Triple(0, 0, "desktop_playback"),
                Triple(0, 1, "duplex"), Triple(1, 2, "duplex"), Triple(1, 1, "phone_microphone")))
            assertFalse(StreamMode.DUPLEX.acceptsOffer(wrong.first, wrong.second, wrong.third))
        assertTrue(StreamMode.MICROPHONE.acceptsOffer(1, 0, "phone_microphone"))
        assertFalse(StreamMode.MICROPHONE.acceptsOffer(1, 1, "duplex"))
    }
}
