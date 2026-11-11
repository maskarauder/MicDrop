import Foundation

/// Phone uptime in milliseconds that keeps counting during sleep.
///
/// Android uses `SystemClock.elapsedRealtime()` for every `uptime_ms`, evidence time, failure time,
/// controls-log time and the local-output-baseline "phone uptime". The app provides
/// `SystemMonotonicClock` (`clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000`); tests inject a fake.
/// Use one instance everywhere so the host's ordering checks hold (events <= uptime, failure <= uptime).
public protocol MonotonicClock: Sendable {
    func nowMs() -> Int64
}

/// Wall-clock timestamps for `captured_at` and the journal header.
///
/// RFC 3339 UTC with millisecond fraction, e.g. `2026-10-13T12:34:56.789Z`. Go's `time.Time` decoding
/// accepts any fractional precision; Android's `Instant.toString()` prints up to 9 digits. Formatting is
/// done with integer civil-date arithmetic so it is identical on Linux and iOS and needs no formatter.
public enum DiagnosticTime {
    /// `captured_at` value for `Date()` now.
    public static func nowRFC3339() -> String {
        rfc3339(Date())
    }

    /// RFC 3339 UTC text (`yyyy-MM-ddTHH:mm:ss.SSSZ`) for `date`, truncated to whole milliseconds.
    public static func rfc3339(_ date: Date) -> String {
        let millisecondsPerDay: Int64 = 86_400_000
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let days =
            totalMs >= 0 ? totalMs / millisecondsPerDay : (totalMs - (millisecondsPerDay - 1)) / millisecondsPerDay
        let msOfDay = totalMs - days * millisecondsPerDay

        // Howard Hinnant's civil_from_days (proleptic Gregorian calendar).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)

        let hour = msOfDay / 3_600_000
        let minute = (msOfDay / 60_000) % 60
        let second = (msOfDay / 1_000) % 60
        let millisecond = msOfDay % 1_000

        var text = pad(year, 4)
        text += "-" + pad(month, 2)
        text += "-" + pad(day, 2)
        text += "T" + pad(hour, 2)
        text += ":" + pad(minute, 2)
        text += ":" + pad(second, 2)
        text += "." + pad(millisecond, 3)
        text += "Z"
        return text
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
