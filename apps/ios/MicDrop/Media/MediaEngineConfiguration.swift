import Foundation
import MicDropCore

/// Everything the media engine needs to build one session's ADM, factory and peer
/// (`SessionDependencies.engineFactory`). Built by `SessionController` at stage AUDIO, after the `/offer` reply was
/// accepted (continual gathering depends on the offer).
///
/// The RTCConfiguration itself is built by `ICEPeerConfiguration.make(servers:policy:)` from `iceServers` + `policy`,
/// so the initial peer and every remote restart use identical field values ("only iceServers change").
struct MediaEngineConfiguration: Sendable {
    /// Session direction: playback = recv-only transceiver; microphone/duplex = local `phone-microphone` track attached
    /// to the host-created transceiver.
    let mode: StreamMode
    /// The single audio plan row: `plan.profile` selects the ADM unit. The arbiter has already applied
    /// category/mode/options before the engine exists.
    let plan: AudioSessionPlan
    /// `lanNetwork.local` (`LanNetwork.kt:12-27`): literal private-IPv4 LAN host → factory option
    /// `ignoreCellularNetworkAdapter`. Remote sessions: false.
    let lanLocal: Bool
    /// `/v1/ice` servers (remote; one RTCIceServer per URL) or `[]` on LAN (no STUN, works offline).
    let iceServers: [RemoteICEServer]
    /// `invitation.remote.forceRelay` → `iceTransportPolicy = .relay`.
    let forceRelay: Bool
    /// Continuous ICE negotiated (remote v3 + `trickle_ice_version == 1` + `continuous_ice_version == 1`,
    /// `StreamReceiver.kt:392-393`) → `.gatherContinually`, fixed at creation.
    let continualGathering: Bool
    /// "Faster recovery after audio interruptions" → `audioJitterBufferFastAccelerate`.
    let fastAccelerate: Bool
    /// Already `effective(mode:input:)` (`MicrophoneProcessing.kt:4-6`): optional constraints of the
    /// microphone `RTCAudioSource` (`googEchoCancellation`, `googNoiseSuppression`, AGC/HPF off).
    let processing: MicrophoneProcessing
    /// The session's TURN/TLS trust counters, fed by the peer's certificate verifier (`StreamReceiver.kt:93`,
    /// `:499-504`). Required so a session cannot create a peer without its counters.
    let turnTLSTrust: TurnTLSTrustCounters
    /// Initial speaker (remote playout) gate state (`module.setSpeakerMute(speakerMuted)` right after
    /// ADM creation, `StreamReceiver.kt:443-447`). Defaults to muted: the session re-applies its
    /// composite `speakerMuted` immediately after publishing the engine.
    let initialSpeakerMuted: Bool

    init(
        mode: StreamMode, plan: AudioSessionPlan, lanLocal: Bool, iceServers: [RemoteICEServer],
        forceRelay: Bool, continualGathering: Bool, fastAccelerate: Bool,
        processing: MicrophoneProcessing, turnTLSTrust: TurnTLSTrustCounters, initialSpeakerMuted: Bool = true
    ) {
        self.mode = mode
        self.plan = plan
        self.lanLocal = lanLocal
        self.iceServers = iceServers
        self.forceRelay = forceRelay
        self.continualGathering = continualGathering
        self.fastAccelerate = fastAccelerate
        self.processing = processing
        self.turnTLSTrust = turnTLSTrust
        self.initialSpeakerMuted = initialSpeakerMuted
    }

    /// `ICEPeerConfiguration.Policy` for the initial peer and every restart.
    var policy: ICEPeerConfiguration.Policy {
        ICEPeerConfiguration.Policy(
            forceRelay: forceRelay, continuous: continualGathering,
            fastAccelerate: fastAccelerate)
    }

    /// Playback and duplex receive desktop audio (`mode.playback`): PlayoutTap, stereo munge.
    var receivesPlayout: Bool { mode != .microphone }

    /// Microphone and duplex send the phone microphone (`mode.microphone`).
    var sendsMicrophone: Bool { mode != .playback }
}
