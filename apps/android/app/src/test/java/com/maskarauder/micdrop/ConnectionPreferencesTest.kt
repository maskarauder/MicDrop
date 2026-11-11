package com.maskarauder.micdrop

import java.io.IOException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLException
import org.junit.Assert.*
import org.junit.Test

class ConnectionPreferencesTest {
    @Test fun defaultsPreserveExistingDeadlinesAndPriorities() {
        val defaults = ConnectionPreferences.from(emptyMap<String, Any>())
        assertEquals(ConnectionOrder.LAN_FIRST, defaults.initialOrder)
        assertEquals(ConnectionOrder.RENDEZVOUS_FIRST, defaults.recoveryOrder)
        assertEquals(30000, defaults[ConnectionTimeout.RECOVERY])
        assertEquals(45000, defaults[ConnectionTimeout.SETUP])
        assertEquals(2000, defaults[ConnectionTimeout.LAN_STATUS])
        assertEquals(8000, defaults[ConnectionTimeout.REMOTE_REQUEST])
        assertEquals(40000, defaults[ConnectionTimeout.INITIAL_OFFER])
        assertEquals(20000, defaults[ConnectionTimeout.BLUETOOTH_RECOVERY])
        assertEquals(2, defaults.maxRestarts)
    }

    @Test fun settingsRoundTripAndInvalidStoredValuesFallBackIndividually() {
        val chosen = ConnectionPreferences(ConnectionOrder.RENDEZVOUS_FIRST, ConnectionOrder.LAN_FIRST,
            mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.LAN_PROBE to 750), 6)
        val restored = ConnectionPreferences.from(chosen.fields())
        assertEquals(chosen.fields(), restored.fields())
        val broken = ConnectionPreferences.from(chosen.fields() + mapOf("LAN_PROBE" to -1, "SETUP" to "90000",
            "initialOrder" to "unknown", "maxRestarts" to 100, "REMOTE_REQUEST" to Int.MAX_VALUE))
        assertEquals(90000, broken[ConnectionTimeout.RECOVERY])
        assertEquals(1500, broken[ConnectionTimeout.LAN_PROBE])
        assertEquals(45000, broken[ConnectionTimeout.SETUP])
        assertEquals(8000, broken[ConnectionTimeout.REMOTE_REQUEST])
        assertEquals(ConnectionOrder.LAN_FIRST, broken.initialOrder)
        assertEquals(2, broken.maxRestarts)
    }

    @Test fun secondsAreBoundedAndDoNotSilentlyRoundOrAcceptNonFiniteNumbers() {
        assertEquals(1500, ConnectionTimeout.LAN_PROBE.parseSeconds("1.5"))
        assertEquals(0, ConnectionTimeout.RESTART_DELAY.parseSeconds("0"))
        for (bad in listOf("", "-1", "NaN", "Infinity", "1e9", "1.0001", "0", "6", "99999999999999"))
            assertNull(bad, ConnectionTimeout.LAN_PROBE.parseSeconds(bad))
        for (key in ConnectionTimeout.entries) {
            assertEquals(key.minimumMs, key.parseSeconds(ConnectionTimeout.seconds(key.minimumMs)))
            assertEquals(key.maximumMs, key.parseSeconds(ConnectionTimeout.seconds(key.maximumMs)))
        }
    }

    @Test fun bluetoothWindowPersistsIndependentlyAndInvalidValuesRestoreTwentySeconds() {
        val key = ConnectionTimeout.BLUETOOTH_RECOVERY
        val custom = ConnectionPreferences(timeouts = mapOf(key to 60500, ConnectionTimeout.RECOVERY to 90000))
        assertEquals(60500, ConnectionPreferences.from(custom.fields())[key])
        assertEquals(60500, key.parseSeconds("60.5"))
        for (bad in listOf<Any>(4999, 120001, "60000", Long.MAX_VALUE, -1)) {
            val restored = ConnectionPreferences.from(custom.fields() + (key.name to bad))
            assertEquals(20000, restored[key])
            assertEquals(90000, restored[ConnectionTimeout.RECOVERY])
        }
        assertTrue(custom.text(ConnectionDeadlines(90000, 45000, 95000, DeadlineState.CONFIRMED)).contains("bluetooth_recovery=60500"))
    }

    @Test fun legacyWindowsCannotSilentlyPromiseAnExtendedWindow() {
        val prefs = ConnectionPreferences(timeouts = mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.SETUP to 90000))
        assertEquals(ConnectionDeadlines(30000, 45000, 35000, DeadlineState.LEGACY), prefs.negotiated(true, 0, 0, 0, 0))
        assertEquals(ConnectionDeadlines(10000, 45000, 15000, DeadlineState.LEGACY), prefs.negotiated(false, 0, 0, 0, 0))
        assertEquals(ConnectionDeadlines(90000, 90000, 95000, DeadlineState.CONFIRMED), prefs.negotiated(true, 1, 90000, 90000, 95000))
        assertThrows(IllegalArgumentException::class.java) { prefs.negotiated(true, 1, 90000, 90000, 35000) }
        assertThrows(IllegalArgumentException::class.java) { prefs.negotiated(true, 1, 30000, 90000, 35000) }
        val short = prefs.copy(timeouts = mapOf(ConnectionTimeout.RECOVERY to 5000, ConnectionTimeout.SETUP to 10000))
        assertEquals(ConnectionDeadlines(5000, 10000, 35000, DeadlineState.LEGACY), short.negotiated(true, 0, 0, 0, 0))
    }

    @Test fun beforeAnOfferReplyDeadlinesAreReportedAsNotNegotiated() {
        val prefs = ConnectionPreferences(timeouts = mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.SETUP to 60000))
        val pending = prefs.unnegotiated()
        // Request budgets keep the old pre-offer numbers; only the label changes.
        assertEquals(ConnectionDeadlines(10000, 45000, 15000, DeadlineState.NOT_NEGOTIATED), pending)
        assertEquals(prefs.negotiated(false, 0, 0, 0, 0).copy(state = DeadlineState.NOT_NEGOTIATED), pending)
        val text = prefs.text(pending)
        assertEquals("Connection deadlines — requested recovery: 90000 ms · requested setup: 60000 ms · not negotiated (no Windows offer reply)",
            text.lines()[1])
        for (fact in listOf("legacy Windows limits", "update Windows", "effective:", "Windows heartbeat:", "confirmed by Windows"))
            assertFalse(fact, text.contains(fact))
        val legacy = prefs.text(prefs.negotiated(false, 0, 0, 0, 0)).lines()
        assertEquals(listOf(legacy[0], legacy[2]), listOf(text.lines()[0], text.lines()[2]))
        assertEquals(3, text.lines().size)
    }

    @Test fun aRejectedOfferReplyIsNotReportedAsMissingOrLegacy() {
        val prefs = ConnectionPreferences(timeouts = mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.SETUP to 60000))
        val rejected = prefs.unnegotiated().copy(state = DeadlineState.REJECTED)
        val text = prefs.text(rejected)
        assertEquals("Connection deadlines — requested recovery: 90000 ms · requested setup: 60000 ms · not negotiated (Windows offer reply rejected)",
            text.lines()[1])
        for (fact in listOf("no Windows offer reply", "legacy Windows limits", "effective:", "confirmed by Windows"))
            assertFalse(fact, text.contains(fact))
        assertEquals(prefs.text(prefs.unnegotiated()).lines().filterIndexed { i, _ -> i != 1 }, text.lines().filterIndexed { i, _ -> i != 1 })
    }

    @Test fun negotiatedDeadlineLabelsAreUnchanged() {
        val prefs = ConnectionPreferences(timeouts = mapOf(ConnectionTimeout.RECOVERY to 90000, ConnectionTimeout.SETUP to 90000))
        assertEquals("Connection deadlines — requested recovery: 90000 ms · effective: 30000 ms · setup: 45000 ms · Windows heartbeat: 35000 ms" +
            " · legacy Windows limits (update Windows for custom deadlines)", prefs.text(prefs.negotiated(true, 0, 0, 0, 0)).lines()[1])
        assertEquals("Connection deadlines — requested recovery: 90000 ms · effective: 10000 ms · setup: 45000 ms · Windows heartbeat: 15000 ms" +
            " · legacy Windows limits (update Windows for custom deadlines)", prefs.text(prefs.negotiated(false, 0, 0, 0, 0)).lines()[1])
        assertEquals("Connection deadlines — requested recovery: 90000 ms · effective: 90000 ms · setup: 90000 ms · Windows heartbeat: 95000 ms" +
            " · confirmed by Windows", prefs.text(prefs.negotiated(true, 1, 90000, 90000, 95000)).lines()[1])
        assertEquals("Connection order — initial: LAN → rendezvous · recovery: Rendezvous → LAN",
            prefs.text(prefs.unnegotiated()).lines()[0])
    }

    @Test fun everyInitialAndRecoveryOrderCombinationUsesItsSelectedPriority() {
        for (initial in ConnectionOrder.entries) for (recovery in ConnectionOrder.entries) {
            val route = SignalingRoute(true, initial, recovery)
            val calls = mutableListOf<String>()
            route.initial { calls += "probe"; true }
            fun exchange() = route.exchange("/status", { calls += "LAN" }, { calls += "remote" }, { true }, { false })
            exchange()
            assertEquals(if (initial == ConnectionOrder.LAN_FIRST) listOf("probe", "LAN") else listOf("remote"), calls)
            route.upgrade { true }
            if (initial == ConnectionOrder.RENDEZVOUS_FIRST) assertFalse(route.direct)
            calls.clear()
            route.recover { calls += "probe"; true }; exchange()
            assertEquals(if (recovery == ConnectionOrder.LAN_FIRST) listOf("probe", "LAN") else listOf("remote"), calls)
        }
    }

    @Test fun lanFirstRecoveryFallsBackAndStillRejectsTlsFailure() {
        val route = SignalingRoute(true, recoveryOrder = ConnectionOrder.LAN_FIRST)
        val calls = mutableListOf<String>()
        route.initial { false }; route.recover { true }
        route.exchange("/recover-answer", { calls += "LAN"; throw IOException() }, { calls += "remote" }, { false }, { false })
        assertEquals(listOf("LAN", "remote"), calls)
        route.recover { true }
        assertThrows(SSLException::class.java) {
            route.exchange("/status", { throw SSLException("test") }, { fail("security failure fell back") }, { false }, { false })
        }
    }

    @Test fun remoteFirstOfferStillRequiresCancellationBeforeAnAmbiguousReplay() {
        val route = SignalingRoute(true, ConnectionOrder.RENDEZVOUS_FIRST)
        route.initial { fail("unexpected LAN probe"); false }
        assertThrows(OfferFallbackRequired::class.java) {
            route.exchange("/offer", { fail("offer replayed") }, { throw IOException() }, { true }, { false })
        }
    }

    @Test fun extendedRecoverySurvivesFadingWifiButKeepsItsOriginalDeadline() {
        val recovery = LanRecovery(true, 90000, 2000, 10000, 6)
        recovery.observe(true, 0)
        assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 100))
        assertFalse(recovery.restartDue(2099)); recovery.begin(2100); recovery.accepted(2200)
        assertFalse(recovery.restartDue(12099)); recovery.begin(12100); recovery.accepted(12200)
        assertTrue(recovery.signalingFailed(SignalingRoutesUnavailable(), 40000))
        recovery.networkChanged(60000)
        assertEquals(30100L, recovery.remaining(60000))
        recovery.begin(60000); recovery.answer = "prepared answer"
        assertThrows(SocketTimeoutException::class.java) {
            recovery.exchangeStatus({ 90100 }, { fail("new restart") }, { fail("late answer") }, { fail("late heartbeat") })
        }
        assertEquals("prepared answer", recovery.answer)
        assertFalse(recovery.observe(true, 90100))
    }
}
