// "Recent controls" log. Port of `PlaybackService.record`/`shownView` (`PlaybackService.kt:451-457`). Local diagnostics
// only: appended to the displayed diagnostics, never to the stop-report journal or the wire.

import Foundation

/// Process-wide bounded log of lifecycle control events, one line per event: `"<uptime ms> ms: <event>"`.
///
/// MicDropCore has no system clock: the app creates one instance with `SystemMonotonicClock()` and shares it between
/// controllers for the life of the process (Android keeps the deque in the `PlaybackService` companion object).
/// Thread-safe; normally used from the main actor.
public final class ControlEventLog: @unchecked Sendable {
    /// Maximum retained entries; the oldest is dropped first (`PlaybackService.kt:453`).
    public static let defaultCapacity = 32
    /// Header line of the diagnostics block (`PlaybackService.kt:457`).
    public static let header = "Recent controls (phone uptime):"

    private let clock: any MonotonicClock
    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []

    public init(clock: any MonotonicClock, capacity: Int = ControlEventLog.defaultCapacity) {
        self.clock = clock
        self.capacity = max(1, capacity)
    }

    /// Appends `"<clock.nowMs()> ms: <event>"`.
    public func record(_ event: String) {
        record(event, uptimeMs: clock.nowMs())
    }

    /// Appends `"<uptimeMs> ms: <event>"` (explicit time for tests).
    public func record(_ event: String, uptimeMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        lines.append("\(uptimeMs) ms: \(event)")
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    /// Current lines, oldest first.
    public var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// `header + "\n" + entries.joined("\n")`, or nil when no event was recorded.
    public var text: String? {
        let current = entries
        if current.isEmpty { return nil }
        return ControlEventLog.header + "\n" + current.joined(separator: "\n")
    }

    /// `shownView().diagnostics` (`PlaybackService.kt:455-457`): the non-nil values of
    /// `[base, text]` joined by `"\n"`, or nil when both are absent.
    public func diagnostics(appendingTo base: String?) -> String? {
        let parts = [base, text].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Clears the log (tests; Android loses it only at process death).
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}

extension ControlEventLog {
    /// Event vocabulary (exact strings). Android names are kept for the iOS equivalents (`focus_loss_transient` for an
    /// interruption began, `focus_gain` for ended + shouldResume, …); the iOS-only events use the same format.
    public enum Event {
        public static let appConnect = "app_connect"
        public static let foregroundStartDenied = "foreground_start_denied"
        public static let focusRequestDenied = "focus_request_denied"
        public static let streamPlaying = "stream_playing"
        public static let mediaPlay = "media_play"
        public static let focusGain = "focus_gain"
        public static let focusLossTransient = "focus_loss_transient"
        public static let focusLossTransientCanDuck = "focus_loss_transient_can_duck"
        public static let focusLossPermanent = "focus_loss_permanent"
        public static let automaticResumeArmed = "automatic_resume_armed"
        public static let manualPause = "manual_pause"
        public static let manualResume = "manual_resume"
        public static let focusResume = "focus_resume"
        public static let focusResumeTimeout = "focus_resume_timeout"
        public static let streamFailed = "stream_failed"
        public static let streamClosed = "stream_closed"
        public static let mediaOutputChecking = "media_output_checking"
        public static let defaultOutputWaiting = "default_output_waiting"
        public static let outputDisconnected = "output_disconnected"

        // iOS additions.
        public static let interruptionBegan = "interruption_began"
        public static let interruptionBeganSuspendedIgnored = "interruption_began_suspended_ignored"
        public static let interruptionEndedResume = "interruption_ended_resume"
        public static let interruptionEndedNoResume = "interruption_ended_no_resume"
        public static let routeOldDeviceUnavailable = "route_old_device_unavailable"
        public static let mediaServicesReset = "media_services_reset"
        public static let backgroundSetupExpired = "background_setup_expired"
        public static let appTerminating = "app_terminating"

        /// `output_selected_<kind lowercase>` (`PlaybackService.kt:84`), e.g. `output_selected_hearing_aid`.
        public static func outputSelected(_ kind: OutputKind) -> String {
            "output_selected_" + AudioPreferences.storageName(of: kind).lowercased()
        }

        /// `stop_<reason.wire>` (`PlaybackService.kt:366`): the precise label, not the negotiated fallback.
        public static func stop(_ reason: StopReason) -> String {
            "stop_" + reason.wire
        }

        /// `audio_session_activation_failed_<code>` with the four-character `AVAudioSession.ErrorCode`
        /// (e.g. `!pri`), formatted by the app.
        public static func audioSessionActivationFailed(_ code: String) -> String {
            "audio_session_activation_failed_" + code
        }
    }
}
