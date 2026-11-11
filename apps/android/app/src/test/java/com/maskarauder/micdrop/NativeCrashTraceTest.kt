package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream

class NativeCrashTraceTest {
    private fun varint(value: Long): ByteArray {
        val bytes = ByteArrayOutputStream(); var remaining = value
        do {
            val part = (remaining and 127).toInt(); remaining = remaining ushr 7
            bytes.write(part or if (remaining != 0L) 128 else 0)
        } while (remaining != 0L)
        return bytes.toByteArray()
    }
    private fun integer(field: Int, value: Long) = varint((field * 8).toLong()) + varint(value)
    private fun message(field: Int, value: ByteArray) = varint((field * 8 + 2).toLong()) + varint(value.size.toLong()) + value
    private fun text(field: Int, value: String) = message(field, value.toByteArray(Charsets.UTF_8))
    private fun thread(id: Long, name: String, frames: ByteArray) = message(16,
        integer(1, id) + message(2, text(2, name) + frames))

    @Test fun extractsOnlyTheCrashingThreadAndSymbolicStack() {
        val frame = integer(1, 0x1234) + text(4, "webrtc::Release") + integer(5, 12) +
            text(6, "/private/synthetic/location/libwebrtc.so") + text(8, "aabbccdd")
        val bytes = thread(42, "unrelated", message(4, text(4, "unrelated_frame"))) + integer(6, 7) +
            text(9, "private_command_line") + message(10, text(2, "SIGABRT") + text(4, "SI_TKILL")) +
            text(14, "synthetic assertion") + thread(7, "rtc-worker", message(4, frame) +
                message(3, text(1, "private_register")) + message(5, text(4, "private_memory"))) +
            message(18, text(1, "private_log_buffer"))
        val report = NativeCrashTrace.decode(bytes)
        assertTrue(report.contains("SIGABRT SI_TKILL"))
        assertTrue(report.contains("rtc-worker"))
        assertTrue(report.contains("pc 1234 libwebrtc.so (webrtc::Release+12) build-id=aabbccdd"))
        assertFalse(report.contains("unrelated_frame"))
        assertFalse(report.contains("private_"))
        assertFalse(report.contains("/private/"))
    }

    @Test fun skipsUnknownFixedAndLengthFieldsAndBoundsTheBacktrace() {
        val unknown = varint((200 * 8 + 1).toLong()) + ByteArray(8) +
            varint((201 * 8 + 5).toLong()) + ByteArray(4) + text(202, "unrecognized")
        val frames = (1..40).fold(ByteArray(0)) { bytes, index -> bytes + message(4, text(4, "frame_$index")) }
        val report = NativeCrashTrace.decode(unknown + integer(6, 3) + thread(3, "worker", frames))
        assertEquals(24, report.lineSequence().count { it.startsWith("  #") })
        assertTrue(report.contains("frame_24")); assertFalse(report.contains("frame_25"))
        assertFalse(report.contains("unrecognized"))
    }

    @Test fun rejectsMalformedLengthsTagsVarintsAndOversizedInput() {
        val malformed = listOf(byteArrayOf(0), byteArrayOf(0x32, 0x7f),
            ByteArray(11) { 0x80.toByte() }, byteArrayOf(0x33), ByteArray(NativeCrashTrace.MAX_BYTES + 1))
        malformed.forEach { bytes ->
            try { NativeCrashTrace.decode(bytes); fail("Malformed trace accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun missingCrashingThreadCannotBeReplacedWithAnotherThreadsStack() {
        val report = NativeCrashTrace.decode(integer(6, 99) + thread(4, "other", message(4, text(4, "wrong_stack"))))
        assertTrue(report.contains("Crashing thread stack: unavailable"))
        assertFalse(report.contains("wrong_stack"))
    }

    @Test fun unsignedRelativeProgramCounterSurvivesAndAbortLinksAreExcluded() {
        val bytes = integer(6, 1) + text(14, "failed https://synthetic.invalid/private-link") +
            thread(1, "worker", message(4, integer(1, -1)))
        val report = NativeCrashTrace.decode(bytes)
        assertTrue(report.contains("ffffffffffffffff"))
        assertFalse(report.contains("synthetic.invalid"))
    }
}
