import Foundation
import MicDropCore
import MicDropTransport

/// Collaborators injected into one `SessionController`. The coordinator builds the production value; tests substitute
/// fakes for the transport, ICE service, engine factory, clock and journal sink.
struct SessionDependencies {
    /// Control transport for this link: `LanControlTransport` (LAN) or `RemoteControlTransport` (remote), one fresh
    /// connection per request, never retries. The worker bridges its `async` `send` with `SessionWorkerWait`.
    let transport: any ControlTransport
    /// Direct LAN and its handshake-only probe share the session's non-cellular path hooks.
    let localTransport: (LanSignalingRoute) -> any ControlTransport
    let localProbe: (LanSignalingRoute) -> any LocalHostProbing
    /// TLS setup for the link, evaluated once at stage PAIRING (Kotlin `tls = invitation.socketFactory()`,
    /// `StreamReceiver.kt:369`) so an unusable identity fails before `/offer`.
    let tls: (ConnectionLink) throws -> ControlTLSSetup
    /// `/v1/ice` rendezvous credentials; used only for remote links, before `/offer` and before each `/recover-offer`.
    let iceService: RemoteICEService
    /// Builds the WebRTC engine at stage AUDIO: configuration, delegate events, and the worker checkpoint that the
    /// engine calls between native steps.
    let engineFactory:
        (MediaEngineConfiguration, any MediaEngineEvents, @escaping () throws -> Void) throws -> MediaEngine
    /// Sole owner of `RTCAudioSession` configuration/activation. The worker uses it for microphone route activation and
    /// the speaker override; the coordinator deactivates it.
    let arbiter: AudioSessionArbiter
    /// Process-wide single audio permit, acquired at WAITING, released last.
    let owner: AudioSessionOwner
    /// Monotonic milliseconds including sleep for every deadline and `uptime_ms`.
    let clock: any MonotonicClock
    /// Persists the stop-report journal text (`StoredReports.saveStream`).
    let journalSave: (String) throws -> Void
    /// Creates the per-session network/runtime observer (`SessionRuntime`).
    let runtime: () -> SessionRuntime
    /// Advanced "Keep microphone active while muted in background", read live by the worker (any thread) so a local
    /// Save applies at the session's next background/foreground step. Production reads
    /// `AdvancedAudioPreferencesStore.shared.liveKeepMicrophoneActive()`, which a Windows edit does not change before
    /// the next microphone Connect; the default is the preference's default (on).
    let keepMicrophoneActiveWhileMuted: @Sendable () -> Bool
    /// Stores and read-only device lists of phone settings exchange v1 (`AppEnvironment` wires the shared stores).
    /// Nil (tests, previews) creates no `PhoneControlAdapter` even when the controller passed a binding.
    let phoneControl: PhoneControlAdapter.Environment?

    init(
        transport: any ControlTransport,
        localTransport: @escaping (LanSignalingRoute) -> any ControlTransport,
        localProbe: @escaping (LanSignalingRoute) -> any LocalHostProbing,
        tls: @escaping (ConnectionLink) throws -> ControlTLSSetup,
        iceService: RemoteICEService,
        engineFactory:
            @escaping (MediaEngineConfiguration, any MediaEngineEvents, @escaping () throws -> Void) throws ->
            MediaEngine,
        arbiter: AudioSessionArbiter,
        owner: AudioSessionOwner,
        clock: any MonotonicClock,
        journalSave: @escaping (String) throws -> Void,
        runtime: @escaping () -> SessionRuntime,
        keepMicrophoneActiveWhileMuted: @escaping @Sendable () -> Bool = {
            AdvancedAudioPreferences().keepMicrophoneActiveWhileMuted
        },
        phoneControl: PhoneControlAdapter.Environment? = nil
    ) {
        self.transport = transport
        self.localTransport = localTransport
        self.localProbe = localProbe
        self.tls = tls
        self.iceService = iceService
        self.engineFactory = engineFactory
        self.arbiter = arbiter
        self.owner = owner
        self.clock = clock
        self.journalSave = journalSave
        self.runtime = runtime
        self.keepMicrophoneActiveWhileMuted = keepMicrophoneActiveWhileMuted
        self.phoneControl = phoneControl
    }
}
