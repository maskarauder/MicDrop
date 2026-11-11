// The single audio-session plan table. Pure data in MicDropCore — no AVFoundation import (Linux-tested).
//
// App-side mapping (AudioSessionArbiter, 07 /, and WebRTCRuntime, 04): RTCAudioSessionConfiguration.category =
// plan.category.rawValue (NSString constant value) RTCAudioSessionConfiguration.mode = plan.mode.rawValue
// RTCAudioSessionConfiguration.categoryOptions = AVAudioSession.CategoryOptions(rawValue: plan.options.rawValue)
// sampleRate / ioBufferDuration / inputNumberOfChannels / outputNumberOfChannels copied verbatim. The raw values below
// equal the AVFoundation constants' string values / option bits; the app may also map with an explicit `switch` (e.g.
// `.playback` → `AVAudioSession.Category.playback`).
//
// Who uses the plan: the controller computes it at Connect (`make`), the arbiter applies and verifies it
// (`acceptsReadBack`), the worker creates the ADM per `profile` and requests input only when `initializesInput`, local
// tools use `.localTool`. Never `.allowBluetooth` on media-output rows (it would turn A2DP listening into mono HFP). LE
// microphone rows do not exist on iOS.

/// One row of (or the local-tool plan): AVAudioSession category/mode/options, the ADM unit, preferred hardware format
/// and the input/activation policy for a session.
public struct AudioSessionPlan: Equatable, Sendable {

    // MARK: - AVAudioSession vocabulary (pure mirrors)

    /// `AVAudioSession.Category` values used by MicDrop. Raw value = the AVFoundation constant's
    /// string value (`RTCAudioSessionConfiguration.category` is an `NSString`).
    public enum Category: String, Sendable, CaseIterable {
        /// `AVAudioSessionCategoryPlayback` — playback row and local tools.
        case playback = "AVAudioSessionCategoryPlayback"
        /// `AVAudioSessionCategoryPlayAndRecord` — every microphone row, and the playback fallback.
        case playAndRecord = "AVAudioSessionCategoryPlayAndRecord"
    }

    /// `AVAudioSession.Mode` values used by MicDrop. Raw value = the AVFoundation constant's string value.
    public enum Mode: String, Sendable, CaseIterable {
        /// `AVAudioSessionModeDefault`.
        case `default` = "AVAudioSessionModeDefault"
        /// `AVAudioSessionModeVoiceChat` — Bluetooth HFP rows only. Never for echo cancellation (`.voiceChat`
        /// implicitly enables HFP routing).
        case voiceChat = "AVAudioSessionModeVoiceChat"
    }

