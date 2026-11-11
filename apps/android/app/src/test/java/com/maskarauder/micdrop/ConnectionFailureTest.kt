package com.maskarauder.micdrop

import java.net.ConnectException
import java.net.SocketTimeoutException
import java.security.cert.CertificateExpiredException
import java.util.concurrent.ExecutionException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.*
import org.junit.Test

class ConnectionFailureTest {
    @Test fun explainsInputSelectionFailureWithoutLeakingDeviceDetails() {
        for (problem in MicrophoneRouteProblem.entries) {
            val message = ConnectionFailure.describe(ConnectionStage.INPUT_ROUTE, MicrophoneRouteException(problem))
            assertTrue(message.contains("MICROPHONE_ROUTE"))
            assertTrue(message.contains(problem.detail))
        }
        val platformFailure = ConnectionFailure.describe(ConnectionStage.INPUT_ROUTE, SecurityException("secret-device-address"))
        assertTrue(platformFailure.contains("MICROPHONE_ROUTE"))
        assertFalse(platformFailure.contains("secret"))
    }
    @Test fun identifiesOldPhoneKeyWithoutBlamingHostOrLeakingException() {
        val error = SSLHandshakeException("secret-host").apply { initCause(PairingKeyUpgradeRequired()) }
        val message = ConnectionFailure.describe(ConnectionStage.PAIRING, error)
        assertTrue(message.contains("PAIRING_KEY_UPDATE"))
        assertTrue(message.contains("Forget saved connection"))
        assertFalse(message.contains("secret-host"))
        assertFalse(ConnectionFailure.retryableStatus(PairingKeyUpgradeRequired()))
    }
    @Test fun retriesOnlyTransientStatusFailures() {
        for (error in listOf(ConnectException(), SocketTimeoutException(), HttpFailure(503),
            ExecutionException(java.io.IOException()))) assertTrue(ConnectionFailure.retryableStatus(error))
        for (error in listOf(HttpFailure(401), HttpFailure(410), HttpFailure(423), HttpFailure(400), HttpFailure(409),
            SSLHandshakeException("private"), ExecutionException(CertificateExpiredException()),
            IllegalStateException(), InterruptedException())) assertFalse(ConnectionFailure.retryableStatus(error))
    }
    @Test fun explainsBusyWithoutInvalidatingSavedConnection() {
        val message = ConnectionFailure.describe(ConnectionStage.PAIRING, HttpFailure(423))
        assertTrue(message.contains("active session"))
        assertTrue(message.contains("Reconnect"))
        assertFalse(message.contains("Restart"))
    }
    @Test fun identifiesConsumedInvitation() {
        val message = ConnectionFailure.describe(ConnectionStage.PAIRING, HttpFailure(401))
        assertTrue(message.contains("HTTP_401"))
        assertTrue(message.contains("new invitation"))
    }
    @Test fun sendsRevokedPhoneToTheWindowsAppToPairAgain() {
        assertEquals("Connecting securely to Windows failed [HTTP_403].\nThis phone is not approved on Windows, or its pairing was revoked. In the Windows app, open Phones → Pair a phone and pair again.",
            ConnectionFailure.describe(ConnectionStage.PAIRING, HttpFailure(403)))
    }

    @Test fun diagnosesWrappedCertificateTimeFailureWithoutLeakingDetails() {
        val error = SSLHandshakeException("secret-url").apply { initCause(CertificateExpiredException("secret-pin")) }
        val message = ConnectionFailure.describe(ConnectionStage.PAIRING, ExecutionException(error))
        assertTrue(message.contains("CERTIFICATE_TIME"))
        assertFalse(message.contains("secret"))
    }

    @Test fun distinguishesReachabilityTimeoutAndNativeLoad() {
        for ((error, code) in listOf(ConnectException("secret-ip") to "HOST_UNREACHABLE",
            SocketTimeoutException("secret-token") to "TIMEOUT", UnsatisfiedLinkError("secret-path") to "NATIVE_LOAD")) {
            val message = ConnectionFailure.describe(ConnectionStage.PAIRING, error)
            assertTrue(message.contains(code)); assertFalse(message.contains("secret"))
        }
    }

    @Test fun retainsNegotiationStageWithoutEchoingSdp() {
        val message = ConnectionFailure.describe(ConnectionStage.CODEC, IllegalStateException("secret-sdp"))
        assertTrue(message.contains(ConnectionStage.CODEC.label))
        assertTrue(message.contains("SETUP_FAILED")); assertFalse(message.contains("secret"))
    }
}
