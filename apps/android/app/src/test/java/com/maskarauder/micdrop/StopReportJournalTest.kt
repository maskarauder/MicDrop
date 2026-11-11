package com.maskarauder.micdrop

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class StopReportJournalTest {
    @Test fun nativeFailureLeavesTheLastPreCleanupCheckpointReadableAfterRecreation() {
        val directory = Files.createTempDirectory("synthetic-stop-report").toFile()
        val file = File(directory, "report")
        try {
            val journal = StopReportJournal("synthetic microphone session") { file.writeText(it) }
            journal.snapshot("terminal diagnostics collected")
            journal.checkpoint("windows_stop")
            journal.checkpoint("peer_dispose")
            try { throw AssertionError("synthetic native boundary") } catch (_: AssertionError) { }
            val recovered = file.readText() // A new reader, with no in-memory report.
            assertTrue(recovered.contains("terminal diagnostics collected"))
            assertTrue(recovered.contains("Last recorded session step: peer_dispose"))
            assertTrue(recovered.contains("Worker cleanup: not confirmed complete"))
            assertFalse(recovered.contains("worker_complete"))
        } finally { directory.deleteRecursively() }
    }

    @Test fun completionIsExplicitAndPersistenceFailureCannotBlockCleanup() {
        val records = mutableListOf<String>()
        val journal = StopReportJournal("synthetic") {
            records.add(it)
            throw java.io.IOException("synthetic full disk")
        }
        journal.snapshot("status"); journal.checkpoint("factory_dispose"); journal.completed()
        assertTrue(journal.text().contains("Worker cleanup: completed"))
        assertTrue(records[1].contains("not confirmed complete"))
        assertTrue(records.last().contains("worker_complete"))
    }
}
