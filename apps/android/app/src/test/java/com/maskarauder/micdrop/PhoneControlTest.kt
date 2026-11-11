package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class PhoneControlTest {
    private val id = "a".repeat(32)
    private fun snapshot(enabled: Boolean = true, value: Boolean = true) = PhoneSettingsSnapshot(enabled, listOf(
        PhoneSetting("audio.fast_recovery", "Fast recovery", "Audio", "bool", value),
        PhoneSetting("live.volume", "Android media volume", "Live", "int", 3, "live", 0, 15),
        PhoneSetting("audio.input", "Microphone input", "Audio", "choice", "phone",
            choices = listOf("phone" to "Phone", "headset" to "Headset"))))
    private fun command(current: PhoneSettingsSnapshot, changes: Map<String, Any?>,
        commandId: String = id): Map<String, Any?> = mapOf("id" to commandId,
        "base_revision" to current.revision, "changes" to changes)

    @Test fun disabledOrStaleCommandsCannotChangeAnyPreference() {
        val current = snapshot()
        val update = command(current, mapOf("audio.fast_recovery" to false))
        var calls = 0
        assertEquals("rejected", PhoneControlSession().receive(update, { snapshot(false) }) { calls++ }?.status)
        assertEquals("rejected", PhoneControlSession().receive(update, { snapshot(value = false) }) { calls++ }?.status)
        assertEquals(0, calls)
        assertNotEquals(current.revision, snapshot(false).revision)
    }

    @Test fun validatesTheWholePatchWithoutCoercionOrCaptureKeys() {
        val current = snapshot()
        for (invalid in listOf(
            mapOf("live.volume" to 16), mapOf("live.volume" to 3.0), mapOf("live.volume" to "3"),
            mapOf("live.volume" to 3L), mapOf("audio.fast_recovery" to "false"),
            mapOf("audio.input" to "disconnected-headset"), mapOf("audio.microphone_enabled" to true),
            mapOf("allowWindows" to true), mapOf("audio.fast_recovery" to false, "unknown" to true),
            emptyMap<String, Any?>(), mapOf("audio.fast_recovery" to null))) {
            var called = false
            val ack = PhoneControlSession().receive(command(current, invalid), { current }) { called = true }
            assertEquals(invalid.toString(), "rejected", ack?.status)
            assertFalse(invalid.toString(), called)
        }
    }

    @Test fun retriesReturnTheSameAcknowledgmentWithoutApplyingAgain() {
        var current = snapshot()
        val update = command(current, mapOf("audio.fast_recovery" to false))
        val session = PhoneControlSession()
        var calls = 0
        val first = session.receive(update, { current }) { changes ->
            calls++; current = snapshot(value = changes["audio.fast_recovery"] as Boolean)
        }
        assertEquals("applied", first?.status)
        assertTrue(first?.message?.contains("Stop and Connect") == true)
        assertEquals(first, session.receive(update, { current }) { calls++ })
        assertEquals(1, calls)
        assertEquals(first?.fields(), current.fields(session.acknowledgment)["ack"])
    }

    @Test fun permissionAndCapabilityChangesInvalidateTheEditorRevision() {
        val current = snapshot()
        val removed = current.copy(settings = current.settings.filterNot { it.key == "live.volume" })
        val newDevice = current.copy(settings = current.settings.map {
            if (it.key == "audio.input") it.copy(choices = listOf("phone" to "Phone", "replacement" to "Headset")) else it
        })
        val update = command(current, mapOf("audio.input" to "headset"))
        for (changed in listOf(removed, newDevice)) {
            assertNotEquals(current.revision, changed.revision)
            assertEquals("rejected", PhoneControlSession().receive(update, { changed }) { fail("Stale edit applied") }?.status)
        }
        assertEquals(current.revision, current.copy(settings = current.settings.reversed()).revision)
        assertTrue(current.revision.matches(Regex("[a-f0-9]{64}")))
    }

    @Test fun reorderedEarlierCommandsCannotApplyAgainAfterASettingWasRestored() {
        var current = snapshot()
        val first = command(current, mapOf("audio.fast_recovery" to false))
        val session = PhoneControlSession()
        var calls = 0
        fun apply(changes: Map<String, Any>) { calls++; current = snapshot(value = changes["audio.fast_recovery"] as Boolean) }
        val firstAck = session.receive(first, { current }, ::apply)
        session.receive(command(current, mapOf("audio.fast_recovery" to true), "b".repeat(32)), { current }, ::apply)
        assertEquals(snapshot().revision, current.revision)
        assertEquals(firstAck, session.receive(first, { current }, ::apply))
        assertEquals(2, calls)
        assertTrue(current.settings.first().value as Boolean)
    }

    @Test fun malformedEnvelopeAndUnknownFieldsAreRejected() {
        val current = snapshot()
        val update = command(current, mapOf("live.volume" to 4))
        assertNull(PhoneControlSession().receive(update + ("id" to "bad"), { current }) { fail() })
        assertEquals("rejected", PhoneControlSession().receive(update + ("start_microphone" to true), { current }) { fail() }?.status)
        assertEquals("1", PhoneControlSession.offerHeader(3, "/offer"))
        assertNull(PhoneControlSession.offerHeader(2, "/offer"))
        assertNull(PhoneControlSession.offerHeader(3, "/status"))
    }

    @Test fun onlyNegotiatedStatusExchangesReceiveTheSettingsBodyBudget() {
        assertEquals(160 * 1024, PhoneControlSession.bodyLimit("/status", true))
        assertEquals(96 * 1024, PhoneControlSession.bodyLimit("/status", false))
        for (path in listOf("/offer", "/answer", "/recover-offer", "/recover-answer", "/stop", "/microphone")) {
            assertEquals(path, 96 * 1024, PhoneControlSession.bodyLimit(path, true))
            assertEquals(path, 96 * 1024, PhoneControlSession.bodyLimit(path, false))
        }
    }

    @Test fun aNewReceiverCannotReplayTheOldReceiversAcknowledgment() {
        val current = snapshot()
        val update = command(current, mapOf("live.volume" to 4))
        val old = PhoneControlSession()
        old.receive(update, { current }) {}
        val replacement = PhoneControlSession()
        assertNull(replacement.acknowledgment)
        assertEquals("rejected", replacement.receive(update, { current.copy(enabled = false) }) { fail() }?.status)
    }
}
