package com.maskarauder.micdrop

import java.io.Closeable
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.cert.X509Certificate
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

// Prove the saved host's identity, not merely an open port or a matching subnet.
// This handshake sends no HTTP request, invitation secret, or session token and
// cannot create a session. The normal request still checks phone authorization.
internal class LocalProbe(private val invitation: LanInvitation, private val socket: Socket) : Closeable {
    private val cancelled = AtomicBoolean(false)
    fun reachable(timeoutMs: Int = 1500): Boolean {
        require(timeoutMs in 1..5000)
        val expired = AtomicBoolean(false)
        val timer = Timer("MicDrop-local-probe", true)
        timer.schedule(object : TimerTask() {
            override fun run() { expired.set(true); runCatching { socket.close() } }
        }, timeoutMs.toLong())
        try {
            checkpoint()
            socket.connect(InetSocketAddress(invitation.host, invitation.port), timeoutMs)
            socket.soTimeout = timeoutMs
            val tls = invitation.socketFactory().createSocket(socket, invitation.host, invitation.port, true) as SSLSocket
            tls.use {
                checkpoint()
                it.enabledProtocols = arrayOf("TLSv1.3")
                it.startHandshake()
                val certificate = it.session.peerCertificates.single() as X509Certificate
                // Match the same literal IP SAN required by tunneled signaling.
                if (certificate.subjectAlternativeNames?.any { san ->
                        san.size == 2 && san[0] == 7 && san[1] == invitation.host } != true) return false
                checkpoint()
                return !expired.get()
            }
        } catch (_: IOException) {
            checkpoint()
            return false // Includes a different pinned host at a reused private IP.
        } finally { timer.cancel(); runCatching { socket.close() } }
    }
    private fun checkpoint() {
        if (cancelled.get() || Thread.currentThread().isInterrupted) throw InterruptedException()
    }
    override fun close() { cancelled.set(true); runCatching { socket.close() } }
}
