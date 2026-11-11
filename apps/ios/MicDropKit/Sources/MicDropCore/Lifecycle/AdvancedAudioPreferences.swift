// Advanced audio settings: the muted background microphone keep-alive and the Bluetooth route recovery window. Android
// ports both ideas: `ConnectionTimeout.BLUETOOTH_RECOVERY` (20000 ms default, 5000-120000 ms,
// `ConnectionPreferences.kt:35`, among the connection timeouts) and `AudioPreferences.keepMicrophoneActive` (default
// off; a verified capture is kept while muted in the foreground and in duplex). iPhone differences: the keep-alive
// defaults on and applies only to a background microphone-only session, which it may start with every gate closed; a
// running session reads it live after a local Save (a Windows edit waits for the next connection); both values live in
// their own file. The strict JSON coding of `Application Support/MicDrop/advanced-audio-settings.json` is here; the
// file store (`AdvancedAudioPreferencesStore`, same protection and backup exclusion as `audio-settings.json`) is
// app-side.

import Foundation

/// Neither value starts a session, starts capture or stands in for microphone permission or the explicit
/// microphone consent of Connect. Contains no device identity, address or credential.
///
/// When a saved change takes effect:
/// - `keepMicrophoneActiveWhileMuted` from a local Save is read live by a running session, so it applies the next
///   time that session leaves the foreground (or returns to it), and to later sessions. A Windows edit (phone
///   settings exchange v1, `audio.keep_microphone_active`) applies only from the next microphone Connect, so Windows
///   can never start a muted background capture in the running session (`AdvancedAudioPreferencesStore`).
/// - `bluetoothRecoveryMs` is read at Connect: a running session keeps the window it started with, so a saved
///   change can never move the deadline of an episode in progress.
public struct AdvancedAudioPreferences: Equatable, Sendable {
    /// File name inside `Application Support/MicDrop/`.
    public static let fileName = "advanced-audio-settings.json"

    /// The persisted keys.
    public enum Key: String, CaseIterable, Sendable {
        case keepMicrophoneActiveWhileMuted = "keepMicrophoneActiveWhileMuted"
        case bluetoothRecoveryMs = "bluetoothRecoveryMs"
    }

    /// A value outside its documented bounds.
    public enum ValidationError: Error, Equatable, Sendable {
        case bluetoothRecoveryOutOfRange
    }

    /// Bluetooth route recovery window in milliseconds, with Android's default and bounds
    /// (`ConnectionTimeout.BLUETOOTH_RECOVERY`, `ConnectionPreferences.kt:35`; `HeadsetRecovery.kt:10` `WINDOW_MS`,
    /// `OutputSelection.kt:90` `BLUETOOTH_RECOVERY_MS`). The minimum equals
    /// the 5 s Bluetooth verification windows (`OutputRouteChange.defaultLimitMs`, Bluetooth unmute
    /// verification), so a recovery is never shorter than a first verification and still fits the three spaced
    /// reselection requests; the maximum equals the longest setup window (`ConnectionPreferences` `.setup`), so
    /// silenced audio ends in a bounded failure within two minutes.
    public static let bluetoothRecoveryLimits = (defaultMs: 20_000, minimumMs: 5_000, maximumMs: 120_000)

    /// `bluetoothRecoveryLimits` as a range.
    public static var bluetoothRecoveryRange: ClosedRange<Int> {
        bluetoothRecoveryLimits.minimumMs...bluetoothRecoveryLimits.maximumMs
    }

    /// "Keep microphone active while muted in background". On (the default) keeps the behavior: a muted microphone-only
    /// session whose scene is not `.active` keeps capture running with the local sample, input and host gates closed.
    /// Off: muted background capture stops, and iOS may suspend the session.
    public let keepMicrophoneActiveWhileMuted: Bool
    /// One fixed deadline per recovery episode of the selected Bluetooth output (`OutputRouteChange`) and of the
    /// Bluetooth headset microphone (`HeadsetRecovery`). Separate from the network recovery window
    /// (`ConnectionPreferences` `.recovery`).
    public let bluetoothRecoveryMs: Int

    /// Defaults: keep-alive on, 20 s.
    public init() {
        keepMicrophoneActiveWhileMuted = true
        bluetoothRecoveryMs = AdvancedAudioPreferences.bluetoothRecoveryLimits.defaultMs
    }

    /// Throws `ValidationError.bluetoothRecoveryOutOfRange` outside `bluetoothRecoveryRange`.
    public init(
        keepMicrophoneActiveWhileMuted: Bool = true,
        bluetoothRecoveryMs: Int = AdvancedAudioPreferences.bluetoothRecoveryLimits.defaultMs
    ) throws {
        guard Self.bluetoothRecoveryRange.contains(bluetoothRecoveryMs) else {
            throw ValidationError.bluetoothRecoveryOutOfRange
        }
        self.keepMicrophoneActiveWhileMuted = keepMicrophoneActiveWhileMuted
        self.bluetoothRecoveryMs = bluetoothRecoveryMs
    }

    /// `bluetoothRecoveryMs` in the `Int64` milliseconds of `OutputRouteChange` / `HeadsetRecovery`.
    public var bluetoothRecoveryWindowMs: Int64 { Int64(bluetoothRecoveryMs) }

