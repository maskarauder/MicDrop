package com.maskarauder.micdrop

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.*
import org.junit.Test
import org.w3c.dom.Element

class PairingTextTest {
    // Gradle runs unit tests in the module directory; the second path covers apps/android.
    private fun file(path: String) = requireNotNull(listOf(path, "app/$path").map(::File).firstOrNull { it.exists() }) { path }

    private fun resources(): Map<String, String> {
        val strings = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(file("src/main/res/values/strings.xml")).getElementsByTagName("string")
        return (0 until strings.length).map { strings.item(it) as Element }.associate { it.getAttribute("name") to it.textContent }
    }

    private val consoleWording = listOf("console", "Enter pair", "enter: approve", "use devices")
        .map { Regex("\\b$it\\b", RegexOption.IGNORE_CASE) }

    @Test fun pairingInstructionsUseTheWindowsAppsPhonesPage() {
        val strings = resources()
        assertEquals("That pairing invitation expired. In the Windows app, open Phones → Pair a phone for a new one.",
            strings["pairing_invitation_expired"])
        assertEquals("Pairing window ended, was rejected, or another phone is pending. In the Windows app, open Phones → Pair a phone for a new invitation.",
            strings["pairing_window_ended"])
        assertEquals("Pairing was not saved. Windows may already have approved the phone; retry the same invitation while it is valid, or select Pair a phone in Windows for a new one.",
            strings["pairing_not_saved"])
        assertEquals("Pairing cancelled. If Windows already approved this phone, remove it in the Windows app under Phones → Remove selected phone.",
            strings["pairing_cancelled"])
        assertEquals("Saved connection and phone identity forgotten. Windows may still list the old phone; remove it in the Windows app under Phones → Remove selected phone.",
            strings["connection_forgotten"])
        assertEquals("Waiting for Windows approval.\nRequest ID: 0123456789ab\nIn the Windows app, open Phones, check that this request ID matches, then select Approve.",
            PairingClient.pendingText("0123456789ab"))
    }

    @Test fun noShippedPairingTextSendsUsersToTheConsole() {
        val texts = resources().values + PairingClient.pendingText("0123456789ab") +
            listOf(401, 403, 409, 410).map { ConnectionFailure.describe(ConnectionStage.PAIRING, HttpFailure(it)) }
        for (text in texts) for (wording in consoleWording) assertFalse(text, wording.containsMatchIn(text))
    }

    @Test fun shippedSourcesNoLongerQuoteConsolePairingCommands() {
        // Non-pairing failures may still mention the console, so sources are checked only for its pairing commands.
        for (source in listOf("src/main/java", "src/debug/java").flatMap { path -> file(path).walk().filter { it.extension == "kt" }.toList() }) {
            val text = source.readText()
            for (wording in consoleWording.drop(1)) assertFalse(source.name, wording.containsMatchIn(text))
        }
    }
}
