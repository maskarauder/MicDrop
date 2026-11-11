package com.maskarauder.micdrop

import javax.crypto.KeyGenerator
import org.junit.Assert.*
import org.junit.Test

class ConnectionEnvelopeTest {
    private fun key() = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private fun rejected(action: () -> Unit) {
        try { action(); fail("Accepted invalid saved credential") } catch (_: Exception) { }
    }

    @Test fun preservesCompleteLinkAndGeneratesNewNonce() {
        val key = key()
        val link = "micdrop://v2/host-port-token-and-certificate-pin"
        val first = ConnectionEnvelope.seal(link, key)
        val second = ConnectionEnvelope.seal(link, key)
        assertEquals(link, ConnectionEnvelope.open(first, key))
        assertEquals(link, ConnectionEnvelope.open(second, key))
        assertFalse(first.contentEquals(second))
        assertFalse(String(first, Charsets.ISO_8859_1).contains(link))
        val longest = "a".repeat(4096)
        assertEquals(longest, ConnectionEnvelope.open(ConnectionEnvelope.seal(longest, key), key))
    }

    @Test fun rejectsTamperingWrongKeyAndPartialWrites() {
        val key = key()
        val original = ConnectionEnvelope.seal("micdrop://v2/secret", key)
        for (index in listOf(0, 3, 5, 16, original.lastIndex)) {
            val changed = original.copyOf()
            changed[index] = (changed[index].toInt() xor 1).toByte()
            rejected { ConnectionEnvelope.open(changed, key) }
        }
        rejected { ConnectionEnvelope.open(original, key()) }
        for (length in listOf(0, 4, 16, 32, original.size - 1))
            rejected { ConnectionEnvelope.open(original.copyOf(length), key) }
        rejected { ConnectionEnvelope.open(ByteArray(ConnectionEnvelope.MAX_BYTES + 1), key) }
        rejected { ConnectionEnvelope.seal("x".repeat(4097), key) }
        rejected { ConnectionEnvelope.seal("", key) }
    }
}
