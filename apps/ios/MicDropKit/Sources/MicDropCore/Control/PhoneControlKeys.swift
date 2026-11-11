import Foundation

/// The phone settings keys the iPhone advertises (D046, phone settings exchange v1) and the two Android keys it omits.
/// Names, order, groups, kinds and `int` bounds are Android's (`A/AppPhoneControl.kt:96-136`; the timeout bounds
/// `A/ConnectionPreferences.kt:16-35`), less `audio.le_stereo` and `live.volume`: 31 of Android's 33 keys.
///
/// `PhoneControlAdapter` advertises its fields under these names, in this order and with these bounds; its tests check
/// every snapshot field against `advertised`. The portable key-parity test (`PhoneControlKeysTests`) pins `advertised`
/// and `omitted` against a fixture of Android's table, so a key or bound that changes on one phone fails there until
/// the other phone follows or the key is listed in `omitted` with its reason.
public enum PhoneControlKeys {
    public static let fastRecovery = "audio.fast_recovery"
    public static let echoCancellation = "audio.echo_cancellation"
    public static let noiseReduction = "audio.noise_reduction"
    public static let keepMicrophoneActive = "audio.keep_microphone_active"
    public static let input = "audio.input"
    public static let output = "audio.output"
    public static let initialOrder = "advanced.initial_order"
    public static let recoveryOrder = "advanced.recovery_order"
    public static let maxRestarts = "advanced.max_restarts"
    /// Android's `BLUETOOTH_RECOVERY` timeout (`A/ConnectionPreferences.kt:35`); on the iPhone
    /// `AdvancedAudioPreferences.bluetoothRecoveryMs`, with the same default and bounds.
    public static let bluetoothRecovery = "advanced.bluetooth_recovery"
    public static let outputEnabled = "live.output_enabled"
    public static let microphoneMuted = "live.microphone_muted"
    /// Android's LE Audio stereo input preference (`A/AppPhoneControl.kt:100`), never advertised (`omitted`).
    public static let leStereo = "audio.le_stereo"
    /// Android's system media or voice volume (`A/AppPhoneControl.kt:134-136`), never advertised (`omitted`).
    public static let volume = "live.volume"

    /// `advanced.<timeout name lowercased>` (`A/AppPhoneControl.kt:129`).
    public static func timeout(_ timeout: ConnectionPreferences.Timeout) -> String {
        "advanced." + timeout.storageKey.lowercased()
    }

    /// One advertised key: its group, kind and, for an `int` field, its inclusive bounds (nil for the other kinds).
    public struct Field: Equatable, Sendable {
        public let key: String
        public let group: PhoneSetting.Group
        public let kind: PhoneSetting.Kind
        public let range: ClosedRange<Int>?

        public init(_ key: String, group: PhoneSetting.Group, kind: PhoneSetting.Kind, range: ClosedRange<Int>? = nil) {
            self.key = key
            self.group = group
            self.kind = kind
            self.range = range
        }
    }

    /// Every advertised key in snapshot order (Android's), 31 in all. One session's snapshot holds a subset:
    /// `audio.keep_microphone_active` only while a Windows edit of it waits for the next connection, and a Live key
    /// only while the session reports that value (`live.output_enabled` in playback and duplex, `live.microphone_muted`
    /// in microphone-only and duplex under phone-control rules).
    public static let advertised: [Field] =
        [
            Field(fastRecovery, group: .audio, kind: .bool),
            Field(echoCancellation, group: .audio, kind: .bool),
            Field(noiseReduction, group: .audio, kind: .bool),
            Field(keepMicrophoneActive, group: .audio, kind: .bool),
            Field(input, group: .audio, kind: .choice),
            Field(output, group: .audio, kind: .choice),
            Field(initialOrder, group: .advanced, kind: .choice),
            Field(recoveryOrder, group: .advanced, kind: .choice),
            Field(maxRestarts, group: .advanced, kind: .int, range: ConnectionPreferences.maxRestartsRange),
        ]
        + ConnectionPreferences.Timeout.allCases.map {
            Field(
                PhoneControlKeys.timeout($0), group: .advanced, kind: .int,
                range: $0.limits.minimumMs...$0.limits.maximumMs)
        }
        + [
            Field(
                bluetoothRecovery, group: .advanced, kind: .int, range: AdvancedAudioPreferences.bluetoothRecoveryRange),
            Field(outputEnabled, group: .live, kind: .bool),
            Field(microphoneMuted, group: .live, kind: .bool),
        ]

    /// Android keys the iPhone never advertises, each with its reason. A Windows command that names one is rejected
    /// like any other key outside the snapshot.
    public static let omitted: [String: String] = [
        leStereo:
            "The iPhone has no LE Audio microphone input and never reads this preference; Bluetooth LE outputs are "
            + "ordinary audio.output choices.",
        volume:
            "iOS lets an app only read the system volume; the volume buttons, Control Center and the system slider "
            + "change it.",
    ]
}
