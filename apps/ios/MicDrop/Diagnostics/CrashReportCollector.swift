import Foundation
import MetricKit
import MicDropCore

/// MetricKit subscriber that persists a sanitized summary of the newest crash (else hang) diagnostic to
/// `StoredReports.saveMetricKitExit` (replaces Android `ApplicationExitInfo` + `NativeCrashTrace`).
///
/// MetricKit delivers each diagnostic payload once, on a later launch, and only when the user enabled Share With App
/// Developers; delivery to free-provisioned sideloads is unverified, which the "no record" text says. Nothing here is
/// uploaded.
///
/// This type only copies primitive fields of the MetricKit objects into `MetricKitCrashSummary.Exit`, which owns the
/// summary text, the exception/signal names and the bounded call-stack parser (attributed thread only, never another
/// thread — `NativeCrashTraceTest` rule).
///
/// Privacy: only exception/signal numbers, the termination reason (redacted by the summary), the
/// Objective-C exception *name* and *class* (never `composedMessage`, `formatString` or
/// `arguments`), and the attributed thread's frames as offsets into the binary text segment with
/// binary name and UUID (no absolute addresses, no `virtualMemoryRegionInfo`).
///
/// Threading: `install()` runs on main at launch; MetricKit calls `didReceive` on its own
/// background queue. All selection state is confined to one private serial queue, so the launch
/// scan of `pastDiagnosticPayloads` and a concurrent delivery cannot overwrite a newer summary with
/// an older one.
final class CrashReportCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReportCollector()

    /// `callStackTree.jsonRepresentation()` larger than this is not kept (≤ 2 MiB); the summary then says `Crashing
    /// thread stack: unavailable`.
    static let maxCallStackBytes = MetricKitCrashSummary.maxInputBytes

    /// Newest diagnostic of one kind seen in this process, with its payload end time.
    private struct Candidate {
        let end: Date
        let exit: MetricKitCrashSummary.Exit
    }

    private let lock = NSLock()
    private var installed = false
    private let queue = DispatchQueue(label: "com.maskarauder.micdrop.metrickit", qos: .utility)
    // Confined to `queue`.
    private var newestCrash: Candidate?
    private var newestHang: Candidate?
    private var persisted: String?

    private override init() {
        super.init()
    }

    /// Registers with `MXMetricManager.shared` and summarizes `pastDiagnosticPayloads` off the main
    /// thread. Idempotent.
    func install() {
        lock.lock()
        guard !installed else {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()
        MXMetricManager.shared.add(self)
        queue.async { [self] in
            absorb(MXMetricManager.shared.pastDiagnosticPayloads)
        }
    }

    // MARK: MXMetricManagerSubscriber

    /// Called by MetricKit on a background queue with newly delivered diagnostics. Persists before
    /// returning (the process may be suspended right after delivery).
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.sync { absorb(payloads) }
    }

    // MARK: Selection and persistence

    /// Folds `payloads` into the newest crash / newest hang of this process (newest by `payload.timeStampEnd`, the last
    /// entry of that payload), then saves the summary of the newest crash, else the newest hang. A delivery without
    /// crash or hang never erases an earlier record; an unchanged summary is not rewritten. Persistence errors are
    /// ignored (diagnostics never crash the app); a failed write is retried on the next delivery.
    private func absorb(_ payloads: [MXDiagnosticPayload]) {
        dispatchPrecondition(condition: .onQueue(queue))
        for payload in payloads {
            let end = payload.timeStampEnd
            if let crash = payload.crashDiagnostics?.last, end >= (newestCrash?.end ?? .distantPast) {
                newestCrash = Candidate(end: end, exit: Self.crashExit(crash, recordedAt: end))
            }
            if let hang = payload.hangDiagnostics?.last, end >= (newestHang?.end ?? .distantPast) {
                newestHang = Candidate(end: end, exit: Self.hangExit(hang, recordedAt: end))
            }
        }
        guard let exit = (newestCrash ?? newestHang)?.exit else { return }
        let summary = MetricKitCrashSummary.text(exit)
        guard summary != persisted else { return }
        do {
            try StoredReports.saveMetricKitExit(summary)
            persisted = summary
        } catch {
            persisted = nil
        }
    }

    /// Summary text of one batch (newest crash, else newest hang; nil when neither exists). Pure
    /// apart from reading the MetricKit objects; `absorb` applies the same rule across deliveries.
    static func newestSummary(in payloads: [MXDiagnosticPayload]) -> String? {
        let newestFirst = payloads.sorted { $0.timeStampEnd > $1.timeStampEnd }
        if let payload = newestFirst.first(where: { $0.crashDiagnostics?.last != nil }),
            let crash = payload.crashDiagnostics?.last
        {
            return MetricKitCrashSummary.text(crashExit(crash, recordedAt: payload.timeStampEnd))
        }
        if let payload = newestFirst.first(where: { $0.hangDiagnostics?.last != nil }),
            let hang = payload.hangDiagnostics?.last
        {
            return MetricKitCrashSummary.text(hangExit(hang, recordedAt: payload.timeStampEnd))
        }
        return nil
    }

    // MARK: MetricKit → primitive copy

    /// Primitive copy of a crash diagnostic (crash summary). `exceptionReason` is the iOS 17 API; only its
    /// `exceptionName` and `className` are read.
    static func crashExit(_ crash: MXCrashDiagnostic, recordedAt: Date) -> MetricKitCrashSummary.Exit {
        let callStack = crash.callStackTree.jsonRepresentation()
        return MetricKitCrashSummary.Exit(
            kind: .crash,
            recordedAt: DiagnosticTime.rfc3339(recordedAt),
            exceptionType: crash.exceptionType?.intValue,
            exceptionCode: crash.exceptionCode?.intValue,
            signal: crash.signal?.intValue,
            applicationBuildVersion: crash.metaData.applicationBuildVersion,
            osVersion: crash.metaData.osVersion,
            terminationReason: crash.terminationReason,
            objectiveCExceptionName: crash.exceptionReason?.exceptionName,
            objectiveCExceptionClassName: crash.exceptionReason?.className,
            callStackTreeJSON: callStack.count <= maxCallStackBytes ? callStack : nil)
    }

    /// Primitive copy of a hang diagnostic: recorded time, build line and duration (no stack; the
    /// summary says `Hang trace is not copied by this action.`).
    static func hangExit(_ hang: MXHangDiagnostic, recordedAt: Date) -> MetricKitCrashSummary.Exit {
        MetricKitCrashSummary.Exit(
            kind: .hang,
            recordedAt: DiagnosticTime.rfc3339(recordedAt),
            applicationBuildVersion: hang.metaData.applicationBuildVersion,
            osVersion: hang.metaData.osVersion,
            hangDurationMs: milliseconds(hang.hangDuration))
    }

    /// Whole milliseconds of `duration`, or nil when not finite, negative or out of `Int64` range.
    static func milliseconds(_ duration: Measurement<UnitDuration>) -> Int64? {
        let value = duration.converted(to: .milliseconds).value
        guard value.isFinite, value >= 0, value < 9.0e18 else { return nil }
        return Int64(value.rounded())
    }
}
