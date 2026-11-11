package com.maskarauder.micdrop

import java.security.cert.CertificateExpiredException
import java.util.concurrent.ExecutionException
import javax.net.ssl.*
import org.junit.Assert.*
import org.junit.Test

class SignalingFailureTest {
    @Test fun routeExhaustionDoesNotClaimMicrophoneHardwareFailure() {
        val text = ConnectionFailure.describe(ConnectionStage.MICROPHONE, SignalingRoutesUnavailable())
        assertTrue(text.startsWith("Connection control failed [SIGNALING_UNAVAILABLE]"))
        assertFalse(text.contains("Sending phone microphone"))
        assertFalse(text.contains("could reach Windows"))
    }

    @Test fun requestFailuresKeepSafeOperationStageTimingAndTransportCategory() {
        for ((error, category) in listOf(
            java.net.SocketTimeoutException("private-url") to "timeout",
            java.net.UnknownHostException("private-host") to "dns",
            java.net.ConnectException("private-address") to "refused",
            java.net.NoRouteToHostException("private-network") to "no_route",
            SignalingStreamEnded() to "transport_eof",
            SignalingIoFailure(SignalingIoProblem.CANCELLED) to "cancelled",
            java.io.IOException("private-token") to "network_io")) {
            val safe = SignalingIoFailure(signalingIoProblem(ExecutionException(error)))
            assertNull(safe.cause)
            assertFalse(safe.message!!.contains("private"))
            val wrapped = SignalingRequestNotSent(safe)
            val text = signalingRequestFailureText(SignalingTransport.RENDEZVOUS, "/status",
                SignalingPhase.WAITING_FOR_WINDOWS, 8123, wrapped)
            assertEquals("route=rendezvous · request=status · phase=waiting_for_windows · category=$category · elapsed=8123 ms", text)
            assertTrue(ConnectionFailure.retryableStatus(wrapped))
        }
    }

    @Test fun diagnosticLabelsCannotExposeExceptionMessagesOrArbitraryRequestPaths() {
        val tls = SignalingTlsFailure.wrap(SSLPeerUnverifiedException("private-pin"), TlsLayer.RENDEZVOUS)
        val text = signalingRequestFailureText(SignalingTransport.RENDEZVOUS, "/private-token",
            SignalingPhase.RENDEZVOUS_CONNECT, -5, tls)
        assertEquals("route=rendezvous · request=other · phase=rendezvous_connect · category=tls_rendezvous_identity · elapsed=0 ms", text)
        assertFalse(ConnectionFailure.retryableStatus(tls))
        assertTrue(signalingRequestFailureText(SignalingTransport.LAN, "/microphone",
            SignalingPhase.RESPONSE_HEADERS, 4, HttpFailure(403)).contains("category=http_403"))
        assertTrue(signalingRequestFailureText(SignalingTransport.LAN, "/status",
            SignalingPhase.LAN_REQUEST, 5, SignalingNetworkChanged()).contains("category=network_changed"))
    }

    @Test fun realEngineMapsUnderlyingEofToTransportInterruption() {
        val engine = SSLContext.getInstance("TLSv1.3").apply { init(null, null, null) }
            .createSSLEngine().apply { useClientMode = true }
        val stream = EngineStream(engine, { _, _, _ -> -1 }, {}, {})
        val failure = assertThrows(SignalingStreamEnded::class.java) { stream.handshake() }
        assertTrue(ConnectionFailure.retryableStatus(failure))
    }
    @Test fun onlyKnownTransportEofRetriesAndTlsRejectionsRemainFatal() {
        assertTrue(ConnectionFailure.retryableStatus(SignalingStreamEnded()))
        assertTrue(ConnectionFailure.retryableStatus(ExecutionException(SignalingStreamEnded())))
        for ((error, category) in listOf(
            SSLHandshakeException("private-url") to TlsProblem.HANDSHAKE,
            SSLException("TLS stream truncated private-token") to TlsProblem.OTHER,
            SSLProtocolException("private-protocol") to TlsProblem.PROTOCOL,
            SSLPeerUnverifiedException("private-host") to TlsProblem.IDENTITY,
            SSLHandshakeException("private-url").apply { initCause(CertificateExpiredException("private-cert")) } to TlsProblem.CERTIFICATE_TIME,
            SSLHandshakeException("private-url").apply { initCause(PairingKeyUpgradeRequired()) } to TlsProblem.KEY_UPDATE)) {
            val failure = SignalingTlsFailure.wrap(ExecutionException(error), TlsLayer.RENDEZVOUS)
            assertEquals(category, failure.problem)
            assertNull(failure.cause)
            assertFalse(ConnectionFailure.retryableStatus(failure))
            assertFalse(failure.text().contains("private"))
            assertFalse(ConnectionFailure.describe(ConnectionStage.MICROPHONE, failure).contains("private"))
            assertSame(failure, SignalingTlsFailure.wrap(failure, TlsLayer.WINDOWS))
        }
    }
    @Test fun genericTlsDoesNotClaimCertificateRejectionOrAskToRePair() {
        val message = ConnectionFailure.describe(ConnectionStage.MICROPHONE, SSLException("private"))
        assertTrue(message.contains("TLS_CONNECTION"))
        assertFalse(message.contains("TLS_IDENTITY")); assertFalse(message.contains("fresh invitation"))
        assertFalse(message.contains("Sending phone microphone"))
        val known = SignalingTlsFailure.wrap(SSLPeerUnverifiedException("private"), TlsLayer.WINDOWS)
        assertTrue(ConnectionFailure.describe(ConnectionStage.PAIRING, known).contains("TLS_IDENTITY"))
        assertTrue(signalingFailureText(SignalingStreamEnded())!!.contains("transport_eof"))
    }
}
