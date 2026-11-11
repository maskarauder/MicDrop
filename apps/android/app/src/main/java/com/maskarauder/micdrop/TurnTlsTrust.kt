package com.maskarauder.micdrop

import java.io.ByteArrayInputStream
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

internal enum class TurnTlsTrustResult(val wire: String) {
    NOT_CHECKED("not_checked"), TRUSTED("trusted"), INVALID_CERTIFICATE("invalid_certificate"),
    REJECTED("rejected"), UNAVAILABLE("unavailable")
}

internal data class TurnTlsTrustSnapshot(val checks: Int, val failures: Int, val lastResult: TurnTlsTrustResult) {
    fun fields(): Map<String, Any> = linkedMapOf("version" to 1, "checks" to checks,
        "failures" to failures, "last_result" to lastResult.wire)
    fun text(): String = "Android TURN/TLS trust fallback: checks=$checks · failures=$failures · last=${lastResult.wire}\n" +
        "Certificate-chain checks do not prove hostname validation, TURN allocation or media delivery."
}

// Native WebRTC's bundled roots omit some public CAs. Validate the full chain
// with Android's trust manager when WebRTC needs a fallback. The SDK still
// checks the configured TURN hostname after this callback; no bypass is set.
internal class TurnTlsTrust(createTrustManager: () -> X509TrustManager = {
    TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
        init(null as KeyStore?)
    }.trustManagers.filterIsInstance<X509TrustManager>().single()
}) {
    private val trustManager by lazy(createTrustManager)
    private var checks = 0
    private var failures = 0
    private var lastResult = TurnTlsTrustResult.NOT_CHECKED

    fun verify(chain: Array<ByteArray>): Boolean {
        if (chain.isEmpty() || chain.size > 16 || chain.any { it.isEmpty() } ||
            chain.sumOf { it.size.toLong() } > 1024 * 1024) return record(TurnTlsTrustResult.INVALID_CERTIFICATE)
        val certificates = try {
            val parser = CertificateFactory.getInstance("X.509")
            chain.map { der ->
                ByteArrayInputStream(der).use { input ->
                    val certificate = parser.generateCertificate(input) as X509Certificate
                    require(input.available() == 0 && certificate.encoded.contentEquals(der))
                    certificate
                }
            }.toTypedArray()
        } catch (_: CertificateException) {
            return record(TurnTlsTrustResult.INVALID_CERTIFICATE)
        } catch (_: RuntimeException) {
            return record(TurnTlsTrustResult.INVALID_CERTIFICATE)
        }
        val manager = try { trustManager }
        catch (_: GeneralSecurityException) { return record(TurnTlsTrustResult.UNAVAILABLE) }
        catch (_: RuntimeException) { return record(TurnTlsTrustResult.UNAVAILABLE) }
        return try {
            // Conscrypt accepts the authentication key's algorithm; do not
            // assume RSA, since public TURN certificates can also use EC keys.
            manager.checkServerTrusted(certificates, certificates[0].publicKey.algorithm)
            record(TurnTlsTrustResult.TRUSTED)
        } catch (_: CertificateException) {
            record(TurnTlsTrustResult.REJECTED)
        } catch (_: RuntimeException) {
            record(TurnTlsTrustResult.UNAVAILABLE)
        }
    }

    @Synchronized private fun record(result: TurnTlsTrustResult): Boolean {
        checks = minOf(checks + 1, 1_000_000)
        if (result != TurnTlsTrustResult.TRUSTED) failures = minOf(failures + 1, 1_000_000)
        lastResult = result
        return result == TurnTlsTrustResult.TRUSTED
    }
    @Synchronized fun snapshot(): TurnTlsTrustSnapshot = TurnTlsTrustSnapshot(checks, failures, lastResult)
}
