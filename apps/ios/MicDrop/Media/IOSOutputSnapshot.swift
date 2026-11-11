import AVFoundation
import Foundation
import MicDropCore

/// The honest iPhone output snapshot.
///
/// Android reads the pinned AAR's private `AudioTrack` (route device, buffer/capacity, underruns, timestamp, queue).
/// The WebRTC iOS ADM exposes no unit internals, so this captures only `AVAudioSession` getters (no setters) plus the
/// engine's own counters. It is **never uploaded**: with `output_diagnostics_version == 1` the report sends `"output":
/// null` and `"local_output_baseline": null`. It feeds:
/// - the copy-report line that replaces `Actual AudioTrack diagnostics: …`;
/// - `outputSnapshot(backend:)`, the 09 `OutputSnapshot` value used for `RecoveryMonitor` epochs and
/// the local-output baseline text (iOS column; never on the wire).
struct IOSOutputSnapshot: Sendable, Equatable {
    /// Monotonic ms at capture, ≤ the report's `uptime_ms`.
    let capturedUptimeMs: Int64
    /// Host route label of `currentRoute.outputs.first` (`OutputKind.routeLabel(portType:)`), nil
    /// when the route has no output.
    let route: String?
    /// `AVAudioSession.sampleRate` (actual hardware rate; HFP runs at 8/16/24 kHz).
    let sampleRateHz: Double
    /// `AVAudioSession.outputNumberOfChannels` (hardware).
    let outputChannels: Int
    /// `AVAudioSession.ioBufferDuration` in seconds (actual, not the preferred 0.01).
    let ioBufferDuration: Double
    /// `AVAudioSession.outputLatency` in seconds (an OS estimate, never a measured queue; never put
    /// into `estimated_queue_ms`).
    let outputLatency: Double
    /// Decoded playout channels seen by `PlayoutTap` (nil before the first callback).
    let decodedChannels: Int?
    /// `didDetectPlayoutGlitch` running total (ADM render gaps; not AudioTrack underruns).
    let playoutGlitches: Int64
    /// Number of audio-unit starts (`audioSessionDidStartPlayOrRecord`, first = 1; 0 = not started).
    let trackGeneration: Int
    /// Route changes of the output set while playing.
    let routeChanges: Int

    init(
        capturedUptimeMs: Int64, route: String?, sampleRateHz: Double, outputChannels: Int,
        ioBufferDuration: Double, outputLatency: Double, decodedChannels: Int?, playoutGlitches: Int64,
        trackGeneration: Int, routeChanges: Int
    ) {
        self.capturedUptimeMs = capturedUptimeMs
        self.route = route
        self.sampleRateHz = sampleRateHz
        self.outputChannels = outputChannels
        self.ioBufferDuration = ioBufferDuration
        self.outputLatency = outputLatency
        self.decodedChannels = decodedChannels
        self.playoutGlitches = playoutGlitches
        self.trackGeneration = trackGeneration
        self.routeChanges = routeChanges
    }

    /// Reads the shared `AVAudioSession` now (getters only; safe from any thread).
    static func capture(
        capturedUptimeMs: Int64, decodedChannels: Int?, playoutGlitches: Int64,
        trackGeneration: Int, routeChanges: Int,
        session: AVAudioSession = AVAudioSession.sharedInstance()
    ) -> IOSOutputSnapshot {
        let portType = session.currentRoute.outputs.first?.portType.rawValue
        return IOSOutputSnapshot(
            capturedUptimeMs: capturedUptimeMs,
            route: portType.flatMap { OutputKind.routeLabel(portType: $0) },
            sampleRateHz: session.sampleRate,
            outputChannels: session.outputNumberOfChannels,
            ioBufferDuration: session.ioBufferDuration,
            outputLatency: session.outputLatency,
            decodedChannels: decodedChannels,
            playoutGlitches: playoutGlitches,
            trackGeneration: trackGeneration,
            routeChanges: routeChanges)
    }

    /// `round(ioBufferDuration × sampleRate)` (`buffer_frames`; iOS has no capacity concept).
    var bufferFrames: Int {
        let frames = (ioBufferDuration * sampleRateHz).rounded()
        guard frames.isFinite, frames >= 0, frames <= Double(Int32.max) else { return 0 }
        return Int(frames)
    }

    /// `RecoveryMonitor` epoch `(trackGeneration, routeChanges)` (`OutputSnapshot.kt:68`).
    var epoch: (Int, Int) { (trackGeneration, routeChanges) }

    /// The copy-report replacement for `Actual AudioTrack diagnostics: …` (diagnostics owns the copy text). Delegates
    /// to `ReportText.audioSession(sampleRateHz:outputChannels:ioBufferSeconds:outputLatencySeconds:)`: `iOS audio
    /// session: <rate %.0f> Hz / <ch> channels · I/O buffer: <ms %.1f> ms · Reported output latency: <ms %.1f> ms` +
    /// newline + the OS-estimate disclaimer. Feeds `ReportText.Periodic.audioSessionText`; not uploaded.
    func text() -> String {
        ReportText.audioSession(
            sampleRateHz: sampleRateHz, outputChannels: outputChannels,
            ioBufferSeconds: ioBufferDuration, outputLatencySeconds: outputLatency)
    }

    /// The `OutputSnapshot` mapping (never uploaded on current hosts): `backend` as given
    /// (`OutputSnapshot.webRTCBackend` / `.localBackend`), `route`, `track_generation` (≥ 1 once started),
    /// `route_changes`, `sample_rate_hz` = rounded session rate, `channels` = hardware output channels, `buffer_frames`
    /// = `capacity_frames` = `bufferFrames`, `underruns` = playout glitches (approximation), `performance_mode`
    /// `"none"`, timestamp age / queue `nil`.
    func outputSnapshot(backend: String) -> OutputSnapshot {
        let rate = sampleRateHz.isFinite ? Int(sampleRateHz.rounded()) : 0
        return OutputSnapshot(
            backend: backend, capturedUptimeMs: capturedUptimeMs, route: route,
            trackGeneration: max(trackGeneration, 1), routeChanges: routeChanges,
            sampleRateHz: rate, channels: outputChannels,
            bufferFrames: bufferFrames, capacityFrames: bufferFrames,
            underruns: Int(clamping: playoutGlitches), performanceMode: "none",
            timestampAgeMs: nil, estimatedQueueMs: nil)
    }
}
