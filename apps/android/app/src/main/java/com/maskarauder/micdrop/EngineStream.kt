package com.maskarauder.micdrop

import java.io.InputStream
import java.nio.ByteBuffer
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult.HandshakeStatus
import javax.net.ssl.SSLEngineResult.Status
import javax.net.ssl.SSLException

// Standard platform TLS over a byte stream. Only the session worker accesses
// the engine; cancellation closes its underlying transport. No custom crypto.
internal class EngineStream(private val engine: SSLEngine, private val receive: (ByteArray, Int, Int) -> Int,
    private val send: (ByteArray) -> Unit, private val checkpoint: () -> Unit) : InputStream() {
    private val encrypted = ByteBuffer.allocate(65536).apply { limit(0) }
    private val plain = ByteBuffer.allocate(65536).apply { limit(0) }
    private val packet = ByteBuffer.allocate(65536)
    private val empty = ByteBuffer.allocate(0)
    fun handshake() { engine.beginHandshake(); finishHandshake() }
    private fun finishHandshake() {
        repeat(4096) {
            checkpoint()
            when (engine.handshakeStatus) {
                HandshakeStatus.NEED_TASK -> {
                    var task = engine.delegatedTask
                    if (task == null) throw SSLException("TLS task unavailable")
                    while (task != null) { task.run(); task = engine.delegatedTask; checkpoint() }
                }
                HandshakeStatus.NEED_WRAP -> wrap(empty)
                HandshakeStatus.NEED_UNWRAP -> unwrap()
                HandshakeStatus.FINISHED, HandshakeStatus.NOT_HANDSHAKING -> return
                else -> throw SSLException("Unsupported TLS handshake state")
            }
        }
        throw SSLException("TLS handshake exceeded progress limit")
    }
    private fun wrap(source: ByteBuffer) {
        checkpoint(); packet.clear()
        val result = engine.wrap(source, packet)
        if (result.status != Status.OK) throw SSLException("TLS write failed")
        packet.flip()
        if (packet.hasRemaining()) send(ByteArray(packet.remaining()).also { packet.get(it) })
        if (result.bytesConsumed() == 0 && result.bytesProduced() == 0 && result.handshakeStatus == HandshakeStatus.NOT_HANDSHAKING)
            throw SSLException("TLS write made no progress")
    }
    private fun unwrap() {
        while (true) {
            checkpoint(); plain.compact()
            val result = engine.unwrap(encrypted, plain)
            plain.flip()
            when (result.status) {
                Status.CLOSED -> return
                Status.BUFFER_OVERFLOW -> throw SSLException("TLS plaintext limit exceeded")
                Status.BUFFER_UNDERFLOW -> {
                    encrypted.compact()
                    if (!encrypted.hasRemaining()) throw SSLException("TLS record limit exceeded")
                    val n = receive(encrypted.array(), encrypted.position(), encrypted.remaining())
                    if (n <= 0) throw SignalingStreamEnded()
                    encrypted.position(encrypted.position() + n); encrypted.flip()
                }
                Status.OK -> {
                    if (result.bytesConsumed() == 0 && result.bytesProduced() == 0 && result.handshakeStatus == HandshakeStatus.NOT_HANDSHAKING)
                        throw SSLException("TLS read made no progress")
                    return
                }
                else -> throw SSLException("TLS read failed")
            }
        }
    }
    fun write(bytes: ByteArray) {
        val source = ByteBuffer.wrap(bytes)
        while (source.hasRemaining()) { finishHandshake(); wrap(source) }
        finishHandshake()
    }
    override fun read(): Int { val b = ByteArray(1); return if (read(b, 0, 1) < 0) -1 else b[0].toInt() and 255 }
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        while (!plain.hasRemaining()) {
            if (engine.isInboundDone) return -1
            finishHandshake(); unwrap()
        }
        val n = minOf(len, plain.remaining()); plain.get(b, off, n); return n
    }
}
