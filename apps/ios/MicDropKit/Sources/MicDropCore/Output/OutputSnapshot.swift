import Foundation

/// Playback output diagnostics shape (`output` / `local_output_baseline`; `OutputSnapshot.kt:5-31`; Go `Output.valid`,
/// `report.go:103-111`).
///
/// iOS never uploads it while the host only accepts Android backends (the report carries `"output": null` and
/// `"local_output_baseline": null`). It remains the value type of the local output baseline
/// (`SessionConfiguration.baseline`) and of the local probe callbacks, used for copy-report text and for the
/// `RecoveryMonitor` epoch.
public struct OutputSnapshot: Equatable, Sendable {
    /// Android backend labels accepted by `report.go:156`.
    public static let webRTCBackend = "webrtc_audiotrack"
    public static let localBackend = "local_audiotrack"
    /// Wire keys in emission order (`OutputSnapshot.kt:12-18`).
    public static let keys = [
        "backend", "captured_uptime_ms", "route", "track_generation", "route_changes",
        "sample_rate_hz", "channels", "buffer_frames", "capacity_frames", "underruns",
        "performance_mode", "timestamp_age_ms", "estimated_queue_ms",
    ]

    public var backend: String
    /// Monotonic ms at capture (`MonotonicClock.nowMs()`), <= the report's `uptime_ms`.
    public var capturedUptimeMs: Int64
    /// Go route label (`OutputKind.routeLabel(portType:)`), nil if unknown.
    public var route: String?
    public var trackGeneration: Int
    public var routeChanges: Int
    public var sampleRateHz: Int
    public var channels: Int
    public var bufferFrames: Int
    public var capacityFrames: Int
    public var underruns: Int
    /// `none|low latency|power saving`.
    public var performanceMode: String
    public var timestampAgeMs: Double?
    public var estimatedQueueMs: Double?

    public init(
        backend: String, capturedUptimeMs: Int64, route: String?, trackGeneration: Int, routeChanges: Int,
        sampleRateHz: Int, channels: Int, bufferFrames: Int, capacityFrames: Int, underruns: Int,
        performanceMode: String, timestampAgeMs: Double?, estimatedQueueMs: Double?
    ) {
        self.backend = backend
        self.capturedUptimeMs = capturedUptimeMs
        self.route = route
        self.trackGeneration = trackGeneration
        self.routeChanges = routeChanges
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bufferFrames = bufferFrames
        self.capacityFrames = capacityFrames
        self.underruns = underruns
        self.performanceMode = performanceMode
        self.timestampAgeMs = timestampAgeMs
        self.estimatedQueueMs = estimatedQueueMs
    }

    /// `RecoveryMonitor` epoch `(trackGeneration, routeChanges)` (`OutputSnapshot.kt:68`).
    public var epoch: (Int, Int) { (trackGeneration, routeChanges) }

    /// Ordered wire object; nil and non-finite doubles become `null`.
    public func json() -> DiagnosticJSON {
        .object([
            (key: "backend", value: .string(backend)),
            (key: "captured_uptime_ms", value: .int(capturedUptimeMs)),
            (key: "route", value: route.map { DiagnosticJSON.string($0) } ?? .null),
            (key: "track_generation", value: .int(Int64(trackGeneration))),
            (key: "route_changes", value: .int(Int64(routeChanges))),
            (key: "sample_rate_hz", value: .int(Int64(sampleRateHz))),
            (key: "channels", value: .int(Int64(channels))),
            (key: "buffer_frames", value: .int(Int64(bufferFrames))),
            (key: "capacity_frames", value: .int(Int64(capacityFrames))),
            (key: "underruns", value: .int(Int64(underruns))),
            (key: "performance_mode", value: .string(performanceMode)),
            (key: "timestamp_age_ms", value: OutputSnapshot.finite(timestampAgeMs)),
            (key: "estimated_queue_ms", value: OutputSnapshot.finite(estimatedQueueMs)),
        ])
    }

