package com.maskarauder.micdrop

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.DataInputStream

class WebRtcOutputCompatibilityTest {
    @Test fun pinnedAarExposesFieldsUsedForOutputObservationAndPublicRouting() {
        // Inspect class-file descriptors instead of loading WebRTC: its pinned
        // producer uses newer Java bytecode than the JDK 17 unit-test VM. The
        // Android app executes D8's DEX output, not these class files directly.
        assertEquals("Lorg/webrtc/audio/WebRtcAudioTrack;",
            fields("org/webrtc/audio/JavaAudioDeviceModule.class")["audioOutput"])
        assertEquals("Landroid/media/AudioTrack;",
            fields("org/webrtc/audio/WebRtcAudioTrack.class")["audioTrack"])
    }

    @Test fun pinnedAarExposesFieldsRequiredForMicrophoneRouteVerification() {
        assertEquals("Lorg/webrtc/audio/WebRtcAudioRecord;",
            fields("org/webrtc/audio/JavaAudioDeviceModule.class")["audioInput"])
        assertEquals("Landroid/media/AudioRecord;",
            fields("org/webrtc/audio/WebRtcAudioRecord.class")["audioRecord"])
    }

    private fun fields(path: String): Map<String, String> {
        val resource = requireNotNull(javaClass.classLoader?.getResourceAsStream(path))
        return DataInputStream(resource).use { input ->
            assertEquals(0xcafebabe.toInt(), input.readInt())
            input.readUnsignedShort(); input.readUnsignedShort() // minor / major
            val utf8 = arrayOfNulls<String>(input.readUnsignedShort())
            var index = 1
            while (index < utf8.size) {
                when (val tag = input.readUnsignedByte()) {
                    1 -> utf8[index] = input.readUTF()
                    3, 4 -> input.skipNBytes(4)
                    5, 6 -> { input.skipNBytes(8); index++ }
                    7, 8, 16, 19, 20 -> input.skipNBytes(2)
                    9, 10, 11, 12, 17, 18 -> input.skipNBytes(4)
                    15 -> input.skipNBytes(3)
                    else -> error("Unknown constant-pool tag: $tag")
                }
                index++
            }
            input.skipNBytes(6) // class access / this / super
            input.skipNBytes(2L * input.readUnsignedShort()) // interfaces
            buildMap {
                repeat(input.readUnsignedShort()) {
                    input.readUnsignedShort() // field access
                    val name = requireNotNull(utf8[input.readUnsignedShort()])
                    val descriptor = requireNotNull(utf8[input.readUnsignedShort()])
                    put(name, descriptor)
                    repeat(input.readUnsignedShort()) {
                        input.readUnsignedShort() // attribute name
                        input.skipNBytes(input.readInt().toLong() and 0xffffffffL)
                    }
                }
            }
        }
    }
}
