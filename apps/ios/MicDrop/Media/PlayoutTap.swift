import Foundation
import WebRTC
import os

/// Playout liveness from the decoded remote track (Shiguredo `ios_audio_track_sink`). iOS replacement for Android
/// `onWebRtcAudioTrackStart/Stop` (`StreamReceiver.kt:408-425`), which are playout-specific (RTCAudioSession's
/// `didStart/StopPlayOrRecord` cover the whole unit, capture included).
///
/// `onData` runs on every ADM playout pull, before the output gain, so it also runs while the
/// speaker gate mutes the track. It executes on the native audio thread and only updates counters
/// under an unfair lock (no allocation, no dispatch, no PCM retained or forwarded). A private
/// 50 ms timer derives `active = last callback within 200 ms` and reports rising/falling edges on
/// its queue.
///
/// Track identity: `receiver.track` returns a new wrapper on every read and a wrapper's `dealloc` removes its sinks, so
/// the exact `RTCAudioTrack` instance passed to `attach` is retained until `detach()`, which calls `remove(_:)` on that
/// same instance (teardown `peer_dispose`).
final class PlayoutTap: NSObject, RTCAudioTrackSink, @unchecked Sendable {
    /// Playout is active while the last callback is at most this old.
    static let activeWindowMs: Int64 = 200
    /// Edge detection period.
    static let pollIntervalMs = 50
    /// A stereo frame counts as distinct when `|L − R| > 100` (host `audio_device.cc:350-353`).
    static let distinctStereoThreshold: Int32 = 100

    /// Counter snapshot (diagnostics, `IOSOutputSnapshot.decodedChannels`, acceptance checks).
    struct Snapshot: Sendable, Equatable {
        /// Last callback within `activeWindowMs`.
        var active: Bool
        /// `onData` invocations.
        var callbacks: Int64
        /// Frames delivered.
        var frames: Int64
        /// Channels of the decoded stream at the last callback (0 before the first one).
        var channels: Int
        /// Sample rate of the decoded stream at the last callback (0 before the first one).
        var sampleRate: Int
        /// Frames with at least one non-zero sample.
        var nonzeroFrames: Int64
        /// Stereo frames with `|L − R| > 100` (distinct stereo).
        var distinctStereoFrames: Int64
        /// Age of the last callback, nil before the first one.
        var lastCallbackAgeMs: Int64?
        /// Rising edges observed (playout starts).
        var starts: Int64

        static let empty = Snapshot(
            active: false, callbacks: 0, frames: 0, channels: 0, sampleRate: 0,
            nonzeroFrames: 0, distinctStereoFrames: 0, lastCallbackAgeMs: nil, starts: 0)
    }

    private struct Counters: Sendable {
        var callbacks: Int64 = 0
        var frames: Int64 = 0
        var channels = 0
        var sampleRate = 0
        var nonzeroFrames: Int64 = 0
        var distinctStereoFrames: Int64 = 0
        /// `DispatchTime.now().uptimeNanoseconds` of the last callback; 0 = none.
        var lastCallbackNs: UInt64 = 0
        var starts: Int64 = 0
    }

    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private let queue = DispatchQueue(label: "MicDrop.playoutTap")
    // Worker-confined (attach/detach).
    private var track: RTCAudioTrack?
    private var timer: DispatchSourceTimer?
    // Queue-confined.
    private var reportedActive = false
    private var onEdge: ((Bool) -> Void)?

    override init() {
        super.init()
    }

    /// `true` between `attach` and `detach`.
    var isAttached: Bool { track != nil }

    /// Attaches to the offer-associated receiver's track (the transceiver whose `mid` is non-empty), once, after
    /// `setRemoteDescription`. `onEdge(true/false)` runs on the tap queue for every rising/falling edge. Session worker
    /// only.
    func attach(to track: RTCAudioTrack, onEdge: @escaping (Bool) -> Void) {
        guard self.track == nil else { return }
        self.track = track
        queue.sync {
            self.onEdge = onEdge
            self.reportedActive = false
        }
        track.add(self)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + .milliseconds(PlayoutTap.pollIntervalMs),
            repeating: .milliseconds(PlayoutTap.pollIntervalMs))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    /// Removes the sink from the same track instance, stops the timer and drops the edge handler
    /// (teardown `peer_dispose`, before `peer.close()`). Idempotent. Session worker only.
    func detach() {
        timer?.cancel()
        timer = nil
        if let attached = track { attached.remove(self) }
        track = nil
        queue.sync {
            self.onEdge = nil
            self.reportedActive = false
        }
    }

