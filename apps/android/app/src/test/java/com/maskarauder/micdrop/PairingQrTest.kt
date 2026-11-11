package com.maskarauder.micdrop

import com.google.zxing.RGBLuminanceSource
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import com.google.zxing.BarcodeFormat
import com.google.zxing.DecodeHintType
import com.google.zxing.client.android.Intents
import org.junit.Assert.*
import org.junit.Test

class PairingQrTest {
    @Test fun decodesWindowsTerminalOutputInBothConsoleThemes() {
        val fixture = requireNotNull(javaClass.classLoader?.getResourceAsStream("pairing-qr.txt"))
            .bufferedReader().use { it.readText() }.replace("\r\n", "\n")
        val expected = fixture.substringBefore('\n')
        val rows = fixture.substringAfter('\n').trimEnd('\n').lines()
        val scale = 5
        val width = rows.first().length * scale
        val height = rows.size * 2 * scale
        for (darkTheme in listOf(true, false)) {
            val pixels = IntArray(width * height) { index ->
                val x = index % width / scale
                val y = index / width / scale
                val ink = when (rows[y / 2][x]) {
                    '█' -> true
                    '▀' -> y % 2 == 0
                    '▄' -> y % 2 == 1
                    ' ' -> false
                    else -> error("Unexpected console glyph")
                }
                if (ink == darkTheme) 0xffffff else 0x000000
            }
            val source = RGBLuminanceSource(width, height, pixels)
            // Production scans alternate normal/inverted frames for terminal
            // themes. Decode with the same factory, independent of Go's encoder.
            val decoder = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE), null, null,
                Intents.Scan.MIXED_SCAN).createDecoder(emptyMap<DecodeHintType, Any>())
            val result = decoder.decode(source) ?: decoder.decode(source)
            assertNotNull("Could not decode darkTheme=$darkTheme", result)
            assertEquals(expected, result!!.text)
            assertTrue(PairingInvitation.isPairingLink(result.text))
        }
    }
}
