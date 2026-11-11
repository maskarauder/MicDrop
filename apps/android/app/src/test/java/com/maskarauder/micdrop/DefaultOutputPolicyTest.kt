package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class DefaultOutputPolicyTest {
    @Test fun defaultBluetoothHandoverDoesNotRequireAnExactPortOrANewSession() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.observe(listOf(OutputKind.BLUETOOTH))
        assertFalse(policy.held)
        for (next in listOf(OutputKind.LE, OutputKind.HEARING_AID, OutputKind.BLUETOOTH)) {
            policy.changing()
            assertTrue(policy.held)
            policy.observe(listOf(next))
            assertFalse(policy.held)
        }
    }

    @Test fun losingTheLastBluetoothOutputProtectsTheSpeakerUntilASafeRouteReturns() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.observe(listOf(OutputKind.BLUETOOTH))
        policy.noisy()
        policy.observe(null)
        assertTrue(policy.held)
        policy.observe(listOf(OutputKind.PHONE))
        assertEquals(OutputPause.BLUETOOTH, policy.pause)
        policy.observe(listOf(OutputKind.PHONE))
        assertTrue(policy.held)
        policy.observe(listOf(OutputKind.BLUETOOTH))
        assertFalse(policy.held)
    }

    @Test fun aLateNoisyBroadcastWithNoPreviousRouteSnapshotStillProtectsTheSpeaker() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.noisy()
        policy.observe(listOf(OutputKind.PHONE))
        assertTrue(policy.held)
        assertTrue(policy.speakerProtected)
    }

    @Test fun missingLastBluetoothOutputKeepsTheSpeakerActionThroughDelayedRouteCallbacks() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.observe(listOf(OutputKind.BLUETOOTH))
        val inventory = BluetoothMediaInventory()
        inventory.update(emptyList()) // Both headset loss and radio shutdown remove media ports.
        for (muted in listOf(false, true)) {
            val microphone = MicrophoneView(SessionView(SessionPhase.PLAYING), muted = muted, mode = StreamMode.DUPLEX)
            for (change in listOf<() -> Unit>(policy::noisy, policy::changing, { policy.observe(null) },
                    { policy.observe(emptyList()) }, policy::unavailable)) {
                change()
                val held = microphone.copy(session = microphone.session.copy(
                    outputPause = policy.pauseForInventory(inventory.available)))
                assertEquals(OutputPause.BLUETOOTH, held.session.outputPause)
                assertTrue(held.session.canUsePhoneSpeaker)
                assertTrue(held.ownsSession)
                assertEquals(muted, held.muted)
                assertTrue(policy.held) // Offering the action does not authorize speaker audio.
                assertEquals(policy.pause, policy.pauseForInventory(true)) // A returning port still needs route verification.
                assertFalse(held.session.copy(outputEnabled = false).canUsePhoneSpeaker)
                assertFalse(held.session.copy(phase = SessionPhase.STOPPING).canUsePhoneSpeaker)
            }
        }
        policy.select(OutputSelection.fallbackSpeaker())
        assertNull(policy.pauseForInventory(false))
        assertFalse(policy.speakerProtected)
    }

    @Test fun missingBluetoothInventoryDoesNotChangeUnprotectedOrVerifiedExternalRoutes() {
        val policy = DefaultOutputPolicy(OutputSelection())
        assertEquals(OutputPause.ROUTE, policy.pauseForInventory(false)) // Starting without Bluetooth grants no new action.
        policy.unavailable()
        assertEquals(OutputPause.UNAVAILABLE, policy.pauseForInventory(false))
        policy.observe(listOf(OutputKind.PHONE))
        assertNull(policy.pauseForInventory(false))
        policy.observe(listOf(OutputKind.BLUETOOTH))
        for (safe in listOf(OutputKind.WIRED, OutputKind.USB)) {
            policy.observe(listOf(safe))
            assertNull(policy.pauseForInventory(false)) // Inventory cannot pause verified wired/USB playback.
        }
        policy.select(OutputSelection(OutputKind.BLUETOOTH))
        policy.noisy(); policy.changing(); policy.unavailable()
        assertNull(policy.pauseForInventory(false)) // Pinned Bluetooth retains its separate recovery contract.
    }

    @Test fun startingOnThePhoneIsAllowedAndAnExplicitPhoneChoiceOverridesFallbackProtection() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.observe(listOf(OutputKind.PHONE))
        assertFalse(policy.held)
        policy.observe(listOf(OutputKind.BLUETOOTH))
        policy.observe(listOf(OutputKind.PHONE))
        assertTrue(policy.held)
        policy.select(OutputSelection.restored(OutputKind.PHONE))
        assertFalse(policy.held)
        assertFalse(policy.speakerProtected)
        policy.select(OutputSelection())
        policy.observe(listOf(OutputKind.PHONE))
        assertFalse(policy.held)
    }

    @Test fun safeWiredOutputCanResumeButAMultiDeviceRouteIncludingTheSpeakerCannot() {
        val policy = DefaultOutputPolicy(OutputSelection(), protectedSpeaker = true)
        policy.observe(listOf(OutputKind.BLUETOOTH, OutputKind.PHONE))
        assertTrue(policy.held)
        policy.observe(listOf(OutputKind.WIRED))
        assertFalse(policy.held)
        policy.observe(emptyList())
        assertTrue(policy.held)
        policy.observe(listOf(OutputKind.PHONE))
        assertTrue(policy.held)
    }

    @Test fun routeAndFocusRecoveryNeverUndoUserSilence() {
        val policy = DefaultOutputPolicy(OutputSelection())
        val gate = AudioOutputGate()
        val focus = MediaOutputFocus()
        policy.observe(listOf(OutputKind.BLUETOOTH))
        policy.noisy(); gate.request(false); focus.lose(true)
        policy.observe(listOf(OutputKind.BLUETOOTH))
        assertFalse(policy.held)
        assertTrue(gate.muted || policy.held || focus.pause != null)
        assertTrue(focus.gain())
        assertTrue(gate.muted)
        assertFalse(gate.enabled)
        gate.request(true)
        assertFalse(gate.muted || policy.held || focus.pause != null)
    }

    @Test fun aFocusOrSourceReplacementRetainsTheDefaultSpeakerGuard() {
        val old = DefaultOutputPolicy(OutputSelection())
        old.observe(listOf(OutputKind.BLUETOOTH))
        old.noisy()
        val replacement = DefaultOutputPolicy(OutputSelection(), old.speakerProtected)
        replacement.observe(listOf(OutputKind.PHONE))
        assertTrue(replacement.held)
        replacement.observe(listOf(OutputKind.LE))
        assertFalse(replacement.held)
    }

    @Test fun outputPauseLeavesDuplexMicrophoneControlsUsableForBothMuteChoices() {
        for (muted in listOf(false, true)) for (enabled in listOf(false, true)) {
            val view = MicrophoneView(SessionView(SessionPhase.PLAYING, outputEnabled = enabled,
                outputPause = OutputPause.BLUETOOTH), muted = muted, mode = StreamMode.DUPLEX)
            assertTrue(view.ownsSession)
            assertTrue(view.canChooseInput)
            assertTrue(view.canSetMuted(!muted))
            assertTrue(view.session.canSetOutput)
            assertEquals(enabled, view.session.outputEnabled)
            assertFalse(view.canResume) // There is no new capture/peer to resume.
        }
    }

    @Test fun explicitExternalOutputsKeepTheirSeparateExactRouteContract() {
        val policy = DefaultOutputPolicy(OutputSelection(OutputKind.BLUETOOTH))
        policy.noisy(); policy.changing(); policy.unavailable()
        assertFalse(policy.held)
        assertNull(policy.pause)
    }

    @Test fun speakerFallbackHasALiveOverrideWithoutChangingTheMicrophoneOrAudioRequest() {
        for (muted in listOf(false, true)) {
            val policy = DefaultOutputPolicy(OutputSelection())
            policy.observe(listOf(OutputKind.BLUETOOTH))
            policy.observe(listOf(OutputKind.PHONE))
            val microphone = MicrophoneView(SessionView(SessionPhase.PLAYING,
                outputEnabled = true, outputPause = policy.pause), muted = muted, mode = StreamMode.DUPLEX)
            assertTrue(microphone.session.outputEnabled)
            assertTrue(microphone.session.outputPaused)
            assertTrue(microphone.session.canUsePhoneSpeaker)
            val speaker = OutputSelection.restored(OutputKind.PHONE)
            policy.select(speaker)
            val resumed = microphone.copy(session = microphone.session.copy(
                outputSelection = speaker, outputPause = policy.pause))
            assertTrue(resumed.ownsSession)
            assertEquals(muted, resumed.muted)
            assertEquals(StreamMode.DUPLEX, resumed.mode)
            assertTrue(resumed.session.outputEnabled)
            assertFalse(resumed.session.outputPaused)
            assertFalse(resumed.session.canUsePhoneSpeaker)
            assertTrue(resumed.session.canFollowAndroidOutput)
            policy.select(OutputSelection())
            policy.observe(listOf(OutputKind.BLUETOOTH))
            val following = resumed.copy(session = resumed.session.copy(outputSelection = OutputSelection(),
                outputPause = policy.pause))
            assertTrue(following.ownsSession)
            assertEquals(muted, following.muted)
            assertEquals(StreamMode.DUPLEX, following.mode)
            assertTrue(following.session.outputEnabled)
            assertFalse(following.session.outputPaused)
            assertFalse(following.session.canFollowAndroidOutput)
        }
    }

    @Test fun returningToAndroidOutputIsOnlyAnExplicitActionOnALiveSpeakerSession() {
        val phone = SessionView(SessionPhase.PLAYING, outputSelection = OutputSelection.restored(OutputKind.PHONE))
        for (phase in SessionPhase.entries.filter { it !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING) })
            assertFalse(phone.copy(phase = phase).canFollowAndroidOutput)
        assertFalse(phone.copy(outputEnabled = false).canFollowAndroidOutput)
        assertFalse(phone.copy(outputSelection = OutputSelection(OutputKind.BLUETOOTH)).canFollowAndroidOutput)
        assertFalse(phone.copy(outputSelection = OutputSelection()).canFollowAndroidOutput)
        assertTrue(phone.copy(outputPause = OutputPause.ROUTE).canFollowAndroidOutput)
    }

    @Test fun aSpeakerOverrideCannotResumeSilencedPausedOrStoppedSessionsOrReplaceAPinnedOutput() {
        val held = SessionView(SessionPhase.PLAYING, outputPause = OutputPause.BLUETOOTH)
        for (phase in SessionPhase.entries.filter { it !in listOf(SessionPhase.PLAYING, SessionPhase.RECOVERING) })
            assertFalse(held.copy(phase = phase).canUsePhoneSpeaker)
        assertFalse(held.copy(outputEnabled = false).canUsePhoneSpeaker)
        assertFalse(held.copy(outputEnabled = false).outputPaused)
        assertFalse(held.copy(outputSelection = OutputSelection(OutputKind.BLUETOOTH)).canUsePhoneSpeaker)
        for (pause in OutputPause.entries.filter { it != OutputPause.BLUETOOTH })
            assertFalse(held.copy(outputPause = pause).canUsePhoneSpeaker)
        val gate = AudioOutputGate()
        gate.request(false)
        val policy = DefaultOutputPolicy(OutputSelection(), protectedSpeaker = true)
        policy.observe(listOf(OutputKind.PHONE))
        policy.select(OutputSelection.restored(OutputKind.PHONE))
        assertFalse(policy.held)
        assertTrue(gate.muted) // Selecting a speaker never grants a silenced audio request.
    }

    @Test fun stopCannotBeUndoneByALateDeviceOrRouteCallback() {
        val policy = DefaultOutputPolicy(OutputSelection())
        policy.stop()
        policy.observe(listOf(OutputKind.BLUETOOTH)); policy.changing(); policy.noisy()
        policy.select(OutputSelection.restored(OutputKind.PHONE))
        assertTrue(policy.held)
    }

    @Test fun outputRecreationIsBoundedAndOnlyANewDeviceChoiceRenewsItsBudget() {
        val budget = OutputRestartBudget()
        budget.request(); assertTrue(budget.take(0))
        budget.request(); assertFalse(budget.take(999)); assertTrue(budget.take(1000))
        repeat(100) { budget.request(); assertFalse(budget.take(10000L + it)) }
        budget.newRoute(); budget.request(); assertTrue(budget.take(20000))
        budget.stop(); budget.newRoute(); budget.request()
        assertFalse(budget.take(30000))
    }

    @Test fun permanentFocusLossRequiresAnExplicitGrantEvenAfterLaterTransientCallbacks() {
        val focus = MediaOutputFocus()
        focus.lose(true); assertTrue(focus.gain()); assertNull(focus.pause)
        focus.lose(false); focus.lose(true)
        assertEquals(OutputPause.FOCUS_MANUAL, focus.pause)
        assertFalse(focus.gain())
        focus.granted(); assertNull(focus.pause)
    }
}