    /// Copy-report block (`OutputSnapshot.kt:20-30`); replaces the first line's "Actual AudioTrack route:" with "Actual
    /// iOS audio route:". Durations follow Android's `String.format(Locale.US, "%.1f ms", value)` (see
    /// `javaOneDecimal`).
    public func text() -> String {
        func ms(_ value: Double?) -> String {
            guard let value else { return "unavailable" }
            return OutputSnapshot.javaOneDecimal(value) + " ms"
        }
        let rate = Double(sampleRateHz)
        let buffer = ms(Double(bufferFrames) * 1000.0 / rate)
        let capacity = ms(Double(capacityFrames) * 1000.0 / rate)
        return [
            "Actual iOS audio route: \(route ?? "unavailable")",
            "Output: \(sampleRateHz) Hz / \(channels) channels · Performance: \(performanceMode)",
            "Buffer size: \(buffer) · Capacity: \(capacity) (not queue occupancy)",
            "Output underruns: \(underruns) · Track generation: \(trackGeneration) · "
                + "Observed route changes: \(routeChanges)",
            "Estimated queued output: \(ms(estimatedQueueMs)) · Timestamp age: \(ms(timestampAgeMs))",
            "Output timing is an OS estimate; headset rendering and physical latency remain unmeasured.",
        ].joined(separator: "\n")
    }

    /// Go `Output.valid(backend, uptime)` (`internal/diagnostics/report.go:103-111`): the host accepts the object only
    /// if this holds. iOS never uploads it; the check keeps fixtures and a future iOS backend honest.
    public func hostValid(backend expected: String, uptimeMs: Int64) -> Bool {
        let counts =
            (1...1_000_000).contains(trackGeneration) && (0...1_000_000).contains(routeChanges)
            && underruns >= 0 && underruns <= Int(Int32.max)
        let format =
            (8_000...384_000).contains(sampleRateHz) && (1...32).contains(channels)
            && bufferFrames >= 0 && capacityFrames >= bufferFrames && capacityFrames <= 384_000 * 60
            && ["none", "low latency", "power saving"].contains(performanceMode)
        let timing =
            OutputSnapshot.bounded(timestampAgeMs, -1_000, 1_000)
            && OutputSnapshot.bounded(estimatedQueueMs, 0, 60_000)
            && (estimatedQueueMs == nil || timestampAgeMs != nil)
        let routeKnown = route.map { OutputKind.hostRouteLabels.contains($0) } ?? true
        return backend == expected && capturedUptimeMs >= 0 && capturedUptimeMs <= uptimeMs
            && routeKnown && counts && format && timing
    }

    /// Java `Formatter` `%.1f` (Android `String.format(Locale.US, "%.1f", value)`, `OutputSnapshot.kt:21`):
    /// the shortest round-trip decimal digits rounded HALF_UP to one fraction digit (`0.25` -> `0.3`,
    /// where C `printf` gives `0.2`), the sign kept (`-0.0`), and `NaN` / `Infinity` / `-Infinity` for
    /// non-finite values (a zero sample rate divides by zero exactly as on Android).
    static func javaOneDecimal(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        // Swift prints the shortest round-trip digits: "21.25", "1e-05", "1e+16".
        var text = "\(value.magnitude)"
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = String(text[..<marker])
        }
        let pieces = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = pieces.first.map(String.init) ?? "0"
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = (whole + fraction).compactMap { $0.wholeNumberValue }
        // Number of digits before the decimal point.
        var point = whole.count + exponent
        while point < 1 {
            digits.insert(0, at: 0)
            point += 1
        }
        while digits.count < point + 1 { digits.append(0) }
        if digits.count > point + 1 {
            let roundUp = digits[point + 1] >= 5
            digits.removeSubrange((point + 1)...)
            if roundUp {
                var index = digits.count - 1
                while index >= 0 && digits[index] == 9 {
                    digits[index] = 0
                    index -= 1
                }
                if index >= 0 {
                    digits[index] += 1
                } else {
                    digits.insert(1, at: 0)
                    point += 1
                }
            }
        }
        var integer = digits[..<point].map(String.init).joined()
        while integer.count > 1 && integer.hasPrefix("0") { integer.removeFirst() }
        return (value.sign == .minus ? "-" : "") + integer + "." + String(digits[point])
    }

    private static func finite(_ value: Double?) -> DiagnosticJSON {
        guard let value, value.isFinite else { return .null }
        return .double(value)
    }

    /// Go `bounded(value, low, high)` (`report.go:99-101`): nil, or finite and within `low...high`.
    static func bounded(_ value: Double?, _ low: Double, _ high: Double) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= low && value <= high
    }
}

