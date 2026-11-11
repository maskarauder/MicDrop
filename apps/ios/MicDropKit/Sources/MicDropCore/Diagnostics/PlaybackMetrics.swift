import Foundation

/// Bounded numeric metrics and fixed labels from one stats cycle (`K:PlaybackMetrics.kt:10-29`).
///
/// `values` keeps Android's emission order (`K:PlaybackMetrics.kt:72-99`): the 14 incoming keys, then the
/// three `sent_*` keys for an outgoing instance, then `rtt_ms`; a duplex snapshot appends the `sent_*`
/// keys of the outgoing instance after `rtt_ms` (Kotlin map `+`). Every listed key is always present;
/// its value is finite or `nil` (JSON `null`).
public struct PlaybackSnapshot: Sendable {
    /// Incoming-stream metric keys in emission order (also computed from an outbound sample in microphone mode, where
    /// most are `nil`).
    public static let incomingKeys: [String] = [
        "window_seconds", "buffer_ms", "buffer_target_ms", "buffer_minimum_ms", "jitter_ms", "bytes_total",
        "payload_kbps", "received_packets", "lost_packets", "discarded_packets", "concealed_samples",
        "concealed_percent", "inserted_samples", "removed_samples",
    ]
    /// Outgoing-only keys; allowed by the host only when `microphone` is present.
    public static let sentKeys: [String] = ["sent_bytes_total", "sent_packets", "sent_payload_kbps"]
    /// Selected candidate-pair round-trip time key.
    public static let rttKey = "rtt_ms"

    /// `Opus` or `unavailable`.
    public var codec: String
    /// Legacy path label: `direct|relay|unavailable` optionally followed by ` / udp` or ` / tcp`.
    public var path: String
    /// Ordered metric values.
    public var values: [(key: String, value: Double?)]
    /// Selected media transport (type).
    public var transport: MediaTransportSnapshot

    public init(
        codec: String, path: String, values: [(key: String, value: Double?)],
        transport: MediaTransportSnapshot
    ) {
        self.codec = codec
        self.path = path
        self.values = values
        self.transport = transport
    }

    /// Value for `key`, or `nil` when absent or unavailable (`snapshot.values["buffer_ms"]`).
    public func value(_ key: String) -> Double? {
        values.first(where: { $0.key == key })?.value ?? nil
    }

    /// Whether `key` is part of this snapshot (even with a `nil` value).
    public func contains(_ key: String) -> Bool {
        values.contains(where: { $0.key == key })
    }

    /// Replaces the value of an existing key in place, or appends a new key (Kotlin map `+`).
    public mutating func set(_ key: String, _ value: Double?) {
        if let index = values.firstIndex(where: { $0.key == key }) {
            values[index].value = value
        } else {
            values.append((key: key, value: value))
        }
    }

    /// The `metrics` object: never `null`, every key present, `nil` and non-finite as `null`.
    public func metricsJSON() -> DiagnosticJSON {
        .object(values.map { (key: $0.key, value: DiagnosticJSON.number($0.value)) })
    }

    /// Copy-report block, verbatim Android (`K:PlaybackMetrics.kt:13-28`).
    public func text() -> String {
        func number(_ key: String, _ unit: String = "", _ decimals: Int = 1) -> String {
            guard let found = self.value(key) else { return "unavailable" }
            return String(format: "%.\(decimals)f", found) + unit
        }
        var lines: [String] = []
        lines.append("Codec: \(codec) · Media path: \(path)")
        lines.append("Network RTT: \(number("rtt_ms", " ms")) · RTP jitter: \(number("jitter_ms", " ms"))")
        lines.append("Recent window: \(number("window_seconds", " s"))")
        lines.append(
            "Jitter buffer — actual: \(number("buffer_ms", " ms")), target: \(number("buffer_target_ms", " ms")), minimum: \(number("buffer_minimum_ms", " ms"))"
        )
        lines.append("Incoming payload: \(number("payload_kbps", " kb/s"))")
        lines.append(
            "Recent packets — received: \(number("received_packets", "", 0)), net loss change: \(number("lost_packets", "", 0)), discarded: \(number("discarded_packets", "", 0))"
        )
        lines.append(
            "Recent concealed samples: \(number("concealed_samples", "", 0)) (\(number("concealed_percent", "%")))")
        lines.append(
            "Recent time stretching — inserted: \(number("inserted_samples", "", 0)), removed: \(number("removed_samples", "", 0)) samples"
        )
        lines.append("Total received: \(number("bytes_total", " bytes", 0))")
        lines.append("RTT and jitter-buffer statistics are not speaker latency.")
        return lines.joined(separator: "\n")
    }
}

