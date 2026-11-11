import Foundation

/// Periodic report upload state (`A/PlaybackReport.kt:65-106`). Worker-confined; not thread-safe.
public final class ReportDelivery {
    public static let waitingText = "Reports: waiting to send to Windows"
    public static let notNegotiatedText = "Windows logging unavailable; Copy last stream report is available"
    public static let unavailableText = "Windows logging unavailable; use Copy last stream report"
    public static let acceptedText = "Reports: sending automatically to Windows"
    public static let busyText = "Windows log is busy; Copy last stream report is available"
    /// In a phone-control session the host acknowledges every report that was neither accepted nor busy as
    /// `not_recorded`: no log, or a log that is full, unavailable or closed (`A/PlaybackReport.kt:103`; host
    /// `server.go:410-414`). It still uses the report for its live device row. Legacy states arrive only in
    /// unnegotiated sessions. Never claims a saved log.
    public static let notRecordedText = "Live status shared with Windows; not saved to a log"
    /// A failed report POST with one of these statuses disables reporting (schema/report
    /// incompatibility must not end working audio).
    public static let rejectStatuses: Set<Int> = [400, 404, 405, 409, 413, 422]

    /// Uploads enabled iff `diagnostics_version == 1`.
    public private(set) var enabled: Bool
    /// Copy-report delivery line.
    public private(set) var text: String

    public init(version: Int) {
        let negotiated = version == 1
        enabled = negotiated
        text = negotiated ? ReportDelivery.waitingText : ReportDelivery.notNegotiatedText
    }

    public func unavailable() {
        enabled = false
        text = ReportDelivery.unavailableText
    }

    /// Called by `exchangeStatus` for a failed `/status` POST that carried a report (with or
    /// without an ICE update) while the session is not stopped. Returns true (and disables
    /// reporting) for a reject status; the caller then retries once without the report.
    /// Authentication, expiry and network statuses follow normal session error handling.
    public func reject(status: Int) -> Bool {
        guard ReportDelivery.rejectStatuses.contains(status) else { return false }
        unavailable()
        return true
    }

    /// `exchangeStatus(body, stopped, exchange)` (`A/PlaybackReport.kt:85-96`): sends
    /// `StatusBody.make(version:phoneControl:report:ice:continuousIce:)` through `exchange` (`nil` is a
    /// body-less GET). An `HTTPFailure` of a body that carried a report, while `stopped()` is false and
    /// `reject(status:)` accepts the status (disabling reporting), is retried exactly once without
    /// the report but with the same `phone_control`, `ice` and `continuous_ice` values, never re-observed or
    /// regenerated (Android removes only `android`); the retry is a GET only when nothing but `version` remains.
    /// Every first-request rejection precedes the host's ICE apply, so the resent ICE is applied once. A
    /// rejection of the retry (for example of the ICE update itself), any other status, Stop and every non-HTTP
    /// error propagate unchanged. Stop is checked before `reject`, so a stopped session keeps `enabled`.
    public func exchangeStatus<T>(
        version: Int, phoneControl: DiagnosticJSON? = nil, report: DiagnosticJSON?, ice: DiagnosticJSON?,
        continuousIce: DiagnosticJSON?, stopped: () -> Bool, exchange: (DiagnosticJSON?) throws -> T
    ) throws -> T {
        do {
            return try exchange(
                StatusBody.make(
                    version: version, phoneControl: phoneControl, report: report, ice: ice,
                    continuousIce: continuousIce))
        } catch let failure as HTTPFailure {
            guard report != nil, !stopped(), reject(status: failure.status) else { throw failure }
            return try exchange(
                StatusBody.make(
                    version: version, phoneControl: phoneControl, report: nil, ice: ice, continuousIce: continuousIce))
        }
    }

    /// `acknowledge(report_log, report_sequence ?? -1, uploading.sequence)`: a sequence
    /// mismatch → unavailable; `accepted` → sending text; `busy` → busy text (stays enabled);
    /// `not_recorded` → live-status text (stays enabled, so the Windows device row keeps updating);
    /// anything else → unavailable. `expected` is the uploaded `PlaybackReport.sequence` (Kotlin `Long`).
    public func acknowledge(status: String, sequence: Int64, expected: Int64) {
        if sequence != expected {
            unavailable()
        } else if status == "accepted" {
            text = ReportDelivery.acceptedText
        } else if status == "busy" {
            text = ReportDelivery.busyText
        } else if status == "not_recorded" {
            text = ReportDelivery.notRecordedText
        } else {
            unavailable()
        }
    }
}
