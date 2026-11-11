package com.maskarauder.micdrop

import java.io.IOException
import java.security.cert.CertificateException
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLProtocolException

internal enum class TlsLayer { RENDEZVOUS, WINDOWS, ICE_SERVICE }
internal enum class TlsProblem { CERTIFICATE_TIME, IDENTITY, KEY_UPDATE, HANDSHAKE, PROTOCOL, OTHER }

// Only fixed labels cross the asynchronous WSS boundary. Never preserve an
// exception message/cause containing URLs, credentials or server-controlled text.
internal class SignalingTlsFailure(val layer: TlsLayer, val problem: TlsProblem) : SSLException("Secure signaling failed") {
    fun text() = "Secure signaling failure: layer=${layer.name.lowercase()} · category=${problem.name.lowercase()}"
    companion object {
        fun wrap(error: Throwable, layer: TlsLayer): SignalingTlsFailure {
            val causes = generateSequence(error) { it.cause }.take(8).toList()
            causes.filterIsInstance<SignalingTlsFailure>().firstOrNull()?.let { return it }
            val problem = when {
                causes.any { it is PairingKeyUpgradeRequired } -> TlsProblem.KEY_UPDATE
                causes.any { it is CertificateExpiredException || it is CertificateNotYetValidException } -> TlsProblem.CERTIFICATE_TIME
                causes.any { it is CertificateException || it is SSLPeerUnverifiedException } -> TlsProblem.IDENTITY
                causes.any { it is SSLHandshakeException } -> TlsProblem.HANDSHAKE
                causes.any { it is SSLProtocolException } -> TlsProblem.PROTOCOL
                else -> TlsProblem.OTHER
            }
            return SignalingTlsFailure(layer, problem)
        }
    }
}

// Raised only for an observed EOF of the underlying byte stream. It never
// converts an SSLEngine verification, handshake or protocol error into a retry.
internal class SignalingStreamEnded : IOException("Secure signaling transport ended")

// An established session changed networks while an idempotent request was in
// flight. The worker must consume that handoff before trying another transport.
internal class SignalingNetworkChanged : IOException("Network changed during signaling")

// TLS/tunnel setup failed before any inner HTTP request bytes were attempted.
internal class SignalingRequestNotSent(cause: IOException) : IOException("Signaling request not sent", cause)

internal enum class SignalingTransport { LAN, RENDEZVOUS }
internal enum class SignalingPhase {
    LAN_REQUEST, RENDEZVOUS_CONNECT, WAITING_FOR_WINDOWS, WINDOWS_TLS,
    REQUEST_WRITE, RESPONSE_HEADERS, RESPONSE_BODY
}
internal enum class SignalingIoProblem { TIMEOUT, DNS, REFUSED, NO_ROUTE, TRANSPORT_EOF, CANCELLED, NETWORK_IO }

// The asynchronous WebSocket callback must discard dependency messages and
// causes, but keep a fixed category so a failed handoff can be diagnosed.
internal class SignalingIoFailure(val problem: SignalingIoProblem) : IOException("Signaling transport failed")

internal fun signalingIoProblem(error: Throwable): SignalingIoProblem {
    val causes = generateSequence(error) { it.cause }.take(8).toList()
    causes.filterIsInstance<SignalingIoFailure>().firstOrNull()?.let { return it.problem }
    return when {
        causes.any { it is java.net.SocketTimeoutException || it is java.util.concurrent.TimeoutException } -> SignalingIoProblem.TIMEOUT
        causes.any { it is java.net.UnknownHostException } -> SignalingIoProblem.DNS
        causes.any { it is java.net.ConnectException } -> SignalingIoProblem.REFUSED
        causes.any { it is java.net.NoRouteToHostException } -> SignalingIoProblem.NO_ROUTE
        causes.any { it is SignalingStreamEnded || it is java.io.EOFException } -> SignalingIoProblem.TRANSPORT_EOF
        causes.any { it is InterruptedException } -> SignalingIoProblem.CANCELLED
        else -> SignalingIoProblem.NETWORK_IO
    }
}

internal fun signalingRequestFailureText(transport: SignalingTransport, path: String, phase: SignalingPhase,
                                        elapsedMs: Long, error: Throwable): String {
    val operation = path.takeIf { it in setOf("/offer", "/answer", "/status", "/recover-offer",
        "/recover-answer", "/microphone", "/stop", "/cancel-offer") }?.removePrefix("/") ?: "other"
    val causes = generateSequence(error) { it.cause }.take(8).toList()
    val http = causes.filterIsInstance<HttpFailure>().firstOrNull()
    val tls = causes.filterIsInstance<SignalingTlsFailure>().firstOrNull()
    val category = when {
        http != null -> "http_${http.status}"
        tls != null -> "tls_${tls.layer.name.lowercase()}_${tls.problem.name.lowercase()}"
        causes.any { it is SSLException || it is CertificateException } -> "tls"
        causes.any { it is SignalingNetworkChanged } -> "network_changed"
        else -> signalingIoProblem(error).name.lowercase()
    }
    return "route=${transport.name.lowercase()} · request=$operation · phase=${phase.name.lowercase()} · " +
        "category=$category · elapsed=${elapsedMs.coerceAtLeast(0)} ms"
}

internal fun signalingFailureText(error: Throwable): String? {
    val causes = generateSequence(error) { it.cause }.take(8).toList()
    return causes.filterIsInstance<SignalingTlsFailure>().firstOrNull()?.text()
        ?: if (causes.any { it is SignalingStreamEnded })
            "Secure signaling failure: layer=windows · category=transport_eof" else null
}
