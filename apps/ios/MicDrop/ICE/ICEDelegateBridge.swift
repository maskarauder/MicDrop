import Foundation
import MicDropCore
import WebRTC

/// Fan-in of the ICE-related `RTCPeerConnectionDelegate` callbacks (Kotlin observer `StreamReceiver.kt:1713-1754`, ICE
/// rows only).
///
/// The media engine's `PeerObserver` or the session's `MediaEngineEvents` adapter forwards the gathering-state,
/// candidate, removal and gathering-error callbacks here, using either the WebRTC-typed or the value-typed entry
/// points. Connection-state rows (`iceConnected`, `peerState`, holds, `peer_failed`) stay in the session.
///
/// Threading: callbacks arrive on the WebRTC signaling thread; the worker reads the evidence buffers and flips the
/// flags. Callbacks only update the locked evidence objects and the gathering signal; they never perform native work,
/// I/O or blocking waits. Private data (candidate strings) never leaves the evidence buffers.
final class ICEDelegateBridge: @unchecked Sendable {

    /// One-shot "gathering complete" latch, recreated per generation (Kotlin `CountDownLatch gathered`,
    /// `StreamReceiver.kt:1590`; `OneShotSignal`). Firing is sticky; waiting is done by the worker only, through
    /// `SessionWorkerWait` so Stop interrupts it. The media engine can implement
    /// `ICEPeerConfiguration.Peer.resetGatheredLatch()` / `waitGathered(timeoutMs:)` as `bridge.resetGatheringSignal()`
    /// / `bridge.gatheringSignal.wait(timeoutMs:worker:)`.
    final class GatheringSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var actions: [@Sendable () -> Void] = []

        init() {}

        /// Count down (`gathered.countDown()`). Idempotent; runs registered actions once, outside the lock.
        func fire() {
            lock.lock()
            if fired {
                lock.unlock()
                return
            }
            fired = true
            let pending = actions
            actions = []
            lock.unlock()
            for action in pending { action() }
        }

