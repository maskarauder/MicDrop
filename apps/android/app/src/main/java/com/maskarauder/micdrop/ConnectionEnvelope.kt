package com.maskarauder.micdrop

import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// Only the encrypted envelope is written to disk. Version and nonce are
// authenticated along with the full pinned connection link.
internal object ConnectionEnvelope {
    private val header = byteArrayOf(0x4d, 0x44, 0x43, 1)
    const val MAX_BYTES = 4 + 12 + 4096 + 16

    fun seal(link: String, key: SecretKey): ByteArray {
        val plain = link.toByteArray(Charsets.UTF_8)
        require(plain.size in 1..4096)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // Provider generates a new random nonce on every write, including retries.
        cipher.init(Cipher.ENCRYPT_MODE, key)
        require(cipher.iv.size == 12)
        cipher.updateAAD(header)
        return header + cipher.iv + cipher.doFinal(plain)
    }

    fun open(envelope: ByteArray, key: SecretKey): String {
        require(envelope.size in 33..MAX_BYTES && envelope.copyOfRange(0, 4).contentEquals(header))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, envelope.copyOfRange(4, 16)))
        cipher.updateAAD(header)
        return String(cipher.doFinal(envelope.copyOfRange(16, envelope.size)), Charsets.UTF_8)
    }
}
