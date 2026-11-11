package com.maskarauder.micdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayInputStream
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemoteProtocolTest {
    private val token = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { it.toByte() })
    @Test fun pairingAndSavedConnectionKeepRemoteRoleAndPolicy() {
        val remote = RemoteConnection("https://relay.example.test:8443", token, true)
        val pair = PairingInvitation.fromFields("192.168.1.20", 9844, "a".repeat(64), token, 2000000000L)
        val json = org.json.JSONObject().put("host", pair.host).put("port", pair.port).put("host_key", pair.pin)
            .put("secret", pair.secret).put("expires_at", pair.expiresAt)
        val link = "micdrop://pair/v1/" + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toString().toByteArray())
        val wrapped = remote.wrap(link)
        assertTrue(PairingInvitation.isPairingLink(wrapped))
        val parsed = PairingInvitation.parse(wrapped).connection("b".repeat(64))
        val saved = LanInvitation.parse(parsed.pairedRecord())
        assertEquals(3, saved.version); assertEquals(parsed.clientKey, saved.clientKey)
        assertEquals(remote.url, saved.remote?.url); assertEquals(token, saved.remote?.token)
        assertEquals(true, saved.remote?.forceRelay)
        val moved = LanInvitation.parse(LanInvitation.paired("10.0.0.20", 9845, "a".repeat(64), saved.clientKey, saved.remote).pairedRecord())
        assertEquals("10.0.0.20", moved.host); assertEquals(9845, moved.port)
        assertEquals(remote.url, moved.remote?.url); assertEquals(token, moved.remote?.token); assertEquals(true, moved.remote?.forceRelay)
        assertFalse(PairingInvitation.isPairingLink(parsed.pairedRecord()))
        assertEquals("Remote connection", remote.toString())
    }
    @Test fun rejectsUnsafeRemoteEndpointsAndNestedInvitations() {
        for (url in listOf("http://relay.test", "https://user@relay.test", "https://relay.test/path", "https://relay.test?secret=x", "https://relay.test#fragment"))
            assertThrows(IllegalArgumentException::class.java) { RemoteConnection(url, token, false) }
        val remote = RemoteConnection("https://relay.test", token, false)
        val paired = LanInvitation.paired("192.168.1.20", 9844, "a".repeat(64), "b".repeat(64)).pairedRecord()
        assertThrows(IllegalArgumentException::class.java) { LanInvitation.parse(remote.wrap(remote.wrap(paired))) }
    }
    private fun response(value: String) = RemoteHttp.readResponse(ByteArrayInputStream(value.toByteArray(Charsets.US_ASCII)))
    @Test fun boundedHttpAcceptsGoResponsesAndRejectsTruncationAndAmbiguousFraming() {
        assertTrue(response("HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}").getBoolean("ok"))
        assertTrue(response("HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n{\"ok\":true}").getBoolean("ok"))
        for (value in listOf(
            "HTTP/1.0 200 OK\r\nContent-Length: 99\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nContent-Length: 999999\r\n\r\n",
            "HTTP/1.0 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
            "HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "HTTP/1.0 200 OK\r\nX-Large: " + "x".repeat(8192),
            "HTTP/1.0 200 OK\r\n\r\n" + "x".repeat(RemoteHttp.MAX_BODY + 1)))
            assertThrows(java.io.IOException::class.java) { response(value) }
        val rejected = assertThrows(HttpFailure::class.java) { response("HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\n\r\n") }
        assertEquals(403, rejected.status)
    }
    @Test fun largeLengthDelimitedStatusCompletesWithoutAcceptingTransportEof() {
        val body = org.json.JSONObject().put("payload", "x".repeat(3000)).toString()
        fun stream(length: Int?, payload: String = body) = object : ByteArrayInputStream(
            ("HTTP/1.0 200 OK\r\n" + (length?.let { "Content-Length: $it\r\n" } ?: "") +
                "\r\n" + payload).toByteArray(Charsets.US_ASCII)) {
            override fun read(): Int = super.read().also { if (it < 0) throw SignalingStreamEnded() }
            override fun read(bytes: ByteArray, offset: Int, count: Int): Int =
                super.read(bytes, offset, count).also { if (it < 0) throw SignalingStreamEnded() }
        }
        assertEquals(3000, RemoteHttp.readResponse(stream(body.length)).getString("payload").length)
        // Neither a complete-looking JSON object without framing nor a partial
        // length-delimited body makes an unauthenticated transport EOF valid.
        assertThrows(SignalingStreamEnded::class.java) { RemoteHttp.readResponse(stream(null)) }
        assertThrows(SignalingStreamEnded::class.java) { RemoteHttp.readResponse(stream(body.length, body.dropLast(10))) }
    }
}
