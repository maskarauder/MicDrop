import Foundation

/// Private, bounded diagnostics files (port of `StoredReports.kt`).
///
/// Location: `Application Support/MicDrop/Diagnostics/`, excluded from backup, file protection
/// `completeUntilFirstUserAuthentication` so the journal can be written while the phone is locked
/// during background audio (never `.completeFileProtection`). Nothing here is uploaded or used as a
/// resume ticket.
///
/// Files:
/// - `last-stream-report.txt` — the stop report journal / last periodic copy report
///   (`StopReportJournal` saves through `saveStream`, wired as `SessionDependencies.journalSave`);
/// - `last-exception-crash.txt` — the Objective-C exception record (Android `last-java-crash.txt`);
/// - `last-metrickit-exit.txt` — the sanitized MetricKit crash/hang summary.
///
/// All accessors share one recursive lock: the uncaught-exception handler may run while the same
/// thread already holds the lock (Kotlin `@Synchronized` is re-entrant too).
enum StoredReports {
    /// Byte limit for every file, read or written (`StoredReports.kt:11`).
    static let limit = 96 * 1024

    static let streamFileName = "last-stream-report.txt"
    static let exceptionCrashFileName = "last-exception-crash.txt"
    static let metricKitExitFileName = "last-metrickit-exit.txt"

    /// Chunk size of the bounded read (`StoredReports.kt:35`).
    private static let readChunkBytes = 4096

    private static let lock = NSRecursiveLock()

    /// Test hook: when set, files live directly in this directory instead of
    /// `Application Support/MicDrop/Diagnostics/`. Guarded by `lock`.
    private static var rootOverride: URL?

    // MARK: Stream report (journal)

    /// Writes the stream report (truncated to `limit` bytes at a UTF-8 scalar boundary).
    /// Callers persisting from teardown (`StopReportJournal.persist`) swallow the error.
    static func saveStream(_ text: String) throws {
        try write(streamFileName, text)
    }

    /// The last stream report, or nil if missing, oversized, blank or unreadable.
    static func stream() -> String? {
        read(streamFileName)
    }

    // MARK: Objective-C exception record

    static func saveExceptionCrash(_ text: String) throws {
        try write(exceptionCrashFileName, text)
    }

    static func exceptionCrash() -> String? {
        read(exceptionCrashFileName)
    }

    // MARK: MetricKit exit summary

    static func saveMetricKitExit(_ text: String) throws {
        try write(metricKitExitFileName, text)
    }

    static func metricKitExit() -> String? {
        read(metricKitExitFileName)
    }

    // MARK: Test support

    /// Redirects all files to `directory` (nil restores the real location). Tests only.
    static func setDirectoryOverride(_ directory: URL?) {
        lock.lock()
        defer { lock.unlock() }
        rootOverride = directory
    }

    // MARK: Implementation

    /// `Application Support/MicDrop/Diagnostics/`, created on demand with backup exclusion and
    /// `completeUntilFirstUserAuthentication` protection (re-roots Android's `noBackupFilesDir`).
    static func directory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let rootOverride {
            try FileManager.default.createDirectory(at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        var directory =
            support
            .appendingPathComponent("MicDrop", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    /// UTF-8 bytes of `text`, cut to at most `limit` bytes without splitting a scalar (improvement over Android's raw
    /// byte cut, `StoredReports.kt:25`).
    static func boundedUTF8(_ text: String, limit: Int = StoredReports.limit) -> Data {
        precondition(limit >= 0, "StoredReports.boundedUTF8: negative limit")
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return Data(bytes) }
        var end = limit
        // bytes[end] is the first excluded byte; if it continues a scalar, drop that scalar's lead.
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return Data(bytes[0..<end])
    }

    private static func write(_ name: String, _ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try directory().appendingPathComponent(name, isDirectory: false)
        try boundedUTF8(text).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Bounded read (refuses files over `limit`), lossy UTF-8 decode, nil if blank or on any error
    /// (`StoredReports.kt:29-31`).
    private static func read(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? directory().appendingPathComponent(name, isDirectory: false),
            let data = boundedContents(of: url, limit: limit)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Port of `StoredReports.readBounded` (`StoredReports.kt:33-43`): reads in 4096-byte chunks and
    /// fails (nil) as soon as the total would exceed `limit`; a missing or unreadable file is nil.
    private static func boundedContents(of url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: readChunkBytes), !chunk.isEmpty {
                guard data.count + chunk.count <= limit else { return nil }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        return data
    }
}
