package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class RemoteHttpBodyLimitTest {
    private fun header(length: Int) = ByteArrayInputStream(
        "HTTP/1.0 200 OK\r\nContent-Length: $length\r\n\r\n".toByteArray(Charsets.US_ASCII))

    @Test fun largerDeclaredBodiesNeedTheNegotiatedBudgetAndRemainBounded() {
        val budget = PhoneControlSession.bodyLimit("/status", true)
        for (size in listOf(96 * 1024 + 1, budget)) {
            assertEquals("Invalid HTTP body size", assertThrows(IOException::class.java) {
                RemoteHttp.readResponse(header(size))
            }.message)
            // The declaration is allowed; the intentionally absent payload is
            // then rejected as truncated before any Android JSON dependency.
            assertEquals("Truncated HTTP response", assertThrows(IOException::class.java) {
                RemoteHttp.readResponse(header(size), budget)
            }.message)
        }
        assertEquals("Invalid HTTP body size", assertThrows(IOException::class.java) {
            RemoteHttp.readResponse(header(budget + 1), budget)
        }.message)
    }

    @Test fun closeDelimitedBodiesCannotBypassEitherLimit() {
        for (budget in listOf(96 * 1024, 160 * 1024)) {
            val input = ByteArrayInputStream("HTTP/1.0 200 OK\r\n\r\n".toByteArray(Charsets.US_ASCII) + ByteArray(budget + 1))
            assertEquals("HTTP body too large", assertThrows(IOException::class.java) {
                RemoteHttp.readResponse(input, budget)
            }.message)
        }
    }
}
