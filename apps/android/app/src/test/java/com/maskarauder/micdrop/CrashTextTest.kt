package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test

class CrashTextTest {
    @Test fun javaStackKeepsTypesAndLocationsWithoutExceptionMessages() {
        val error = IllegalStateException("micdrop://private-invitation", IllegalArgumentException("private-token"))
        error.stackTrace = arrayOf(StackTraceElement("SyntheticSession", "stop", "SyntheticSession.kt", 12))
        val report = CrashText.javaStack(error)
        assertTrue(report.contains("java.lang.IllegalStateException"))
        assertTrue(report.contains("java.lang.IllegalArgumentException"))
        assertTrue(report.contains("SyntheticSession.kt:12"))
        assertFalse(report.contains("private-invitation")); assertFalse(report.contains("private-token"))
    }

    @Test fun outputIsBoundedAndLinksLongIdentifiersAndControlCharactersAreExcluded() {
        val value = "micdrop://pair/synthetic " + "a".repeat(64) + "\u0001" + "remaining".repeat(1000)
        val safe = CrashText.safe(value, 256)
        assertFalse(safe.contains("micdrop://")); assertFalse(safe.contains("a".repeat(64)))
        assertFalse(safe.contains('\u0001')); assertTrue(safe.length < 300)
    }
}
