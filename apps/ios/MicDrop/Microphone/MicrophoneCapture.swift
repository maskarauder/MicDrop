import AVFoundation
import Foundation
import MicDropCore
import WebRTC

/// Capture primitives of one microphone session: the one-time input initialisation, the local sample gate, and
/// stop/start of the ADM input bus.
///
/// Android → iOS:
/// - `audio.setMicrophoneMute` + `microphoneTrack.setEnabled` → `closeSampleGate()`/`openSampleGate()`
/// = `engine.setMicrophoneSampleGate(open:)` (track `isEnabled`, applied on the engine's gate queue) **and**
/// `AVAudioApplication.shared.setInputMuted(_:)`. Close is synchronous from any thread (callers hold the session audio
/// lock); open only at final step.
/// - `connection.setAudioRecording(false/true)` → `pause()`/`resume()` =
/// `engine.setCaptureRunning(_:)` (`factory.runOnWorker { adm.pauseRecording()/resumeRecording() }`). Each call
/// re-initialises the audio unit (brief playout glitch in duplex); `pause()` skips the worker hop when capture is not
/// running (last bullet).
/// - `setPreferredInputDevice` lives in `MicrophoneRouting.setPreferredInput(_:)` (arbiter).
///
/// Order: `InputInitialization.request()` at stage AUDIO (before the ADM/factory exist); the first `resume()` only
/// after `inputInitialization == .succeeded` (the worker waits inside the 2000/5000 ms verification deadline);
/// `resumeRecording < 0` → `CaptureError.startFailed`. `captureActive` (Android `recordStarted`) is true after a 0
/// return and false after `pause()`, teardown or `detach()`. Never reads or retains PCM.
///
/// The engine is held weakly so this object can never delay factory/ADM deallocation (a late dealloc makes the next
/// session's `initializeInput` fail as a duplicate).
final class MicrophoneCapture: @unchecked Sendable {
    /// Capture failures mapped by the worker (table, iOS additions).
    enum CaptureError: Error, Equatable, Sendable {
        /// `setInitialMicrophoneMute(true)` returned false: a previous unit lifetime still holds
        /// input (`microphone_init`).
        case initialMuteRejected
        /// `initializeInput` completed with an error (`microphone_init`).
        case inputInitializationFailed
        /// `resume()` before the input initialisation succeeded (programming error; `microphone_start`).
        case inputNotInitialized
        /// `resumeRecording()` returned a negative value (`microphone_start`).
        case startFailed(code: Int)
        /// No engine attached yet or already detached.
        case engineUnavailable
    }

    /// The two engine primitives capture needs (`MediaEngine` names). `MediaEngine` conforms in
    /// `MicrophoneLiveWiring.swift`; `WebRTCEngine` is the direct WebRTC fallback.
    protocol Engine: AnyObject {
        /// Microphone track `isEnabled` (send stream silent while false); non-blocking, coalesced.
        func setMicrophoneSampleGate(open: Bool)
        /// `factory.runOnWorker { running ? adm.resumeRecording() : adm.pauseRecording() }`; 0 = success
        /// or no-op, negative = failure.
        func setCaptureRunning(_ running: Bool) -> Int
    }

    private let lock = NSLock()
    private weak var engine: Engine?
    private var active = false
    private var gateOpen = false

    /// One-time input initialisation of this session (shared with the engine at stage AUDIO).
    let input: InputInitialization

    init(input: InputInitialization) {
        self.input = input
    }

    /// Attaches the session's engine once it exists (after stage AUDIO created ADM/factory/track).
    func attach(_ engine: Engine) {
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    /// Drops the engine reference (teardown, after `audio_recording_stop`); later calls are no-ops.
    func detach() {
        lock.lock()
        engine = nil
        active = false
        lock.unlock()
    }

    /// Android `recordStarted`.
    var captureActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Whether the local sample gate is currently open (diagnostics/tests).
    var sampleGateOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gateOpen
    }

    /// `input.state`.
    var inputInitialization: InputInitialization.State { input.state }

    /// Local sample gate closed: track disabled + `setInputMuted(true)`. Any thread, never blocks.
    func closeSampleGate() {
        lock.lock()
        gateOpen = false
        let engine = self.engine
        lock.unlock()
        engine?.setMicrophoneSampleGate(open: false)
        MicrophoneCapture.setApplicationInputMuted(true)
    }

    /// Local sample gate open: `setInputMuted(false)` + track enabled — only from final, lock-checked step.
    func openSampleGate() {
        MicrophoneCapture.setApplicationInputMuted(false)
        lock.lock()
        gateOpen = true
        let engine = self.engine
        lock.unlock()
        engine?.setMicrophoneSampleGate(open: true)
    }

    /// `setAudioRecording(false)`: no-op (returns 0) when capture is not running; otherwise
    /// `engine.setCaptureRunning(false)` and `captureActive = false` regardless of the result.
    @discardableResult
    func pause() -> Int {
        lock.lock()
        guard active else {
            lock.unlock()
            return 0
        }
        active = false
        let engine = self.engine
        lock.unlock()
        return engine?.setCaptureRunning(false) ?? 0
    }