extension PlaybackSnapshot: Equatable {
    public static func == (lhs: PlaybackSnapshot, rhs: PlaybackSnapshot) -> Bool {
        guard lhs.codec == rhs.codec, lhs.path == rhs.path, lhs.transport == rhs.transport,
            lhs.values.count == rhs.values.count
        else { return false }
        for index in lhs.values.indices
        where lhs.values[index].key != rhs.values[index].key || lhs.values[index].value != rhs.values[index].value {
            return false
        }
        return true
    }
}

/// Per-direction windowed statistics calculator (`K:PlaybackMetrics.kt:47-117`). Worker-thread only (one instance per
/// direction per session); not thread-safe.
public final class PlaybackMetrics {
    /// Cumulative counters whose decrease means a reset (`K:PlaybackMetrics.kt:113-115`). `packetsLost`
    /// is deliberately absent: RTCP's net loss can decrease.
    public static let cumulativeKeys: [String] = [
        "bytesReceived", "packetsReceived", "bytesSent", "packetsSent", "packetsDiscarded",
        "jitterBufferEmittedCount", "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferMinimumDelay",
        "totalSamplesReceived", "concealedSamples", "insertedSamplesForDeceleration", "removedSamplesForAcceleration",
    ]

    private let outgoing: Bool
    private var previous: RtcSample?

    public init(outgoing: Bool = false) {
        self.outgoing = outgoing
    }

