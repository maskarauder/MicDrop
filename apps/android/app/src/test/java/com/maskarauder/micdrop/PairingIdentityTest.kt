package com.maskarauder.micdrop

import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class PairingIdentityTest {
    @Test fun routesOnlyPairingPrefixesToEnrollment() {
        assertTrue(PairingInvitation.isPairingLink("  micdrop://pair/v1/AbC_123\n"))
        assertTrue(PairingInvitation.isPairingLink("micdrop://pair/V1/AbC_123"))
        for (link in listOf("micdrop://v2/pair", "micdrop://paired/v1/AbC_123",
            "micdrop://pair/v2/AbC_123", "https://example.com/pair/v1/AbC_123")) {
            assertFalse(PairingInvitation.isPairingLink(link))
        }
    }
    private val pin = "a".repeat(64)
    private val client = "b".repeat(64)

    @Test fun trustsRenewedPublicKeyAndRejectsWrongPinAndExpiredCertificate() {
        val fixture = requireNotNull(javaClass.classLoader?.getResourceAsStream("host_certificates_v1.json"))
            .bufferedReader().use { it.readText() }
        fun field(name: String) = requireNotNull(Regex("\"$name\":\\s*\"([^\"]+)\"").find(fixture)).groupValues[1]
        fun certificate(name: String) = CertificateFactory.getInstance("X.509")
            .generateCertificate(Base64.getDecoder().decode(field(name)).inputStream()) as X509Certificate
        val initial = certificate("initial"); val renewed = certificate("renewed")
        assertFalse(initial.encoded.contentEquals(renewed.encoded))
        val trust = PublicIdentity.trust(LanInvitation.pinBytes(field("sha256_hex")), true)
        trust.checkServerTrusted(arrayOf(initial), "EC")
        trust.checkServerTrusted(arrayOf(renewed), "EC")
        for (action in listOf<() -> Unit>(
            { PublicIdentity.trust(ByteArray(32), true).checkServerTrusted(arrayOf(initial), "EC") },
            { trust.checkServerTrusted(arrayOf(certificate("expired")), "EC") },
            { trust.checkServerTrusted(emptyArray(), "EC") })) {
            try { action(); fail("Invalid host trust accepted") }
            catch (_: java.security.cert.CertificateException) { }
        }
    }

    @Test fun publicKeyEncodingMatchesIndependentGoFixture() {
        val fixture = requireNotNull(javaClass.classLoader?.getResourceAsStream("host_public_key_v1.json"))
            .bufferedReader().use { it.readText() }
        fun field(name: String) = requireNotNull(Regex("\"$name\":\\s*\"([^\"]+)\"").find(fixture)).groupValues[1]
        val hex = field("subject_public_key_info_der_hex")
        val der = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(der))
        assertEquals(field("sha256_hex"), PublicIdentity.hex(PublicIdentity.fingerprint(key)))
    }

    @Test fun rejectsOtherKeyAlgorithmsAndCurves() {
        val keys = listOf(
            KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair().public,
            KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp384r1")) }.generateKeyPair().public)
        for (key in keys) {
            try { PublicIdentity.fingerprint(key); fail("Unsupported key accepted") }
            catch (_: java.security.cert.CertificateException) { }
        }
    }

    @Test fun pairedConnectionHasNoBearerAndNoInvitationExpiry() {
        val connection = LanInvitation.paired("192.168.1.20", 9844, pin, client)
        assertEquals(3, connection.version)
        assertEquals("", connection.token)
        assertEquals(client, connection.clientKey)
        assertFalse(connection.expired(Long.MAX_VALUE))
        val moved = LanInvitation.paired("10.0.0.20", 9845, PublicIdentity.hex(connection.fingerprint), connection.clientKey)
        assertArrayEquals(connection.fingerprint, moved.fingerprint)
        assertEquals(connection.clientKey, moved.clientKey)
    }

    @Test fun pairingWindowAndTrustFieldsAreRequired() {
        val invitation = PairingInvitation.fromFields("192.168.1.20", 9844, pin, "s".repeat(43), 2000)
        assertFalse(invitation.expired(1999)); assertTrue(invitation.expired(2000))
        assertEquals(client, invitation.connection(client).clientKey)
        val invalid = listOf<() -> Unit>(
            { LanInvitation.paired("8.8.8.8", 9844, pin, client) },
            { LanInvitation.paired("192.168.001.20", 9844, pin, client) },
            { LanInvitation.paired("192.168.1.20", 0, pin, client) },
            { LanInvitation.paired("192.168.1.20", 9844, "", client) },
            { LanInvitation.paired("192.168.1.20", 9844, pin, "") },
            { PairingInvitation.fromFields("192.168.1.20", 9844, pin, "short", 2000) },
            { PairingInvitation.fromFields("192.168.1.20", 9844, pin, "s".repeat(43), 0) })
        for (action in invalid) {
            try { action(); fail("Incomplete pairing accepted") } catch (_: IllegalArgumentException) { }
        }
    }
}
