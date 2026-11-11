import Foundation
import MicDropCore

/// The ICE parts of one `/status` round (steps 5 and 7; Kotlin `StreamReceiver.kt:620-633`, `:658-659`,
/// `acceptTrickle`/`acceptContinuous` `:1622-1647`) and the owner of the session's trickle / continuous exchange state
/// (`beforeRestart`).
///
/// Worker-owned: every member is called on the session worker only; the exchanges are the synchronous types. `outgoing`
/// must be called inside `LanRecovery.exchangeStatus`'s `poll` (after any restore) so a pre-restart delta never
/// accompanies the confirmation poll.
final class StatusICEStep {
    /// Upper bound for one native `addIceCandidate` completion. Android's call is synchronous (adds no timeout); iOS
    /// bounds the completion wait so a lost completion cannot hold the worker past the host's 35 s heartbeat. A timeout
    /// is a rejected candidate (fatal), like Android's `false`.
    static let candidateApplyTimeoutMs = 8_000

    /// decision code (`StreamReceiver.kt:392-393`).
    struct Negotiation: Equatable, Sendable {
        /// `invitation.isRemote && invitation.version == 3 && offer.trickle_ice_version == 1`.
        let useTrickle: Bool
        /// `useTrickle && offer.continuous_ice_version == 1`.
        let continuous: Bool

        init(useTrickle: Bool, continuous: Bool) {
            self.useTrickle = useTrickle
            self.continuous = useTrickle && continuous
        }

        /// Offer integers are read leniently (missing/non-integer → 0, `optInt`).
        init(isRemote: Bool, invitationVersion: Int, trickleVersion: Int, continuousVersion: Int) {
            let trickle = isRemote && invitationVersion == 3 && trickleVersion == 1
            self.init(useTrickle: trickle, continuous: trickle && continuousVersion == 1)
        }

        /// No trickle (LAN, legacy remote host).
        static let disabled = Negotiation(useTrickle: false, continuous: false)
    }

    /// The ICE members of one outgoing `/status` body. `StatusBody` (03) encodes them as `"ice"` / `"continuous_ice"`
    /// via `Delta.json()` / `Snapshot.json()`; when either is present the body is a POST even without a report. A
    /// rejected report is retried once without it but with these exact members (`ReportDelivery.exchangeStatus`); any
    /// HTTP error of a body without a report, or of that retry, is handled by the session's status-failure rules.
    struct Outgoing: Sendable {
        let ice: TrickleExchange.Delta?
        let continuousICE: ContinuousExchange.Snapshot?

        init(ice: TrickleExchange.Delta?, continuousICE: ContinuousExchange.Snapshot?) {
            self.ice = ice
            self.continuousICE = continuousICE
        }

        static let empty = Outgoing(ice: nil, continuousICE: nil)

        /// Neither member: a report-rejection fallback is a body-less `GET /status`; otherwise it is a POST
        /// carrying the same members (`A/PlaybackReport.kt:85-96`).
        var isEmpty: Bool { ice == nil && continuousICE == nil }
    }

    let negotiation: Negotiation
    /// `invitation.remote?.forceRelay == true`: received and local candidates must be `relay`.
    let relayOnly: Bool
    /// Delegate fan-in; its continuous evidence filters the local description.
    let bridge: ICEDelegateBridge

    /// Generation-0 trickle exchange; retired by the first restart and never recreated (notes).
    private(set) var trickle: TrickleExchange?
    /// Continuous exchange of the current generation (nil between `retire()` and the restart offer).
    private(set) var continuous: ContinuousExchange?

    /// Sets `bridge.continuousEnabled` to the negotiated mode so callback candidates are proven from
    /// the first answer on.
    init(negotiation: Negotiation, relayOnly: Bool, bridge: ICEDelegateBridge) {
        self.negotiation = negotiation
        self.relayOnly = relayOnly
        self.bridge = bridge
        bridge.continuousEnabled = negotiation.continuous
    }

    /// After the offer: continuous → `ContinuousExchange(remote: offer, relayOnly, generation: 0)`; else trickle →
    /// `TrickleExchange(remote: offer, relayOnly)`; else nothing. An invalid offer description throws
    /// (`ICEProtocolError`, fatal `SETUP_FAILED`).
    func start(remoteOffer: String) throws {
        if negotiation.continuous {
            continuous = try ContinuousExchange(remoteDescription: remoteOffer, relayOnly: relayOnly, generation: 0)
        } else if negotiation.useTrickle {
            trickle = try TrickleExchange(remoteDescription: remoteOffer, relayOnly: relayOnly)
        }
    }

