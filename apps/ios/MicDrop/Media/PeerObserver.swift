import Foundation
import WebRTC

/// The session peer's `RTCPeerConnectionDelegate` (Kotlin `observer`, `StreamReceiver.kt:1713-1754`).
///
/// All methods run on the WebRTC signalling thread. Rules: read the closed state first and return if closed; never call
/// blocking WebRTC APIs, dispose, or signal over HTTP from here; only forward to `MediaEngineEvents` (which updates
/// locked state and wakes the worker) and fire the engine's gathered latch. Candidate strings are private data and are
/// only forwarded, never logged.
///
/// The ICE-gathering latch fires even after `close()` (Kotlin counts `gathered` down without a
/// closed check, `StreamReceiver.kt:1726-1728`); every other callback is dropped once closed.
final class PeerObserver: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: MediaEngineEvents?
    private var gatheringComplete: (() -> Void)?

    /// `events` is held strongly until `close()` (the engine closes the observer first in teardown).
    init(events: MediaEngineEvents) {
        self.events = events
        super.init()
    }

    /// Sets the engine's gathered-latch hook (`gathered.countDown()`); called once by `MediaEngine`.
    func setGatheringCompleteHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        gatheringComplete = handler
        lock.unlock()
    }

    /// Stops forwarding (teardown step `peer_dispose`, before `peer.close()`); idempotent.
    func close() {
        lock.lock()
        events = nil
        gatheringComplete = nil
        lock.unlock()
    }

    /// `true` after `close()`.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events == nil
    }

    // MARK: - Labels (host vocabularies)

    /// Android `value.name.lowercase().replaceFirstChar { it.uppercase() }` (`StreamReceiver.kt:1731`):
    /// `New, Connecting, Connected, Disconnected, Failed, Closed` (`report.go:126`).
    static func peerStateLabel(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "New"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        case .closed: return "Closed"
        @unknown default: return "Closed"
        }
    }

    /// Android `value.name.lowercase()` of the legacy ICE state (`StreamReceiver.kt:1717`):
    /// `new, checking, connected, completed, failed, disconnected, closed` (`session.go:57`).
    /// `nil` for `.count` (a sentinel, never a state) and unknown values: the callback is ignored.
    static func iceConnectionLabel(_ state: RTCIceConnectionState) -> String? {
        switch state {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return nil
        @unknown default: return nil
        }
    }

    // MARK: - RTCPeerConnectionDelegate (required)

    @objc(peerConnection:didChangeSignalingState:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        // Ignored (Android `onSignalingChange` is empty).
    }

    @objc(peerConnection:didAddStream:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // Ignored (Android `onAddStream`).
    }

    @objc(peerConnection:didRemoveStream:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        // Ignored (Android `onRemoveStream`).
    }

    @objc(peerConnectionShouldNegotiate:)
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // Ignored (Android `onRenegotiationNeeded`): the host drives every negotiation.
    }

    /// Legacy ICE connection state (do **not** use the standardized variant).
    @objc(peerConnection:didChangeIceConnectionState:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard let label = PeerObserver.iceConnectionLabel(newState), let target = currentEvents() else { return }
        target.iceConnectionChanged(label, connected: newState == .connected || newState == .completed)
    }

    @objc(peerConnection:didChangeIceGatheringState:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.lock()
        let latch = gatheringComplete
        let target = events
        lock.unlock()
        latch?()
        target?.iceGatheringCompleted()
    }

    @objc(peerConnection:didGenerateIceCandidate:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        currentEvents()?.localCandidate(index: candidate.sdpMLineIndex, sdp: candidate.sdp)
    }

    @objc(peerConnection:didRemoveIceCandidates:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        guard let target = currentEvents() else { return }
        target.localCandidatesRemoved(candidates.map { ($0.sdpMLineIndex, $0.sdp) })
    }

    @objc(peerConnection:didOpenDataChannel:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Ignored (Android `onDataChannel`): MicDrop negotiates no data channel.
    }

    // MARK: - RTCPeerConnectionDelegate (optional)

    /// `onConnectionChange`.
    @objc(peerConnection:didChangeConnectionState:)
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        currentEvents()?.peerStateChanged(PeerObserver.peerStateLabel(newState))
    }

    /// `onIceCandidateError`: only `errorCode` is read.
    @objc(peerConnection:didFailToGatherIceCandidate:)
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent
    ) {
        currentEvents()?.candidateError(code: event.errorCode)
    }

    // MARK: - Private

    private func currentEvents() -> MediaEngineEvents? {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