    /// `setAudioRecording(true)`: requires `input.state == .succeeded` (else `.inputNotInitialized`, or
    /// `.inputInitializationFailed` when it failed); no-op when already running (keep-alive); `setCaptureRunning(true)
    /// < 0` → `.startFailed(code)`; success → `captureActive = true`.
    func resume() throws {
        switch input.state {
        case .succeeded:
            break
        case .failed:
            throw CaptureError.inputInitializationFailed
        case .notRequested, .pending:
            throw CaptureError.inputNotInitialized
        }
        lock.lock()
        if active {
            lock.unlock()
            return
        }
        let engine = self.engine
        lock.unlock()
        guard let engine else { throw CaptureError.engineUnavailable }
        let code = engine.setCaptureRunning(true)
        if code < 0 { throw CaptureError.startFailed(code: code) }
        lock.lock()
        active = true
        lock.unlock()
    }

    /// `AVAudioApplication.shared.setInputMuted(_:)` (app-wide, persistent). Called with `false` at launch, before
    /// `initializeInput`, in `microphone_route_close`, and at the final gate open; with `true` on every gate close.
    /// Returns false when iOS rejected it (the track gate and the host gate remain the backstop).
    @discardableResult
    static func setApplicationInputMuted(_ muted: Bool) -> Bool {
        do {
            try AVAudioApplication.shared.setInputMuted(muted)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Input initialisation

extension MicrophoneCapture {
    /// `RTCAudioSession.setInitialMicrophoneMute(true)` + `initializeInput` (step 1), exactly once per ADM lifetime and
    /// only for microphone modes. The completion arrives on the main queue; `discard()` (session ended) makes late
    /// completions irrelevant. An engine that performs the request itself feeds its completion through `complete(_:)`.
    final class InputInitialization: @unchecked Sendable {
        enum State: Equatable, Sendable {
            case notRequested
            case pending
            case succeeded
            case failed
        }

        private let lock = NSLock()
        private var current: State = .notRequested
        private var discarded = false

        init() {}

        var state: State {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        /// Stage AUDIO, before the ADM is created: `setApplicationInputMuted(false)`, then
        /// `setInitialMicrophoneMute(true)` (false → `.failed` + `CaptureError.initialMuteRejected`), then
        /// `initializeInput { complete($0) }`. Idempotent: a second call (or one after `discard()`) does nothing,
        /// because the patch would complete a duplicate request immediately with
        /// `kRTCAudioSessionErrorInputInitialization`.
        func request(audioSession: RTCAudioSession = RTCAudioSession.sharedInstance()) throws {
            lock.lock()
            guard current == .notRequested, !discarded else {
                lock.unlock()
                return
            }
            current = .pending
            lock.unlock()
            MicrophoneCapture.setApplicationInputMuted(false)
            guard audioSession.setInitialMicrophoneMute(true) else {
                lock.lock()
                current = .failed
                lock.unlock()
                throw CaptureError.initialMuteRejected
            }
            audioSession.initializeInput { [weak self] error in
                self?.complete(error)
            }
        }

        /// Records the `initializeInput` completion: nil → `.succeeded`, error → `.failed`; ignored after
        /// `discard()` or when not pending.
        func complete(_ error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            guard !discarded, current == .pending || current == .notRequested else { return }
            current = error == nil ? .succeeded : .failed
        }

        /// Session ended: later completions are ignored (the ADM's `Terminate()` cancels a pending request).
        func discard() {
            lock.lock()
            discarded = true
            lock.unlock()
        }
    }
}

// MARK: - Direct WebRTC engine

extension MicrophoneCapture {
    /// `Engine` over the raw WebRTC objects of one session, for callers that do not route capture through
    /// `MediaEngine`. Track gating runs on a private serial queue coalesced to the latest value (`isEnabled` is a
    /// blocking proxy to the signalling thread); recording calls hop to the WebRTC worker with `runOnWorker` (Shiguredo
    /// `ios_audio_pause_resume.patch`).
    final class WebRTCEngine: Engine, @unchecked Sendable {
        private let factory: RTCPeerConnectionFactory
        private let adm: RTCAudioDeviceModule
        private let track: RTCAudioTrack
        private let queue = DispatchQueue(label: "MicDrop.microphoneGate")
        private let lock = NSLock()
        private var generation = 0

        init(factory: RTCPeerConnectionFactory, adm: RTCAudioDeviceModule, track: RTCAudioTrack) {
            self.factory = factory
            self.adm = adm
            self.track = track
        }

        func setMicrophoneSampleGate(open: Bool) {
            lock.lock()
            generation += 1
            let current = generation
            lock.unlock()
            let track = self.track
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let latest = self.generation == current
                self.lock.unlock()
                if latest { track.isEnabled = open }
            }
        }

        func setCaptureRunning(_ running: Bool) -> Int {
            let adm = self.adm
            return factory.run(onWorker: { running ? adm.resumeRecording() : adm.pauseRecording() })
        }
    }
}
