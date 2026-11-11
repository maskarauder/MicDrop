import Foundation
import WebRTC

/// The local sample gates of one session, applied off-thread (Kotlin `audio.setSpeakerMute` / `setMicrophoneMute` /
/// `microphoneTrack.setEnabled`).
///
/// iOS equivalents: speaker mute = `isEnabled = !muted` on the `RTCAudioTrack` of **every** audio receiver (playback
/// sessions have two receivers, the ADM keeps pulling NetEq and the unit keeps running, which also keeps the app alive
/// in the background); microphone gate = the local `phone-microphone` track's `isEnabled` (the send stream transmits
/// silence while disabled).
///
/// `RTCMediaStreamTrack.isEnabled` is a **blocking** proxy call to the signalling thread, so: requests only record the
/// desired value under a private lock and enqueue an apply block on the private serial queue `MicDrop.audioGates`,
/// which coalesces to the latest values (generation counter) and calls `isEnabled` without holding any lock. Requests
/// therefore never block and may be made from any thread, including under the session's audio lock and from WebRTC
/// callbacks. `closeAll()` / `applyFinalSynchronously()` make the closed state sticky ("Stop wins over any late
/// enable").
final class AudioGateApplier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MicDrop.audioGates")
    private let lock = NSLock()
    // Guarded by `lock`.
    private var speakerMutedValue: Bool
    private var microphoneOpenValue = false
    private var closed = false
    private var generation: UInt64 = 0
    private var receiverTracks: [RTCAudioTrack] = []
    private var microphoneTrack: RTCAudioTrack?

    /// `speakerMuted`: initial remote playout gate (`module.setSpeakerMute(speakerMuted)`, `StreamReceiver.kt:446`).
    /// The microphone gate always starts closed.
    init(speakerMuted: Bool) {
        speakerMutedValue = speakerMuted
    }

    // MARK: - Desired state (any thread)

    /// Effective speaker mute (desired value, or muted once closed).
    var speakerMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return speakerMutedValue || closed
    }

    /// Effective microphone gate (desired value, closed once closed).
    var microphoneOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return microphoneOpenValue && !closed
    }

    /// Remote playout gate (`setSpeakerMute`). Ignored after `closeAll()`.
    func setSpeakerMuted(_ muted: Bool) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        speakerMutedValue = muted
        lock.unlock()
        schedule()
    }

    /// Microphone sample gate. Closing is always honoured; opening is ignored after `closeAll()`. Only the session
    /// worker reopens the gate, after verification and the host-gate acknowledgement (final step).
    func setMicrophoneOpen(_ open: Bool) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        microphoneOpenValue = open
        lock.unlock()
        schedule()
    }

    /// Session `close()` (`StreamReceiver.kt:315-336`): sticky speaker mute and microphone gate closed, applied
    /// asynchronously; never blocks.
    func closeAll() {
        lock.lock()
        closed = true
        lock.unlock()
        schedule()
    }

    // MARK: - Targets and teardown (session worker only)

    /// Replaces the gated tracks (after `addTransceiver`, after `setRemoteDescription` — a new receiver appears — and
    /// after the microphone track is attached) and re-applies the current values. A disabled state set before the
    /// receive stream exists is honoured by the SDK.
    func setTargets(receiverTracks: [RTCAudioTrack], microphoneTrack: RTCAudioTrack?) {
        lock.lock()
        self.receiverTracks = receiverTracks
        self.microphoneTrack = microphoneTrack
        lock.unlock()
        schedule()
    }

    /// Teardown (step 3): sticky closed state, then applies the final mute synchronously on the gate queue (serialised
    /// behind any pending apply). Worker only — never call from the gate queue, the main thread or a WebRTC callback.
    func applyFinalSynchronously() {
        lock.lock()
        closed = true
        generation &+= 1
        lock.unlock()
        queue.sync { self.apply(generation: nil) }
    }

    /// Drops every track reference (teardown step `peer_dispose`, after the final mute), so no stale
    /// wrapper outlives the peer. Worker only.
    func clearTargets() {
        queue.sync {
            self.lock.lock()
            self.receiverTracks = []
            self.microphoneTrack = nil
            self.lock.unlock()
        }
    }

    // MARK: - Private

    private func schedule() {
        lock.lock()
        generation &+= 1
        let current = generation
        lock.unlock()
        queue.async { [weak self] in self?.apply(generation: current) }
    }

    /// Applies the latest values; a block whose generation is stale returns (a newer block follows).
    /// `nil` generation = unconditional (final apply).
    private func apply(generation expected: UInt64?) {
        lock.lock()
        if let expected, expected != generation {
            lock.unlock()
            return
        }
        let tracks = receiverTracks
        let microphone = microphoneTrack
        let playoutEnabled = !(speakerMutedValue || closed)
        let microphoneEnabled = microphoneOpenValue && !closed
        lock.unlock()
        for track in tracks { track.isEnabled = playoutEnabled }
        microphone?.isEnabled = microphoneEnabled
    }
}
