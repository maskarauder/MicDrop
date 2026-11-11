package com.maskarauder.micdrop

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.net.InetAddress
import java.net.Socket
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PairingPlatformTest {
    // This test APK has its own UID/Keystore namespace; no production app key is touched.
    private val alias = "micdrop.pairing.identity.v1"
    private fun keys() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    @Before fun reset() { AndroidIdentity.forget() }
    @After fun cleanup() { AndroidIdentity.forget() }

    @Test fun oldPolicyCannotSignTlsDigestAndIsNotSilentlyReplaced() {
        KeyPairGenerator.getInstance("EC", "AndroidKeyStore").apply {
            initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256).build())
        }.generateKeyPair()
        val key = keys().getKey(alias, null) as PrivateKey
        val before = PublicIdentity.fingerprint(keys().getCertificate(alias).publicKey)
        var rejected = false
        try { signDigest(key, ByteArray(32) { 1 }) } catch (_: GeneralSecurityException) { rejected = true }
        assertTrue("The old SHA-256-only key must reject Conscrypt's prehashed operation", rejected)
        try { AndroidIdentity.ensure(); fail("Old key policy was accepted") }
        catch (_: PairingKeyUpgradeRequired) { }
        assertArrayEquals(before, PublicIdentity.fingerprint(keys().getCertificate(alias).publicKey))
        AndroidIdentity.forget() // Explicit user recovery path.
        assertNotEquals(PublicIdentity.hex(before), AndroidIdentity.ensure())
    }

    @Test fun protectedKeySignsPrehashedDataAndSurvivesReload() {
        val fingerprint = AndroidIdentity.ensure()
        assertEquals(fingerprint, AndroidIdentity.ensure())
        val key = keys().getKey(alias, null) as PrivateKey
        assertNull("Private key must remain non-exportable", key.encoded)
        val message = "MicDrop TLS signing regression test".toByteArray(Charsets.UTF_8)
        val signature = signDigest(key, MessageDigest.getInstance("SHA-256").digest(message))
        val verifier = Signature.getInstance("SHA256withECDSA").apply {
            initVerify(keys().getCertificate(alias).publicKey); update(message)
        }
        assertTrue(verifier.verify(signature))
    }

    @Test fun conscryptCompletesMutualTlsWithProtectedClientKey() = mutualTls(false)
    @Test fun engineCompletesMutualTlsWithProtectedClientKeyAndFragmentedRecords() = mutualTls(true)

    private fun mutualTls(engineTransport: Boolean) {
        val fingerprint = AndroidIdentity.ensure()
        val manager = AndroidIdentity.manager(fingerprint)
        val name = requireNotNull(manager.getClientAliases("EC", null)).single()
        val certificate = requireNotNull(manager.getCertificateChain(name)).single()
        val serverManager = object : X509ExtendedKeyManager() {
            override fun getPrivateKey(alias: String?): PrivateKey? = manager.getPrivateKey(alias)
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? = manager.getCertificateChain(alias)
            override fun getServerAliases(type: String?, issuers: Array<out Principal>?): Array<String>? =
                if (type == "EC") arrayOf(name) else null
            override fun chooseServerAlias(type: String?, issuers: Array<out Principal>?, socket: Socket?): String? =
                getServerAliases(type, issuers)?.firstOrNull()
            override fun chooseEngineServerAlias(type: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String? =
                getServerAliases(type, issuers)?.firstOrNull()
            override fun getClientAliases(type: String?, issuers: Array<out Principal>?): Array<String>? = null
            override fun chooseClientAlias(types: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? = null
        }
        val serverTrust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkServerTrusted(chain: Array<X509Certificate>, type: String) { throw java.security.cert.CertificateException() }
            override fun checkClientTrusted(chain: Array<X509Certificate>, type: String) {
                check(chain.size == 1)
                chain[0].checkValidity(); chain[0].verify(chain[0].publicKey)
                check(PublicIdentity.hex(PublicIdentity.fingerprint(chain[0].publicKey)) == fingerprint)
            }
        }
        val serverContext = SSLContext.getInstance("TLSv1.3").apply { init(arrayOf(serverManager), arrayOf(serverTrust), null) }
        val clientContext = SSLContext.getInstance("TLSv1.3").apply {
            init(arrayOf(manager), arrayOf(PublicIdentity.trust(PublicIdentity.fingerprint(certificate.publicKey), true)), null)
        }
        val loopback = InetAddress.getByName("127.0.0.1")
        val executor = Executors.newSingleThreadExecutor()
        try {
            (serverContext.serverSocketFactory.createServerSocket(0, 1, loopback) as SSLServerSocket).use { server ->
                server.enabledProtocols = arrayOf("TLSv1.3"); server.needClientAuth = true; server.soTimeout = 5000
                val result = executor.submit {
                    (server.accept() as SSLSocket).use { socket ->
                        socket.soTimeout = 5000; socket.startHandshake()
                        assertEquals("TLSv1.3", socket.session.protocol)
                        assertEquals(0x4d, socket.inputStream.read())
                        socket.outputStream.write(if (engineTransport) ByteArray(70000) { (it % 251).toByte() } else byteArrayOf(0x44)); socket.outputStream.flush()
                    }
                }
                // This loopback contract targets Keystore/Conscrypt signing. The
                // app's HTTPS endpoint/SAN verification remains enabled in production.
                if (engineTransport) {
                    Socket(loopback, server.localPort).use { socket ->
                        socket.soTimeout = 5000
                        val engine = clientContext.createSSLEngine().apply { useClientMode = true; enabledProtocols = arrayOf("TLSv1.3") }
                        val tls = EngineStream(engine, { bytes, offset, count -> socket.inputStream.read(bytes, offset, minOf(count, 137)) },
                            { bytes -> socket.outputStream.write(bytes); socket.outputStream.flush() }, {})
                        tls.handshake(); assertEquals("TLSv1.3", engine.session.protocol)
                        tls.write(byteArrayOf(0x4d))
                        val received = ByteArray(70000); var total = 0
                        while (total < received.size) { val n = tls.read(received, total, received.size - total); assertTrue(n > 0); total += n }
                        assertArrayEquals(ByteArray(70000) { (it % 251).toByte() }, received)
                    }
                } else (clientContext.socketFactory.createSocket(loopback, server.localPort) as SSLSocket).use { socket ->
                    socket.soTimeout = 5000; socket.enabledProtocols = arrayOf("TLSv1.3"); socket.startHandshake()
                    assertEquals("TLSv1.3", socket.session.protocol)
                    socket.outputStream.write(0x4d); socket.outputStream.flush()
                    assertEquals(0x44, socket.inputStream.read())
                }
                result.get(10, TimeUnit.SECONDS)
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun connectRoutingPreservesCaseSensitivePairingPayload() {
        val pin = "a".repeat(64)
        val secret = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { it.toByte() })
        val json = JSONObject().put("host", "192.168.1.20").put("port", 9844)
            .put("host_key", pin).put("secret", secret).put("expires_at", 2000)
        val payload = Base64.getUrlEncoder().withoutPadding().encodeToString(json.toString().toByteArray(Charsets.UTF_8))
        val invitation = PairingInvitation.parse(" micdrop://pair/V1/$payload ")
        assertEquals(secret, invitation.secret)
        assertEquals(pin, invitation.pin)
        assertFalse(PairingInvitation.isPairingLink(invitation.connection("b".repeat(64)).pairedRecord()))
    }

    private fun signDigest(key: PrivateKey, digest: ByteArray): ByteArray = Signature.getInstance("NONEwithECDSA").run {
        initSign(key); update(digest); sign()
    }
}
