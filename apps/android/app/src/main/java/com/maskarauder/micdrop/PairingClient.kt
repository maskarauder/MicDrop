package com.maskarauder.micdrop

import android.os.SystemClock
import java.io.IOException
import java.net.URL
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException
import org.json.JSONObject

internal data class PairingInvitation(val host: String, val port: Int, val pin: String,
    val secret: String, val expiresAt: Long, val remote: RemoteConnection? = null) {
    fun connection(clientKey: String) = LanInvitation.paired(host, port, pin, clientKey).copy(remote = remote)
    fun expired(now: Long = System.currentTimeMillis() / 1000) = now >= expiresAt
    companion object {
        private const val PREFIX = "micdrop://pair/v1/"
        fun isPairingLink(value: String): Boolean = runCatching {
            (RemoteConnection.unwrap(value)?.second ?: value.trim()).startsWith(PREFIX, ignoreCase = true)
        }.getOrDefault(false)
        fun parse(value: String): PairingInvitation {
            val text = value.trim()
            RemoteConnection.unwrap(text)?.let { (remote, inner) -> return parse(inner).copy(remote = remote) }
            require(text.length <= 4096 && isPairingLink(text))
            // Only the routing prefix is case-insensitive. Base64url payloads
            // are case-sensitive and must never be normalized.
            val raw = Base64.getUrlDecoder().decode(text.substring(PREFIX.length))
            require(raw.size <= 2048)
            val json = JSONObject(String(raw, Charsets.UTF_8))
            require(json.length() == 5 && json.get("port") is Int)
            val expiry = json.get("expires_at")
            require(expiry is Long || expiry is Int)
            return fromFields(json.getString("host"), json.getInt("port"), json.getString("host_key"),
                json.getString("secret"), (expiry as Number).toLong())
        }
        fun fromFields(host: String, port: Int, pin: String, secret: String, expiresAt: Long): PairingInvitation {
            LanInvitation.validateEndpoint(host, port); LanInvitation.pinBytes(pin)
            require(secret.matches(Regex("[A-Za-z0-9_-]{43}")) && expiresAt in 1..253402300799L)
            return PairingInvitation(host, port, pin, secret, expiresAt)
        }
    }
}

internal class PairingAttempt {
    val cancelled = AtomicBoolean(false)
    @Volatile var remoteRequest: RemoteHttp? = null
    @Volatile var request: HttpsURLConnection? = null
    @Volatile var thread: Thread? = null
    @Volatile var localProbe: LocalProbe? = null
    fun cancel() {
        cancelled.set(true); thread?.interrupt()
        remoteRequest?.cancel()
        localProbe?.close()
        val active = request
        if (active != null) Thread({ active.disconnect() }, "MicDrop-pair-cancel").start()
    }
    fun check() { if (cancelled.get()) throw InterruptedException() }
}

internal object PairingClient {
    // Not a resource: the pairing contract APK compiles this file without app resources.
    fun pendingText(id: String) =
        "Waiting for Windows approval.\nRequest ID: $id\nIn the Windows app, open Phones, check that this request ID matches, then select Approve."

    fun enroll(context: android.content.Context, invitation: PairingInvitation, key: String, label: String, attempt: PairingAttempt,
               progress: (String) -> Unit): LanInvitation {
        require(!invitation.expired())
        val connection = invitation.connection(key)
        val tls = connection.socketFactory()
        val deadline = SystemClock.elapsedRealtime() + minOf(300_000L,
            (invitation.expiresAt - System.currentTimeMillis() / 1000) * 1000)
        val body = JSONObject().put("version", 1).put("secret", invitation.secret).put("label", label)
            .toString().toByteArray(Charsets.UTF_8)
        attempt.thread = Thread.currentThread()
        val lan = LanNetwork(context, connection.host) { }
        var direct = connection.remote == null || try {
            LocalProbe(connection, lan.socket()).use { probe ->
                attempt.localProbe = probe; attempt.check(); probe.reachable()
            }
        } catch (_: IOException) { false }
        finally { attempt.localProbe = null }
        while (SystemClock.elapsedRealtime() < deadline && !invitation.expired()) {
            attempt.check()
            var request: HttpsURLConnection? = null
            var fallbackNow = false
            try {
                if (direct) request = lan.open(URL("https://${connection.host}:${connection.port}/pair")) as HttpsURLConnection
                attempt.request = request
                attempt.check()
                val reply = if (!direct) {
                    RemoteHttp(connection, minOf(15000, (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1).toInt())).use { remote ->
                        attempt.remoteRequest = remote; attempt.check()
                        remote.request("/pair", "", JSONObject(String(body, Charsets.UTF_8)))
                    }
                } else {
                    requireNotNull(request).sslSocketFactory = tls // Default hostname/IP verification stays enabled.
                    request.instanceFollowRedirects = false; request.useCaches = false
                    val remaining = (deadline - SystemClock.elapsedRealtime()).coerceIn(1, 5000).toInt()
                    request.connectTimeout = remaining; request.readTimeout = remaining
                    request.requestMethod = "POST"; request.doOutput = true
                    request.setRequestProperty("Content-Type", "application/json")
                    request.setFixedLengthStreamingMode(body.size)
                    request.outputStream.use { it.write(body) }
                    if (request.responseCode != 200) throw HttpFailure(request.responseCode)
                    val bytes = request.inputStream.use { input ->
                        val buffer = ByteArray(1025)
                        var count = 0
                        while (count < buffer.size) {
                            val read = input.read(buffer, count, buffer.size - count)
                            if (read < 0) break
                            count += read
                        }
                        buffer.copyOf(count)
                    }
                    require(bytes.size <= 1024)
                    JSONObject(String(bytes, Charsets.UTF_8))
                }
                require(reply.length() == 3 && reply.getInt("version") == 1)
                when (reply.getString("state")) {
                    "approved" -> { attempt.check(); return connection }
                    "pending" -> {
                        val id = reply.getString("request_id")
                        require(id.matches(Regex("[0-9a-f]{12}")))
                        progress(pendingText(id))
                    }
                    else -> throw IllegalArgumentException("Unsupported pairing response")
                }
            } catch (error: IOException) {
                attempt.check()
                // Polling is idempotent for this key and invitation. Never retry
                // a pin failure, rejection, or wrong protocol as legacy playback.
                if (error is SSLException || error is HttpFailure && error.status !in listOf(429, 503)) throw error
                if (direct && connection.remote != null) { direct = false; fallbackNow = true }
                progress("Waiting for Windows. Pairing will retry within the approval window.")
            } finally { request?.disconnect(); attempt.request = null; attempt.remoteRequest = null }
            if (fallbackNow) continue // Enrollment receipts are idempotent for this phone and secret.
            Thread.sleep(minOf(3000L, (deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1)))
        }
        throw HttpFailure(410)
    }
}
