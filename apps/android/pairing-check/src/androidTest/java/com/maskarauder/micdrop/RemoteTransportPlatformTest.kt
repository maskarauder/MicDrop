package com.maskarauder.micdrop

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import org.java_websocket.WebSocket
import org.java_websocket.drafts.Draft_6455
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.protocols.Protocol
import org.java_websocket.server.DefaultSSLWebSocketServerFactory
import org.java_websocket.server.WebSocketServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RemoteTransportPlatformTest {
    @Test fun pairedHttpThroughRealWssVerifiesBothTlsLayersAndReconnects() {
        AndroidIdentity.forget()
        val phone = AndroidIdentity.ensure()
        // Deliberately public, test-only key; never packaged in the real app.
        val fixture = InstrumentationRegistry.getInstrumentation().context.assets.open("public-test-tls.json").use {
            JSONObject(it.bufferedReader().readText())
        }
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(
            Base64.getDecoder().decode(fixture.getString("certificate")).inputStream()) as X509Certificate
        val privateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(
            Base64.getDecoder().decode(fixture.getString("private_key_pkcs8"))))
        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null); setKeyEntry("fixture", privateKey, "test".toCharArray(), arrayOf(certificate))
        }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keyStore, "test".toCharArray()) }
        val trustStore = KeyStore.getInstance(KeyStore.getDefaultType()).apply { load(null); setCertificateEntry("fixture", certificate) }
        val roots = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trustStore) }
        val outer = SSLContext.getInstance("TLSv1.3").apply { init(null, roots.trustManagers, null) }
        val clientTrust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkServerTrusted(chain: Array<X509Certificate>, type: String) { throw java.security.cert.CertificateException() }
            override fun checkClientTrusted(chain: Array<X509Certificate>, type: String) {
                check(chain.size == 1 && PublicIdentity.hex(PublicIdentity.fingerprint(chain[0].publicKey)) == phone)
                chain[0].checkValidity(); chain[0].verify(chain[0].publicKey)
            }
        }
        val inner = SSLContext.getInstance("TLSv1.3").apply { init(keys.keyManagers, arrayOf(clientTrust), null) }
        val loopback = InetAddress.getByName("127.0.0.1")
        val workers = Executors.newCachedThreadPool()
        val backend = inner.serverSocketFactory.createServerSocket(0, 10, loopback) as SSLServerSocket
        backend.needClientAuth = true; backend.enabledProtocols = arrayOf("TLSv1.3")
        val sockets = ConcurrentHashMap<WebSocket, Socket>()
        val started = CountDownLatch(1)
        val dropStatus = java.util.concurrent.atomic.AtomicBoolean(false)
        val holdStatus = java.util.concurrent.atomic.AtomicBoolean(false)
        val statusWaiting = CountDownLatch(1)
        val releaseStatus = CountDownLatch(1)
        val stallBody = java.util.concurrent.atomic.AtomicBoolean(false)
        val bodyWaiting = CountDownLatch(1)
        val releaseBody = CountDownLatch(1)
        val httpRequests = java.util.concurrent.atomic.AtomicInteger()
        val probes = java.util.concurrent.LinkedBlockingQueue<Boolean>()
        val relay = object : WebSocketServer(InetSocketAddress(loopback, 0),
            listOf(Draft_6455(emptyList(), listOf(Protocol("micdrop-tls-v1")), 65536))) {
            override fun onStart() { started.countDown() }
            override fun onOpen(connection: WebSocket, handshake: ClientHandshake) {
                val socket = Socket(loopback, backend.localPort)
                sockets[connection] = socket
                connection.send("micdrop-tls-v1 ready")
                workers.submit {
                    try {
                        val buffer = ByteArray(4096)
                        while (true) {
                            val n = socket.inputStream.read(buffer); if (n < 0) break
                            connection.send(buffer.copyOf(n))
                        }
                    } catch (_: Exception) { }
                }
            }
            override fun onMessage(connection: WebSocket, bytes: ByteBuffer) {
                val value = ByteArray(bytes.remaining()).also { bytes.get(it) }
                sockets[connection]?.outputStream?.apply { write(value); flush() }
            }
            override fun onMessage(connection: WebSocket, text: String) { connection.close() }
            override fun onClose(connection: WebSocket, code: Int, reason: String, remote: Boolean) { sockets.remove(connection)?.close() }
            override fun onError(connection: WebSocket?, error: Exception) { connection?.close() }
        }
        val publicContext = SSLContext.getInstance("TLSv1.3").apply { init(keys.keyManagers, null, null) }
        relay.setWebSocketFactory(DefaultSSLWebSocketServerFactory(publicContext))
        relay.connectionLostTimeout = 0
        workers.submit {
            while (!backend.isClosed) {
                val accepted = try { backend.accept() as SSLSocket } catch (_: Exception) { break }
                workers.submit {
                    accepted.use { socket ->
                        try {
                            socket.soTimeout = 5000; socket.startHandshake()
                            val request = socket.inputStream.bufferedReader()
                            val requestLine = request.readLine() ?: run { probes.offer(true); return@use }
                            httpRequests.incrementAndGet()
                            val requestHeaders = generateSequence { request.readLine()?.takeIf { it.isNotEmpty() } }.toList()
                            val contentLength = requestHeaders.firstOrNull { it.startsWith("Content-Length:", true) }
                                ?.substringAfter(':')?.trim()?.toInt() ?: 0
                            repeat(contentLength) { check(request.read() >= 0) }
                            if (holdStatus.compareAndSet(true, false)) {
                                socket.outputStream.write("HTTP/1.0 200".toByteArray()); socket.outputStream.flush()
                                statusWaiting.countDown()
                                releaseStatus.await(5, TimeUnit.SECONDS)
                                return@use
                            }
                            if (dropStatus.compareAndSet(true, false)) {
                                // Drop WSS after authenticated TLS and part of a
                                // status response, without an inner close_notify.
                                socket.outputStream.write("HTTP/1.0 200".toByteArray()); socket.outputStream.flush()
                                sockets.entries.firstOrNull { it.value.localPort == socket.port }?.key?.closeConnection(1006, "")
                                return@use
                            }
                            val body = JSONObject().put("payload", "x".repeat(20000))
                                .put("request_line", requestLine)
                                .put("trickle", requestHeaders.firstOrNull { it.startsWith("${TrickleIce.HEADER}:", true) }
                                    ?.substringAfter(':')?.trim() ?: "")
                                .put("continuous", requestHeaders.firstOrNull { it.startsWith("${ContinuousIce.HEADER}:", true) }
                                    ?.substringAfter(':')?.trim() ?: "")
                                .put("recovery_window", requestHeaders.firstOrNull { it.startsWith("${ConnectionPreferences.RECOVERY_HEADER}:", true) }
                                    ?.substringAfter(':')?.trim() ?: "")
                                .put("setup_window", requestHeaders.firstOrNull { it.startsWith("${ConnectionPreferences.SETUP_HEADER}:", true) }
                                    ?.substringAfter(':')?.trim() ?: "")
                                .put("offer_attempt", requestHeaders.firstOrNull { it.startsWith("${OfferAttempt.HEADER}:", true) }
                                    ?.substringAfter(':')?.trim() ?: "").toString().toByteArray()
                            socket.outputStream.write("HTTP/1.0 200 OK\r\nContent-Length: ${body.size}\r\n\r\n".toByteArray())
                            if (stallBody.compareAndSet(true, false)) {
                                socket.outputStream.write(body, 0, 1); socket.outputStream.flush()
                                bodyWaiting.countDown()
                                releaseBody.await(10, TimeUnit.SECONDS)
                                return@use
                            }
                            socket.outputStream.write(body); socket.outputStream.flush()
                        } catch (_: Exception) { /* Negative pin/SAN contracts deliberately abort TLS. */ }
                    }
                }
            }
        }
        try {
            relay.start(); assertTrue(started.await(5, TimeUnit.SECONDS))
            val token = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 })
            val remote = RemoteConnection("https://127.0.0.1:${relay.port}", token, false)
            val invitation = LanInvitation.paired("10.0.0.1", 9844,
                PublicIdentity.hex(PublicIdentity.fingerprint(certificate.publicKey)), phone).copy(remote = remote)
            fun localProbe(target: LanInvitation) = LocalProbe(target, object : Socket() {
                override fun connect(endpoint: java.net.SocketAddress, timeout: Int) {
                    // Route to the fixture while retaining the real invited IP
                    // for pin/SAN verification, as a network-bound socket does.
                    super.connect(InetSocketAddress(loopback, backend.localPort), timeout)
                }
            })
            localProbe(invitation).use { assertTrue(it.reachable(5000)) }
            assertEquals(true, probes.poll(5, TimeUnit.SECONDS))
            assertEquals(0, httpRequests.get()) // A probe cannot allocate an offer.
            localProbe(invitation.copy(fingerprint = ByteArray(32))).use { assertFalse(it.reachable()) }
            localProbe(invitation.copy(host = "10.0.0.2")).use { assertFalse(it.reachable()) }
            assertEquals(0, httpRequests.get())

            // A TCP listener that never completes TLS must not stall the session
            // worker. Stop must also cancel that same outstanding socket.
            java.net.ServerSocket(0, 1, loopback).use { stalled ->
                fun stalledProbe() = LocalProbe(invitation, object : Socket() {
                    override fun connect(endpoint: java.net.SocketAddress, timeout: Int) {
                        super.connect(InetSocketAddress(loopback, stalled.localPort), timeout)
                    }
                })
                val bounded = workers.submit<Boolean> { stalledProbe().use { it.reachable(150) } }
                stalled.accept().use { assertFalse(bounded.get(2, TimeUnit.SECONDS)) }
                stalledProbe().use { probe ->
                    val cancelled = workers.submit<Boolean> {
                        try { probe.reachable(5000); false } catch (_: InterruptedException) { true }
                    }
                    stalled.accept().use { probe.close(); assertTrue(cancelled.get(2, TimeUnit.SECONDS)) }
                }
            }
            repeat(2) {
                RemoteHttp(invitation, 15000, outer.socketFactory).use { request ->
                    assertEquals(20000, request.request("/status", "").getString("payload").length)
                }
            }
            // Cancellation has to cross the same authenticated inner TLS
            // stream as the offer, with the exact nonce, even without a session token.
            val attempt = OfferAttempt(true).also { it.begin() }
            val configured = ConnectionPreferences(timeouts = mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.SETUP to 60000))
            for (path in listOf("/offer", "/cancel-offer", "/status")) {
                RemoteHttp(invitation, 15000, outer.socketFactory, connectionPreferences = configured).use { request ->
                    val body = if (path == "/status") null else JSONObject().put("version", 3)
                    val response = request.request(path, "", body, attempt.header(path), path == "/offer")
                    assertEquals(if (path == "/offer") "1" else "", response.getString("trickle"))
                    assertEquals(if (path == "/offer") "1" else "", response.getString("continuous"))
                    assertEquals(attempt.header(path) ?: "", response.getString("offer_attempt"))
                    assertEquals(if (path == "/offer") "90000" else "", response.getString("recovery_window"))
                    assertEquals(if (path == "/offer") "60000" else "", response.getString("setup_window"))
                    assertEquals("${if (body == null) "GET" else "POST"} $path HTTP/1.0", response.getString("request_line"))
                }
            }
            dropStatus.set(true)
            val interruptedDetails = mutableListOf<String>()
            val interrupted = assertThrows(SignalingStreamEnded::class.java) {
                RemoteHttp(invitation, 15000, outer.socketFactory, interruptedDetails::add).use { it.request("/status", "") }
            }
            assertTrue(ConnectionFailure.retryableStatus(interrupted))
            assertEquals(1, interruptedDetails.size)
            assertTrue(interruptedDetails.single().contains("request=status · phase=response_headers · category=transport_eof"))
            // No default-network callback and no ICE disconnect are required:
            // retry exhaustion of both control routes for this established session.
            val establishedRecovery = LanRecovery(true).apply { observe(true, android.os.SystemClock.elapsedRealtime()) }
            val recoveringRoute = SignalingRoute(true).apply { recover() }
            val attemptAt = android.os.SystemClock.elapsedRealtime()
            dropStatus.set(true)
            val exhausted = assertThrows(SignalingRoutesUnavailable::class.java) {
                RemoteHttp(invitation, 15000, outer.socketFactory).use { request ->
                    recoveringRoute.exchange("/status", { fail("unverified LAN"); JSONObject() },
                        { request.request("/status", "") }, { false }, { false })
                }
            }
            assertFalse(ConnectionFailure.retryableStatus(exhausted)) // Initial setup remains terminal.
            assertTrue(establishedRecovery.signalingFailed(exhausted, attemptAt))
            recoveringRoute.recover()
            RemoteHttp(invitation, 15000, outer.socketFactory).use { request ->
                assertEquals(20000, recoveringRoute.exchange("/status", { fail("LAN before rendezvous"); JSONObject() },
                    { request.request("/status", "") }, { false }, { false }).getString("payload").length)
            }
            assertTrue(establishedRecovery.observe(true, android.os.SystemClock.elapsedRealtime()))
            // The copied report must distinguish a stalled response body from
            // failure to reach rendezvous or waiting for a Windows tunnel.
            val timeoutDetails = mutableListOf<String>()
            stallBody.set(true)
            try {
                val timedOut = workers.submit<java.io.IOException> {
                    assertThrows(java.io.IOException::class.java) {
                        RemoteHttp(invitation, 3000, outer.socketFactory, timeoutDetails::add).use { it.request("/status", "") }
                    }
                }
                assertTrue(bodyWaiting.await(5, TimeUnit.SECONDS))
                assertTrue(timedOut.get(5, TimeUnit.SECONDS) is java.net.SocketTimeoutException)
                assertEquals(1, timeoutDetails.size)
                assertTrue(timeoutDetails.single().contains("request=status · phase=response_body · category=timeout"))
                assertFalse(timeoutDetails.single().contains(token))
                assertFalse(timeoutDetails.single().contains(invitation.host))
            } finally { releaseBody.countDown() }
            // A handoff cancels only the active heartbeat. Its real WSS/TLS
            // cancellation must return to recovery without spending LAN fallback.
            val networkPending = java.util.concurrent.atomic.AtomicBoolean(false)
            val route = SignalingRoute(true).apply { recover() }
            holdStatus.set(true)
            try {
                RemoteHttp(invitation, 15000, outer.socketFactory).use { request ->
                    val result = workers.submit<java.io.IOException?> {
                        try {
                            route.exchange("/status", { fail("LAN during handoff"); JSONObject() },
                                { request.request("/status", "") }, { fail("probe during handoff"); false },
                                { false }, networkPending::get)
                            null
                        } catch (error: java.io.IOException) { error }
                    }
                    assertTrue(statusWaiting.await(5, TimeUnit.SECONDS))
                    networkPending.set(true); request.cancel()
                    val changed = result.get(2, TimeUnit.SECONDS)
                    assertTrue(changed is SignalingNetworkChanged)
                    assertTrue(ConnectionFailure.retryableStatus(requireNotNull(changed)))
                }
            } finally { releaseStatus.countDown() }
            networkPending.set(false); route.recover()
            RemoteHttp(invitation, 15000, outer.socketFactory).use {
                assertEquals(20000, route.exchange("/status", { fail("LAN before rendezvous"); JSONObject() },
                    { it.request("/status", "") }, { fail("unneeded probe"); false }, { false }, networkPending::get)
                    .getString("payload").length)
            }
            assertThrows(SSLException::class.java) {
                RemoteHttp(invitation.copy(fingerprint = ByteArray(32)), 15000, outer.socketFactory).use { it.request("/status", "") }
            }
            assertThrows(SSLException::class.java) {
                RemoteHttp(invitation.copy(host = "10.0.0.2"), 15000, outer.socketFactory).use { it.request("/status", "") }
            }
            // Explicit outer TLS must finish before the WebSocket read/write
            // threads can race a certificate failure with a generic closure.
            repeat(30) {
                val untrusted = assertThrows(SignalingTlsFailure::class.java) {
                    RemoteHttp(invitation, 15000).use { it.request("/status", "") } // Default CA trust must reject the fixture.
                }
                assertEquals(TlsLayer.RENDEZVOUS, untrusted.layer)
                assertFalse(ConnectionFailure.retryableStatus(untrusted))
                assertFalse(ConnectionFailure.retryableStatus(untrusted, establishedSession = true))
            }
        } finally {
            releaseBody.countDown()
            backend.close(); sockets.values.forEach { runCatching { it.close() } }
            relay.stop(2000); workers.shutdownNow(); AndroidIdentity.forget()
        }
    }
}
