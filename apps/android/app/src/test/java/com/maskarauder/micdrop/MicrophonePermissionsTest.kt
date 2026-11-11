package com.maskarauder.micdrop

import android.Manifest
import org.junit.Assert.*
import org.junit.Test

class MicrophonePermissionsTest {
    private val microphone = Manifest.permission.RECORD_AUDIO
    private val nearby = Manifest.permission.BLUETOOTH_CONNECT

    @Test fun phoneAndDirectInputsNeverRequestNearbyDevices() {
        for (kind in listOf(MicrophoneKind.BUILT_IN, MicrophoneKind.WIRED, MicrophoneKind.USB)) {
            assertEquals(listOf(microphone), MicrophonePermissions.missing(kind) { false })
            assertTrue(MicrophonePermissions.missing(kind) { it == microphone }.isEmpty())
            assertNull(MicrophonePermissions.denial(kind) { it == microphone })
        }
    }

    @Test fun priorMicrophoneConsentStillRequiresTheHeadsetIdentityPermission() {
        for (kind in listOf(MicrophoneKind.SCO, MicrophoneKind.LE)) {
            assertEquals(listOf(nearby), MicrophonePermissions.missing(kind) { it == microphone })
            assertEquals(MicrophoneRouteProblem.BLUETOOTH_PERMISSION.detail,
                MicrophonePermissions.denial(kind) { it == microphone })
            assertEquals(listOf(microphone), MicrophonePermissions.missing(kind) { it == nearby })
        }
    }

    @Test fun bothCaptureRequirementsMustBeGrantedAndNotificationsAreOptional() {
        for (kind in listOf(MicrophoneKind.SCO, MicrophoneKind.LE)) {
            val required = setOf(microphone, nearby)
            assertEquals(required, MicrophonePermissions.missing(kind) { false }.toSet())
            assertTrue(MicrophonePermissions.missing(kind) { it in required }.isEmpty())
            assertNull(MicrophonePermissions.denial(kind) { it in required })
            assertNotNull(MicrophonePermissions.denial(kind) { it == Manifest.permission.POST_NOTIFICATIONS })
        }
    }
}