    /// `beforeRestart` ICE part (step 5, `StreamReceiver.kt:610-613`): retire the old credentials before any later
    /// status body — `trickle = nil`, `continuous = nil`, `continuousEvidence.clear()`. The session also holds and
    /// suspends network audio.
    func retire() {
        trickle = nil
        continuous = nil
        bridge.continuousEvidence.clear()
    }

    /// Restart (`StreamReceiver.kt:1593`): continuous sessions get a fresh exchange for the new generation `G` built
    /// from the restart offer; its first snapshot is sent by the very next poll. No-op for non-continuous sessions.
    /// Throws on an invalid restart offer (fatal).
    func beginGeneration(remoteOffer: String, generation: Int64) throws {
        guard negotiation.continuous else { return }
        continuous = try ContinuousExchange(
            remoteDescription: remoteOffer, relayOnly: relayOnly,
            generation: generation)
    }

    /// step 5 `poll` body ICE members (`StreamReceiver.kt:620-631`). `recoveryGeneration` is `LanRecovery.generation`.
    /// Trickle: only while not finished and generation 0; completion is read before the SDP. Continuous: the exchange
    /// generation must equal `recoveryGeneration` (Kotlin `check` → fatal), and the observed SDP is the
    /// evidence-filtered description.
    func outgoing(peer: ICEPeerConfiguration.Peer, recoveryGeneration: Int64) throws -> Outgoing {
        var ice: TrickleExchange.Delta? = nil
        if let trickle, !trickle.finished, recoveryGeneration == 0 {
            let complete = peer.iceGatheringComplete
            try trickle.observe(localDescription: try Self.localDescription(peer), complete: complete)
            ice = trickle.delta()
        }
        var snapshot: ContinuousExchange.Snapshot? = nil
        if let continuous {
            guard continuous.generation == recoveryGeneration else {
                throw ICEProtocolError("ICE generation mismatch")
            }
            let observed = try bridge.continuousEvidence.description(for: try Self.localDescription(peer))
            try continuous.observe(localDescription: observed)
            snapshot = continuous.snapshot()
        }
        return Outgoing(ice: ice, continuousICE: snapshot)
    }

    /// step 7 (`StreamReceiver.kt:658-659`): when the request carried `ice` / `continuous_ice`, the 200 body must carry
    /// the matching member (else fatal `missingUpdate`); phone-side checks run before `accept`, and all validation
    /// precedes native work. Native adds use `peer.addIceCandidate`; continuous removals use `peer.removeIceCandidates`
    /// (always true). Every error here is fatal.
    func accept(statusBody: [UInt8], outgoing: Outgoing, peer: ICEPeerConfiguration.Peer) throws {
        if outgoing.ice != nil {
            guard let trickle else { throw ICEProtocolError.missingUpdate }
            let delta = try TrickleExchange.Delta.hostUpdate(statusBody: statusBody)
            try TrickleExchange.validateIncoming(delta)
            try trickle.accept(delta) { candidate in
                peer.addIceCandidate(
                    mid: candidate.mid, index: Int32(clamping: candidate.index),
                    sdp: candidate.candidate, timeoutMs: Self.candidateApplyTimeoutMs)
            }
        }
        if outgoing.continuousICE != nil {
            guard let continuous else { throw ICEProtocolError.missingUpdate }
            let snapshot = try ContinuousExchange.Snapshot.hostUpdate(statusBody: statusBody)
            try ContinuousExchange.validateIncoming(snapshot)
            try continuous.accept(
                snapshot,
                add: { candidate in
                    peer.addIceCandidate(
                        mid: candidate.mid, index: Int32(clamping: candidate.index),
                        sdp: candidate.candidate, timeoutMs: Self.candidateApplyTimeoutMs)
                },
                remove: { candidate in
                    peer.removeIceCandidates([
                        (
                            mid: candidate.mid, index: Int32(clamping: candidate.index),
                            sdp: candidate.candidate
                        )
                    ])
                    return true
                })
        }
    }

    /// Copy-report lines appended per status iteration when present (`StreamReceiver.kt:751-752`): `trickle.text`, then
    /// `continuous.text`.
    var texts: [String] {
        var lines: [String] = []
        if let trickle { lines.append(trickle.text()) }
        if let continuous { lines.append(continuous.text()) }
        return lines
    }

    /// `pc.localDescription!!.description` (Kotlin NPE → `SETUP_FAILED`).
    private static func localDescription(_ peer: ICEPeerConfiguration.Peer) throws -> String {
        guard let sdp = peer.localDescription else { throw ICEProtocolError("Local ICE description unavailable") }
        return sdp
    }
}
