import Foundation
import MicDropCore
import WebRTC

/// The single builder of every MicDrop `RTCConfiguration` and of the factory options (Kotlin
/// `StreamReceiver.kt:453-472` initial, `:1576-1583` restart).
///
/// libwebrtc rejects any `setConfiguration` change other than the ICE servers, so the initial peer (built by the media
/// engine) and every remote restart (`ICERecoveryCoordinator`) must build their configuration through
/// `make(servers:policy:)` with the same `Policy`; only the server list differs. Renomination is not settable in the
/// ObjC wrapper: it is observed through `a=ice-options` only, never configured or rewritten.
enum ICEPeerConfiguration {

    /// Worker-side peer operations the ICE layer drives (step 5/7, "renegotiation primitives"). The media engine
    /// (`MediaEngine`) owns the `RTCPeerConnection` and conforms; the requirement spellings follow so the conformance
    /// is `extension MediaEngine: ICEPeerConfiguration.Peer {}` plus `setConfiguration(_:)`. The gathering latch can be
    /// backed by `ICEDelegateBridge` (`resetGatheringSignal()` / `gatheringSignal.wait(timeoutMs:worker:)`).
    ///
    /// Every member is called on the session worker thread only. Blocking members wait for the WebRTC completion
    /// handler through `SessionWorkerWait` (Stop interrupts the wait, the native call itself is never interrupted).
    protocol Peer: AnyObject {
        /// `pc.localDescription?.sdp`: the exact SDK description, never rewritten (step 5).
        var localDescription: String? { get }
        /// `pc.iceGatheringState == .complete`. Callers read it **before** `localDescription` (step 5,
        /// `StreamReceiver.kt:622`).
        var iceGatheringComplete: Bool { get }
        /// `gathered = CountDownLatch(1)`: a fresh gathering-complete latch, created before a restart offer is applied
        /// (`StreamReceiver.kt:1590`).
        func resetGatheredLatch()
        /// `workerWait.await { gathered.await(timeoutMs) }`: true once the current latch fired, false
        /// when `timeoutMs` elapsed first; Stop → `SessionStopped` (`StreamReceiver.kt:519,535,1599`).
        func waitGathered(timeoutMs: Int) throws -> Bool
        /// `pc.setConfiguration(_:)`; `false` is fatal for the caller (`StreamReceiver.kt:1583`).
        func setConfiguration(_ configuration: RTCConfiguration) -> Bool
        /// `setRemoteDescription(RTCSessionDescription(type: .offer, sdp:))` with a cancellable wait of `timeoutMs`.
        /// Failure → `MediaEngineError`; timeout → `StageTimeoutError`.
        func applyOffer(_ sdp: String, timeoutMs: Int) throws
        /// `answer(for: empty constraints)`; returns the SDK answer **without** the Opus stereo edit (the caller
        /// applies `OpusSdp.localAnswer(_:mode:)`, step 3, `StreamReceiver.kt:1597`).
        func createAnswer(timeoutMs: Int) throws -> String
        /// `setLocalDescription(RTCSessionDescription(type: .answer, sdp:))` with a cancellable wait.
        func setLocalAnswer(_ sdp: String, timeoutMs: Int) throws
        /// `pc.add(RTCIceCandidate(sdp:sdpMLineIndex:sdpMid:), completionHandler:)`; `false` when WebRTC rejected the
        /// candidate, the completion did not arrive within `timeoutMs`, or Stop interrupted the wait (Android
        /// `addIceCandidate` returns a Boolean).
        func addIceCandidate(mid: String, index: Int32, sdp: String, timeoutMs: Int) -> Bool
        /// `pc.remove([RTCIceCandidate])`; idempotent, treated as success (`StreamReceiver.kt:1646`).
        func removeIceCandidates(_ candidates: [(mid: String, index: Int32, sdp: String)])
    }

    /// The configuration inputs that never change during a session. Built once after the offer has been parsed
    /// (`continuous` depends on the offer) and reused for restarts.
    struct Policy: Equatable, Sendable {
        /// `invitation.remote?.forceRelay == true` → `iceTransportPolicy = .relay`.
        let forceRelay: Bool
        /// `continuous_ice_version == 1` negotiated → `.gatherContinually` (fixed at creation).
        let continuous: Bool
        /// User setting "Faster recovery after audio interruptions" (playback subsystem).
        let fastAccelerate: Bool
    }

    /// Native default jitter-buffer capacity, set explicitly so the value never depends on the wrapper's defaults
    /// ("packet capacity unchanged", `StreamReceiver.kt:468-470`).
    static let audioJitterBufferMaxPackets: Int32 = 200

    /// Peer configuration: one `RTCIceServer` per URL with its username/credential (`""` for STUN), `.relay` iff forced
    /// relay (else `.all`), Unified Plan, continual gathering iff continuous, fast accelerate per the user setting, and
    /// the explicit jitter-buffer capacity. Nothing else is set.
    static func make(servers: [RemoteICEServer], policy: Policy) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers(servers)
        configuration.iceTransportPolicy = policy.forceRelay ? .relay : .all
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = policy.continuous ? .gatherContinually : .gatherOnce
        configuration.audioJitterBufferFastAccelerate = policy.fastAccelerate
        configuration.audioJitterBufferMaxPackets = audioJitterBufferMaxPackets
        return configuration
    }

    /// spelling of `make(servers:policy:)`.
    static func make(
        servers: [RemoteICEServer], forceRelay: Bool, continuous: Bool,
        fastAccelerate: Bool
    ) -> RTCConfiguration {
        make(
            servers: servers,
            policy: Policy(forceRelay: forceRelay, continuous: continuous, fastAccelerate: fastAccelerate))
    }

    /// One native ICE server per URL, server order preserved (`RemoteIce.kt:63`). STUN entries pass `""`
    /// username/credential (WebRTC treats it as no credential).
    static func iceServers(_ servers: [RemoteICEServer]) -> [RTCIceServer] {
        servers.map { RTCIceServer(urlStrings: [$0.url], username: $0.username, credential: $0.credential) }
    }

    /// Factory options (`StreamReceiver.kt:453-455`): LAN sessions with a literal private IPv4 host ignore cellular
    /// adapters; remote sessions (host `"remote"`) allow them. Always passed to `factory.setOptions(_:)` (the native
    /// default without options would differ).
    static func factoryOptions(lanLocal: Bool) -> RTCPeerConnectionFactoryOptions {
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreCellularNetworkAdapter = lanLocal
        return options
    }

    /// `lanNetwork.local` (`LanNetwork.kt:26`): the signaling host is a literal 10/8, 172.16/12,
    /// 192.168/16 or 169.254/16 IPv4 address. Remote sessions pass `"remote"` → false.
    static func isLanLocal(host: String) -> Bool {
        LanAddress.bytes(host) != nil
    }

    /// All URLs of the ICE servers actually passed to the peer, for
    /// `InitialRelayGathering.eligible(relayOnly:urls:)` (`StreamReceiver.kt:516`). LAN → `[]`.
    static func serverURLs(_ configuration: RemoteICEConfiguration?) -> [String] {
        configuration?.urls ?? []
    }
}

extension RemoteICEConfiguration {
    /// `rtcIceServers()`: the native servers for this configuration (`RemoteICEServer` doc names this app-target
    /// extension). Same mapping as `ICEPeerConfiguration.iceServers(_:)`.
    func rtcIceServers() -> [RTCIceServer] {
        ICEPeerConfiguration.iceServers(servers)
    }
}
