import Foundation
import MicDropCore

/// Paired ICE restart and ICE envelope acceptance (`StreamReceiver.kt:1568-1646`).
extension SessionController {

    /// `budget(max) = clamp(lanRecovery.remaining(now), 1, max)` (`StreamReceiver.kt:1569`).
    func recoveryBudget(_ maximumMs: Int64) throws -> Int {
        try operationBudget(Int(clamping: maximumMs))
    }

    /// `beforeRestart` (`StreamReceiver.kt:610-614`): retire old trickle credentials before any later status body,
    /// retire continuous ICE and its candidate evidence, hold and suspend network audio.
    func retireICEBeforeRestart() {
        trickle = nil
        continuous = nil
        continuousCandidates.clear()
        holdNetworkAudio()
        suspendNetworkAudio()
    }

    /// `restoreLanConnection` (`StreamReceiver.kt:1651-1710`). A lost `/recover-answer` reply is retried with the same
    /// generation and the same prepared SDP (no new native work); `retrySignaling` already restored the configured
    /// recovery route before every retry.
    func restoreLanConnection() throws {
        if isClosed || lanRecovery.expired(nowMs()) { return }
        emitPhase(.recovering)
        emitStatus(Messages.restoringMediaConnection)
        guard let engine else { throw ProtocolViolation("media engine unavailable") }
        let generation = lanRecovery.generation
        if lanRecovery.answer == nil {
            if recoveryLocalGeneration != generation {
                if let refreshed = try fetchRemoteICEConfiguration() {
                    guard engine.setConfiguration(iceServers: refreshed.servers) else {
                        throw ICEProtocolError("ICE configuration rejected")
                    }
                    iceConfiguration = refreshed
                }
                let offer = try request(
                    "/recover-offer", token: requireSessionToken(),
                    body: WireBody.object([("version", .int(3)), ("generation", .int64(generation))]),
                    timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryOffer])))
                guard try offer.requireInt("version") == 3, try offer.requireInt64("generation") == generation else {
                    throw ICEProtocolError("Invalid recovery offer")
                }
                let description = try offer.requireString("sdp")
                guard OpusSdp.acceptsRecoveryOfferDescription(description) else { throw ICEProtocolError.invalidUpdate }
                if isClosed || lanRecovery.expired(nowMs()) { return }
                engine.resetGatheredLatch()
                guard let previous = engine.localDescription else { throw ICEProtocolError.missingUpdate }
                recoveryPreviousLocal = previous
                recoveryCandidates.clear()
                collectingRecoveryFlag.value = !continuousEnabledFlag.value
                continuousCandidates.clear()
                if continuousEnabledFlag.value {
                    continuous = try ContinuousExchange(
                        remoteDescription: description, relayOnly: configuration.forceRelay, generation: generation)
                }
                try engine.applyOffer(
                    description, timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryAnswer])))
                try workerWait.checkpoint()
                let answer = try engine.createAnswer(
                    timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryAnswer])))
                let local = try engine.localAnswer(for: answer, checkDirection: false)
                try engine.setLocalAnswer(
                    local, timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryAnswer])))
                recoveryLocalGeneration = generation
            }
            let complete =
                try !continuousEnabledFlag.value
                && engine.waitGathered(
                    timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryICE])))
                && engine.iceGatheringComplete
            guard let description = engine.localDescription else { throw ICEProtocolError.missingUpdate }
            if continuousEnabledFlag.value {
                guard IceGatheringAnalyzer.freshCredentials(description, previous: recoveryPreviousLocal) else {
                    throw ICEProtocolError.credentialsNotRenewed
                }
                lanRecovery.answer = ContinuousExchange.withoutCandidates(description)
            } else {
                let gathering = IceGatheringAnalyzer.recovery(
                    description, previous: recoveryPreviousLocal, complete: complete, remote: isRemote,
                    relayOnly: configuration.forceRelay, elapsedMs: Timing.recoveryGatheringMaxMs,
                    evidence: recoveryCandidates.snapshot())
                guard gathering.canSubmit else { throw RecoveryTimeout.candidatesUnavailable }
                lanRecovery.answer = description
            }
            collectingRecoveryFlag.value = false
            recoveryCandidates.clear()
        }
        if isClosed || lanRecovery.expired(nowMs()) { return }
        guard let answer = lanRecovery.answer else { throw ICEProtocolError.missingUpdate }
        let acknowledgment = try request(
            "/recover-answer", token: requireSessionToken(),
            body: WireBody.object([("version", .int(3)), ("generation", .int64(generation)), ("sdp", .string(answer))]),
            timeoutMs: recoveryBudget(Int64(configuration.connectionPreferences[.recoveryAnswer])))
        guard acknowledgment.bool("ok"), try acknowledgment.requireInt64("generation") == generation else {
            throw ICEProtocolError("Invalid recovery acknowledgment")
        }
        try lanRecovery.accepted(nowMs())
    }

    /// `acceptTrickle` (`StreamReceiver.kt:1623-1633`): version 1, generation 0, ≤ 16 candidates, each
    /// `{mid,index,ufrag,candidate}`; candidates applied with `engine.addIceCandidate`. Violations are non-retryable
    /// (session failure).
    func acceptTrickle(_ update: ControlJSON) throws {
        guard let trickle, let engine else { throw ICEProtocolError.missingUpdate }
        let delta: TrickleExchange.Delta
        do { delta = try JSONDecoder().decode(TrickleExchange.Delta.self, from: update.encoded()) } catch {
            throw ICEProtocolError.invalidUpdate
        }
        try TrickleExchange.validateIncoming(delta)
        try trickle.accept(delta) { candidate in
            try self.workerWait.checkpoint()
            return engine.addIceCandidate(
                mid: candidate.mid, index: Int32(candidate.index), sdp: candidate.candidate,
                timeoutMs: StatusICEStep.candidateApplyTimeoutMs)
        }
    }

    /// `acceptContinuous` (`StreamReceiver.kt:1635-1646`): ≤ 64 candidates; add via `engine.addIceCandidate`, remove
    /// via `engine.removeIceCandidates` (always succeeds).
    func acceptContinuous(_ update: ControlJSON) throws {
        guard let continuous, let engine else { throw ICEProtocolError.missingUpdate }
        let snapshot: ContinuousExchange.Snapshot
        do { snapshot = try JSONDecoder().decode(ContinuousExchange.Snapshot.self, from: update.encoded()) } catch {
            throw ICEProtocolError.invalidUpdate
        }
        try ContinuousExchange.validateIncoming(snapshot)
        try continuous.accept(
            snapshot,
            add: { candidate in
                try self.workerWait.checkpoint()
                return engine.addIceCandidate(
                    mid: candidate.mid, index: Int32(candidate.index), sdp: candidate.candidate,
                    timeoutMs: StatusICEStep.candidateApplyTimeoutMs)
            },
            remove: { candidate in
                try self.workerWait.checkpoint()
                engine.removeIceCandidates([
                    (mid: candidate.mid, index: Int32(candidate.index), sdp: candidate.candidate)
                ])
                return true
            })
    }
}
