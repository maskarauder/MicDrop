import AVFoundation
import Foundation
import MicDropCore
import os

/// Audio-only local output baseline below WebRTC's network/decoder/jitter buffer (Kotlin `LocalOutputProbe.kt:18-105`).
///
/// iOS port: `AVAudioEngine` + `AVAudioSourceNode` (48 kHz, 2 channels, Float32) rendering zeros,
/// or the 10 ms `ClickChirp` (the same integer samples / 32768, both channels equal) when the single
/// pending-click flag is set (atomic test-and-clear; at most one pending click, never a queue).
/// Limitation: uses AVAudioEngine/RemoteIO rather than WebRTC's ADM — a comparable
/// output baseline, not a bit-for-bit duplicate.
///
/// Preconditions (owned by the caller — `LocalAudioTools`): the process-wide `AudioSessionOwner.tryAcquire()` permit is
/// held and the arbiter applied `AudioSessionPlan.localTool` (`.playback`/`.default`, preferred 48 kHz, 0.01 s) while
/// `RTCAudioSession.isAudioEnabled == false`; both are released by the caller after `onEnded`. The probe never touches
/// `AVAudioSession` setters, never publishes Now Playing and does not observe `AVAudioSession` notifications (the UI
/// closes it on interruption began, route change `.oldDeviceUnavailable`, scene leaving `.active` and user Stop). It
/// does observe its own engine's `AVAudioEngineConfigurationChange` (→ failure end).
///
/// Callbacks: `onSnapshot` every 500 ms with the `OutputSnapshot` (backend `local_audiotrack`; copy-report baseline
/// only, never uploaded) and `onEnded` exactly once with `Local output test stopped.` or `Local output test failed.
/// Stop and choose the output again.`; both delivered on the main queue.
final class LocalOutputProbe: @unchecked Sendable {

    // MARK: - Constants (`LocalOutputProbe.kt`)

    /// Normal end (`LocalOutputProbe.kt:36`).
    static let stoppedMessage = "Local output test stopped."
    /// Any failure, including a render stall (`LocalOutputProbe.kt:92`).
    static let failedMessage = "Local output test failed. Stop and choose the output again."
    /// Fixed probe format: 48 kHz stereo (the WebRTC playout format).
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2
    /// Snapshot cadence (`LocalOutputProbe.kt:86`).
    static let snapshotIntervalMs = 500
    /// Render callbacks not advancing this long → failure (`LocalOutputProbe.kt:68`, 3000 ms).
    static let stallLimitMs: Int64 = 3_000

    // MARK: - Render-thread state

    /// Click flag and render progress shared with the real-time render block (unfair lock, no
    /// allocation). `clickFrame` is the next chirp frame to render (nil = no chirp in progress).
    final class RenderState: @unchecked Sendable {
        private struct Values: Sendable {
            var stopped = false
            var clickPending = false
            var clickFrame: Int?
            var renderedFrames: Int64 = 0
            /// `DispatchTime.now().uptimeNanoseconds` of the last render callback; 0 = none.
            var lastRenderNs: UInt64 = 0
        }

        private let values = OSAllocatedUnfairLock(initialState: Values())

        init() {}

        /// `playClick()`: sets the single pending flag (never queues).
        func armClick() {
            values.withLock { if !$0.stopped { $0.clickPending = true } }
        }

        func stop() {
            values.withLock {
                $0.stopped = true
                $0.clickPending = false
                $0.clickFrame = nil
            }
        }

        /// Render thread: test-and-clear of the pending flag; returns the chirp frame to continue from
        /// (0 for a newly armed click), or nil when no chirp is due. `advance` frames are consumed.
        func takeChirpStart(advance: Int) -> Int? {
            values.withLock { (v: inout Values) -> Int? in
                guard !v.stopped else { return nil }
                if v.clickPending && v.clickFrame == nil {
                    v.clickPending = false
                    v.clickFrame = 0
                }
                guard let start = v.clickFrame else { return nil }
                let next = start + advance
                v.clickFrame = next < ClickChirp.frames ? next : nil
                return start
            }
        }

        /// Render thread: progress for stall detection.
        func noteRendered(frames: Int, nowNs: UInt64) {
            let count = Int64(frames)
            values.withLock {
                $0.renderedFrames += count
                $0.lastRenderNs = nowNs
            }
        }

        /// Total rendered frames and the last render time (0 = never).
        func progress() -> (frames: Int64, lastRenderNs: UInt64) {
            values.withLock { ($0.renderedFrames, $0.lastRenderNs) }
        }
    }

    // MARK: - State

    private let clock: any MonotonicClock
    private let onSnapshot: (OutputSnapshot) -> Void
    private let onEnded: (String) -> Void
    private let render = RenderState()
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Guarded by `lock`.
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var timer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var started = false
    private var ended = false
    private var stopRequested = false
    private var startedUptimeMs: Int64 = 0

    /// `clock` supplies the snapshot `captured_uptime_ms` and the baseline "phone uptime".
    init(
        clock: any MonotonicClock, onSnapshot: @escaping (OutputSnapshot) -> Void,
        onEnded: @escaping (String) -> Void,
        queue: DispatchQueue = DispatchQueue(label: "MicDrop.localOutputProbe")
    ) {
        self.clock = clock
        self.onSnapshot = onSnapshot
        self.onEnded = onEnded
        self.queue = queue
    }

