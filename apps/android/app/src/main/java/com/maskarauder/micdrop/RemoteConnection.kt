package com.maskarauder.micdrop

import java.net.URI
import java.util.Base64
import org.json.JSONObject

// Saved only inside the existing encrypted connection envelope. Never include
// the role credential or the full invitation in reports, errors or toString().
internal class RemoteConnection(val url: String, val token: String, val forceRelay: Boolean) {
    init {
        val uri = URI(url)
        require(url.length <= 512 && uri.scheme == "https" && !uri.host.isNullOrEmpty() &&
            uri.rawUserInfo == null && uri.rawPath in listOf("", "/") && uri.rawQuery == null &&
            uri.rawFragment == null && (uri.port == -1 || uri.port in 1..65535))
        val bytes = Base64.getUrlDecoder().decode(token)
        require(bytes.size == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == token)
    }
    override fun toString() = "Remote connection"
    fun wrap(connection: String): String {
        val json = JSONObject().put("url", url).put("token", token).put("connection", connection).put("force_relay", forceRelay)
        return PREFIX + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toString().toByteArray(Charsets.UTF_8))
    }
    companion object {
        const val PREFIX = "micdrop://remote/v1/"
        fun unwrap(value: String): Pair<RemoteConnection, String>? {
            val text = value.trim()
            if (!text.startsWith(PREFIX)) return null
            require(text.length <= 4096)
            val bytes = Base64.getUrlDecoder().decode(text.removePrefix(PREFIX))
            require(bytes.size <= 3072)
            val json = JSONObject(String(bytes, Charsets.UTF_8))
            require(json.length() == 4 && json.get("force_relay") is Boolean)
            val inner = json.getString("connection")
            require(inner.startsWith("micdrop://paired/v1/") || inner.startsWith("micdrop://pair/v1/", true))
            return RemoteConnection(json.getString("url"), json.getString("token"), json.getBoolean("force_relay")) to inner
        }
    }
}
