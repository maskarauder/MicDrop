import Foundation
import MicDropCore
import WebRTC

/// `RTCStatisticsReport` → `[String: RtcSample]` (Appendix B.2; Kotlin `RtcSample(id, type, timestampUs, members)`,
/// `StreamReceiver.kt:690-696`).
///
/// Member mapping: an `NSNumber` that is a `CFBoolean` → `.bool` (never `.number`: a Kotlin
/// `Boolean` is not a `Number`); any other `NSNumber` → `.number(doubleValue)`; an `NSString` →
/// `.string`; arrays, dictionaries and anything else → `.other`. IDs and strings are lookup state
/// only and are never serialised or logged. Pure conversion; the 5 s wait lives in
/// `MediaEngine.statistics(timeoutMs:)`.
enum StatsCollector {

    /// Every statistics object of `report`, keyed by its id.
    static func samples(from report: RTCStatisticsReport) -> [String: RtcSample] {
        var result: [String: RtcSample] = [:]
        for (key, statistics) in report.statistics {
            var members: [String: StatValue] = [:]
            for (name, value) in statistics.values {
                members[name] = statValue(value)
            }
            result[key] = RtcSample(
                id: statistics.id, type: statistics.type,
                timestampUs: statistics.timestamp_us, members: members)
        }
        return result
    }

    /// One member value.
    static func statValue(_ object: NSObject) -> StatValue {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let text = object as? String { return .string(text) }
        return .other
    }

    // MARK: - Engine-side probes

    /// The audio `media-source` sample's `(timestampUs, totalSamplesDuration)` (iOS-only capture evidence, / optional
    /// confirmation). Smallest id wins if several exist. nil when the stat is absent on this SDK build.
    static func captureProgress(_ samples: [String: RtcSample]) -> (timestampUs: Double, seconds: Double)? {
        let source = samples.values
            .filter {
                $0.type == "media-source" && $0.string("kind") == "audio" && $0.number("totalSamplesDuration") != nil
            }
            .min { $0.id < $1.id }
        guard let source, let seconds = source.number("totalSamplesDuration") else { return nil }
        return (source.timestampUs, seconds)
    }

    /// `packetsReceived` of the audio `inbound-rtp` sample (smallest id, the `PlaybackMetrics` pick) for the iOS-only 5
    /// s playout watchdog. nil when absent.
    static func inboundPacketsReceived(_ samples: [String: RtcSample]) -> Double? {
        let inbound = samples.values
            .filter { $0.type == "inbound-rtp" && $0.string("kind") == "audio" }
            .min { $0.id < $1.id }
        return inbound?.number("packetsReceived")
    }
}