    /// One cycle. Stream choice is deterministic on iOS (note): the sample with the previous id if present, else the
    /// lexicographically smallest id among audio samples of the wanted RTP type.
    public func update(_ samples: [String: RtcSample]) -> PlaybackSnapshot {
        let wanted = outgoing ? "outbound-rtp" : "inbound-rtp"
        let candidates = samples.values.filter { $0.type == wanted && $0.string("kind") == "audio" }
        let stream: RtcSample?
        if let previousId = previous?.id, let same = candidates.first(where: { $0.id == previousId }) {
            stream = same
        } else {
            stream = candidates.min(by: { $0.id < $1.id })
        }
        let old = previous
        previous = stream

        func current(_ key: String) -> Double? { stream?.number(key) }

        var seconds: Double?
        if let stream, let old, old.id == stream.id {
            let elapsed = (stream.timestampUs - old.timestampUs) / 1e6
            if elapsed.isFinite && elapsed > 0 && elapsed <= 10 { seconds = elapsed }
        }
        let reset = Self.cumulativeKeys.contains { key in
            guard let now = current(key), let before = old?.number(key) else { return false }
            return now < before
        }
        let window = reset ? nil : seconds

        func delta(_ key: String, signed: Bool = false) -> Double? {
            guard window != nil,
                let now = stream?.number(key, signed: signed),
                let before = old?.number(key, signed: signed)
            else { return nil }
            let difference = now - before
            return difference.isFinite && (signed || difference >= 0) ? difference : nil
        }
        let emitted = delta("jitterBufferEmittedCount").flatMap { $0 > 0 ? $0 : nil }
        func mean(_ key: String) -> Double? {
            guard let count = emitted, let total = delta(key) else { return nil }
            return 1000 * total / count
        }
        func kbps(_ key: String) -> Double? {
            guard let window, let bytes = delta(key) else { return nil }
            return bytes * 8 / window / 1000
        }

        var values: [(key: String, value: Double?)] = []
        values.append((key: "window_seconds", value: window))
        values.append((key: "buffer_ms", value: mean("jitterBufferDelay")))
        values.append((key: "buffer_target_ms", value: mean("jitterBufferTargetDelay")))
        values.append((key: "buffer_minimum_ms", value: mean("jitterBufferMinimumDelay")))
        values.append((key: "jitter_ms", value: current("jitter").map { $0 * 1000 }))
        values.append((key: "bytes_total", value: current("bytesReceived")))
        values.append((key: "payload_kbps", value: kbps("bytesReceived")))
        values.append((key: "received_packets", value: delta("packetsReceived")))
        values.append((key: "lost_packets", value: delta("packetsLost", signed: true)))
        values.append((key: "discarded_packets", value: delta("packetsDiscarded")))
        values.append((key: "concealed_samples", value: delta("concealedSamples")))
        let concealedPercent: Double?
        if let totalSamples = delta("totalSamplesReceived"), totalSamples > 0, let concealed = delta("concealedSamples")
        {
            let percent = 100 * concealed / totalSamples
            concealedPercent = (0.0...100.0).contains(percent) ? percent : nil
        } else {
            concealedPercent = nil
        }
        values.append((key: "concealed_percent", value: concealedPercent))
        values.append((key: "inserted_samples", value: delta("insertedSamplesForDeceleration")))
        values.append((key: "removed_samples", value: delta("removedSamplesForAcceleration")))
        if outgoing {
            values.append((key: "sent_bytes_total", value: current("bytesSent")))
            values.append((key: "sent_packets", value: delta("packetsSent")))
            values.append((key: "sent_payload_kbps", value: kbps("bytesSent")))
        }

        func linked(_ sample: RtcSample?, _ key: String, _ type: String) -> RtcSample? {
            guard let id = sample?.string(key), let target = samples[id], target.type == type else { return nil }
            return target
        }
        let transport = linked(stream, "transportId", "transport")
        let pair = linked(transport, "selectedCandidatePairId", "candidate-pair")
            // Keepalive checks can put an established selected pair in progress.
            // Selection identifies the path; it does not prove live audio.
            .flatMap { ["succeeded", "in-progress"].contains($0.string("state") ?? "") ? $0 : nil }
        values.append((key: "rtt_ms", value: pair?.number("currentRoundTripTime").map { $0 * 1000 }))
        let selected = MediaTransportSnapshot.selected(
            local: linked(pair, "localCandidateId", "local-candidate"),
            remote: linked(pair, "remoteCandidateId", "remote-candidate"))
        let codec = linked(stream, "codecId", "codec")?.string("mimeType") == "audio/opus" ? "Opus" : "unavailable"
        let finite = values.map { (key: $0.key, value: $0.value.flatMap { $0.isFinite ? $0 : nil }) }
        return PlaybackSnapshot(codec: codec, path: selected.legacyPath, values: finite, transport: selected)
    }
}

/// Per-mode composition (`K:PlaybackMetrics.kt:33-45`). Each direction keeps its own history so an outbound counter
/// reset cannot erase inbound windows. Worker-thread only.
public final class SessionMetrics {
    private let mode: StreamMode
    private let incoming = PlaybackMetrics()
    private let outgoing = PlaybackMetrics(outgoing: true)

    public init(mode: StreamMode) {
        self.mode = mode
    }

    /// `PLAYBACK`: incoming only. `MICROPHONE`: outgoing only. `DUPLEX`: incoming result plus only the
    /// `sent_*` keys of the outgoing instance.
    public func update(_ samples: [String: RtcSample]) -> PlaybackSnapshot {
        switch mode {
        case .playback:
            return incoming.update(samples)
        case .microphone:
            return outgoing.update(samples)
        case .duplex:
            var received = incoming.update(samples)
            let sent = outgoing.update(samples)
            for (key, value) in sent.values where key.hasPrefix("sent_") {
                received.set(key, value)
            }
            return received
        }
    }
}
