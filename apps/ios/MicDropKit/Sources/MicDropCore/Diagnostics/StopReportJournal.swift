import Foundation

/// Crash-surviving teardown journal (`K:StopReportJournal.kt`).
///
/// Written by the session worker that owns `AudioSessionOwner` (`journalActive`) before each teardown boundary, so a
/// native crash during WebRTC disposal still leaves a readable report on the next launch. `save` is
/// `StoredReports.saveStream`. Persistence is best effort: a failing `save` never blocks local gates, Stop or media
/// destruction.
public final class StopReportJournal: @unchecked Sendable {
    /// Snapshot bound (`K:StopReportJournal.kt:11`), in Characters.
    public static let snapshotLimit = 48 * 1024
    public static let initialSnapshot = "No periodic stream snapshot was collected."
    public static let initialPoint = "session_start"
    public static let completedPoint = "worker_complete"

    private let headerText: String
    private let save: (String) throws -> Void
    private let lock = NSLock()
    private var snapshotText = StopReportJournal.initialSnapshot
    private var pointText = StopReportJournal.initialPoint
    private var complete = false

    public init(header: String, save: @escaping (String) throws -> Void) {
        self.headerText = header
        self.save = save
    }

    /// `MicDrop <version> · build <revision>\nSession mode: <direction>\nSession started at: <ISO instant>`
    /// (`K:StreamReceiver.kt:143-144`). `buildHeader` is `BuildInfo.current.reportHeader`.
    public static func header(buildHeader: String, mode: StreamMode, startedAt: Date) -> String {
        "\(buildHeader)\nSession mode: \(mode.direction)\nSession started at: \(DiagnosticTime.rfc3339(startedAt))"
    }

    /// Replaces the snapshot when `value` is not blank (truncated to 48 Ki characters), then persists.
    public func snapshot(_ value: String) {
        lock.lock()
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshotText = String(value.prefix(Self.snapshotLimit))
        }
        let text = textLocked()
        lock.unlock()
        persist(text)
    }

    /// Records the last reached step (`setup_<stage>`, `runtime_close`, …) and persists.
    public func checkpoint(_ value: String) {
        lock.lock()
        pointText = value
        let text = textLocked()
        lock.unlock()
        persist(text)
    }

    /// Marks cleanup complete and checkpoints `worker_complete`.
    public func completed() {
        lock.lock()
        complete = true
        lock.unlock()
        checkpoint(Self.completedPoint)
    }

    /// `<header>\nLast recorded session step: <point>\nWorker cleanup: <completed|not confirmed complete>\n\n<snapshot>`.
    public func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return textLocked()
    }

    /// Last checkpoint name.
    public var point: String {
        lock.lock()
        defer { lock.unlock() }
        return pointText
    }

    /// Whether `completed()` ran.
    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }

    private func textLocked() -> String {
        "\(headerText)\nLast recorded session step: \(pointText)\nWorker cleanup: \(complete ? "completed" : "not confirmed complete")\n\n\(snapshotText)"
    }

    private func persist(_ text: String) {
        do {
            try save(text)
        } catch {
            // Best effort (`K:StopReportJournal.kt:25`): teardown continues.
        }
    }
}
