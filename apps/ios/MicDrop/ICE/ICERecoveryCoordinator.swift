import Foundation
import MicDropCore
import WebRTC

/// The paired ICE restart (`restoreLanConnection`, Kotlin `StreamReceiver.kt:1568-1621`): the `restore` and the ICE
/// part of `beforeRestart` passed to `LanRecovery.exchangeStatus` (step 5).
///
/// Worker-owned: synchronous and throwing. Create it after `/offer` (when the session's final `LanRecovery(supported:)`
/// and the ICE `Policy` exist) and after the media engine exists. A lost `/recover-offer` reply retries the same
/// generation; once an answer is prepared (`LanRecovery.answer`), a lost `/recover-answer` reply re-posts it verbatim
/// without new native work (`RecoveryExchangeTest.lostAnswerAcknowledgmentRetriesTheSameGenerationBeforeAnyStatus`).
/// LAN restarts never touch the ICE configuration.
final class ICERecoveryCoordinator {
    /// Status published when a restore starts, with phase RECOVERING.
    static let restoringStatus =
        "Restoring the current media connection. Selected devices and mute settings are retained…"
    /// `/recover-offer` budget cap (`StreamReceiver.kt:1586`).
    static let recoverOfferMaxMs: Int64 = 18_000
    /// Cap for each of setRemote / createAnswer / setLocal (`StreamReceiver.kt:1594-1597`).
    static let descriptionStepMaxMs: Int64 = 5_000
    /// Non-continuous restart gathering wait cap (`StreamReceiver.kt:1599`).
    static let gatheringMaxMs: Int64 = 8_000
    /// `elapsedMs` reported by the restart gathering analysis (`StreamReceiver.kt:1607`).
    static let recoveryElapsedMs: Int64 = 8_000
    /// `/recover-answer` budget cap (`StreamReceiver.kt:1618`).
    static let recoverAnswerMaxMs: Int64 = 5_000

    /// The session's request paths used by a restore.
    struct Signaling {
        /// One ordinary (registered, Stop-cancellable) control request from the worker: the session applies
        /// `ControlRequest.effectiveTimeoutMs` (remote raise/recovery clamp) to the given caller timeout and returns
        /// the parsed 200 body (e.g. via `SessionWorkerWait.sendJSON(_:over:timeoutMs:onStart:)`). throws the signaling
        /// error types.
        var send: (_ request: ControlRequest, _ timeoutMs: Int) throws -> ControlJSON
        /// Remote sessions: refreshed `/v1/ice` credentials (cache refreshed only when < 60 s
        /// remain), e.g. `RemoteICEService.fetchOnWorker`. `nil` for LAN sessions.
        var fetchICE: (() throws -> RemoteICEConfiguration)?

        init(
            send: @escaping (_ request: ControlRequest, _ timeoutMs: Int) throws -> ControlJSON,
            fetchICE: (() throws -> RemoteICEConfiguration)?
        ) {
            self.send = send
            self.fetchICE = fetchICE
        }
    }

    let peer: ICEPeerConfiguration.Peer
    let bridge: ICEDelegateBridge
    let step: StatusICEStep
    let recovery: LanRecovery
    /// Same policy as the initial configuration; only the servers change.
    let policy: ICEPeerConfiguration.Policy
    /// Playback and duplex answers get the Opus stereo edit (`StreamReceiver.kt:1597`).
    let mode: StreamMode
    let isRemote: Bool
    let clock: any MonotonicClock
    /// The session's `closed` flag.
    let isClosed: () -> Bool

    /// Kotlin `recoveryLocalGeneration`: the generation whose restart offer was applied locally.
    private(set) var recoveryLocalGeneration: Int64 = 0
    /// Kotlin `recoveryPreviousLocal`: the local description before the restart offer (private).
    private(set) var recoveryPreviousLocal = ""

    /// `bridge` supplies the restart evidence buffers and the `collectingRecovery` flag; `peer`
    /// supplies the native steps and the gathering latch.
    init(
        peer: ICEPeerConfiguration.Peer, bridge: ICEDelegateBridge, step: StatusICEStep,
        recovery: LanRecovery, policy: ICEPeerConfiguration.Policy, mode: StreamMode, isRemote: Bool,
        clock: any MonotonicClock, isClosed: @escaping () -> Bool
    ) {
        self.peer = peer
        self.bridge = bridge
        self.step = step
        self.recovery = recovery
        self.policy = policy
        self.mode = mode
        self.isRemote = isRemote
        self.clock = clock
        self.isClosed = isClosed
    }

    /// ICE part of `beforeRestart` (step 5): retire the trickle and continuous exchanges and clear continuous evidence
    /// before any later status body. The session also holds and suspends network audio.
    func beforeRestart() {
        step.retire()
    }

