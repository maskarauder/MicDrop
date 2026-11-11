package com.maskarauder.micdrop

import java.security.MessageDigest

// A notification carries only a random control ID. The private ticket binds it
// to the exact encrypted saved link, including its token, certificate and expiry.
internal data class ResumeTicket(val id: String, val digest: String, val fast: Boolean) {
    fun matches(link: String): Boolean = digest == fingerprint(link)
    companion object {
        fun fingerprint(link: String): String = MessageDigest.getInstance("SHA-256")
            .digest(link.trim().toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
