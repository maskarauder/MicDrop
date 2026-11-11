package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class BluetoothOutputRecoveryTest {
    private val selected = OutputSelection(OutputKind.BLUETOOTH, 40,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, "AA:BB:CC:DD:EE:10")

    @Test fun customRecoveryDeadlineSurvivesRebindingButDoesNotExtendNewSelectionVerification() {
        val route = OutputRouteChange(selected, bluetoothRecoveryMs = 60500)
        route.verified(route.ticket)
        route.recoverBluetooth(route.ticket, 1000)
        route.rebind(route.ticket, selected.copy(deviceId = 90))
        route.trackStarted()
        route.beginCheck(route.ticket, 40000)
        assertFalse(route.expired(61499))
        assertTrue(route.expired(61500))
        val old = route.ticket
        route.request(OutputSelection(OutputKind.PHONE, deviceType = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertFalse(route.verified(old))
        route.beginCheck(route.ticket, 62000)
        assertFalse(route.expired(66999))
        assertTrue(route.expired(67000))
    }

    @Test fun recoveryWaitsTwentySecondsAndRejectsTheOldTracksAcknowledgment() {
        val route = OutputRouteChange(selected)
        val old = route.ticket
        assertTrue(route.verified(old))
        assertTrue(route.recoverBluetooth(old, 1000))
        assertTrue(route.pending)
        assertTrue(route.recovering)
        assertFalse(route.verified(old))
        assertFalse(route.rebind(old, selected.copy(deviceId = 60)))
        assertFalse(route.expired(20999))
        assertTrue(route.expired(21000))
    }

    @Test fun repeatedEventsPortRecreationAndTrackRestartCannotExtendTheDeadline() {
        val route = OutputRouteChange(selected)
        route.verified(route.ticket)
        assertTrue(route.recoverBluetooth(route.ticket, 1000))
        assertFalse(route.recoverBluetooth(route.ticket, 9000))
        assertTrue(route.rebind(route.ticket, selected.copy(deviceId = 60, address = selected.address.lowercase())))
        route.beginCheck(route.ticket, 15000)
        route.trackStarted()
        route.beginCheck(route.ticket, 20000)
        assertTrue(route.recovering)
        assertFalse(route.expired(20999))
        assertTrue(route.expired(21000))
    }

    @Test fun rebindCannotChangeHeadsetProfileOrPhysicalIdentity() {
        val route = OutputRouteChange(selected)
        route.verified(route.ticket); route.recoverBluetooth(route.ticket, 0)
        assertFalse(route.rebind(route.ticket, selected.copy(deviceId = 60, address = "AA:BB:CC:DD:EE:20")))
        assertFalse(route.rebind(route.ticket, selected.copy(kind = OutputKind.LE,
            deviceType = AudioDeviceInfo.TYPE_BLE_HEADSET)))
        assertTrue(route.rebind(route.ticket, selected.copy(deviceId = 60)))
        assertEquals(60, route.selection.deviceId)
    }

    @Test fun successfulRecoveryPreservesUserSilenceAndAllowsANewIndependentEpisode() {
        for (enabled in listOf(false, true)) {
            val route = OutputRouteChange(selected)
            val gate = AudioOutputGate(enabled = enabled)
            route.verified(route.ticket); route.recoverBluetooth(route.ticket, 0); gate.hold()
            assertTrue(gate.muted)
            if (route.verified(route.ticket)) gate.verified()
            assertEquals(!enabled, gate.muted)
            assertFalse(route.recovering)
            assertTrue(route.recoverBluetooth(route.ticket, 30000))
            assertFalse(route.expired(49999))
            assertTrue(route.expired(50000))
        }
    }

    @Test fun stopOrANewOutputChoiceCancelsTheOriginalRecovery() {
        val route = OutputRouteChange(selected)
        route.verified(route.ticket); route.recoverBluetooth(route.ticket, 0)
        val old = route.ticket
        assertTrue(route.request(OutputSelection()))
        assertFalse(route.recovering)
        assertFalse(route.verified(old))
        assertFalse(route.rebind(old, selected.copy(deviceId = 60)))
        assertFalse(route.recoverBluetooth(route.ticket, 10000))
        assertTrue(route.verified(route.ticket))
        assertTrue(route.request(selected))
        route.recoverBluetooth(route.ticket, 10000)
        val stopped = route.ticket
        route.stop()
        assertFalse(route.verified(stopped))
        assertFalse(route.rebind(stopped, selected.copy(deviceId = 60)))
        assertFalse(route.recoverBluetooth(stopped, 30000))
        route.trackStarted()
        assertFalse(route.pending)
        assertFalse(route.recovering)
    }

    @Test fun selectedOutputRecoveryLeavesBothDuplexMicrophoneMuteChoicesUsable() {
        for (muted in listOf(false, true)) for (enabled in listOf(false, true)) {
            val view = MicrophoneView(SessionView(SessionPhase.PLAYING, outputEnabled = enabled,
                outputPause = OutputPause.SELECTED_BLUETOOTH), muted = muted, mode = StreamMode.DUPLEX)
            assertTrue(view.ownsSession)
            assertTrue(view.canSetMuted(!muted))
            assertTrue(view.canChooseInput)
            assertTrue(view.session.canSetOutput)
            assertFalse(view.canResume)
        }
    }

    @Test fun settlingClearsQueuedRecreationWithoutRenewingTheFiniteBudget() {
        val budget = OutputRestartBudget()
        budget.request(); assertTrue(budget.take(0))
        budget.request(); budget.settled(); assertFalse(budget.take(1000))
        budget.request(); assertTrue(budget.take(1000))
        budget.request(); budget.settled(); budget.request()
        assertFalse(budget.take(5000))
        budget.newRoute(); budget.request(); assertTrue(budget.take(10000))
    }
}
