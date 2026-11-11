package com.maskarauder.micdrop

import android.media.AudioDeviceInfo
import org.junit.Assert.*
import org.junit.Test

class MediaRouteTargetTest {
    private val original = OutputDevice(7, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, true, "10:20:30:40:50:60")
    private val other = original.copy(address = "10:20:30:40:50:61")
    private val choice = OutputSelection(OutputKind.BLUETOOTH, original.id, original.type, original.address)
    private val route = SystemMediaRoute("opaque-original", original.type, true)
    private val routes = listOf(route.copy(selected = false), route.copy(id = "opaque-other"))
    private fun learned() = SelectedMediaTarget().apply {
        learn(choice, listOf(original), listOf(original), listOf(route), 0)
        learn(choice, listOf(original), listOf(original), listOf(route), 1000)
    }

    @Test fun defaultComparesPhysicalTargetsEvenIfAndroidReusesPortAndProfile() {
        assertEquals(true, DefaultMediaTarget.matches(listOf(original), listOf(original)))
        assertEquals(false, DefaultMediaTarget.matches(listOf(original), listOf(other)))
        assertEquals(false, DefaultMediaTarget.matches(listOf(original), listOf(original.copy(id = 8))))
        assertNull(DefaultMediaTarget.matches(listOf(original), null))
        assertNull(DefaultMediaTarget.matches(emptyList(), listOf(original)))
    }
    @Test fun everyActualSinkMustMatchTheDefaultPrediction() {
        val speaker = OutputDevice(2, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, true)
        assertEquals(false, DefaultMediaTarget.matches(listOf(original, speaker), listOf(original)))
        assertEquals(true, DefaultMediaTarget.matches(listOf(speaker, original), listOf(original, speaker)))
        assertEquals(false, DefaultMediaTarget.matches(listOf(original, original), listOf(original, other)))
    }
    @Test fun originalInactiveRouteCanBeRestoredWithoutAnAudioManagerPort() {
        val target = learned()
        assertEquals("opaque-original", target.request(choice, routes, 100))
        // Public route request is only a request. Actual-track verification,
        // not this identity contract, releases the receiver's audio gate.
        assertFalse(choice.verifies(listOf(other)))
        assertEquals("opaque-original", target.request(choice.copy(deviceId = 9), routes, 3100))
    }
    @Test fun wrongDefaultUnknownOrAmbiguousSystemRouteCannotTeachAnIdentity() {
        for ((actual, predicted, selected) in listOf(
            Triple(listOf(other), listOf(original), listOf(route)),
            Triple(listOf(original), listOf(other), listOf(route)),
            Triple(listOf(original), listOf(original), listOf(route, route.copy(id = "ambiguous"))),
            Triple(listOf(original), listOf(original), listOf(route.copy(type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO)))
        )) {
            val target = SelectedMediaTarget()
            target.learn(choice, actual, predicted, selected, 0)
            target.learn(choice, actual, predicted, selected, 1000)
            assertFalse(target.known)
            assertNull(target.request(choice, routes, 100))
        }
    }
    @Test fun replacementsWrongProfilesAndMissingOriginalAreNeverChosen() {
        val target = learned()
        assertNull(target.request(choice.copy(address = other.address), routes, 100))
        assertNull(target.request(choice, listOf(route.copy(id = "opaque-other", selected = false)), 100))
        assertNull(target.request(choice, listOf(route.copy(type = AudioDeviceInfo.TYPE_BLUETOOTH_SCO, selected = false)), 100))
        assertNull(target.request(choice, listOf(route), 100))
    }
    @Test fun transferBudgetIsFiniteAndResetAndStopInvalidateTheTarget() {
        val target = learned()
        assertNotNull(target.request(choice, routes, 0))
        assertNull(target.request(choice, routes, 100))
        assertNotNull(target.request(choice, routes, 3000))
        assertNull(target.request(choice, routes, 10000))
        target.newEpisode()
        assertNotNull(target.request(choice, routes, 10000))
        target.reset()
        assertNull(target.request(choice, routes, 14000))
        target.learn(choice, listOf(original), listOf(original), listOf(route), 14000)
        target.learn(choice, listOf(original), listOf(original), listOf(route), 15000)
        target.stop()
        target.learn(choice, listOf(original), listOf(original), listOf(route), 16000)
        target.newEpisode()
        assertNull(target.request(choice, routes, 18000))
    }
    @Test fun transientOrUnknownIdentityCannotTeachAnOpaqueRoute() {
        val target = SelectedMediaTarget()
        target.learn(choice, listOf(original), listOf(original), listOf(route), 0)
        assertFalse(target.known)
        target.learn(choice, listOf(original), listOf(original), listOf(route.copy(id = "transition")), 1000)
        assertFalse(target.known)
        target.learn(choice, listOf(original), null, listOf(route), 2000)
        target.learn(choice.copy(address = ""), listOf(original.copy(address = "")),
            listOf(original.copy(address = "")), listOf(route), 3000)
        assertFalse(target.known)
    }
}
