package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class PairingConnectIntentTest {
    @Test fun onlyItsOwnSavedApprovalContinuesExactlyOnce() {
        val intent = PairingConnectIntent()
        assertFalse(intent.take(12, false, true, true)) // Loading/scanning has no intent.
        intent.begin(12)
        assertFalse(intent.take(12, true, true, true)) // Save not yet confirmed.
        assertTrue(intent.take(12, false, true, true))
        assertFalse(intent.take(12, false, true, true)) // Replayed observer/service callback.
    }
    @Test fun backgroundStopCancelForgetOrNewActionPreventLateApproval() {
        for (action in listOf("background", "stop", "cancel", "forget")) {
            val intent = PairingConnectIntent()
            intent.begin(12); intent.cancel()
            assertFalse(action, intent.take(12, false, true, true))
        }
        val intent = PairingConnectIntent()
        intent.begin(12); intent.begin(13)
        assertFalse(intent.take(12, true, true, true))
        assertTrue(intent.take(13, false, true, true))
    }
    @Test fun rejectedExpiredCancelledAndUnsavedPairingNeverContinue() {
        for ((success, available) in listOf(0L to true, 11L to true, 12L to false)) {
            val intent = PairingConnectIntent()
            intent.begin(12)
            assertFalse(intent.take(success, false, available, true))
            assertFalse(intent.pending)
        }
        val intent = PairingConnectIntent()
        intent.begin(null)
        assertFalse(intent.take(12, false, true, true))
    }
    @Test fun approvalWaitsForVisibleBoundServicesAndDoesNotRememberAudioChoices() {
        val intent = PairingConnectIntent()
        intent.begin(12)
        assertFalse(intent.take(12, false, true, false))
        assertTrue(intent.pending)
        // The caller reads current AudioPreferences and uses the ordinary
        // Connect/permission path after taking this one-shot operation.
        assertTrue(intent.take(12, false, true, true))
    }
}