    /// `playoutActive` (`OutputPlayoutEngine.playoutActive`): last callback within 200 ms.
    var isActive: Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return counters.withLock { PlayoutTap.active($0, nowNs: now) }
    }

    /// Current counters.
    func snapshot() -> Snapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        return counters.withLock { c in
            Snapshot(
                active: PlayoutTap.active(c, nowNs: now), callbacks: c.callbacks, frames: c.frames,
                channels: c.channels, sampleRate: c.sampleRate, nonzeroFrames: c.nonzeroFrames,
                distinctStereoFrames: c.distinctStereoFrames,
                lastCallbackAgeMs: c.lastCallbackNs == 0
                    ? nil
                    : Int64((now &- c.lastCallbackNs) / 1_000_000),
                starts: c.starts)
        }
    }

    // MARK: - RTCAudioTrackSink (native audio thread)

    /// `-onData:bitsPerSample:sampleRate:numberOfChannels:numberOfFrames:` (`RTCAudioTrackSink.h`).
    ///
    /// Import hazard: omit-needless-words may prune the trailing type name `Data` from the base name
    /// `onData` (as `writeData:` becomes `write(_:)`), giving `on(_:bitsPerSample:…)`; SE-0005's
    /// vacuous-name list does not include `on`. Both spellings are declared and forward to one
    /// implementation: whichever matches the imported requirement is the `@objc` witness (inferred
    /// selector), the other is a plain Swift method (no implicit `@objc` on NSObject subclasses since
    /// SE-0160, so no selector conflict). Keep both spellings until the imported requirement is
    /// verified against the pinned Apple WebRTC framework.
    func onData(_ audioData: Data, bitsPerSample: Int, sampleRate: Int, numberOfChannels: Int, numberOfFrames: Int) {
        consume(
            audioData, bitsPerSample: bitsPerSample, sampleRate: sampleRate,
            numberOfChannels: numberOfChannels, numberOfFrames: numberOfFrames)
    }

    /// Alternative imported spelling of the same requirement (see `onData`).
    func on(_ audioData: Data, bitsPerSample: Int, sampleRate: Int, numberOfChannels: Int, numberOfFrames: Int) {
        consume(
            audioData, bitsPerSample: bitsPerSample, sampleRate: sampleRate,
            numberOfChannels: numberOfChannels, numberOfFrames: numberOfFrames)
    }

    /// PCM16LE interleaved (`bitsPerSample` is always 16). Counts frames, non-zero frames and distinct
    /// stereo frames; never stores or forwards samples. Native audio thread: no allocation, no dispatch.
    private func consume(
        _ audioData: Data, bitsPerSample: Int, sampleRate: Int, numberOfChannels: Int,
        numberOfFrames: Int
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        var nonzero: Int64 = 0
        var distinct: Int64 = 0
        var frames = 0
        if bitsPerSample == 16, numberOfChannels >= 1, numberOfFrames > 0 {
            audioData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let available = raw.count / (2 * numberOfChannels)
                frames = min(numberOfFrames, available)
                var frame = 0
                while frame < frames {
                    let base = frame * numberOfChannels * 2
                    var any = false
                    var channel = 0
                    while channel < numberOfChannels {
                        if raw.loadUnaligned(fromByteOffset: base + channel * 2, as: Int16.self) != 0 { any = true }
                        channel += 1
                    }
                    if any { nonzero += 1 }
                    if numberOfChannels == 2 {
                        let left = Int32(raw.loadUnaligned(fromByteOffset: base, as: Int16.self))
                        let right = Int32(raw.loadUnaligned(fromByteOffset: base + 2, as: Int16.self))
                        let difference = left - right
                        if difference > PlayoutTap.distinctStereoThreshold
                            || difference < -PlayoutTap.distinctStereoThreshold
                        {
                            distinct += 1
                        }
                    }
                    frame += 1
                }
            }
        }
        let countedFrames = Int64(frames)
        let countedNonzero = nonzero
        let countedDistinct = distinct
        let channels = numberOfChannels
        let rate = sampleRate
        counters.withLock { c in
            c.callbacks += 1
            c.frames += countedFrames
            c.nonzeroFrames += countedNonzero
            c.distinctStereoFrames += countedDistinct
            c.channels = channels
            c.sampleRate = rate
            c.lastCallbackNs = now
        }
    }

    // MARK: - Private

    private static func active(_ c: Counters, nowNs: UInt64) -> Bool {
        guard c.lastCallbackNs != 0, nowNs >= c.lastCallbackNs else { return c.lastCallbackNs != 0 }
        return (nowNs - c.lastCallbackNs) <= UInt64(activeWindowMs) * 1_000_000
    }

    /// Timer tick on `queue`: compares the derived state with the last reported one.
    private func poll() {
        let now = DispatchTime.now().uptimeNanoseconds
        let active = counters.withLock { PlayoutTap.active($0, nowNs: now) }
        guard active != reportedActive else { return }
        reportedActive = active
        if active { counters.withLock { $0.starts += 1 } }
        onEdge?(active)
    }
}
