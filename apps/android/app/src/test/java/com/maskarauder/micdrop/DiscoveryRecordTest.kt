package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class DiscoveryRecordTest {
    private val pin = "ab".repeat(32)
    private val client = "cd".repeat(32)
    private fun txt(): Map<String, ByteArray?> = mapOf("v" to "1".toByteArray(),
        "p" to "3".toByteArray(), "id" to pin.toByteArray())
    private val host = DiscoveredHost("192.168.1.20", 9844, pin)

    @Test fun acceptsOnlyTheSupportedServiceAndWireSchema() {
        for (type in listOf("_micdrop._tcp", "_micdrop._tcp.", "_micdrop._tcp.local.", "_MICDROP._TCP.")) {
            assertTrue(DiscoveryRecord.acceptsType(type))
        }
        for (type in listOf("", "_micdrop._udp", "_micdrop._tcp.example.com", "_http._tcp")) {
            assertFalse(DiscoveryRecord.acceptsType(type))
        }
        assertEquals(listOf(host), DiscoveryRecord.parse(listOf(host.host, host.host), 9844, txt()))
        val invalid: List<Map<String, ByteArray?>> = listOf(
            txt() - "id", txt() + ("secret" to "private".toByteArray()),
            txt() + ("v" to "2".toByteArray()), txt() + ("p" to "2".toByteArray()),
            txt() + ("id" to null), txt() + ("p" to null),
            txt() + ("id" to pin.uppercase().toByteArray()),
            txt() + ("id" to (pin + "a").toByteArray()),
            txt() + ("id" to ByteArray(64) { 0xff.toByte() }))
        for (attributes in invalid) assertTrue(DiscoveryRecord.parse(listOf(host.host), 9844, attributes).isEmpty())
    }

    @Test fun rejectsHostnamesPublicAddressesIpv6AndInvalidPorts() {
        val invalid = listOf("localhost", "host.local", "8.8.8.8", "127.0.0.1", "0.0.0.0",
            "169.254.1.2", "224.0.0.251", "fc00::1", "::1", "192.168.001.20", "192.168.1.999")
        for (address in invalid) assertTrue(DiscoveryRecord.parse(listOf(address), 9844, txt()).isEmpty())
        for (port in listOf(-1, 0, 65536)) assertTrue(DiscoveryRecord.parse(listOf(host.host), port, txt()).isEmpty())
        assertEquals(listOf(host), DiscoveryRecord.parse(listOf("fc00::1", host.host), 9844, txt()))
        assertEquals(4, DiscoveryRecord.parse((1..8).map { "10.0.0.$it" }, 9844, txt()).size)
    }

    @Test fun addressHintRetainsSavedTrustAndCannotEnrollOrDowngrade() {
        val saved = LanInvitation.paired("10.0.0.20", 9845, pin, client)
        val moved = host.connectionFor(saved)
        assertEquals(host.host, moved.host)
        assertEquals(host.port, moved.port)
        assertArrayEquals(saved.fingerprint, moved.fingerprint)
        assertEquals(saved.clientKey, moved.clientKey)
        assertEquals(3, moved.version)
        assertEquals("", moved.token)
        assertEquals("10.0.0.20", saved.host) // Candidate creation does not mutate the saved connection.
        val remoteToken = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 7 })
        val remote = RemoteConnection("https://relay.example.com", remoteToken, true)
        val savedRemote = LanInvitation.paired("10.0.0.20", 9845, pin, client, remote)
        val movedRemote = host.connectionFor(savedRemote)
        assertNull(moved.remote)
        assertEquals(host.host, movedRemote.host)
        assertEquals(host.port, movedRemote.port)
        assertSame(remote, movedRemote.remote)
        assertEquals("https://relay.example.com", movedRemote.remote?.url)
        assertEquals(remoteToken, movedRemote.remote?.token)
        assertEquals(true, movedRemote.remote?.forceRelay)
        val v2 = LanInvitation.fromFields(2, host.host, host.port, "a".repeat(43), pin, 2000)
        assertFalse(host.matches(null)); assertFalse(host.matches(v2))
        for (untrusted in listOf(v2, LanInvitation.paired(host.host, host.port, "f".repeat(64), client))) {
            try { host.connectionFor(untrusted); fail("Discovery replaced saved trust") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun callbacksFromLostOrPreviousSearchCannotRestoreAHost() {
        val index = DiscoveryIndex()
        val old = requireNotNull(index.claim("host/network"))
        index.update(old, listOf(host)); assertEquals(listOf(host), index.hosts())
        assertEquals(old, index.remove(old.service))
        val current = requireNotNull(index.claim(old.service))
        index.update(old, listOf(host)); assertTrue(index.hosts().isEmpty())
        index.update(current, listOf(host)); assertEquals(listOf(host), index.hosts())
        index.clear()
        val next = requireNotNull(index.claim(old.service))
        index.update(current, listOf(host)); assertTrue(index.hosts().isEmpty())
        assertFalse(index.contains(current)); assertTrue(index.contains(next))
    }

    @Test fun discoveryBoundsAndDeduplicatesWorkAndResults() {
        val index = DiscoveryIndex()
        assertNull(index.claim("")); assertNull(index.claim("x".repeat(257)))
        val first = requireNotNull(index.claim("one"))
        assertNull(index.claim("one"))
        index.update(first, List(5) { host })
        val second = requireNotNull(index.claim("two"))
        index.update(second, listOf(host)); assertEquals(listOf(host), index.hosts())
        for (i in 2 until DiscoveryRecord.MAX_SERVICES) {
            val ticket = requireNotNull(index.claim("service-$i"))
            index.update(ticket, (1..6).map { host.copy(host = "10.0.$i.$it") })
        }
        assertNull(index.claim("overflow"))
        assertEquals(DiscoveryRecord.MAX_HOSTS, index.hosts().size)
        index.remove("one"); assertNotNull(index.claim("replacement"))
    }
}
