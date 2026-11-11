import Foundation
import MicDropCore

/// The app's `MonotonicClock`: milliseconds of Darwin `CLOCK_MONOTONIC`, which keeps counting while the phone sleeps,
/// like Android `SystemClock.elapsedRealtime()`.
///
/// Every `uptime_ms`, evidence time, failure time, controls-log time and the local-output-baseline
/// "phone uptime" must use this one source so the host's ordering checks hold (events ≤ uptime,
/// failure ≤ uptime). Never substitute `ProcessInfo.systemUptime`, `mach_absolute_time` or
/// `CLOCK_UPTIME_RAW`: they stop during sleep. Tests inject a fake `MonotonicClock` instead.
struct SystemMonotonicClock: MonotonicClock {
    /// `clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000`.
    func nowMs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
    }
}