    /// The Connection settings sheet's Save, as `ConnectionPreferences.merged(onto:since:)`: each value of `self`
    /// (shown) that differs from `opened` (loaded) replaces that value of `latest` (the store at Save time); the
    /// other keeps `latest`, so a Windows edit made while the sheet was open is not reverted. Throws only for a
    /// window out of bounds, which three valid inputs never produce.
    public func merged(
        onto latest: AdvancedAudioPreferences, since opened: AdvancedAudioPreferences
    ) throws -> AdvancedAudioPreferences {
        try AdvancedAudioPreferences(
            keepMicrophoneActiveWhileMuted: keepMicrophoneActiveWhileMuted != opened.keepMicrophoneActiveWhileMuted
                ? keepMicrophoneActiveWhileMuted : latest.keepMicrophoneActiveWhileMuted,
            bluetoothRecoveryMs: bluetoothRecoveryMs != opened.bluetoothRecoveryMs
                ? bluetoothRecoveryMs : latest.bluetoothRecoveryMs)
    }

    /// Defensive clamp for a window that did not come through the validating initializer.
    public static func boundedBluetoothRecoveryMs(_ value: Int64) -> Int64 {
        min(max(value, Int64(bluetoothRecoveryLimits.minimumMs)), Int64(bluetoothRecoveryLimits.maximumMs))
    }

    /// Typed seconds with the rules of the connection timeouts (`ConnectionPreferences.parseUserSeconds`):
    /// exact decimal, at most three fractional digits, the locale's decimal separator, within bounds.
    public static func parseBluetoothRecoverySeconds(_ text: String, locale: Locale = .current) -> Int? {
        ConnectionPreferences.parseUserSeconds(
            text, minimumMs: bluetoothRecoveryLimits.minimumMs, maximumMs: bluetoothRecoveryLimits.maximumMs,
            locale: locale)
    }

    // MARK: - Storage

    /// Exactly the two keys; the store rewrites both on every save.
    public func fields() -> [String: AudioPreferences.StoredValue] {
        [
            Key.keepMicrophoneActiveWhileMuted.rawValue: .bool(keepMicrophoneActiveWhileMuted),
            Key.bluetoothRecoveryMs.rawValue: .number(Double(bluetoothRecoveryMs)),
        ]
    }

    /// Strict per-key decode (the `AudioPreferences` / `ConnectionPreferences` rules): the Bool is honored only
    /// for a JSON boolean; the window only for an integral JSON number within bounds. Any other value, a missing
    /// key or `null` gives that key's default; unknown keys are ignored.
    public static func from(_ fields: [String: AudioPreferences.StoredValue]) -> AdvancedAudioPreferences {
        let defaults = AdvancedAudioPreferences()
        var keep = defaults.keepMicrophoneActiveWhileMuted
        if case .bool(let value)? = fields[Key.keepMicrophoneActiveWhileMuted.rawValue] { keep = value }
        var window = defaults.bluetoothRecoveryMs
        if case .number(let value)? = fields[Key.bluetoothRecoveryMs.rawValue], value.isFinite,
            value.rounded(.towardZero) == value, value >= Double(bluetoothRecoveryLimits.minimumMs),
            value <= Double(bluetoothRecoveryLimits.maximumMs)
        {
            window = Int(value)
        }
        return
            (try? AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: keep, bluetoothRecoveryMs: window))
            ?? defaults
    }

    /// Missing data, unparsable JSON or a non-object top level → all defaults.
    public static func decodeJSON(_ data: Data?) -> AdvancedAudioPreferences {
        guard let data, let fields = try? JSONDecoder().decode([String: AudioPreferences.StoredValue].self, from: data)
        else {
            return AdvancedAudioPreferences()
        }
        return from(fields)
    }

    /// Both keys as one JSON object (sorted keys).
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields())
    }

    // MARK: - Text

    /// `ConnectionPreferences.seconds` of a window, e.g. `20` or `7.5`.
    public static func seconds(_ milliseconds: Int64) -> String {
        ConnectionPreferences.seconds(Int(clamping: milliseconds))
    }

    /// Android's microphone copy-report line (`StreamReceiver.kt:783` on main `87b15af`), verbatim:
    /// `Muted capture option: <true|false> · Capture retained while muted: <true|false>`. `option` is the live
    /// keep-alive setting, `retained` whether a muted capture is actually running now (gates closed); the two
    /// differ when iOS refused the background start, in the foreground and in duplex. No identifier.
    public static func mutedCaptureText(option: Bool, retained: Bool) -> String {
        "Muted capture option: \(option) · Capture retained while muted: \(retained)"
    }

    /// Copy-report line, without identifiers: the session's effective Bluetooth window (fixed at Connect) and,
    /// for microphone sessions, the current keep-alive preference, e.g.
    /// `Bluetooth route recovery: 20 s (default) · Keep microphone active while muted in background: on`.
    public static func text(bluetoothRecoveryMs: Int64, keepMicrophoneActiveWhileMuted: Bool?) -> String {
        let window = Int64(bluetoothRecoveryLimits.defaultMs) == bluetoothRecoveryMs ? " (default)" : ""
        let text = "Bluetooth route recovery: \(seconds(bluetoothRecoveryMs)) s\(window)"
        guard let keepMicrophoneActiveWhileMuted else { return text }
        let state = keepMicrophoneActiveWhileMuted ? "on" : "off"
        return text + " · Keep microphone active while muted in background: \(state)"
    }
}
