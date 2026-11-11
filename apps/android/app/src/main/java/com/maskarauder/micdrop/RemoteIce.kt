package com.maskarauder.micdrop

import java.io.IOException
import java.net.URI
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject
import org.webrtc.PeerConnection

internal object RemoteIce {
    private var key: Pair<String, String>? = null
    private var expires = 0L
    private var servers: List<PeerConnection.IceServer> = emptyList()
    private var nextAttempt = 0L
    private var hasTurn = false
    // Preserve usable cached credentials. A bounded established-session retry
    // must not spend its whole recovery window in the failed-fetch cooldown.
    @Synchronized fun retryAfterInterruption() { nextAttempt = 0L }
    @Synchronized fun clear() {
        key = null
        expires = 0L
        servers = emptyList()
        nextAttempt = 0L
        hasTurn = false
    }
    @Synchronized fun fetch(remote: RemoteConnection, active: (HttpsURLConnection?) -> Unit,
        checkpoint: () -> Unit, remainingMs: () -> Long = { 8000L }, timeoutMs: Int = 8000): List<PeerConnection.IceServer> {
        val deadline = System.nanoTime() + timeoutMs.toLong() * 1_000_000
        fun budget(): Int {
            checkpoint()
            val remaining = minOf(remainingMs(), (deadline - System.nanoTime()) / 1_000_000)
            if (remaining <= 0) throw java.net.SocketTimeoutException("Media recovery deadline reached")
            return minOf(timeoutMs.toLong(), remaining).toInt()
        }
        budget()
        val now = System.currentTimeMillis() / 1000
        val selected = remote.url to remote.token
        if (key == selected && expires > now + 60) {
            if (remote.forceRelay && !hasTurn) throw IOException("Forced relay requires TURN on the server")
            return servers
        }
        if (key == selected && android.os.SystemClock.elapsedRealtime() < nextAttempt)
            throw IOException("Remote ICE configuration temporarily unavailable")
        key = selected; expires = 0
        nextAttempt = android.os.SystemClock.elapsedRealtime() + 3_000L
        val request = URL(remote.url.trimEnd('/') + "/v1/ice").openConnection() as HttpsURLConnection
        active(request)
        try {
            checkpoint(); request.instanceFollowRedirects = false; request.useCaches = false
            request.connectTimeout = budget(); request.readTimeout = budget()
            request.setRequestProperty("Authorization", "Bearer ${remote.token}")
            val status = request.responseCode
            if (status != 200) {
                nextAttempt = android.os.SystemClock.elapsedRealtime() + 30_000L
                throw HttpFailure(status)
            }
            request.readTimeout = budget()
            val bytes = request.inputStream.use { input ->
                input.readNBytesBounded(16384) { request.readTimeout = budget() }
            }
            nextAttempt = android.os.SystemClock.elapsedRealtime() + 30_000L
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            require(json.length() == 3 && json.getInt("version") == 1)
            val expiry = json.getLong("expires_at")
            require(expiry in (now + 61)..(now + 660))
            val list = json.getJSONArray("ice_servers"); require(list.length() <= 8)
            val result = mutableListOf<PeerConnection.IceServer>()
            var turnFound = false
            for (i in 0 until list.length()) {
                val server = list.getJSONObject(i)
                require(server.keys().asSequence().all { it in listOf("urls", "username", "credential") })
                val urls = server.getJSONArray("urls"); require(urls.length() in 1..8)
                val user = server.optString("username"); val password = server.optString("credential")
                require(user.length <= 512 && password.length <= 512 && !(user + password).any { it in "\u0000\r\n" })
                for (j in 0 until urls.length()) {
                    val url = urls.getString(j); require(url.length <= 512 && !url.any { it in " \r\n\t/#%@" })
                    val scheme = url.substringBefore(':')
                    val turn = scheme in listOf("turn", "turns")
                    require(turn || scheme == "stun")
                    val rest = url.substringAfter(':')
                    val endpoint = URI("https://" + rest.substringBefore('?'))
                    require(!endpoint.host.isNullOrEmpty() && endpoint.port in 1..65535 && endpoint.rawUserInfo == null)
                    if (turn) {
                        require(rest.substringAfter('?', "") in listOf("transport=udp", "transport=tcp"))
                        require(scheme != "turns" || rest.endsWith("?transport=tcp"))
                        require(user.isNotEmpty() && password.isNotEmpty()); turnFound = true
                    } else require(!rest.contains('?') && user.isEmpty() && password.isEmpty())
                    result += PeerConnection.IceServer.builder(url).setUsername(user).setPassword(password).createIceServer()
                    require(result.size <= 8)
                }
            }
            if (remote.forceRelay && !turnFound) throw IOException("Forced relay requires TURN on the server")
            budget(); expires = expiry; servers = result; hasTurn = turnFound; nextAttempt = 0L
            return result
        } catch (error: javax.net.ssl.SSLException) {
            throw SignalingTlsFailure.wrap(error, TlsLayer.ICE_SERVICE)
        } finally { request.disconnect(); active(null) }
    }
}

private fun java.io.InputStream.readNBytesBounded(max: Int, checkpoint: () -> Unit): ByteArray {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(4096)
    while (true) {
        checkpoint()
        val n = read(buffer); if (n < 0) break
        if (output.size() + n > max) throw IOException("ICE configuration too large")
        output.write(buffer, 0, n)
    }
    return output.toByteArray()
}