    /// Mirror of `AVAudioSession.CategoryOptions` with identical bit values
    /// (`AVAudioSessionCategoryOptions`, NSUInteger).
    public struct CategoryOptions: OptionSet, Sendable, Hashable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        /// `.mixWithOthers` (0x1): microphone-only non-Bluetooth row only.
        public static let mixWithOthers = CategoryOptions(rawValue: 0x1)
        /// `.allowBluetooth` (0x4), named `.allowBluetoothHFP` in the iOS 26 SDK (same bit).
        /// Bluetooth HFP rows only.
        public static let allowBluetooth = CategoryOptions(rawValue: 0x4)
        /// Alias of `allowBluetooth` matching the iOS 26 SDK spelling.
        public static let allowBluetoothHFP = CategoryOptions(rawValue: 0x4)
        /// `.defaultToSpeaker` (0x8): playAndRecord media rows (speaker instead of receiver fallback).
        public static let defaultToSpeaker = CategoryOptions(rawValue: 0x8)
        /// `.allowBluetoothA2DP` (0x20): keeps Bluetooth media output on A2DP with a built-in/wired/USB mic.
        public static let allowBluetoothA2DP = CategoryOptions(rawValue: 0x20)
        /// `.allowAirPlay` (0x40).
        public static let allowAirPlay = CategoryOptions(rawValue: 0x40)
    }

    // MARK: - Constants common to every row

    /// Preferred hardware sample rate (Android in/out 48 kHz). HFP routes run at 8/16/24 kHz:
    /// report actual values, never this constant.
    public static let preferredSampleRate: Double = 48_000
    /// Preferred I/O buffer duration in seconds (ms; 0.01 vs 0.02).
    public static let preferredIOBufferDuration: Double = 0.01
    /// Mono capture (`setUseStereoInput(false)`, `StreamReceiver.kt:401`).
    public static let preferredInputNumberOfChannels = 1
    /// Options of the non-mixable playAndRecord media-output rows (duplex non-Bluetooth, fallback).
    public static let mediaOutputOptions: CategoryOptions = [.allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]

    // MARK: - Stored row values

    /// Session mode this plan was made for; `nil` for the local-tool plan.
    public let streamMode: StreamMode?
    /// AVAudioSession category.
    public let category: Category
    /// AVAudioSession mode.
    public let mode: Mode
    /// AVAudioSession category options.
    public let options: CategoryOptions
    /// ADM unit created by the worker at stage AUDIO.
    public let profile: AudioDeviceProfile
    /// `RTCAudioSessionConfiguration.sampleRate` (preferred).
    public let sampleRate: Double
    /// `RTCAudioSessionConfiguration.ioBufferDuration` in seconds (preferred).
    public let ioBufferDuration: Double
    /// `RTCAudioSessionConfiguration.inputNumberOfChannels`.
    public let inputNumberOfChannels: Int
    /// `RTCAudioSessionConfiguration.outputNumberOfChannels` (= `profile.outputNumberOfChannels`).
    public let outputNumberOfChannels: Int
    /// decoded playout channels expected from the ADM (2 stereo RemoteIO, 1 VPIO); `nil` = not applicable
    /// (microphone-only non-Bluetooth row, which plays nothing).
    public let playoutChannels: Int?
    /// the worker calls `setInitialMicrophoneMute(true)` + `initializeInput` at stage AUDIO. Playback and local-tool
    /// plans never request input (no permission prompt, no input path).
    public let initializesInput: Bool
    /// the arbiter activates the session at Connect, before the worker starts (playback: audio-focus analogue; mixable
    /// microphone row: cannot interrupt others).
    public let activatesBeforeConnect: Bool
    /// Effective echo cancellation (`MicrophoneProcessing.effective(mode:input:)`), which selects VPIO for
    /// non-Bluetooth duplex. Wire flags stay the requested effective options.
    public let echoCancellation: Bool
    /// Effective noise reduction (software APM `googNoiseSuppression`; does not change the row).
    public let noiseReduction: Bool

    /// Memberwise initializer (tests and the two static plans; production code uses `make`).
    public init(
        streamMode: StreamMode?, category: Category, mode: Mode, options: CategoryOptions,
        profile: AudioDeviceProfile, sampleRate: Double, ioBufferDuration: Double,
        inputNumberOfChannels: Int, outputNumberOfChannels: Int, playoutChannels: Int?,
        initializesInput: Bool, activatesBeforeConnect: Bool,
        echoCancellation: Bool, noiseReduction: Bool
    ) {
        self.streamMode = streamMode
        self.category = category
        self.mode = mode
        self.options = options
        self.profile = profile
        self.sampleRate = sampleRate
        self.ioBufferDuration = ioBufferDuration
        self.inputNumberOfChannels = inputNumberOfChannels
        self.outputNumberOfChannels = outputNumberOfChannels
        self.playoutChannels = playoutChannels
        self.initializesInput = initializesInput
        self.activatesBeforeConnect = activatesBeforeConnect
        self.echoCancellation = echoCancellation
        self.noiseReduction = noiseReduction
    }

    // MARK: - Derived values

    /// only the microphone-only non-Bluetooth row. Mixable sessions get no Now Playing presence.
    public var mixable: Bool { return options.contains(.mixWithOthers) }
    /// spelling of `initializesInput`.
    public var requestsInput: Bool { return initializesInput }
    /// spelling of `profile.stereoPlayoutEnabled`.
    public var stereoPlayout: Bool { return profile.stereoPlayoutEnabled }
    /// spelling of `profile.bypassVoiceProcessing` (always `false`).
    public var bypassVoiceProcessing: Bool { return profile.bypassVoiceProcessing }
    /// spelling of `profile.usesVoiceProcessingIO`.
    public var voiceProcessing: Bool { return profile.usesVoiceProcessingIO }
    /// `true` for the Bluetooth HFP rows (`.allowBluetooth`).
    public var usesBluetoothHFP: Bool { return options.contains(.allowBluetooth) }
    /// `overrideOutputAudioPort(.speaker)` is only valid in `.playAndRecord`
    /// (`AudioRouteInspecting.speakerOverrideSupported`). With the `.playback` row the permanent iPhone-speaker pin is
    /// offered only while the route already is the built-in speaker.
    public var supportsSpeakerOverride: Bool { return category == .playAndRecord }
    /// `true` for `.localTool`.
    public var isLocalTool: Bool { return streamMode == nil }
    /// The effective microphone processing this plan was made with (the wire flags of `microphone.processing`).
    public var processing: MicrophoneProcessing {
        return MicrophoneProcessing(echoCancellation: echoCancellation, noiseReduction: noiseReduction)
    }
    /// Software APM constraints for `factory.audioSource(with:)`: `googEchoCancellation=<ec>`,
    /// `googNoiseSuppression=<nr>`, `googAutoGainControl=false`, `googHighpassFilter=false`
    /// (`MicrophoneProcessing.kt:7-10`).
    public var audioProcessingConstraints: [String: String] { return processing.constraints() }

    // MARK: - Construction

    /// The authoritative plan for a session. `processing` may be the stored preference or an already-effective value:
    /// `effective(mode:input:)` is applied here and is idempotent. Rows (category / mode / options / ADM / playout
    /// channels / mixable / input):
    ///
    /// - playback, any input: `.playback` / `.default` / `[]` / stereo RemoteIO / 2 / no /
    ///   never.
    /// - microphone, built-in/wired/USB: `.playAndRecord` / `.default` /
    ///   `[.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]` / stereo RemoteIO / n/a / yes /
    ///   yes.
    /// - microphone, Bluetooth: `.playAndRecord` / `.voiceChat` / `[.allowBluetooth]` / VPIO / 1 /
    ///   no / yes.
    /// - duplex, built-in/wired/USB, effective echo cancellation off: `.playAndRecord` / `.default` /
    ///   `mediaOutputOptions` / stereo RemoteIO / 2 / no / yes.
    /// - duplex, built-in/wired/USB, effective echo cancellation on: `.playAndRecord` / `.default` /
    ///   `mediaOutputOptions` / VPIO / 1 / no / yes.
    /// - duplex, Bluetooth: `.playAndRecord` / `.voiceChat` / `[.allowBluetooth]` / VPIO / 1 / no /
    ///   yes.
    ///
    /// "Bluetooth" = `input.isBluetooth` (`.sco`; `.le` is never selectable on iOS and is treated as
    /// HFP defensively). Every row: 48 kHz, 0.01 s, 1 input channel, early activation. Effective
    /// noise reduction never changes the row (software APM `googNoiseSuppression`).
    /// - Parameter playAndRecordPlayback: Fallback switch for the playback row only:
    ///   `.playAndRecord` + `mediaOutputOptions`, still no `initializeInput`. Default `false`.
    public static func make(
        mode: StreamMode, input: MicrophoneKind, processing: MicrophoneProcessing,
        playAndRecordPlayback: Bool = false
    ) -> AudioSessionPlan {
        if case .playback = mode {
            return playback(playAndRecordFallback: playAndRecordPlayback)
        }
        let effective = processing.effective(mode: mode, input: input)
        let bluetooth = input.isBluetooth
        let category: Category = .playAndRecord
        let sessionMode: Mode
        let options: CategoryOptions
        let profile: AudioDeviceProfile
        let playoutChannels: Int?
        switch mode {
        case .playback:
            // Handled above; kept for exhaustiveness.
            return playback(playAndRecordFallback: playAndRecordPlayback)
        case .microphone:
            if bluetooth {
                sessionMode = .voiceChat
                options = [.allowBluetooth]
                profile = .voiceProcessing
                playoutChannels = 1
            } else {
                sessionMode = .default
                options = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
                profile = .stereoRemoteIO
                playoutChannels = nil
            }
        case .duplex:
            if bluetooth {
                sessionMode = .voiceChat
                options = [.allowBluetooth]
                profile = .voiceProcessing
                playoutChannels = 1
            } else if effective.echoCancellation {
                sessionMode = .default
                options = mediaOutputOptions
                profile = .voiceProcessing
                playoutChannels = 1
            } else {
                sessionMode = .default
                options = mediaOutputOptions
                profile = .stereoRemoteIO
                playoutChannels = 2
            }
        }
        return AudioSessionPlan(
            streamMode: mode, category: category, mode: sessionMode, options: options, profile: profile,
            sampleRate: preferredSampleRate, ioBufferDuration: preferredIOBufferDuration,
            inputNumberOfChannels: preferredInputNumberOfChannels,
            outputNumberOfChannels: profile.outputNumberOfChannels, playoutChannels: playoutChannels,
            initializesInput: true, activatesBeforeConnect: true,
            echoCancellation: effective.echoCancellation, noiseReduction: effective.noiseReduction)
    }

    /// The playback row: `.playback` / `.default` / `[]` (non-mixable, interrupts others = Android `AUDIOFOCUS_GAIN`),
    /// stereo RemoteIO, 2 playout channels, never `initializeInput`. With `playAndRecordFallback` (only if device
    /// testing shows `configureWebRTCSession` failing with "No audio input path"): `.playAndRecord` +
    /// `mediaOutputOptions`, input still off.
    public static func playback(playAndRecordFallback: Bool = false) -> AudioSessionPlan {
        return AudioSessionPlan(
            streamMode: .playback,
            category: playAndRecordFallback ? .playAndRecord : .playback,
            mode: .default,
            options: playAndRecordFallback ? mediaOutputOptions : [],
            profile: .stereoRemoteIO,
            sampleRate: preferredSampleRate, ioBufferDuration: preferredIOBufferDuration,
            inputNumberOfChannels: preferredInputNumberOfChannels,
            outputNumberOfChannels: AudioDeviceProfile.stereoRemoteIO.outputNumberOfChannels,
            playoutChannels: 2, initializesInput: false, activatesBeforeConnect: true,
            echoCancellation: false, noiseReduction: false)
    }

    /// Local output probe, the only local tool since Android retired the test tone: `.playback` / `.default` / `[]`,
    /// preferred 48 kHz and 0.01 s. No ADM is created (AVAudioEngine), so `profile` is informational only; never
    /// requests input; runs only while `RTCAudioSession.isAudioEnabled == false` and while holding
    /// `AudioSessionOwner.tryAcquire()`. Used as `arbiter.prepare(.localTool)`.
    public static let localTool = AudioSessionPlan(
        streamMode: nil, category: .playback, mode: .default, options: [],
        profile: .stereoRemoteIO,
        sampleRate: AudioSessionPlan.preferredSampleRate,
        ioBufferDuration: AudioSessionPlan.preferredIOBufferDuration,
        inputNumberOfChannels: AudioSessionPlan.preferredInputNumberOfChannels,
        outputNumberOfChannels: AudioDeviceProfile.stereoRemoteIO.outputNumberOfChannels,
        playoutChannels: 2, initializesInput: false, activatesBeforeConnect: true,
        echoCancellation: false, noiseReduction: false)

    // MARK: - Read-back verification

    /// Checks the values read back from `AVAudioSession` after the arbiter applied this plan (the
    /// patched `setConfiguration:active:error:` always returns YES, so read-back is the only
    /// reliable check). `category`/`mode` are `nil` when the app could not map the actual value.
    ///
    /// Accepts iff category and mode are equal, every planned option bit is present, and the two policy-defining bits
    /// match exactly: `.mixWithOthers` (focus/Now Playing behaviour) and `.allowBluetooth` (never HFP on a media row).
    /// Other OS-added bits (e.g. implied by a mode) are tolerated. A `false` result fails setup (`UNVERIFIED` during
    /// INPUT_ROUTE, generic otherwise).
    public func acceptsReadBack(
        category actualCategory: Category?, mode actualMode: Mode?,
        optionsRawValue: UInt
    ) -> Bool {
        guard actualCategory == category, actualMode == mode else { return false }
        let actual = CategoryOptions(rawValue: optionsRawValue)
        guard actual.isSuperset(of: options) else { return false }
        guard actual.contains(.mixWithOthers) == options.contains(.mixWithOthers) else { return false }
        guard actual.contains(.allowBluetooth) == options.contains(.allowBluetooth) else { return false }
        return true
    }
}
