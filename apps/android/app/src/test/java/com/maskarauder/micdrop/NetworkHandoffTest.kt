package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class NetworkHandoffTest {
    @Test fun defaultChangesIgnoreInitialDuplicatesAndDelayedLoss() {
        val identity = DefaultNetworkChanges<Int>()
        assertFalse(identity.available(1)); assertFalse(identity.blocked(1, false))
        assertFalse(identity.available(1))
        assertTrue(identity.available(2))
        assertFalse(identity.lost(1)); assertFalse(identity.blocked(1, true))
        assertFalse(identity.blocked(2, false))
        assertTrue(identity.blocked(2, true)); assertFalse(identity.blocked(2, true))
        assertTrue(identity.blocked(2, false))
        assertTrue(identity.lost(2)); assertFalse(identity.lost(2))
        assertTrue(identity.available(3))
    }

    @Test fun burstsCoalesceAndStopNeverResumesWork() {
        val handoff = NetworkHandoff()
        assertFalse(handoff.changed(0)); assertFalse(handoff.take(1000))
        handoff.arm(); assertFalse(handoff.take(1000))
        assertTrue(handoff.changed(2000)); assertTrue(handoff.changed(2100))
        assertFalse(handoff.take(2399)); assertTrue(handoff.take(2400))
        assertFalse(handoff.take(2500))
        handoff.changed(2600); handoff.stop()
        assertFalse(handoff.waiting()); assertFalse(handoff.take(10000))
        assertFalse(handoff.changed(20000)); handoff.arm(); assertFalse(handoff.take(30000))
    }

    @Test fun staleConnectedStateCannotCancelNetworkRestartAndFlappingCannotExtendDeadline() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0)
        recovery.networkChanged(500)
        assertFalse(recovery.observe(true, 500)); assertTrue(recovery.active)
        assertTrue(recovery.restartDue(500)); recovery.begin(500)
        recovery.answer = "one prepared answer"
        recovery.networkChanged(1000)
        assertEquals("one prepared answer", recovery.answer)
        assertFalse(recovery.restartDue(2000))
        recovery.accepted(2200)
        assertFalse(recovery.observe(true, 2500))
        assertTrue(recovery.restartDue(8500)); recovery.begin(8500); recovery.accepted(8600)
        assertTrue(recovery.observe(true, 9000)); assertFalse(recovery.active)
        recovery.networkChanged(10000)
        assertFalse(recovery.restartDue(10000)); assertFalse(recovery.restartDue(13599))
        recovery.begin(13600)
        repeat(10) { recovery.networkChanged(10001L + it * 1000) }
        assertTrue(recovery.expired(40000))
        assertFalse(recovery.observe(true, 40000))
    }

    @Test fun noRestartBeforeEstablishedOrForUnsupportedHosts() {
        for (supported in listOf(false, true)) {
            val recovery = LanRecovery(supported)
            recovery.networkChanged(1)
            assertFalse(recovery.active); assertFalse(recovery.restartDue(1000))
        }
    }
}
