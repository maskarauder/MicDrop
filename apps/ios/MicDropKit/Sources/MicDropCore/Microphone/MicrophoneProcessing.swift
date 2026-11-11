import Foundation

/// Microphone voice-processing options (`A/MicrophoneProcessing.kt`).
///
/// Stored values are the user preferences (`echoCancellation`, `noiseReduction`, default off, read once at session
/// start). Sessions always use `effective(mode:input:)`; the wire flags are the *effective requested* app options,
/// which keeps host validation intact even though iOS realizes echo cancellation only through VoiceProcessingIO.
public struct MicrophoneProcessing: Equatable, Hashable, Sendable, Encodable {
    public var echoCancellation: Bool
    public var noiseReduction: Bool

    /// `Encodable` uses the report keys of `fields()` (`microphone.processing`).
    private enum CodingKeys: String, CodingKey {
        case echoCancellation = "echo_cancellation_requested"
        case noiseReduction = "noise_reduction_requested"
    }

    public init(echoCancellation: Bool = false, noiseReduction: Bool = false) {
        self.echoCancellation = echoCancellation
        self.noiseReduction = noiseReduction
    }

    /// `effective(mode, input)` (`A/MicrophoneProcessing.kt:4-6`): echo cancellation only in
    /// duplex with a non-Bluetooth input; noise reduction only in microphone modes
    /// (microphone, duplex) with a non-Bluetooth input.
    public func effective(mode: StreamMode, input: MicrophoneKind) -> MicrophoneProcessing {
        MicrophoneProcessing(
            echoCancellation: echoCancellation && mode == .duplex && !input.isBluetooth,
            noiseReduction: noiseReduction && mode != .playback && !input.isBluetooth)
    }

    /// Optional `RTCMediaConstraints` for `factory.audioSource(with:)` (`:7-8`): `googEchoCancellation`,
    /// `googNoiseSuppression` = `"true"|"false"`; `googAutoGainControl` and `googHighpassFilter` always `"false"`.
    /// (WebRTC ignores `googEchoCancellation` on iOS; the audio plan selects VPIO instead,.)
    public func constraints() -> [String: String] {
        [
            "googEchoCancellation": echoCancellation ? "true" : "false",
            "googNoiseSuppression": noiseReduction ? "true" : "false",
            "googAutoGainControl": "false",
            "googHighpassFilter": "false",
        ]
    }

    /// `fields()` (`:9-10`): the `microphone.processing` report object members.
    public func fields() -> [String: Bool] {
        [
            "echo_cancellation_requested": echoCancellation,
            "noise_reduction_requested": noiseReduction,
        ]
    }

    /// `microphone.processing` as an ordered report object
    /// (`{"echo_cancellation_requested":bool,"noise_reduction_requested":bool}`).
    public func json() -> DiagnosticJSON {
        .object([
            (key: "echo_cancellation_requested", value: .bool(echoCancellation)),
            (key: "noise_reduction_requested", value: .bool(noiseReduction)),
        ])
    }

    /// iOS copy-report line (makes 08 the owner of this text): `Microphone processing: iOS voice-processing echo
    /// cancellation <requested|off> · Noise reduction <requested|off>.` + (VPIO in use ? ` iOS voice processing also
    /// applies its own noise suppression and automatic gain control; desktop playback is mono.`: "") + ` Acoustic
    /// effectiveness is unmeasured.`
    public func text(voiceProcessingActive: Bool = false) -> String {
        let echo = echoCancellation ? "requested" : "off"
        let noise = noiseReduction ? "requested" : "off"
        var line = "Microphone processing: iOS voice-processing echo cancellation \(echo) · Noise reduction \(noise)."
        if voiceProcessingActive {
            line +=
                " iOS voice processing also applies its own noise suppression and automatic gain control; desktop playback is mono."
        }
        line += " Acoustic effectiveness is unmeasured."
        return line
    }

    /// UI strings (`strings.xml:2-5` with the iOS additions).
    public enum UIText {
        public static let echoToggle = "Reduce microphone echo (experimental)"
        public static let noiseToggle = "Reduce microphone background noise"
        public static let help =
            "Choose before connecting. Echo reduction can help with phone-speaker playback; headphones are still recommended. These options process only the microphone. On iPhone, echo reduction uses iOS voice processing: desktop audio plays in mono and iOS also applies its own noise suppression and gain control."
        public static let bluetoothHelp =
            "Bluetooth microphone processing is managed by iOS and the headset. These options are retained for phone or wired/USB input."
    }
}
