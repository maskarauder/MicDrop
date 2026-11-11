import Foundation
import MicDropCore

/// Initial ICE gathering before `/answer` (stage ROUTES; steps 3-7, Kotlin `StreamReceiver.kt:515-540`).
///
/// Runs on the session worker right after `setLocalAnswer` returned. It never rewrites the SDK description: the answer
/// it returns is exactly `peer.localDescription` (continuous sessions submit `ContinuousExchange.withoutCandidates` of
/// it).
///
/// Timing outcomes (table): LAN waits for completion (≤ 15 s); remote without trickle accepts a usable partial set at
/// the deadline; forced relay with exactly one `turn:…?transport=udp` polls every 50 ms and submits once a usable relay
/// set persisted 500 ms; trickle/continuous submit at once with result `trickle`.
enum InitialGathering {
    /// Gathering deadline after `setLocalDescription` returned (`StreamReceiver.kt:518`).
    static let deadlineMs: Int64 = 15_000
    /// Fast-relay poll interval (`StreamReceiver.kt:535`).
    static let fastRelayPollMs: Int64 = 50

    /// The frozen initial gathering result and the exact SDK answer it analysed.
    struct Outcome: Sendable {
        /// `initialGathering` (kept for the terminal report even when not submittable, step 7).
        let snapshot: IceGatheringSnapshot
        /// `pc.localDescription!.sdp` read in the deciding iteration (private data).
        let localAnswer: String

        /// `/answer` SDP (`StreamReceiver.kt:542-543`): continuous → candidate-free description; trickle and legacy →
        /// the exact analysed description.
        func answerBody(continuous: Bool) -> String {
            continuous ? ContinuousExchange.withoutCandidates(localAnswer) : localAnswer
        }

        /// `includeIceGathering = initialGathering.canReport(ice_gathering_diagnostics_version)` (step 6,
        /// `StreamReceiver.kt:539`).
        func includeInReports(diagnosticsVersion: Int) -> Bool {
            snapshot.canReport(to: diagnosticsVersion)
        }

        /// step 7: a non-submittable result is a stage timeout (Kotlin `TimeoutException`, `StreamReceiver.kt:540`) →
        /// "Gathering local network routes failed [TIMEOUT]." / `stage_timeout` (`StageTimeoutError`, not retryable).
        func requireSubmittable() throws {
            guard snapshot.canSubmit else { throw StageTimeoutError("ice_gathering") }
        }
    }

    /// steps 3-5. `gatheringStartedMs` is the monotonic time taken before `setLocalDescription` (step 4); the 15 s
    /// deadline is computed at entry. `serverURLs` are the URLs passed to the peer (`ICEPeerConfiguration.serverURLs`);
    /// `errors` is the gathering-error snapshot (`IceGatheringErrors.snapshot`); `checkpoint` is the worker's
    /// `SessionWorkerWait.checkpoint` (Stop → `SessionStopped`, checked every iteration). A missing local description
    /// throws `ICEProtocolError` (Kotlin `requireNotNull` → `SETUP_FAILED`).
    static func run(
        peer: ICEPeerConfiguration.Peer, clock: any MonotonicClock, gatheringStartedMs: Int64,
        isRemote: Bool, forceRelay: Bool, useTrickle: Bool, serverURLs: [String],
        errors: () -> (count: Int, lastCode: Int),
        checkpoint: () throws -> Void, timeoutMs: Int64 = InitialGathering.deadlineMs
    ) throws -> Outcome {
        let fastRelay = InitialRelayGathering.eligible(relayOnly: forceRelay, urls: serverURLs)
        var early = InitialRelayGathering(enabled: fastRelay)
        let deadline = clock.nowMs() + timeoutMs
        if !fastRelay && !useTrickle {
            _ = try peer.waitGathered(timeoutMs: Int(timeoutMs))
        }
        while true {
            try checkpoint()
            // Read completion before the description (`StreamReceiver.kt:524-525`); analyse and
            // submit the exact same SDK description, nothing relaxed for early submission.
            let complete = peer.iceGatheringComplete
            guard let localAnswer = peer.localDescription else {
                throw ICEProtocolError("Local ICE description unavailable")
            }
            let now = clock.nowMs()
            let snapshot = IceGatheringAnalyzer.initial(
                localAnswer, complete: complete, remote: isRemote,
                relayOnly: forceRelay,
                elapsedMs: now - gatheringStartedMs,
                errors: errors())
            let ready = !complete && now < deadline && early.ready(usable: snapshot.canSubmit, nowMs: now)
            if useTrickle || !fastRelay || complete || now >= deadline || ready {
                let result =
                    useTrickle
                    ? snapshot.with(result: "trickle")
                    : ready ? snapshot.with(result: "candidates_ready") : snapshot
                return Outcome(snapshot: result, localAnswer: localAnswer)
            }
            let waitMs = fastRelay ? min(fastRelayPollMs, deadline - now) : deadline - now
            _ = try peer.waitGathered(timeoutMs: Int(clamping: waitMs))
        }
    }

    /// Convenience: errors from an `ICEDelegateBridge`, checkpoint from the session's
    /// `SessionWorkerWait`.
    static func run(
        peer: ICEPeerConfiguration.Peer, bridge: ICEDelegateBridge, worker: SessionWorkerWait,
        clock: any MonotonicClock, gatheringStartedMs: Int64, isRemote: Bool, forceRelay: Bool,
        useTrickle: Bool, serverURLs: [String]
    ) throws -> Outcome {
        try run(
            peer: peer, clock: clock, gatheringStartedMs: gatheringStartedMs, isRemote: isRemote,
            forceRelay: forceRelay, useTrickle: useTrickle, serverURLs: serverURLs,
            errors: { bridge.gatheringErrors.snapshot() },
            checkpoint: { try worker.checkpoint() })
    }
}
