package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class LanRecoveryTest {
    @Test fun interruptedStartupNeverRenegotiatesOrStartsANewSession() {
        val recovery = LanRecovery(true)
        recovery.observe(false, 0)
        assertFalse(recovery.restartDue(2000))
        assertTrue(recovery.expired(30000))
    }
    @Test fun failedSignalingReusesOneGenerationAndCannotExtendTheDeadline() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.observe(false, 100)
        assertFalse(recovery.restartDue(1099))
        recovery.begin(1100)
        val prepared = "synthetic answer"
        recovery.answer = prepared
        recovery.observe(false, 20000)
        assertEquals(1, recovery.generation)
        assertEquals(prepared, recovery.answer)
        assertFalse(recovery.restartDue(21000))
        assertEquals(9100, recovery.remaining(21000))
        assertTrue(recovery.expired(30100))
        assertFalse(recovery.observe(true, 30100))
        assertTrue(recovery.active)
    }
    @Test fun atMostTwoRestartAttemptsBelongToTheSameRecoveryWindow() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.observe(false, 100)
        recovery.begin(1100); recovery.accepted(1200)
        assertFalse(recovery.restartDue(9099))
        recovery.begin(9100); recovery.accepted(9200)
        assertFalse(recovery.restartDue(20000))
        assertEquals(2, recovery.generation)
        assertTrue(recovery.expired(30100))
    }
    @Test fun confirmedRecoveryAllowsANewEpisodeWithoutReusingGenerations() {
        val recovery = LanRecovery(true)
        recovery.observe(true, 0); recovery.observe(false, 100)
        recovery.begin(1100); recovery.accepted(1200)
        assertTrue(recovery.observe(true, 2000))
        assertFalse(recovery.active)
        recovery.observe(false, 5000); recovery.begin(6500)
        assertEquals(2, recovery.generation)
        assertEquals(28500, recovery.remaining(6500))
    }
    @Test fun olderHostsKeepTheirTenSecondRecoveryWindow() {
        val recovery = LanRecovery(false)
        recovery.observe(true, 0); recovery.observe(false, 100)
        assertFalse(recovery.restartDue(2000))
        assertFalse(recovery.expired(10099))
        assertTrue(recovery.expired(10100))
    }
    @Test fun onlyLiteralPrivateIPv4HostsUseLanSignaling() {
        for (host in listOf("10.4.5.6", "172.16.0.1", "172.31.255.254", "192.168.4.2", "169.254.2.3"))
            assertNotNull(host, LanAddress.bytes(host))
        for (host in listOf("172.15.0.1", "172.32.0.1", "192.169.0.1", "8.8.8.8", "host.example", "::1", "10.2.3", "10.2.3.256"))
            assertNull(host, LanAddress.bytes(host))
    }
}
