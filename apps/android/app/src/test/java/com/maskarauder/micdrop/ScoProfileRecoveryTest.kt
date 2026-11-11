package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class ScoProfileRecoveryTest {
    private val address = "AA:BB:CC:DD:EE:10"
    private val car = "AA:BB:CC:DD:EE:20"
    private val original = MicrophoneDevice(30, AudioDeviceInfo.TYPE_BLUETOOTH_SCO, false, address)
    private val endpoint = HeadsetEndpoint(original)

    private class Connection(var addresses: List<String>, var supported: Boolean = true,
                             var accepted: Boolean = true) : ScoProfileConnection {
        val starts = mutableListOf<String>()
        val stops = mutableListOf<String>()
        var onSupport: () -> Unit = {}
        var onStart: () -> Unit = {}
        override fun connectedAddresses() = addresses
        override fun supportsAudioRequest(address: String): Boolean { onSupport(); return supported }
        override fun startAudio(address: String): Boolean { starts.add(address); onStart(); return accepted }
        override fun stopOwnedAudio(address: String) { stops.add(address) }
    }

    @Test fun aHiddenAudioPortCanRequestOnlyItsOriginalConnectedProfile() {
        val recovery = HeadsetRecovery().also { it.request(1000) }
        val profile = ScoProfileRecovery(endpoint)
        val connection = Connection(listOf(car, address.lowercase()))
        // Audio policy exposes only the car, although both HFP links remain.
        val carPort = original.copy(id = 50, address = car)
        assertNull(endpoint.resolve(listOf(carPort)))
        assertEquals(ScoProfileCheck.ACCEPTED, profile.request(connection, recovery, { 1001 }) { true })
        assertEquals(listOf(address.lowercase()), connection.starts)
        assertTrue(recovery.pending()) // A profile request does not verify/resume PCM.
        assertTrue(recovery.text().contains("Completed: 0"))
        assertTrue(recovery.text().contains("SCO profile requests: 1"))
        assertTrue(recovery.text().contains("Reselection requests: 0"))
        val replacement = original.copy(id = 31)
        assertEquals(replacement, endpoint.resolve(listOf(carPort, replacement)))
        assertFalse(endpoint.matches(carPort, replacement))
        profile.close(); profile.close()
        assertEquals(listOf(address.lowercase()), connection.stops)
    }

    @Test fun anAcceptedRequestIsNotRestartedWhileItsAudioPortIsAppearing() {
        val recovery = HeadsetRecovery().also { it.request(1000) }
        val profile = ScoProfileRecovery(endpoint)
        val connection = Connection(listOf(address))
        assertEquals(ScoProfileCheck.ACCEPTED, profile.request(connection, recovery, { 1001 }) { true })
        assertEquals(15000L, recovery.remaining(6000))
        for (now in 1500L..20500L step 500) {
            recovery.request(now)
            assertEquals(ScoProfileCheck.ACCEPTED, profile.request(connection, recovery, { now }) { true })
        }
        assertEquals(1, connection.starts.size)
        assertTrue(recovery.text().contains("Completed: 0")) // Acceptance is still not a verified route.
        assertEquals(ScoProfileCheck.CANCELLED, profile.request(connection, recovery, { 21000 }) { true })
        assertEquals(0L, recovery.remaining(21000))
    }

    @Test fun unsupportedDisconnectedAmbiguousAndUnknownIdentitiesNeverStartAudio() {
        val cases = listOf(
            Triple(endpoint, Connection(listOf(car)), ScoProfileCheck.DISCONNECTED),
            Triple(endpoint, Connection(listOf(address, address.lowercase())), ScoProfileCheck.AMBIGUOUS),
            Triple(endpoint, Connection(listOf(address), supported = false), ScoProfileCheck.UNSUPPORTED),
            Triple(HeadsetEndpoint(original.copy(address = "XX:XX:XX:XX:EE:10")),
                Connection(listOf(address)), ScoProfileCheck.DISCONNECTED),
            Triple(HeadsetEndpoint(original.copy(address = "")),
                Connection(listOf(address)), ScoProfileCheck.DISCONNECTED),
            Triple(HeadsetEndpoint(original.copy(type = AudioDeviceInfo.TYPE_BLE_HEADSET)),
                Connection(listOf(address)), ScoProfileCheck.DISCONNECTED)
        )
        for ((pin, connection, expected) in cases) {
            val recovery = HeadsetRecovery().also { it.request(1000) }
            val profile = ScoProfileRecovery(pin)
            assertEquals(expected, profile.request(connection, recovery, { 1001 }) { true })
            profile.close()
            assertTrue(connection.starts.isEmpty()); assertTrue(connection.stops.isEmpty())
            assertTrue(recovery.text().contains("SCO profile requests: 0"))
        }
    }

    @Test fun rejectedRequestsHaveTheirOwnBoundedBudgetInsideTheSameDeadline() {
        val recovery = HeadsetRecovery().also { it.request(1000) }
        val profile = ScoProfileRecovery(endpoint)
        val connection = Connection(listOf(address), accepted = false)
        assertEquals(ScoProfileCheck.REJECTED, profile.request(connection, recovery, { 1001 }) { true })
        assertEquals(ScoProfileCheck.WAITING, profile.request(connection, recovery, { 1500 }) { true })
        for (now in listOf(1501L, 2001L))
            assertEquals(ScoProfileCheck.REJECTED, profile.request(connection, recovery, { now }) { true })
        assertEquals(ScoProfileCheck.WAITING, profile.request(connection, recovery, { 2501 }) { true })
        assertEquals(3, connection.starts.size)
        assertEquals(18499L, recovery.remaining(2501))
        assertTrue(recovery.reselectionDue(2501)) // Normal port selection has a separate budget.
        profile.close()
        assertTrue(connection.stops.isEmpty()) // A rejected request confers no ownership.
        assertTrue(recovery.complete(requireNotNull(recovery.current()), 2502))
        recovery.request(3000)
        connection.accepted = true
        assertEquals(ScoProfileCheck.ACCEPTED, profile.request(connection, recovery, { 3001 }) { true })
        assertTrue(recovery.text().contains("SCO profile requests: 4"))
    }

    @Test fun permissionLossStopOrExpiryWhileInspectingTheProfilePreventsTheRequest() {
        for (reason in listOf("stop", "expiry", "permission")) {
            val recovery = HeadsetRecovery().also { it.request(1000) }
            val profile = ScoProfileRecovery(endpoint)
            val connection = Connection(listOf(address))
            var now = 1001L
            var allowed = true
            connection.onSupport = {
                when (reason) {
                    "stop" -> recovery.cancel()
                    "expiry" -> now = 21000L
                    else -> allowed = false
                }
            }
            assertEquals(ScoProfileCheck.CANCELLED, profile.request(connection, recovery, { now }) { allowed })
            assertTrue(connection.starts.isEmpty())
            assertTrue(recovery.text().contains("SCO profile requests: 0"))
        }
    }

    @Test fun anAcceptedRequestThatFinishesAfterStopOrExpiryStillBelongsToCleanup() {
        for (stop in listOf(true, false)) {
            val recovery = HeadsetRecovery().also { it.request(1000) }
            val profile = ScoProfileRecovery(endpoint)
            val connection = Connection(listOf(address))
            var now = 1001L
            connection.onStart = { if (stop) recovery.cancel() else now = 21000L }
            assertEquals(ScoProfileCheck.CANCELLED, profile.request(connection, recovery, { now }) { true })
            assertFalse(recovery.complete(HeadsetRecoveryTicket(1, 1), now))
            profile.close()
            assertEquals(listOf(address), connection.stops)
            assertEquals(listOf(address), connection.starts)
        }
    }

    @Test fun unavailableProxyAndPlatformExceptionsDoNotInferAnotherDeviceOrClaimSuccess() {
        val recovery = HeadsetRecovery().also { it.request(1000) }
        val profile = ScoProfileRecovery(endpoint)
        assertEquals(ScoProfileCheck.UNAVAILABLE, profile.request(null, recovery, { 1001 }) { true })
        val connection = Connection(listOf(address)).also {
            it.onSupport = { throw SecurityException("synthetic permission denial") }
        }
        assertEquals(ScoProfileCheck.UNAVAILABLE, profile.request(connection, recovery, { 1001 }) { true })
        assertTrue(connection.starts.isEmpty())
        assertTrue(recovery.text().contains("SCO profile requests: 0"))
        assertFalse(recovery.text().contains(address))
        for (check in ScoProfileCheck.entries) {
            assertFalse(check.text.contains(address)); assertFalse(check.text.contains(car))
        }
    }
}
