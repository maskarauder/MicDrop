import Foundation

/// One WebRTC statistics member value.
///
/// The app-side adapter (`StatsCollector`) maps `RTCStatistics.values`: an `NSNumber` that is a `CFBoolean` becomes
/// `.bool` (never `.number`: a Kotlin `Boolean` is not a `Number`), any other `NSNumber` becomes
/// `.number(doubleValue)`, an `NSString` becomes `.string`, everything else `.other`.
public enum StatValue: Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case other

    /// Kotlin `(get(key) as? Number)?.toDouble()?.takeIf { it.isFinite() && (signed || it >= 0) }`
    /// (`K:PlaybackMetrics.kt:109-110`).
    public func number(signed: Bool = false) -> Double? {
        guard case .number(let value) = self, value.isFinite, signed || value >= 0 else { return nil }
        return value
    }

    /// Kotlin `get(key) as? String`.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// One statistics object (`K:PlaybackMetrics.kt:7-8`). IDs and string members are lookup/comparison
/// state only and are never serialized or printed.
public struct RtcSample: Sendable, Equatable {
    public let id: String
    public let type: String
    /// `RTCStatistics.timestamp_us` (microseconds).
    public let timestampUs: Double
    public let members: [String: StatValue]

    public init(id: String, type: String, timestampUs: Double, members: [String: StatValue]) {
        self.id = id
        self.type = type
        self.timestampUs = timestampUs
        self.members = members
    }

    /// Finite numeric member, non-negative unless `signed`.
    public func number(_ key: String, signed: Bool = false) -> Double? {
        members[key]?.number(signed: signed)
    }

    /// String member.
    public func string(_ key: String) -> String? {
        members[key]?.stringValue
    }
}
