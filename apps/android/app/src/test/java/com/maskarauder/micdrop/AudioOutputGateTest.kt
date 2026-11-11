package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class AudioOutputGateTest {
    @Test fun silenceCanBeSetBeforeTheOutputModuleExists() {
        val gate = AudioOutputGate(enabled = false)
        assertTrue(gate.muted)
        gate.request(true)
        assertFalse(gate.muted)
        gate.request(false)
        assertTrue(gate.muted)
    }

    @Test fun verifiedRouteRecoveryDoesNotOverrideUserSilence() {
        val gate = AudioOutputGate()
        gate.hold()
        gate.request(true)
        assertTrue(gate.muted) // Enabling audio cannot bypass route verification.
        gate.request(false)
        gate.verified()
        assertTrue(gate.muted)
        gate.hold(); gate.verified()
        assertTrue(gate.muted)
        gate.request(true)
        assertFalse(gate.muted)
    }

    @Test fun aFreshFocusResumeCanKeepBothItsInitialHoldAndSilence() {
        val previous = AudioOutputGate()
        previous.request(false)
        val resumed = AudioOutputGate(previous.enabled, held = true)
        assertTrue(resumed.muted)
        resumed.verified()
        assertTrue(resumed.muted)
        resumed.request(true)
        assertFalse(resumed.muted)
    }

    @Test fun stopWinsOverLateVerificationAndEnableRequests() {
        for (enabled in listOf(true, false)) {
            val gate = AudioOutputGate(enabled, held = true)
            gate.stop()
            gate.verified(); gate.request(true)
            assertTrue(gate.muted)
            gate.hold(); gate.verified()
            assertTrue(gate.muted)
        }
    }

    @Test fun onlyRetainedSessionsAcceptOutputChanges() {
        for (phase in SessionPhase.entries) {
            val allowed = phase !in listOf(SessionPhase.IDLE, SessionPhase.ENDED, SessionPhase.STOPPING)
            assertEquals(allowed, SessionView(phase).canSetOutput)
        }
    }
}
