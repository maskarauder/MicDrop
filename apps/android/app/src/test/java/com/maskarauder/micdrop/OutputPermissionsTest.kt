package com.maskarauder.micdrop

import android.Manifest
import org.junit.Assert.*
import org.junit.Test

class OutputPermissionsTest {
    @Test fun eachExplicitBluetoothProfileRequestsOnlyNearbyDevices() {
        for (kind in listOf(OutputKind.BLUETOOTH, OutputKind.LE, OutputKind.HEARING_AID)) {
            assertEquals(listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), OutputPermissions.required(kind))
            assertEquals(OutputPermissions.required(kind), OutputPermissions.missing(kind) { false })
            assertNotNull(OutputPermissions.denial(kind) { false })
        }
    }

    @Test fun listeningCanIdentifyBluetoothWithoutMicrophoneConsent() {
        val grants = setOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN)
        for (kind in listOf(OutputKind.BLUETOOTH, OutputKind.LE, OutputKind.HEARING_AID)) {
            assertTrue(OutputPermissions.missing(kind, grants::contains).isEmpty())
            assertNull(OutputPermissions.denial(kind, grants::contains))
            assertFalse(OutputPermissions.required(kind).contains(Manifest.permission.RECORD_AUDIO))
            assertFalse(OutputPermissions.required(kind).contains(Manifest.permission.ACCESS_FINE_LOCATION))
            assertEquals(listOf(Manifest.permission.BLUETOOTH_SCAN), OutputPermissions.missing(kind) {
                it == Manifest.permission.BLUETOOTH_CONNECT
            })
            // A later permission revocation is checked even after earlier consent.
            assertNotNull(OutputPermissions.denial(kind) { false })
        }
    }

    @Test fun defaultPhoneAndOtherNonBluetoothOutputsNeedNoNearbyPermission() {
        for (kind in listOf(OutputKind.DEFAULT, OutputKind.PHONE, OutputKind.WIRED, OutputKind.USB, OutputKind.OTHER)) {
            assertTrue(OutputPermissions.required(kind).isEmpty())
            assertNull(OutputPermissions.denial(kind) { false })
        }
    }

    @Test fun consentCannotAuthorizeAnotherSessionOrMicrophoneMode() {
        val listening = OutputPermissionScope(StreamMode.PLAYBACK, "original-generation")
        assertTrue(listening.matches(listening.copy()))
        assertFalse(listening.matches(OutputPermissionScope(StreamMode.PLAYBACK, "new-generation")))
        assertFalse(listening.matches(OutputPermissionScope(StreamMode.DUPLEX, "original-generation")))
        assertFalse(listening.matches(OutputPermissionScope(null, null)))
        val idle = OutputPermissionScope(null, null)
        assertTrue(idle.matches(OutputPermissionScope(null, null)))
        assertFalse(idle.matches(listening))
    }
}
