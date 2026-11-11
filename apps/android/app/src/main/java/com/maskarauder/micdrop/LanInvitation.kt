package com.maskarauder.micdrop

import java.util.Base64
import org.json.JSONObject
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory

internal data class LanInvitation(val host: String, val port: Int, val token: String, val fingerprint: ByteArray,
    val version: Int = 1, val expiresAt: Long = 0, val clientKey: String = "", val remote: RemoteConnection? = null) {
    fun expired(nowSeconds: Long = System.currentTimeMillis() / 1000): Boolean = version == 2 && nowSeconds >= expiresAt

    fun socketFactory(): SSLSocketFactory = tlsContext().socketFactory

    fun tlsContext(): SSLContext {
        val managers = if (version == 3) arrayOf(AndroidIdentity.manager(clientKey)) else null
        return SSLContext.getInstance("TLSv1.3").apply {
            init(managers, arrayOf(PublicIdentity.trust(fingerprint, version == 3)), null)
        }
    }

    // Local saved record, not a pairing invitation or bearer credential.
    fun pairedRecord(): String {
        require(version == 3)
        val json = JSONObject().put("host", host).put("port", port)
            .put("host_key", PublicIdentity.hex(fingerprint)).put("client_key", clientKey)
        val record = "micdrop://paired/v1/" + Base64.getUrlEncoder().withoutPadding()
            .encodeToString(json.toString().toByteArray(Charsets.UTF_8))
        return remote?.wrap(record) ?: record
    }

    companion object {
        fun parse(value: String): LanInvitation {
            val text = value.trim()
            require(text.length <= 4096)
            RemoteConnection.unwrap(text)?.let { (remote, inner) ->
                return parse(inner).also { require(it.version == 3) }.copy(remote = remote)
            }
            if (text.startsWith("micdrop://paired/v1/")) {
                val raw = Base64.getUrlDecoder().decode(text.removePrefix("micdrop://paired/v1/"))
                require(raw.size <= 2048)
                val json = JSONObject(String(raw, Charsets.UTF_8))
                require(json.length() == 4 && json.get("port") is Int)
                return paired(json.getString("host"), json.getInt("port"),
                    json.getString("host_key"), json.getString("client_key"))
            }
            val version = when {
                text.startsWith("micdrop://v1/") -> 1
                text.startsWith("micdrop://v2/") -> 2
                else -> throw IllegalArgumentException("Unsupported connection link")
            }
            val raw = Base64.getUrlDecoder().decode(text.substring(13))
            require(raw.size <= 2048)
            val json = JSONObject(String(raw, Charsets.UTF_8))
            require(json.length() == if (version == 2) 5 else 4)
            val expiresAt = if (version == 2) {
                val value = json.get("expires_at")
                require(value is Long || value is Int)
                (value as Number).toLong().also { require(it in 1..253402300799L) }
            } else 0L
            return fromFields(version, json.getString("host"), json.getInt("port"),
                json.getString("token"), json.getString("fingerprint"), expiresAt)
        }

        internal fun fromFields(version: Int, host: String, port: Int, token: String,
            pin: String, expiresAt: Long): LanInvitation {
            require(version in 1..2)
            require(if (version == 2) expiresAt in 1..253402300799L else expiresAt == 0L)
            validateEndpoint(host, port)
            require(token.matches(Regex("[A-Za-z0-9_-]{43}")))
            return LanInvitation(host, port, token, pinBytes(pin), version, expiresAt)
        }

        internal fun validateEndpoint(host: String, port: Int) {
            require(host.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")))
            val parts = host.split('.').map { it.toInt() }
            require(host == parts.joinToString(".")) // No ambiguous leading-zero address forms.
            require(parts.all { it in 0..255 } && (parts[0] == 10 ||
                (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168)))
            require(port in 1..65535)
        }
        internal fun pinBytes(pin: String): ByteArray {
            require(pin.matches(Regex("[0-9a-f]{64}")))
            return ByteArray(32) { pin.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
        internal fun paired(host: String, port: Int, pin: String, clientKey: String,
            remote: RemoteConnection? = null): LanInvitation {
            validateEndpoint(host, port)
            pinBytes(clientKey)
            return LanInvitation(host, port, "", pinBytes(pin), 3, 0, clientKey, remote)
        }
    }
}
