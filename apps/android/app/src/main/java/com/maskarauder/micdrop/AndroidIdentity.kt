package com.maskarauder.micdrop

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyFactory
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.security.auth.x500.X500Principal

// All calls run on a storage/network worker, never the main thread. Android's
// TLS provider signs CertificateVerify through the non-exportable Keystore key.
internal object AndroidIdentity {
    private const val ALIAS = "micdrop.pairing.identity.v1"
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    fun exists(): Boolean = store().containsAlias(ALIAS)

    fun ensure(): String {
        val keys = store()
        if (!keys.containsAlias(ALIAS)) {
            val now = System.currentTimeMillis()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    // Conscrypt hashes TLS CertificateVerify itself and asks
                    // Keystore to sign that digest through NONEwithECDSA.
                    // SHA-256 is also needed for the self-signed certificate.
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                    .setCertificateSubject(X500Principal("CN=MicDrop Android"))
                    .setCertificateSerialNumber(BigInteger.ONE)
                    .setCertificateNotBefore(Date(now - 300_000))
                    .setCertificateNotAfter(Date(now + 10L * 365 * 24 * 60 * 60 * 1000))
                    .setUserAuthenticationRequired(false).build())
            }.generateKeyPair()
        }
        val certificate = store().getCertificate(ALIAS) as? X509Certificate
            ?: throw IllegalStateException("Protected identity unavailable")
        certificate.checkValidity()
        val fingerprint = PublicIdentity.hex(PublicIdentity.fingerprint(certificate.publicKey))
        manager(fingerprint) // Detect an old, immutable key policy before TLS.
        return fingerprint
    }

    fun manager(expected: String): X509ExtendedKeyManager {
        val keys = store()
        val key = keys.getKey(ALIAS, null) as? PrivateKey
            ?: throw IllegalStateException("Protected identity unavailable")
        val certificate = keys.getCertificate(ALIAS) as? X509Certificate
            ?: throw IllegalStateException("Protected identity unavailable")
        check(PublicIdentity.hex(PublicIdentity.fingerprint(certificate.publicKey)) == expected)
        certificate.checkValidity()
        val info = KeyFactory.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java)
        if (KeyProperties.DIGEST_NONE !in info.digests || KeyProperties.DIGEST_SHA256 !in info.digests) {
            throw PairingKeyUpgradeRequired()
        }
        return object : X509ExtendedKeyManager() {
            private fun suitable(types: Array<out String>?): String? = if (types?.any { it == "EC" } == true) ALIAS else null
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?): String? = suitable(keyType)
            override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?): String? = suitable(keyType)
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
                if (keyType == "EC") arrayOf(ALIAS) else null
            override fun getCertificateChain(alias: String?): Array<X509Certificate>? = if (alias == ALIAS) arrayOf(certificate) else null
            override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == ALIAS) key else null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
        }
    }

    fun forget() { store().deleteEntry(ALIAS); check(!store().containsAlias(ALIAS)) }
}
