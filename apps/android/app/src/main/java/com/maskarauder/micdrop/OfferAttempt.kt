package com.maskarauder.micdrop

import java.security.SecureRandom
import java.util.Base64

// Never persisted or logged. The same nonce covers explicit busy retries; a
// later Connect, or acknowledged cancellation before fallback, gets a new nonce.
internal class OfferAttempt(private val supported: Boolean) {
    private fun freshNonce() = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    private var nonce = freshNonce()
    private var started = false

    fun begin() { started = true }
    fun cancelledForFallback(acknowledged: Boolean) {
        check(supported && started && acknowledged)
        nonce = freshNonce(); started = false
    }
    fun header(path: String): String? = nonce.takeIf {
        supported && started && path in listOf("/offer", "/cancel-offer")
    }
    fun needsCancellation(sessionToken: String?): Boolean = supported && started && sessionToken == null

    companion object { const val HEADER = "X-MicDrop-Offer-Attempt" }
}
