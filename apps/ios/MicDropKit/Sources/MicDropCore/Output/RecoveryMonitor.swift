import Foundation

/// `recovery` diagnostics object (`OutputSnapshot.kt:48-55`; Go `report.go:88-94, 184-191`: phase
/// `waiting|settling|settled`, `settled_after_ms` non-null iff settled and <= `episode_ms`, `peak_buffer_ms` null or
/// 0...60000). Sent for playback modes whenever `output_diagnostics_version == 1`.
public struct RecoverySnapshot: Equatable, Sendable {
    /// Wire keys in emission order (`OutputSnapshot.kt:50-52`).
    public static let keys = ["fast_accelerate", "phase", "episode_ms", "settled_after_ms", "peak_buffer_ms"]

    /// The session's "Faster recovery" preference.
    public let fastAccelerate: Bool
    /// `waiting`, `settling` or `settled`.
    public let phase: String
    public let episodeMs: Int64
    public let settledAfterMs: Int64?
    public let peakBufferMs: Double?

    public init(fastAccelerate: Bool, phase: String, episodeMs: Int64, settledAfterMs: Int64?, peakBufferMs: Double?) {
        self.fastAccelerate = fastAccelerate
        self.phase = phase
        self.episodeMs = episodeMs
        self.settledAfterMs = settledAfterMs
        self.peakBufferMs = peakBufferMs
    }

    /// Ordered wire object with explicit nulls.
    public func json() -> DiagnosticJSON {
        .object([
            (key: "fast_accelerate", value: .bool(fastAccelerate)),
            (key: "phase", value: .string(phase)),
            (key: "episode_ms", value: .int(episodeMs)),
            (key: "settled_after_ms", value: settledAfterMs.map { DiagnosticJSON.int($0) } ?? .null),
            (key: "peak_buffer_ms", value: RecoverySnapshot.finite(peakBufferMs)),
        ])
    }

    /// `Buffer recovery: <phase> · Fast recovery: <bool> · Settled after: <n ms|unavailable>`
    /// (`OutputSnapshot.kt:53-54`).
    public func text() -> String {
        "Buffer recovery: \(phase) · Fast recovery: \(fastAccelerate) · Settled after: "
            + (settledAfterMs.map { "\($0) ms" } ?? "unavailable")
    }

    /// Go `recovery` rules (`internal/diagnostics/report.go:184-191`) for a report whose `uptime_ms` is
    /// `uptimeMs`: phase `waiting|settling|settled`, `0 <= episode_ms <= uptime_ms`, `peak_buffer_ms` nil
    /// or finite in `0...60000`, `settled_after_ms` nil or in `0...episode_ms`, and non-nil exactly when
    /// settled. The monitor itself is ported verbatim and does not clamp (a metrics `buffer_ms` above
    /// 60 s would be reported as Android reports it).
    public func hostValid(uptimeMs: Int64) -> Bool {
        let settledInRange = settledAfterMs.map { $0 >= 0 && $0 <= episodeMs } ?? true
        let peakInRange = peakBufferMs.map { $0.isFinite && $0 >= 0 && $0 <= 60_000 } ?? true
        return ["waiting", "settling", "settled"].contains(phase) && episodeMs >= 0 && episodeMs <= uptimeMs
            && peakInRange && settledInRange && ((phase == "settled") == (settledAfterMs != nil))
    }

    private static func finite(_ value: Double?) -> DiagnosticJSON {
        guard let value, value.isFinite else { return .null }
        return .double(value)
    }
}

/// Manual encoding with explicit nulls, key order as `keys`.
extension RecoverySnapshot: Encodable {
    private enum CodingKeys: String, CodingKey {
        case fastAccelerate = "fast_accelerate"
        case phase
        case episodeMs = "episode_ms"
        case settledAfterMs = "settled_after_ms"
        case peakBufferMs = "peak_buffer_ms"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fastAccelerate, forKey: .fastAccelerate)
        try container.encode(phase, forKey: .phase)
        try container.encode(episodeMs, forKey: .episodeMs)
        if let settledAfterMs {
            try container.encode(settledAfterMs, forKey: .settledAfterMs)
        } else {
            try container.encodeNil(forKey: .settledAfterMs)
        }
        if let peakBufferMs, peakBufferMs.isFinite {
            try container.encode(peakBufferMs, forKey: .peakBufferMs)
        } else {
            try container.encodeNil(forKey: .peakBufferMs)
        }
    }
}

/// Buffer-recovery observer (B.6; `OutputSnapshot.kt:57-88`).
///
/// "Observes recovery; never flushes audio or restarts a peer. 'Settled' means three consecutive valid windows at <=
/// max(80 ms, target + 20 ms)." Platform-neutral, ported verbatim. iOS epoch: `(1, audioRouteChangeCount)`, or nil.
/// Called from the session worker only.
public final class RecoveryMonitor: @unchecked Sendable {
    private let fastAccelerate: Bool
    private var started: Int64?
    private var routeEpoch: (Int, Int)?
    private var stable = 0
    private var settled: Int64?
    private var peak: Double?

    public init(fastAccelerate: Bool) {
        self.fastAccelerate = fastAccelerate
    }

    /// One report window. `running` = `media_output == "running" && state == "Connected"`
    /// (`StreamReceiver.kt:708`); `bufferMs`/`targetMs` = metrics `buffer_ms`/`buffer_target_ms`.
    public func update(
        nowMs: Int64, running: Bool, epoch: (Int, Int)?, bufferMs: Double?,
        targetMs: Double?
    ) -> RecoverySnapshot {
        if !running {
            started = nil
            stable = 0
            settled = nil
            peak = nil
            routeEpoch = epoch
            return RecoverySnapshot(
                fastAccelerate: fastAccelerate, phase: "waiting", episodeMs: 0,
                settledAfterMs: nil, peakBufferMs: nil)
        }
        var restart = started == nil
        if let epoch, let previous = routeEpoch, epoch != previous { restart = true }
        if restart {
            started = nowMs
            stable = 0
            settled = nil
            peak = nil
        }
        if let epoch { routeEpoch = epoch }
        let elapsed = max(0, nowMs - (started ?? nowMs))
        let buffer: Double? = bufferMs.flatMap { value -> Double? in value.isFinite && value >= 0 ? value : nil }
        if let buffer { peak = max(peak ?? 0, buffer) }
        let target: Double = targetMs.flatMap { value -> Double? in value.isFinite && value >= 0 ? value : nil } ?? 0
        if let buffer, buffer <= max(80, target + 20) {
            stable = min(stable + 1, 3)
        } else {
            stable = 0
            settled = nil
        }
        if stable >= 3 && settled == nil { settled = elapsed }
        return RecoverySnapshot(
            fastAccelerate: fastAccelerate, phase: settled != nil ? "settled" : "settling",
            episodeMs: elapsed, settledAfterMs: settled, peakBufferMs: peak)
    }

    /// Kotlin-shaped overload (`OutputSnapshot.kt:66`): epoch from the output snapshot, nil without one.
    public func update(
        nowMs: Int64, running: Bool, output: OutputSnapshot?, bufferMs: Double?,
        targetMs: Double?
    ) -> RecoverySnapshot {
        update(nowMs: nowMs, running: running, epoch: output?.epoch, bufferMs: bufferMs, targetMs: targetMs)
    }
}