/// Manual encoding with explicit nulls, key order as `keys`.
extension OutputSnapshot: Encodable {
    private enum CodingKeys: String, CodingKey {
        case backend
        case capturedUptimeMs = "captured_uptime_ms"
        case route
        case trackGeneration = "track_generation"
        case routeChanges = "route_changes"
        case sampleRateHz = "sample_rate_hz"
        case channels
        case bufferFrames = "buffer_frames"
        case capacityFrames = "capacity_frames"
        case underruns
        case performanceMode = "performance_mode"
        case timestampAgeMs = "timestamp_age_ms"
        case estimatedQueueMs = "estimated_queue_ms"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(capturedUptimeMs, forKey: .capturedUptimeMs)
        if let route { try container.encode(route, forKey: .route) } else { try container.encodeNil(forKey: .route) }
        try container.encode(trackGeneration, forKey: .trackGeneration)
        try container.encode(routeChanges, forKey: .routeChanges)
        try container.encode(sampleRateHz, forKey: .sampleRateHz)
        try container.encode(channels, forKey: .channels)
        try container.encode(bufferFrames, forKey: .bufferFrames)
        try container.encode(capacityFrames, forKey: .capacityFrames)
        try container.encode(underruns, forKey: .underruns)
        try container.encode(performanceMode, forKey: .performanceMode)
        if let timestampAgeMs, timestampAgeMs.isFinite {
            try container.encode(timestampAgeMs, forKey: .timestampAgeMs)
        } else {
            try container.encodeNil(forKey: .timestampAgeMs)
        }
        if let estimatedQueueMs, estimatedQueueMs.isFinite {
            try container.encode(estimatedQueueMs, forKey: .estimatedQueueMs)
        } else {
            try container.encodeNil(forKey: .estimatedQueueMs)
        }
    }
}

/// Coherent frame/time queue estimate (`OutputSnapshot.kt:33-46`). Kept for the ported tests; iOS reports
/// `timestamp_age_ms`/`estimated_queue_ms` as null (no coherent written/presented frame pair; `outputLatency` is a
/// hardware estimate, not a queue).
public enum OutputTiming {
    /// nil if `written` is nil/negative, `presented < 0`, `presented > written`, `sampleRate <= 0` or
    /// `timestampNs < epochNs`; `age = (now - ts) / 1e6` must lie in [-1000, 1000];
    /// `q = (written - presented) * 1000 / sampleRate - age`, returned only if finite and in [0, 60000].
    /// Future committed timestamps (negative age) are legitimate.
    public static func queueMs(
        written: Int64?, presented: Int64, timestampNs: Int64, nowNs: Int64,
        sampleRate: Int, epochNs: Int64
    ) -> Double? {
        guard let written, written >= 0, presented >= 0, presented <= written, sampleRate > 0,
            timestampNs >= epochNs
        else { return nil }
        // Kotlin Long subtraction wraps; `&-` keeps that behavior instead of trapping.
        let ageMs = Double(nowNs &- timestampNs) / 1e6
        guard (-1000.0...1000.0).contains(ageMs) else { return nil }
        let queue = Double(written - presented) * 1000.0 / Double(sampleRate) - ageMs
        guard queue.isFinite, (0.0...60000.0).contains(queue) else { return nil }
        return queue
    }
}
