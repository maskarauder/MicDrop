import AVFoundation
import Foundation
import MicDropCore
import WebRTC

/// Process-global WebRTC state and the per-session native object factory (Kotlin `StreamReceiver.kt:398-462,
/// 1756-1768`).
///
/// Only this type creates `RTCAudioDeviceModule` / `RTCPeerConnectionFactory` instances and toggles
/// `RTCAudioSession.isAudioEnabled`; every other `RTCAudioSession` configuration/activation call belongs to
/// `AudioSessionArbiter` (item 1).
///
/// Lifetime rules:
/// - WebRTC global state is initialised once and never torn down (`RTCCleanupSSL()` is never
/// called; Android "dispose also tears down native global state", `StreamReceiver.kt:1757`).
/// - One ADM per factory per session (the Shiguredo factory consumes the ADM's native module;
/// passing it to a second factory returns nil).
/// - A factory that is still alive after its session's teardown (stray strong reference, deferred
/// autorelease) blocks every later session in this process: a new `initializeInput` would fail as a duplicate and the
/// old audio unit could still hold the session (last paragraph).
enum WebRTCRuntime {

    // MARK: - App launch (step 4)

    /// Called once from the app entry (launch hook) before any factory exists: `useManualAudio = true`, `isAudioEnabled
    /// = false`, so WebRTC never initialises or starts the audio unit except while a session explicitly allows it.
    /// Replaces Android's `setAudioPlayout`/`setAudioRecording` start-time control.
    /// (`AVAudioApplication.setInputMuted(false)` hygiene,.) Idempotent and equivalent to the two manual-audio lines of
    /// `AudioSessionArbiter.configureForLaunch()`; calling either is sufficient.
    static func configureAtLaunch() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    // MARK: - Session start (steps 1-3, `StreamReceiver.kt:1756-1768`)

    /// Idempotent global initialisation, called on the session worker at stage AUDIO:
    /// `RTCInitializeSSL()` once, `RTCSetMinDebugLogLevel(.none)` (WebRTC logs may contain SDP,
    /// candidates and identifiers; Android installs a discarding logger), no field trials, no
    /// `RTCCallbackLogger`/`RTCFileLogger`.
    ///
    /// Throws `MediaEngineError.previousMediaNotReleased` while a previous session's factory is still alive ("do not
    /// start another session in this process until it deallocates").
    static func ensureInitialized() throws {
        lock.lock()
        defer { lock.unlock() }
        if lingeringFactory.value != nil { throw MediaEngineError.previousMediaNotReleased }
        guard !initialized else { return }
        _ = RTCInitializeSSL()
        RTCSetMinDebugLogLevel(RTCLoggingSeverity.none)
        initialized = true
    }

    // MARK: - Native objects

    /// The per-session ADM for `profile` (Shiguredo `initWithBypassVoiceProcessing:stereoPlayoutEnabled:`,
    /// port-rules: no ObjC shim). `stereoRemoteIO` → RemoteIO with 2-channel playout and no iOS
    /// AEC/AGC; `voiceProcessing` → VPIO, mono playout. Stereo is fixed at construction.
    static func makeAudioDeviceModule(_ profile: AudioDeviceProfile) -> RTCAudioDeviceModule {
        RTCAudioDeviceModule(
            bypassVoiceProcessing: profile.bypassVoiceProcessing,
            stereoPlayoutEnabled: profile.stereoPlayoutEnabled)
    }

    /// `RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDeviceModule:)` plus
    /// `setOptions(ICEPeerConfiguration.factoryOptions(lanLocal:))`, always called (Android always passes an Options
    /// object whose mask defaults to 0; the native default without options is `LOOPBACK`). nil factory →
    /// `MediaEngineError.factoryUnavailable` (SETUP_FAILED). Audio codecs are the built-in factories (Android builder
    /// default).
    static func makeFactory(audioDeviceModule: RTCAudioDeviceModule, lanLocal: Bool) throws -> RTCPeerConnectionFactory
    {
        guard
            let factory = RTCPeerConnectionFactory(
                encoderFactory: nil, decoderFactory: nil,
                audioDeviceModule: audioDeviceModule)
        else {
            throw MediaEngineError.factoryUnavailable
        }
        factory.setOptions(ICEPeerConfiguration.factoryOptions(lanLocal: lanLocal))
        return factory
    }

    // MARK: - Manual audio

    /// `RTCAudioSession.isAudioEnabled`: whether WebRTC may initialise/start the audio unit. The local output probe
    /// runs only while this is `false`.
    static var isAudioEnabled: Bool {
        RTCAudioSession.sharedInstance().isAudioEnabled
    }

    /// Sets `RTCAudioSession.isAudioEnabled`. Callers: `MediaEngine` (end of stage AUDIO → true;
    /// `restartPlayout()` false → true; teardown step `audio_module_release` → false). `false` stops
    /// and uninitialises an active unit. Never toggled for interruptions (`AudioDeviceIOS` stops and
    /// restarts the unit itself).
    static func setAudioEnabled(_ enabled: Bool) {
        RTCAudioSession.sharedInstance().isAudioEnabled = enabled
    }

    // MARK: - Teardown verification (step 6)

    /// Release order of the native objects inside `MediaEngine.close(onStep:)`; raw values are the
    /// Android `cleanupStep` names written to the stop-report journal (`StreamReceiver.kt:855-859`).
    static let teardownOrder: [MediaEngine.TeardownStep] = [
        .peerDispose, .microphoneTrackDispose, .microphoneSourceDispose, .factoryDispose, .audioModuleRelease,
    ]

    /// Records a factory that survived its session's autorelease pool (held weakly). While it is
    /// alive, `ensureInitialized()` refuses to start a session; once it deallocates the next session
    /// proceeds normally.
    static func recordLingeringFactory(_ factory: RTCPeerConnectionFactory) {
        lock.lock()
        lingeringFactory.value = factory
        lock.unlock()
    }

    /// `true` while a previous session's factory is still alive (diagnostics/tests).
    static var previousFactoryAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lingeringFactory.value != nil
    }

    // MARK: - Private state

    private final class WeakFactory {
        weak var value: RTCPeerConnectionFactory?
    }

    private static let lock = NSLock()
    private static var initialized = false
    private static let lingeringFactory = WeakFactory()
}