    /// `budget(max) = clamp(lanRecovery.remaining(now), 1, max)`.
    func budget(_ maxMs: Int64) -> Int {
        Int(clamping: min(max(recovery.remaining(clock.nowMs()), 1), maxMs))
    }

    /// `restore` for `LanRecovery.generation` (`StreamReceiver.kt:1568-1621`). `session` is the `/offer` session
    /// bearer; `onRestoring` publishes phase RECOVERING and `restoringStatus`. Returns early (no error) when closed or
    /// the window expired. Errors: request/ICE-service errors propagate (retryable or fatal); a rejected configuration,
    /// a malformed reply, stale credentials or an invalid restart offer are `ICEProtocolError` / `ControlResponseError`
    /// (fatal); missing restart candidates are `RecoveryTimeout.candidatesUnavailable` (retryable; the next round waits
    /// again).
    func restore(session: String, signaling: Signaling, onRestoring: () -> Void) throws {
        if isClosed() || recovery.expired(clock.nowMs()) { return }
        onRestoring()
        let generation = recovery.generation
        if recovery.answer == nil {
            if recoveryLocalGeneration != generation {
                if isRemote {
                    guard let fetchICE = signaling.fetchICE else {
                        throw ICEProtocolError("Remote ICE service unavailable")
                    }
                    let servers = try fetchICE()
                    guard peer.setConfiguration(ICEPeerConfiguration.make(servers: servers.servers, policy: policy))
                    else {
                        throw ICEProtocolError("ICE configuration rejected")
                    }
                }
                let offer = try signaling.send(
                    ControlRequest.recoverOffer(session: session, generation: generation),
                    budget(Self.recoverOfferMaxMs))
                guard try offer.requireInt("version") == 3, try offer.requireInt64("generation") == generation else {
                    throw ICEProtocolError("Invalid recovery offer")
                }
                let description = try offer.requireString("sdp")
                guard OpusSdp.acceptsRecoveryOfferDescription(description) else {
                    throw ICEProtocolError("Invalid recovery offer")
                }
                if isClosed() || recovery.expired(clock.nowMs()) { return }
                peer.resetGatheredLatch()
                recoveryPreviousLocal = try Self.localDescription(peer)
                bridge.recoveryEvidence.clear()
                bridge.collectingRecovery = !policy.continuous
                bridge.continuousEvidence.clear()
                try step.beginGeneration(remoteOffer: description, generation: generation)
                try peer.applyOffer(description, timeoutMs: budget(Self.descriptionStepMaxMs))
                if isClosed() { return }
                let answer = try peer.createAnswer(timeoutMs: budget(Self.descriptionStepMaxMs))
                let local = try OpusSdp.localAnswer(answer, mode: mode)
                try peer.setLocalAnswer(local, timeoutMs: budget(Self.descriptionStepMaxMs))
                recoveryLocalGeneration = generation
            }
            let complete =
                try !policy.continuous
                && peer.waitGathered(timeoutMs: budget(Self.gatheringMaxMs))
                && peer.iceGatheringComplete
            let description = try Self.localDescription(peer)
            if policy.continuous {
                guard IceGatheringAnalyzer.freshCredentials(description, previous: recoveryPreviousLocal) else {
                    throw ICEProtocolError.credentialsNotRenewed
                }
                recovery.answer = ContinuousExchange.withoutCandidates(description)
            } else {
                let gathering = IceGatheringAnalyzer.recovery(
                    description, previous: recoveryPreviousLocal,
                    complete: complete, remote: isRemote,
                    relayOnly: policy.forceRelay,
                    elapsedMs: Self.recoveryElapsedMs,
                    evidence: bridge.recoveryEvidence.snapshot())
                guard gathering.canSubmit else { throw RecoveryTimeout.candidatesUnavailable }
                recovery.answer = description
            }
            bridge.collectingRecovery = false
            bridge.recoveryEvidence.clear()
        }
        if isClosed() || recovery.expired(clock.nowMs()) { return }
        guard let answer = recovery.answer else { throw ICEProtocolError("Recovery answer unavailable") }
        let acknowledgment = try signaling.send(
            ControlRequest.recoverAnswer(session: session, generation: generation, sdp: answer),
            budget(Self.recoverAnswerMaxMs))
        guard acknowledgment.bool("ok"), try acknowledgment.requireInt64("generation") == generation else {
            throw ICEProtocolError("Invalid recovery acknowledgment")
        }
        try recovery.accepted(clock.nowMs())
    }

    /// `pc.localDescription!!.description` (Kotlin NPE → `SETUP_FAILED`).
    private static func localDescription(_ peer: ICEPeerConfiguration.Peer) throws -> String {
        guard let sdp = peer.localDescription else { throw ICEProtocolError("Local ICE description unavailable") }
        return sdp
    }
}
