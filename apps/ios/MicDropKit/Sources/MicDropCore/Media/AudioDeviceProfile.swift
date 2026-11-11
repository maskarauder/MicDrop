// WebRTC audio device module (ADM) unit type for one session.;. Pure data: the app creates the ADM with
// `RTCAudioDeviceModule(bypassVoiceProcessing: profile.bypassVoiceProcessing,
//                       stereoPlayoutEnabled: profile.stereoPlayoutEnabled)` (port-rules; Shiguredo
// `initWithBypassVoiceProcessing:stereoPlayoutEnabled:`). Stereo is fixed at construction and the
// ADM must be configured before it is handed to the factory (one ADM per factory/session).

/// Which audio unit the per-session `RTCAudioDeviceModule` creates.
///
/// Not a wire value (never serialised). Android's ADM has no unit choice; its closest settings are
/// `setUseStereoOutput(...)` and the audio source (`StreamReceiver.kt:400-407`).
public enum AudioDeviceProfile: Sendable, CaseIterable {
    /// `stereoPlayoutEnabled: YES` → RemoteIO unit, 2-channel 16-bit playout, no iOS hardware AEC/AGC; WebRTC
    /// temporarily forces mode `.default` while configuring. Rows: playback, non-Bluetooth microphone, non-Bluetooth
    /// duplex without echo cancellation.
    case stereoRemoteIO
    /// `stereoPlayoutEnabled: NO` → VoiceProcessingIO (VPIO), mono playout, Apple AEC/NS/AGC. Rows: Bluetooth HFP
    /// input, non-Bluetooth duplex with echo cancellation.
    case voiceProcessing

    /// Second argument of `RTCAudioDeviceModule(bypassVoiceProcessing:stereoPlayoutEnabled:)`.
    public var stereoPlayoutEnabled: Bool {
        return self == .stereoRemoteIO
    }

    /// First argument of the ADM initializer: always `false` (Android disables hardware effects only through RemoteIO;
    /// `bypassVoiceProcessing: YES` is ignored for RemoteIO, and the audio plan never asks for a bypassed VPIO).
    public var bypassVoiceProcessing: Bool {
        return false
    }

    /// `true` when the unit is VoiceProcessingIO (hardware voice processing active).
    /// Feeds 08's `MicrophoneProcessing.text(voiceProcessingActive:)`.
    public var usesVoiceProcessingIO: Bool {
        return self == .voiceProcessing
    }

    /// `RTCAudioSessionConfiguration.outputNumberOfChannels` for this unit: 2 for stereo RemoteIO, 1 for VPIO (WebRTC
    /// keeps its preferred output at 1 internally either way; harmless).
    public var outputNumberOfChannels: Int {
        return self == .stereoRemoteIO ? 2 : 1
    }
}