        /// Whether `fire()` already happened.
        var isFired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }

        /// Registers `action` to run on `fire()`; runs it immediately (on the caller's thread) when
        /// already fired. Used to complete a `SessionWorkerWait.await` box.
        func onFire(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            if fired {
                lock.unlock()
                action()
                return
            }
            actions.append(action)
            lock.unlock()
        }

        /// `gathered.await(timeoutMs)` inside `workerWait.await { … }` (`StreamReceiver.kt:519,1599`): true once fired,
        /// false when `timeoutMs` elapses first (`timeoutMs <= 0` only reports the current state). Throws
        /// `SessionStopped` when Stop interrupts the wait; the worker checkpoint is re-checked afterwards.
        func wait(timeoutMs: Int, worker: SessionWorkerWait) throws -> Bool {
            try worker.awaitCompletion(timeoutMs: max(0, timeoutMs), orElse: false) {
                (completion: SessionWorkerWait.Completion<Bool>) in
                onFire { completion.succeed(true) }
            }
        }
    }

    /// Continuous-mode callback provenance; fed while `continuousEnabled`.
    let continuousEvidence: ContinuousCandidateEvidence
    /// Non-continuous restart proof; fed while `collectingRecovery`.
    let recoveryEvidence: RecoveryCandidateEvidence
    /// `onIceCandidateError` counter; always fed while not closed.
    let gatheringErrors: IceGatheringErrors

    private let lock = NSLock()
    private var collectingRecoveryValue = false
    private var continuousEnabledValue = false
    private var closedValue = false
    private var signal = GatheringSignal()

    /// The session may pass its own evidence instances (they are thread-safe reference types).
    init(
        continuousEvidence: ContinuousCandidateEvidence = ContinuousCandidateEvidence(),
        recoveryEvidence: RecoveryCandidateEvidence = RecoveryCandidateEvidence(),
        gatheringErrors: IceGatheringErrors = IceGatheringErrors()
    ) {
        self.continuousEvidence = continuousEvidence
        self.recoveryEvidence = recoveryEvidence
        self.gatheringErrors = gatheringErrors
    }

    // MARK: - Flags (Kotlin @Volatile, `StreamReceiver.kt:113-114`)

    /// Kotlin `collectingRecovery`: `!continuous` between the restart offer and the prepared answer.
    var collectingRecovery: Bool {
        get { locked { collectingRecoveryValue } }
        set { locked { collectingRecoveryValue = newValue } }
    }

    /// Kotlin `continuousEnabled`: continuous ICE negotiated for this session. Set before `setLocalDescription` of the
    /// first answer so its callback candidates are proven.
    var continuousEnabled: Bool {
        get { locked { continuousEnabledValue } }
        set { locked { continuousEnabledValue = newValue } }
    }

    /// Session closed (`close()`); later candidate/error callbacks are ignored ("only if not closed"). The gathering
    /// signal still fires (Kotlin counts down unconditionally).
    var isClosed: Bool { locked { closedValue } }

    /// Called from the session's `close(_:)`, never blocks.
    func close() {
        locked { closedValue = true }
    }

    // MARK: - Gathering signal

    /// The current generation's latch.
    var gatheringSignal: GatheringSignal { locked { signal } }

    /// `gathered = CountDownLatch(1)` before applying a restart offer (`StreamReceiver.kt:1590`, "fresh latch created
    /// before applying"). Returns the new latch.
    @discardableResult
    func resetGatheringSignal() -> GatheringSignal {
        let fresh = GatheringSignal()
        locked { signal = fresh }
        return fresh
    }

    // MARK: - WebRTC-typed entry points (PeerObserver)

    /// `peerConnection(_:didChange: RTCIceGatheringState)`: `.complete` fires the current latch.
    func gathering(_ state: RTCIceGatheringState) {
        if state == .complete { gatheringCompleted() }
    }

    /// `peerConnection(_:didGenerate:)`. `candidate.sdp` is `candidate:…` without `a=`.
    func generated(_ candidate: RTCIceCandidate) {
        generated(index: Int(candidate.sdpMLineIndex), sdp: candidate.sdp)
    }

    /// `peerConnection(_:didRemove:)` (index is −1 from the SDK).
    func removed(_ candidates: [RTCIceCandidate]) {
        for candidate in candidates {
            removed(index: Int(candidate.sdpMLineIndex), sdp: candidate.sdp)
        }
    }

    /// `peerConnection(_:didFailToGatherIceCandidate:)`. Only `errorCode` is read; address, URL
    /// and error text are private and never touched.
    func gatheringFailed(_ event: RTCIceCandidateErrorEvent) {
        gatheringFailed(code: Int(event.errorCode))
    }

    // MARK: - Value-typed entry points (MediaEngineEvents)

    /// `onIceGatheringChange(COMPLETE)` → `gathered.countDown()` (no closed check, `StreamReceiver.kt:1726-1728`).
    func gatheringCompleted() {
        gatheringSignal.fire()
    }

    /// `onIceCandidate` (`StreamReceiver.kt:1739-1742`).
    func generated(index: Int, sdp: String) {
        let (closed, recovery, continuous) = locked { (closedValue, collectingRecoveryValue, continuousEnabledValue) }
        guard !closed else { return }
        if recovery { recoveryEvidence.add(index: index, sdp: sdp) }
        if continuous { continuousEvidence.add(index: index, sdp: sdp) }
    }

    /// `onIceCandidatesRemoved`, one candidate (`StreamReceiver.kt:1746-1748`).
    func removed(index: Int, sdp: String) {
        let (closed, continuous) = locked { (closedValue, continuousEnabledValue) }
        guard !closed, continuous else { return }
        continuousEvidence.remove(index: index, sdp: sdp)
    }

    /// `onIceCandidateError` (`StreamReceiver.kt:1743-1745`).
    func gatheringFailed(code: Int) {
        guard !isClosed else { return }
        gatheringErrors.record(code: code)
    }

    // MARK: - `MediaEngineEvents` spellings

    // The session's `EngineEventsBridge` can forward its ICE callbacks one-to-one.

    /// `MediaEngineEvents.iceGatheringCompleted()`.
    func iceGatheringCompleted() {
        gatheringCompleted()
    }

    /// `MediaEngineEvents.localCandidate(index:sdp:)`.
    func localCandidate(index: Int32, sdp: String) {
        generated(index: Int(index), sdp: sdp)
    }

    /// `MediaEngineEvents.localCandidatesRemoved(_:)` (SDK index −1).
    func localCandidatesRemoved(_ candidates: [(Int32, String)]) {
        for (index, sdp) in candidates {
            removed(index: Int(index), sdp: sdp)
        }
    }

    /// `MediaEngineEvents.candidateError(code:)`.
    func candidateError(code: Int32) {
        gatheringFailed(code: Int(code))
    }

    // MARK: - Private

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
