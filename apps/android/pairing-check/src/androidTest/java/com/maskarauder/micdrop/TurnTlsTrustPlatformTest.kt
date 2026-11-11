package com.maskarauder.micdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TurnTlsTrustPlatformTest {
    private val fixtures by lazy {
        InstrumentationRegistry.getInstrumentation().context.assets.open("turn-test-certificates.json")
            .bufferedReader().use { JSONObject(it.readText()) }
    }
    private fun certificate(name: String): X509Certificate = fixtures.getString(name).byteInputStream().use {
        CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
    }
    private fun chain(vararg names: String): Array<ByteArray> = names.map { certificate(it).encoded }.toTypedArray()
    private fun trusted(root: String = "root"): TurnTlsTrust = TurnTlsTrust {
        // In-memory only: these tests never add a CA to Android's system/user
        // trust stores and never use a trust-all implementation.
        val store = KeyStore.getInstance("PKCS12").apply {
            load(null); setCertificateEntry("test-root", certificate(root))
        }
        val manager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
            .trustManagers.filterIsInstance<X509TrustManager>().single()
        manager
    }

    @Test fun acceptsFullRsaAndEcChainsUsingAndroidTrust() {
        val rsa = trusted()
        assertTrue(rsa.verify(chain("server", "intermediate")))
        assertEquals(TurnTlsTrustSnapshot(1, 0, TurnTlsTrustResult.TRUSTED), rsa.snapshot())
        assertTrue(trusted("ec_root").verify(chain("ec_server", "ec_intermediate")))
    }

    @Test fun rejectsUnknownRootEvenWhenThePeerSuppliesIt() {
        val verifier = TurnTlsTrust()
        assertFalse(verifier.verify(chain("server", "intermediate", "root")))
        assertEquals(TurnTlsTrustSnapshot(1, 1, TurnTlsTrustResult.REJECTED), verifier.snapshot())
    }

    @Test fun rejectsExpiredWrongUsageBadSignatureAndMissingIntermediate() {
        for (name in listOf("expired", "clientonly", "invalidsignature")) {
            val verifier = trusted()
            assertFalse(name, verifier.verify(chain(name, "intermediate")))
            assertEquals(TurnTlsTrustResult.REJECTED, verifier.snapshot().lastResult)
        }
        assertFalse(trusted().verify(chain("server")))
    }

    @Test fun rejectsMalformedAndOversizedInputBeforeConstructingTrustManager() {
        val verifier = TurnTlsTrust { error("Trust manager must not be reached") }
        for (chain in listOf(emptyArray<ByteArray>(), arrayOf(byteArrayOf()), arrayOf(byteArrayOf(1, 2, 3)),
            Array(17) { byteArrayOf(1) }, arrayOf(ByteArray(1024 * 1024 + 1)),
            arrayOf(certificate("server").encoded + byteArrayOf(0)))) {
            assertFalse(verifier.verify(chain))
            assertEquals(TurnTlsTrustResult.INVALID_CERTIFICATE, verifier.snapshot().lastResult)
        }
        assertEquals(6, verifier.snapshot().checks)
        assertEquals(6, verifier.snapshot().failures)
    }

    @Test fun trustProviderFailureFailsClosedWithoutPrivateExceptionText() {
        val verifier = TurnTlsTrust { throw java.security.KeyStoreException("private server information") }
        assertFalse(verifier.verify(chain("server", "intermediate")))
        val snapshot = verifier.snapshot()
        assertEquals(TurnTlsTrustResult.UNAVAILABLE, snapshot.lastResult)
        assertFalse(snapshot.fields().toString().contains("private"))
        assertFalse(snapshot.text().contains("private"))
    }
}
