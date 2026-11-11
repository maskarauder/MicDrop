package com.maskarauder.micdrop

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

// One HTTP/1.0 request per inner TLS stream. Close-delimited responses avoid a
// second HTTP stack or transparent retry of an ambiguous session-creating POST.
internal class RemoteHttp(private val invitation: LanInvitation, timeout: Int,
    outerFactory: javax.net.SocketFactory = javax.net.ssl.SSLSocketFactory.getDefault(),
    private val onFailure: (String) -> Unit = {},
    private val connectionPreferences: ConnectionPreferences? = null,
    connectTimeout: Int = 8000) : Closeable {
    private val closed = AtomicBoolean(false)
    private var requestStarted = false
    private val started = System.nanoTime()
    private val deadline = started + timeout.toLong() * 1_000_000
    @Volatile private var phase = SignalingPhase.RENDEZVOUS_CONNECT
    private val tunnel = RemoteTunnel(requireNotNull(invitation.remote), ::checkpoint, outerFactory, minOf(timeout, connectTimeout)) {
        phase = SignalingPhase.WAITING_FOR_WINDOWS
    }
    private fun checkpoint() {
        if (closed.get() || Thread.currentThread().isInterrupted) throw SignalingIoFailure(SignalingIoProblem.CANCELLED)
        if (System.nanoTime() >= deadline) throw SocketTimeoutException("Remote request timed out")
    }
    fun request(path: String, token: String, body: JSONObject? = null, offerAttempt: String? = null, trickle: Boolean = false,
        resume: SessionResume.Reason? = null, phoneControlNegotiated: Boolean = false): JSONObject {
        try {
            try { return exchange(path, token, body, offerAttempt, trickle, resume, phoneControlNegotiated) }
            catch (error: javax.net.ssl.SSLException) { throw SignalingTlsFailure.wrap(error, TlsLayer.WINDOWS) }
            catch (error: java.security.cert.CertificateException) { throw SignalingTlsFailure.wrap(error, TlsLayer.WINDOWS) }
            catch (error: IOException) { if (!requestStarted) throw SignalingRequestNotSent(error); throw error }
        } catch (error: Exception) {
            onFailure(signalingRequestFailureText(SignalingTransport.RENDEZVOUS, path, phase,
                (System.nanoTime() - started) / 1_000_000, error))
            throw error
        }
    }
    private fun exchange(path: String, token: String, body: JSONObject?, offerAttempt: String?, trickle: Boolean,
        resume: SessionResume.Reason?, phoneControlNegotiated: Boolean): JSONObject {
        checkpoint(); tunnel.connect()
        phase = SignalingPhase.WINDOWS_TLS
        val engine = invitation.tlsContext().createSSLEngine(invitation.host, invitation.port).apply {
            useClientMode = true; enabledProtocols = arrayOf("TLSv1.3")
        }
        val tls = EngineStream(engine, tunnel::read, tunnel::write, ::checkpoint)
        tls.handshake()
        // The trust manager verifies validity, self-signature and the pinned
        // host SPKI. Preserve the LAN IP SAN check on the tunneled transport.
        val certificate = engine.session.peerCertificates.single() as X509Certificate
        if (certificate.subjectAlternativeNames?.any { it.size == 2 && it[0] == 7 && it[1] == invitation.host } != true)
            throw javax.net.ssl.SSLPeerUnverifiedException("Windows certificate address mismatch")
        require(path.matches(Regex("/[a-z-]+")))
        require(token.isEmpty() || token.matches(Regex("[A-Za-z0-9_-]{43}")))
        require(offerAttempt == null || (path in listOf("/offer", "/cancel-offer") &&
            offerAttempt.matches(Regex("[A-Za-z0-9_-]{43}"))))
        require(!trickle || path == "/offer")
        val bodyLimit = PhoneControlSession.bodyLimit(path, phoneControlNegotiated)
        val bytes = body?.toString()?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        require(bytes.size <= bodyLimit)
        val header = buildString {
            append(if (body == null) "GET " else "POST "); append(path); append(" HTTP/1.0\r\n")
            append("Host: ${invitation.host}:${invitation.port}\r\nConnection: close\r\n")
            if (token.isNotEmpty()) append("Authorization: Bearer $token\r\n")
            if (offerAttempt != null) append("${OfferAttempt.HEADER}: $offerAttempt\r\n")
            PhoneControlSession.offerHeader(invitation.version, path)?.let {
                append("${PhoneControlSession.HEADER}: $it\r\n")
            }
            SessionResume.offerHeaders(invitation.version, path, resume).forEach { (name, value) ->
                append("$name: $value\r\n")
            }
            if (path == "/offer" && invitation.version == 3) connectionPreferences?.offerHeaders()?.forEach { (name, value) ->
                append("$name: $value\r\n")
            }
            if (trickle) { append("${TrickleIce.HEADER}: 1\r\n"); append("${ContinuousIce.HEADER}: 1\r\n") }
            if (body != null) append("Content-Type: application/json\r\nContent-Length: ${bytes.size}\r\n")
            append("\r\n")
        }
        requestStarted = true // Conservatively ambiguous before the first write.
        phase = SignalingPhase.REQUEST_WRITE
        tls.write(header.toByteArray(Charsets.US_ASCII)); if (body != null) tls.write(bytes)
        phase = SignalingPhase.RESPONSE_HEADERS
        return readResponse(tls, bodyLimit) { phase = SignalingPhase.RESPONSE_BODY }
    }
    fun cancel() {
        if (!closed.compareAndSet(false, true)) return
        Thread({ tunnel.close() }, "MicDrop-remote-cancel").start()
    }
    override fun close() { closed.set(true); tunnel.close() }
    companion object {
        const val MAX_BODY = PhoneControlSession.DEFAULT_BODY_LIMIT
        internal fun readResponse(input: InputStream, bodyLimit: Int = MAX_BODY, onBody: () -> Unit = {}): JSONObject {
            require(bodyLimit in 1..PhoneControlSession.CONTROL_BODY_LIMIT)
            var headerBytes = 0
            fun line(): String {
                val out = ByteArrayOutputStream()
                while (true) {
                    val b = input.read()
                    if (b < 0 || ++headerBytes > 8192) throw IOException("Invalid HTTP response headers")
                    if (b == 10) {
                        val bytes = out.toByteArray()
                        if (bytes.isEmpty() || bytes.last() != 13.toByte()) throw IOException("Invalid HTTP line")
                        return String(bytes, 0, bytes.size - 1, Charsets.US_ASCII)
                    }
                    out.write(b)
                }
            }
            val status = Regex("HTTP/1\\.[01] ([0-9]{3})(?: .*)?").matchEntire(line())
                ?.groupValues?.get(1)?.toInt() ?: throw IOException("Invalid HTTP status")
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = line(); if (line.isEmpty()) break
                val parts = line.split(':', limit = 2)
                if (parts.size != 2 || !parts[0].matches(Regex("[A-Za-z0-9-]+"))) throw IOException("Invalid HTTP header")
                val name = parts[0].lowercase()
                if (headers.put(name, parts[1].trim()) != null) throw IOException("Duplicate HTTP header")
            }
            if (status != 200) throw HttpFailure(status)
            if (headers.containsKey("transfer-encoding")) throw IOException("Unsupported HTTP transfer encoding")
            val length = headers["content-length"]?.let {
                it.toIntOrNull()?.takeIf { n -> n in 0..bodyLimit } ?: throw IOException("Invalid HTTP body size")
            }
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            onBody()
            while (length == null || output.size() < length) {
                val n = input.read(buffer, 0, minOf(buffer.size, (length ?: (bodyLimit + 1)) - output.size()))
                if (n < 0) break
                if (output.size() + n > bodyLimit) throw IOException("HTTP body too large")
                output.write(buffer, 0, n)
            }
            if (length != null && output.size() != length) throw IOException("Truncated HTTP response")
            return JSONObject(output.toString("UTF-8"))
        }
    }
}
