package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class LanInvitationTest {
    private fun fields(version: Int = 2, host: String = "192.168.1.10", port: Int = 9844,
        token: String = "a".repeat(43), pin: String = "01".repeat(32), expiry: Long = 2000) =
        LanInvitation.fromFields(version, host, port, token, pin, expiry)

    @Test fun retainsTrustAndExpiresAtBoundary() {
        val invitation = fields()
        assertEquals("192.168.1.10", invitation.host)
        assertEquals(9844, invitation.port)
        assertEquals("a".repeat(43), invitation.token)
        assertArrayEquals(ByteArray(32) { 1 }, invitation.fingerprint)
        assertFalse(invitation.expired(1999))
        assertTrue(invitation.expired(2000))
        assertTrue(invitation.expired(2001))
        val legacy = fields(version = 1, expiry = 0)
        assertEquals(1, legacy.version)
        assertFalse(legacy.expired(2001)) // Only its old host can decide v1 expiry.
    }

    @Test fun rejectsInvalidOrIncompleteTrustMaterial() {
        val invalid = listOf<() -> Unit>(
            { fields(version = 3) }, { fields(version = 1) }, { fields(expiry = 0) },
            { fields(expiry = Long.MAX_VALUE) }, { fields(host = "8.8.8.8") },
            { fields(host = "192.168.1.999") }, { fields(host = "localhost") },
            { fields(port = 0) }, { fields(port = 65536) }, { fields(token = "short") },
            { fields(token = "?".repeat(43)) }, { fields(pin = "a".repeat(63)) },
            { fields(pin = "z".repeat(64)) })
        for (action in invalid) {
            try { action(); fail("Invalid connection link accepted") } catch (_: IllegalArgumentException) { }
        }
    }
}
