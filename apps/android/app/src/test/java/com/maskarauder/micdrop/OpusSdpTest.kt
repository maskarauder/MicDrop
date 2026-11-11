package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class OpusSdpTest {
    private fun sdp(vararg lines: String) = lines.joinToString("\r\n", postfix = "\r\n")

    @Test fun preservesTransportAndOtherPayloadsWhileReplacingMono() {
        val input = sdp("v=0", "a=ice-pwd:example-credential", "m=audio 9 UDP/TLS/RTP/SAVPF 111 101",
            "a=recvonly", "a=rtpmap:111 opus/48000/2", "a=fmtp:111 minptime=10;stereo=0;useinbandfec=1",
            "a=rtpmap:101 telephone-event/8000", "a=fmtp:101 0-16", "a=candidate:example",
            "m=video 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 VP8/90000", "a=fmtp:111 x=1")
        val answer = OpusSdp.stereoAnswer(input)
        assertEquals(input.replace("minptime=10;stereo=0;useinbandfec=1", "minptime=10;useinbandfec=1;stereo=1"), answer)
        assertEquals(answer, OpusSdp.stereoAnswer(answer))
    }

    @Test fun createsMissingFmtpForDynamicPayloadAndPreservesRejectedSection() {
        val input = sdp("v=0", "m=audio 0 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 stereo=0", "m=audio 9 UDP/TLS/RTP/SAVPF 109", "a=rtpmap:109 OPUS/48000/2")
        assertEquals(input + "a=fmtp:109 stereo=1\r\n", OpusSdp.stereoAnswer(input.replace("\r\n", "\n")))
    }

    @Test fun removesDuplicateStereoParameters() {
        val input = sdp("v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;stereo=0; STEREO = 0; useinbandfec=1")
        assertTrue(OpusSdp.stereoAnswer(input).contains("a=fmtp:111 minptime=10;useinbandfec=1;stereo=1\r\n"))
    }

    @Test fun refusesMissingOrRejectedOpusInsteadOfSilentlyUsingMono() {
        for (input in listOf(sdp("v=0", "m=audio 0 UDP/TLS/RTP/SAVPF 111", "a=rtpmap:111 opus/48000/2"),
            sdp("v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 0", "a=rtpmap:111 opus/48000/2"))) {
            assertThrows(IllegalStateException::class.java) { OpusSdp.stereoAnswer(input) }
        }
    }
}
