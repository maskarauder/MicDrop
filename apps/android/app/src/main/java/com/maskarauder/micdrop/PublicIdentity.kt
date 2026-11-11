package com.maskarauder.micdrop

import java.security.AlgorithmParameters
import java.security.MessageDigest
import java.security.PublicKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.X509TrustManager

internal object PublicIdentity {
    fun fingerprint(key: PublicKey): ByteArray {
        val ec = key as? ECPublicKey ?: throw CertificateException("P-256 identity required")
        val p256 = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        if (ec.params.curve != p256.curve || ec.params.generator != p256.generator ||
            ec.params.order != p256.order || ec.params.cofactor != p256.cofactor) {
            throw CertificateException("P-256 identity required")
        }
        return MessageDigest.getInstance("SHA-256").digest(key.encoded)
    }
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }

    fun trust(pin: ByteArray, publicKey: Boolean): X509TrustManager = object : X509TrustManager {
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            throw CertificateException("Client certificates are unsupported")
        }
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            if (chain.size != 1) throw CertificateException("One pinned host certificate required")
            val certificate = chain[0]
            val actual = if (publicKey) fingerprint(certificate.publicKey)
                else MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
            if (!MessageDigest.isEqual(pin, actual)) throw CertificateException("Host identity changed")
            certificate.checkValidity()
            if (publicKey) {
                if (certificate.hasUnsupportedCriticalExtension()) throw CertificateException("Unsupported certificate")
                if (certificate.keyUsage?.getOrNull(0) == false) throw CertificateException("Signing key required")
                val usage = certificate.extendedKeyUsage
                if (usage != null && "1.3.6.1.5.5.7.3.1" !in usage && "2.5.29.37.0" !in usage) {
                    throw CertificateException("Server certificate required")
                }
                certificate.verify(certificate.publicKey)
            }
            // HttpsURLConnection still performs its normal IP/hostname check.
        }
    }
}