    // MARK: - Control

    /// Builds and starts the engine (main thread). Algorithm: if `WebRTCRuntime.isAudioEnabled` → end with
    /// `failedMessage`; create `AVAudioEngine`; format `AVAudioFormat(standardFormatWithSampleRate: 48000, channels:
    /// 2)`; `AVAudioSourceNode(format:)` whose render block zero-fills every buffer, then for a due chirp writes
    /// `ClickChirp.render(into:channels: 1, startFrame:)` into each (non-interleaved) channel buffer, and calls
    /// `render.noteRendered(frames:nowNs:)`; attach, connect to `mainMixerNode` with that format, observe
    /// `.AVAudioEngineConfigurationChange` for this engine (→ `finish(failedMessage)`), `prepare()` + `start()` (error
    /// → `finish(failedMessage)`); start a 500 ms timer on `queue` that checks the stall limit (no render progress for
    /// 3000 ms → `finish(failedMessage)`) and publishes `IOSOutputSnapshot.capture(...).outputSnapshot(backend:
    /// OutputSnapshot.localBackend)` on main. Idempotent; ignored after `close()`.
    func start() {
        lock.lock()
        guard !started, !ended, !stopRequested else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        lock.lock()
        let alreadyEnded = ended || stopRequested
        lock.unlock()
        guard !alreadyEnded else { return }
        guard !WebRTCRuntime.isAudioEnabled,
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: Self.channelCount)
        else {
            finishOnQueue(Self.failedMessage)
            return
        }
        _ = ClickChirp.floatSamples  // Initialise the table before the real-time callback.
        let running = AVAudioEngine()
        let render = self.render
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let count = Int(frameCount)
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            guard buffers.allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= count * MemoryLayout<Float>.size })
            else {
                isSilence.pointee = true
                return -50
            }
            let chirp = render.takeChirpStart(advance: count)
            if let chirp {
                for buffer in buffers {
                    let samples = UnsafeMutableBufferPointer(
                        start: buffer.mData!.assumingMemoryBound(to: Float.self), count: count)
                    ClickChirp.render(into: samples, channels: 1, startFrame: chirp)
                }
            }
            isSilence.pointee = ObjCBool(chirp == nil)
            render.noteRendered(frames: count, nowNs: DispatchTime.now().uptimeNanoseconds)
            return 0
        }
        running.attach(node)
        running.connect(node, to: running.mainMixerNode, format: format)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: running, queue: nil
        ) { [weak self] _ in self?.finish(Self.failedMessage) }
        lock.lock()
        engine = running
        sourceNode = node
        configurationObserver = observer
        startedUptimeMs = clock.nowMs()
        let shouldStart = !stopRequested
        lock.unlock()
        guard shouldStart else { return }
        let startedNs = DispatchTime.now().uptimeNanoseconds
        do {
            running.prepare()
            try running.start()
        } catch {
            finishOnQueue(Self.failedMessage)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.snapshotIntervalMs), repeating: .milliseconds(Self.snapshotIntervalMs)
        )
        timer.setEventHandler { [weak self, weak running] in
            guard let self, let running else { return }
            let progress = self.render.progress()
            let last = progress.lastRenderNs == 0 ? startedNs : progress.lastRenderNs
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- last) / 1_000_000
            if !running.isRunning || elapsedMs >= UInt64(Self.stallLimitMs) {
                self.finishOnQueue(Self.failedMessage)
                return
            }
            let snapshot = IOSOutputSnapshot.capture(
                capturedUptimeMs: self.clock.nowMs(), decodedChannels: Int(Self.channelCount),
                playoutGlitches: 0, trackGeneration: 1, routeChanges: 0
            )
            .outputSnapshot(backend: OutputSnapshot.localBackend)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.onSnapshot(snapshot)
            }
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// Arms one 10 ms chirp (`click.set(true)`, a single pending flag). Any thread; ignored once ended.
    func playClick() {
        lock.lock()
        let active = !ended && !stopRequested
        lock.unlock()
        if active { render.armClick() }
    }

    /// Stops the probe (user Stop, interruption, noisy route, scene not active); `onEnded` follows once
    /// with `stoppedMessage`. Any thread, never blocks on audio.
    func close() {
        finish(LocalOutputProbe.stoppedMessage)
    }

    /// `true` between `start()` and the end.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !ended && !stopRequested
    }

    // MARK: - Private

    /// Ends exactly once: cancels the timer, removes the observer, stops and detaches the engine, then
    /// posts `onEnded(message)` to the main queue.
    private func finish(_ message: String) {
        lock.lock()
        guard !stopRequested else {
            lock.unlock()
            return
        }
        stopRequested = true
        lock.unlock()
        render.stop()
        // The caller may drop its last reference immediately after close(). Retain until teardown.
        queue.async { [self] in finishOnQueue(message) }
    }

    private func finishOnQueue(_ message: String) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        stopRequested = true
        let runningEngine = engine
        let node = sourceNode
        let snapshotTimer = timer
        let observer = configurationObserver
        engine = nil
        sourceNode = nil
        timer = nil
        configurationObserver = nil
        lock.unlock()

        render.stop()

        snapshotTimer?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let runningEngine {
            runningEngine.stop()
            if let node { runningEngine.detach(node) }
        }
        let callback = onEnded
        DispatchQueue.main.async { callback(message) }
    }
}
