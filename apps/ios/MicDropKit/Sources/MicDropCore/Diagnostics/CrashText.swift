import Foundation

/// Bounded, redacted crash text (`K:CrashText.kt`). Exception reasons/messages are never included; only type names,
/// symbolicated frames and fixed text.
public enum CrashText {
    /// Stored/copied crash report bound (`K:CrashDiagnostics.kt:47`, `StoredReports.LIMIT`).
    public static let reportLimit = 96 * 1024
    /// Frames kept per exception (`K:CrashText.kt:19`).
    public static let maxFrames = 24
    /// `CrashDiagnostics.latest()` text when nothing was retained (step 3).
    public static let noRecordText =
        "iOS has no retained MicDrop crash record. MetricKit delivers crash reports on a later launch and only when Share With App Developers is enabled in iOS Settings."
    /// `CrashDiagnostics.latest()` text on any thrown error.
    public static let unavailableText = "Crash information unavailable."

    private static let linkPattern = try! NSRegularExpression(
        pattern: "(?:https?|micdrop)://[^\\s]+",
        options: [.caseInsensitive])
    private static let controlPattern = try! NSRegularExpression(pattern: "[\\x00-\\x08\\x0B-\\x1F\\x7F]")
    private static let longIdentifierPattern = try! NSRegularExpression(pattern: "\\b[A-Za-z0-9_-]{43,}\\b")

    /// First `limit` characters; links (`http(s)://`, `micdrop://`) → `[link excluded]`; ASCII control
    /// characters except `\n` and `\t` → space (`K:CrashText.kt:4-6`).
    public static func symbol(_ value: String, limit: Int = 512) -> String {
        let bounded = String(value.prefix(max(0, limit)))
        let unlinked = replace(linkPattern, in: bounded, with: "[link excluded]")
        return replace(controlPattern, in: unlinked, with: " ")
    }

    /// `symbol(value, limit)` plus `[long identifier excluded]` for runs of 43+ token characters
    /// (tokens, keys; `K:CrashText.kt:8-9`).
    public static func safe(_ value: String, limit: Int = 1024) -> String {
        replace(longIdentifierPattern, in: symbol(value, limit: limit), with: "[long identifier excluded]")
    }

    /// `Exception type: <name>` then up to 24 `  at <frame>` lines, every line newline-terminated
    /// (iOS analog of `K:CrashText.kt:13-23` for one `NSException`).
    public static func exceptionStack(name: String, symbols: [String]) -> String {
        var text = "Exception type: \(symbol(name))\n"
        for frame in symbols.prefix(maxFrames) {
            text += "  at \(symbol(frame))\n"
        }
        return text
    }

    /// Record saved by the app's uncaught `NSException` handler to `last-exception-crash.txt` (step 1; Android
    /// `K:MicDropApplication.kt:14-16`). `buildHeader` is `BuildInfo.current.reportHeader`; `lastStreamReport` is
    /// `StoredReports.stream()`.
    public static func exceptionRecord(
        capturedAt: String, buildHeader: String, name: String, symbols: [String],
        lastStreamReport: String?
    ) -> String {
        "Exception crash captured at: \(capturedAt)\n\(buildHeader)\n" + exceptionStack(name: name, symbols: symbols)
            + "\n" + (lastStreamReport ?? "")
    }

    /// `CrashDiagnostics.latest()` composition (step 3), pure so it is testable on Linux. `exit` is the stored
    /// MetricKit summary, `exception` the stored exception record, `stream` the stored stream report, `readerRevision`
    /// `BuildInfo.current.revision`. Bounded to 96 Ki characters.
    public static func processExitReport(
        exit: String?, exception: String?, stream: String?,
        readerRevision: String
    ) -> String {
        guard let exit else { return exception ?? noRecordText }
        var text = "MicDrop iOS process exit report\n"
        text += "Reader build: \(readerRevision); MetricKit reports the crashed app build separately.\n"
        text += exit
        if let exception {
            text += "\n\nSaved exception record; compare its timestamp with the exit above:\n" + exception
        }
        if let stream {
            text += "\n\nLast saved stream report; it may belong to a different session or process:\n" + stream
        }
        return String(text.prefix(reportLimit))
    }

    private static func replace(_ expression: NSRegularExpression, in value: String, with template: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}
