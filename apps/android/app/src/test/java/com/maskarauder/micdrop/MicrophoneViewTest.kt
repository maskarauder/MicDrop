package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class MicrophoneViewTest {
    @Test fun delayedCleanupAndRepeatedFocusLossCannotExtendTheResumeWindow() {
        val window = DuplexPauseWindow()
        window.retain(1_000)
        window.retain(120_000) // A repeated loss must not renew the original consent.
        assertFalse(window.expired(300_999))
        // Android may return focus after sleep before its Handler cleanup runs.
        assertTrue(window.expired(301_000))
        assertTrue(window.expired(3_600_000))
        window.clear()
        assertFalse(window.expired(3_600_000))
        window.retain(3_600_000)
        assertFalse(window.expired(3_899_999))
        assertTrue(window.expired(3_900_000))
    }

    @Test fun pausedDuplexRetainsOwnershipAndResumeButCannotStartAMicrophoneOnlySession() {
        for (phase in listOf(SessionPhase.PAUSING, SessionPhase.PAUSED, SessionPhase.INTERRUPTED)) {
            val duplex = MicrophoneView(SessionView(phase), muted = false,
                changing = phase == SessionPhase.PAUSING, mode = StreamMode.DUPLEX)
            assertTrue(duplex.ownsSession)
            assertTrue(duplex.canResume)
            assertTrue(duplex.canSetMuted(true))
            assertFalse(duplex.copy(mode = StreamMode.MICROPHONE).canResume)
            if (phase != SessionPhase.PAUSING) assertTrue(duplex.copy(muted = true).canSetMuted(false))
        }
        for (phase in listOf(SessionPhase.IDLE, SessionPhase.ENDED, SessionPhase.STOPPING, SessionPhase.CONNECTING))
            assertFalse(MicrophoneView(SessionView(phase), mode = StreamMode.DUPLEX).canResume)
    }

    @Test fun repeatedNotificationCommandsCannotGateAudioOrLeaveControlPending() {
        for (phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING)) {
            for (muted in listOf(true, false)) {
                val view = MicrophoneView(SessionView(phase), muted)
                assertFalse(view.canSetMuted(muted))
                assertTrue(view.canSetMuted(!muted))
                assertFalse(view.copy(changing = true).canSetMuted(muted))
                assertFalse(view.copy(changing = true).canSetMuted(!muted))
            }
        }
    }

    @Test fun setupStopAndInactiveStatesRejectMuteActions() {
        for (phase in SessionPhase.entries.filter { it !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING,
                SessionPhase.ROUTE_RECOVERING, SessionPhase.CONNECTING, SessionPhase.SWITCHING) }) {
            for (muted in listOf(true, false)) {
                val view = MicrophoneView(SessionView(phase), muted)
                assertFalse(view.canSetMuted(true))
                assertFalse(view.canSetMuted(false))
            }
        }
    }

    @Test fun inputChoicesRequireAnExistingNegotiatedMicrophoneAndNoOverlappingSetup() {
        for (phase in SessionPhase.entries) {
            val available = phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING,
                SessionPhase.ROUTE_RECOVERING, SessionPhase.PAUSED, SessionPhase.INTERRUPTED)
            val mic = MicrophoneView(SessionView(phase), mode = StreamMode.DUPLEX)
            assertEquals(available, mic.canChooseInput)
            assertFalse(mic.copy(mode = StreamMode.PLAYBACK).canChooseInput)
        }
    }

    @Test fun muteCanCancelCaptureDuringSetupAndInputReplacementButCannotStartIt() {
        for (phase in listOf(SessionPhase.CONNECTING, SessionPhase.SWITCHING)) {
            val changing = MicrophoneView(SessionView(phase), muted = false, changing = true)
            assertTrue(changing.canSetMuted(true))
            assertFalse(changing.copy(muted = true).canSetMuted(false))
            assertFalse(changing.copy(session = SessionView(SessionPhase.STOPPING)).canSetMuted(true))
        }
    }

    @Test fun windowsCanUnmuteOnlyCaptureThisPhoneEnabledWhilePermissionIsGranted() {
        for (phase in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING, SessionPhase.ROUTE_RECOVERING)) {
            val unmuted = MicrophoneView(SessionView(phase), muted = false)
            // Mute keeps its authority without either Unmute term.
            for (granted in listOf(true, false)) for (enabled in listOf(true, false))
                assertTrue("$phase", unmuted.offersPhoneControlMute(granted, enabled))
            val muted = unmuted.copy(muted = true)
            assertTrue("$phase", muted.offersPhoneControlMute(permissionGranted = true, phoneEnabledCapture = true))
            assertFalse("$phase", muted.offersPhoneControlMute(permissionGranted = false, phoneEnabledCapture = true))
            assertFalse("$phase", muted.offersPhoneControlMute(permissionGranted = true, phoneEnabledCapture = false))
            assertFalse("$phase", muted.offersPhoneControlMute(permissionGranted = false, phoneEnabledCapture = false))
            // A local change in flight hides the field in both directions.
            assertFalse("$phase", muted.copy(changing = true).offersPhoneControlMute(true, true))
            assertFalse("$phase", unmuted.copy(changing = true).offersPhoneControlMute(true, true))
            assertFalse("$phase", muted.copy(mode = StreamMode.PLAYBACK).offersPhoneControlMute(true, true))
        }
    }

    @Test fun aMuteDuringSetupNeverLetsWindowsStartTheFirstCapture() {
        val connecting = MicrophoneView(SessionView(SessionPhase.CONNECTING), muted = false, changing = true)
        assertTrue(connecting.canSetMuted(true))
        assertFalse(connecting.offersPhoneControlMute(true, false))
        // The session then reaches Playing muted with capture never opened.
        val playing = MicrophoneView(SessionView(SessionPhase.PLAYING), muted = true)
        assertTrue(playing.canSetMuted(false)) // The phone itself can still unmute.
        assertFalse(playing.offersPhoneControlMute(permissionGranted = true, phoneEnabledCapture = false))
        assertTrue(playing.offersPhoneControlMute(permissionGranted = true, phoneEnabledCapture = true))
        for (phase in listOf(SessionPhase.CONNECTING, SessionPhase.SWITCHING))
            assertFalse(MicrophoneView(SessionView(phase), muted = true).offersPhoneControlMute(true, true))
    }

    @Test fun inactiveAndStoppingSessionsOfferWindowsNoMuteField() {
        for (phase in SessionPhase.entries.filter { it !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING,
                SessionPhase.ROUTE_RECOVERING, SessionPhase.CONNECTING, SessionPhase.SWITCHING) }) {
            for (muted in listOf(true, false))
                assertFalse("$phase", MicrophoneView(SessionView(phase), muted).offersPhoneControlMute(true, true))
        }
    }

    @Test fun muteCanOverrideAnUnmuteWhileTheHeadsetIsBeingRestored() {
        val pending = MicrophoneView(SessionView(SessionPhase.ROUTE_RECOVERING), muted = false, changing = true)
        assertTrue(pending.canSetMuted(true))
        assertFalse(pending.canSetMuted(false))
        val muted = pending.copy(muted = true)
        assertFalse(muted.canSetMuted(true))
        assertFalse(muted.canSetMuted(false))
        assertTrue(muted.copy(changing = false).canSetMuted(false))
        assertFalse(pending.copy(session = SessionView(SessionPhase.STOPPING)).canSetMuted(true))
    }
}
