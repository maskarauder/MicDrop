import Foundation
import MicDropCore

/// Crash capture and the "Copy crash report" composer (replaces `MicDropApplication.kt` + `CrashDiagnostics.kt`).
///
/// iOS cannot read its own crash logs (no `ApplicationExitInfo`/tombstone). The honest
/// replacement is:
/// 1. an Objective-C uncaught-exception record (`installExceptionHandler`), saved to
///    `StoredReports.saveExceptionCrash` with the exception name and call-stack symbols only —
///    never `reason` or `userInfo` (they may contain URLs, invitations or tokens);
/// 2. MetricKit crash/hang summaries persisted by `CrashReportCollector` on a later launch.
///
/// Limitation: Swift runtime traps (`fatalError`, force-unwrap, bounds) and native signals are not
/// `NSException`s and are not captured by (1); POSIX signal handlers are deliberately not installed
/// (async-signal-unsafe, conflicts with system crash reporting). Never suppress the crash: the
/// previous handler is always chained.
///
/// The record and report texts are pure functions of (`CrashText.exceptionRecord`, `CrashText.processExitReport`); this
/// type supplies the platform inputs (handler, files, clock).
enum CrashDiagnostics {
    /// Shown when no record exists (shorter form is superseded by the owner's text).
    static let noRecordText = CrashText.noRecordText
    /// UI fallback when building the crash report fails (`MainActivity.kt:479`).
    static let unavailableText = CrashText.unavailableText
    /// Output bound in characters (`CrashDiagnostics.kt:44`).
    static let limit = CrashText.reportLimit

    private static let lock = NSLock()
    private static var installed = false
    /// Set once under `lock` before `NSSetUncaughtExceptionHandler`; read only by the handler.
    private static var previousHandler: (@convention(c) (NSException) -> Void)?

    /// Launch hook: installs the exception handler and the MetricKit subscriber (both idempotent).
    /// Called once from the app entry point before any session can start.
    static func install() {
        installExceptionHandler()
        CrashReportCollector.shared.install()
    }

    /// `NSSetUncaughtExceptionHandler`, chaining the handler returned by
    /// `NSGetUncaughtExceptionHandler()` (`MicDropApplication.kt:6-18`). Idempotent. Unlike Android,
    /// which skips installation when no default handler exists, iOS normally has none (the runtime
    /// aborts after the handler returns), so the record handler is always installed.
    static func installExceptionHandler() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashDiagnostics.handleUncaught(exception)
        }
    }

    /// Saves the record (errors ignored, `runCatching` parity), then always calls the previous handler.
    private static func handleUncaught(_ exception: NSException) {
        let record = exceptionRecord(
            name: exception.name.rawValue, symbols: exception.callStackSymbols,
            capturedAt: Date(), lastStreamReport: StoredReports.stream())
        try? StoredReports.saveExceptionCrash(record)
        previousHandler?(exception)
    }

    /// Exception record text, mirroring `MicDropApplication.kt:14-16`: `Exception crash captured at: <RFC
    /// 3339>\nMicDrop <ver> · build <rev>\n` + exception type and up to 24 `  at <symbol>` lines (link/control
    /// redaction) + `\n` + last stream report.
    static func exceptionRecord(
        name: String, symbols: [String], capturedAt: Date,
        lastStreamReport: String?, header: String = BuildInfo.current.reportHeader
    ) -> String {
        CrashText.exceptionRecord(
            capturedAt: timestamp(capturedAt), buildHeader: header, name: name, symbols: symbols,
            lastStreamReport: lastStreamReport)
    }

    /// "Copy crash report" text. The file reads always run on a detached task (never on the caller's actor), as Android
    /// runs `latest` on a background thread. Never throws; unreadable files count as absent.
    static func latest() async -> String {
        await Task.detached(priority: .utility) { CrashDiagnostics.report() }.value
    }

    /// Synchronous body of `latest()`: reads the three stored files and composes the report.
    static func report() -> String {
        compose(
            exit: StoredReports.metricKitExit(), exception: StoredReports.exceptionCrash(),
            stream: StoredReports.stream(), revision: BuildInfo.current.revision)
    }

    /// Pure composition (`CrashDiagnostics.kt:10-44`): no MetricKit exit → the exception record or `noRecordText`;
    /// otherwise the exit report header, the MetricKit summary, the optional exception record and the optional last
    /// stream report, bounded to `limit`.
    static func compose(exit: String?, exception: String?, stream: String?, revision: String) -> String {
        CrashText.processExitReport(exit: exit, exception: exception, stream: stream, readerRevision: revision)
    }

    /// RFC 3339 UTC with millisecond fraction (`DiagnosticTime`, the same format as `captured_at`).
    static func timestamp(_ date: Date) -> String {
        DiagnosticTime.rfc3339(date)
    }
}
