package com.maskarauder.micdrop

import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.net.URI
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import org.java_websocket.client.WebSocketClient
import org.java_websocket.drafts.Draft
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.exceptions.InvalidHandshakeException
import org.java_websocket.handshake.Handshakedata
import org.java_websocket.handshake.ServerHandshake
import org.java_websocket.protocols.Protocol

internal class RemoteTunnel(remote: RemoteConnection, private val checkpoint: () -> Unit,
    private val outerFactory: SocketFactory = SSLSocketFactory.getDefault(),
    connectTimeout: Int = 8000,
    private val onOpen: () -> Unit = {}) : Closeable {
    private val stopped = AtomicBoolean(false)
    private val closing = AtomicBoolean(false)
    private val ownedSocket = AtomicReference<Socket?>()
    private val queue = ArrayBlockingQueue<ByteBuffer>(8)
    @Volatile private var ready = false
    @Volatile private var failed: IOException? = null
    private var current = ByteBuffer.allocate(0)
    private class BoundedDraft : Draft_6455(emptyList(), listOf(Protocol(PROTOCOL)), 65536) {
        override fun copyInstance(): Draft = BoundedDraft()
        override fun translateHandshake(buffer: ByteBuffer): Handshakedata {
            if (buffer.remaining() > 8192) throw InvalidHandshakeException("Upgrade headers too large")
            return super.translateHandshake(buffer)
        }
    }
    private val client = object : WebSocketClient(
        URI(remote.url.trimEnd('/').replaceFirst("https://", "wss://") + "/v1/tunnel"),
        BoundedDraft(), mapOf("Authorization" to "Bearer ${remote.token}"), connectTimeout) {
        override fun onSetSSLParameters(parameters: SSLParameters) {
            super.onSetSSLParameters(parameters) // Normal outer hostname/CA verification.
            parameters.protocols = arrayOf("TLSv1.3")
            // Java-WebSocket 1.6.0 otherwise starts its reader and writer with
            // TLS still lazy. A writer's certificate failure can close the
            // reader before onError publishes that failure. Complete TLS on
            // the connect thread: its catch publishes onError before onClose,
            // and no WebSocket writer exists yet. Cancellation still owns and
            // closes this socket; the request deadline remains authoritative.
            val socket = ownedSocket.get() as? SSLSocket
                ?: throw javax.net.ssl.SSLException("TLS socket unavailable")
            socket.sslParameters = parameters
            socket.startHandshake()
        }
        override fun onOpen(handshake: ServerHandshake) {
            if (protocol?.providedProtocol != PROTOCOL) abort() else this@RemoteTunnel.onOpen()
        }
        override fun onMessage(text: String) {
            if (ready || text != "$PROTOCOL ready") abort() else ready = true
        }
        override fun onMessage(bytes: ByteBuffer) {
            if (!ready || !bytes.hasRemaining() || bytes.remaining() > 65536 || !queue.offer(bytes)) abort()
        }
        override fun onClose(code: Int, reason: String, remote: Boolean) { stopped.set(true) }
        override fun onError(error: Exception) {
            // Keep certificate errors distinguishable without relaying a URL,
            // token, server-supplied reason or dependency diagnostic string.
            failed = if (generateSequence<Throwable>(error) { it.cause }.take(8).any {
                    it is javax.net.ssl.SSLException || it is java.security.cert.CertificateException })
                SignalingTlsFailure.wrap(error, TlsLayer.RENDEZVOUS)
                else SignalingIoFailure(signalingIoProblem(error))
            stopped.set(true)
        }
        private fun abort() { failed = IOException("Invalid rendezvous stream"); this@RemoteTunnel.close() }
    }.apply {
        isDaemon = true
        connectionLostTimeout = 0
        // Own the socket before connect/handshake starts, so cancellation works
        // even before Java-WebSocket has opened its writer thread.
        setSocketFactory(object : SocketFactory() {
            override fun createSocket(): Socket {
                val created = outerFactory.createSocket()
                ownedSocket.set(created)
                if (stopped.get()) { created.close(); throw IOException("Request cancelled") }
                created.soTimeout = 45000
                return created
            }
            override fun createSocket(h: String, p: Int): Socket = throw UnsupportedOperationException()
            override fun createSocket(h: String, p: Int, l: InetAddress, lp: Int): Socket = throw UnsupportedOperationException()
            override fun createSocket(h: InetAddress, p: Int): Socket = throw UnsupportedOperationException()
            override fun createSocket(h: InetAddress, p: Int, l: InetAddress, lp: Int): Socket = throw UnsupportedOperationException()
        })
    }
    private fun check() {
        checkpoint()
        // onError publishes the cause before stopped. Read stopped first so
        // observing that publication cannot lose its TLS cause to a stale read.
        val ended = stopped.get()
        failed?.let { throw it }
        if (ended) throw IOException("Rendezvous stream closed")
    }
    fun connect() {
        check(); client.connect()
        while (!ready) { check(); Thread.sleep(10) }
        check()
    }
    fun read(bytes: ByteArray, offset: Int, count: Int): Int {
        while (!current.hasRemaining()) {
            checkpoint()
            val ended = stopped.get()
            failed?.let { throw it }
            val next = queue.poll(100, TimeUnit.MILLISECONDS)
            if (next != null) current = next else if (ended) return -1
        }
        val n = minOf(count, current.remaining()); current.get(bytes, offset, n); return n
    }
    fun write(bytes: ByteArray) {
        var offset = 0
        while (offset < bytes.size) {
            check()
            val end = minOf(offset + 16384, bytes.size)
            try { client.send(bytes.copyOfRange(offset, end)) }
            catch (_: org.java_websocket.exceptions.WebsocketNotConnectedException) {
                check() // Prefer an already-published TLS failure over generic transport closure.
                throw IOException("Rendezvous transport closed")
            }
            offset = end
            while (client.hasBufferedData()) { check(); Thread.sleep(5) }
        }
    }
    override fun close() {
        stopped.set(true)
        if (!closing.compareAndSet(false, true)) return
        runCatching { ownedSocket.get()?.close() }
        runCatching { client.closeConnection(1000, "") }
    }
    companion object { private const val PROTOCOL = "micdrop-tls-v1" }
}
