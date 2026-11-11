// Remembered audio preferences. Port of `AudioPreferences.kt` and the strict JSON coding of `Application
// Support/MicDrop/audio-settings.json`. The file store itself (`AudioPreferencesStore`, backup-excluded,
// `completeUntilFirstUserAuthentication`) is app-side.

import Foundation

/// Preferences describe the next explicit app connection, not permission to start capture in the
/// background. This file holds kinds only; the identities (port uids) of explicit external choices are
/// remembered separately in `RememberedAudioDevices` (`audio-devices.json`), which restores them only for the
/// kinds named here.
public struct AudioPreferences: Equatable, Sendable {
    /// File name inside `Application Support/MicDrop/`.
    public static let fileName = "audio-settings.json"

    /// The eight persisted keys, in `AudioPreferences.fields()` order (`AudioPreferences.kt:26-31`).
    public enum Key: String, CaseIterable, Sendable {
        case outputEnabled = "outputEnabled"
        case microphoneEnabled = "microphoneEnabled"
        case fastRecovery = "fastRecovery"
        case leStereo = "leStereo"
        case preferredInputKind = "preferredInputKind"
        case preferredOutputKind = "preferredOutputKind"
        case echoCancellation = "echoCancellation"
        case noiseReduction = "noiseReduction"
    }

    /// One JSON value of the settings file, decoded without type coercion. A JSON boolean is `.bool`; a
    /// number is never a Bool (Kotlin `as? Boolean` on `0` fails, so `outputEnabled: 0` decodes as the
    /// default `true`). Arrays and objects are `.other`. Reusable for other small strict JSON files
    /// (e.g. `paused-playback.json`).
    public enum StoredValue: Equatable, Sendable, Codable {
        case bool(Bool)
        case string(String)
        case number(Double)
        case null
        case other

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .other
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .null, .other: try container.encodeNil()
            }
        }
    }

    public var outputEnabled: Bool
    public var microphoneEnabled: Bool
    public var fastRecovery: Bool
    public var leStereo: Bool
    /// nil forces explicit reselection (present-but-invalid stored value).
    public var preferredInputKind: MicrophoneKind?
    /// nil forces explicit reselection (present-but-invalid stored value).
    public var preferredOutputKind: OutputKind?
    public var echoCancellation: Bool
    public var noiseReduction: Bool

    /// Defaults of `AudioPreferences.kt:5-14`.
    public init(
        outputEnabled: Bool = true,
        microphoneEnabled: Bool = false,
        fastRecovery: Bool = true,
        leStereo: Bool = true,
        preferredInputKind: MicrophoneKind? = .builtIn,
        preferredOutputKind: OutputKind? = .default,
        echoCancellation: Bool = false,
        noiseReduction: Bool = false
    ) {
        self.outputEnabled = outputEnabled
        self.microphoneEnabled = microphoneEnabled
        self.fastRecovery = fastRecovery
        self.leStereo = leStereo
        self.preferredInputKind = preferredInputKind
        self.preferredOutputKind = preferredOutputKind
        self.echoCancellation = echoCancellation
        self.noiseReduction = noiseReduction
    }

    /// Mode of the next explicit connection (`AudioPreferences.kt:15-19`). Both toggles off keeps a silent,
    /// microphone-free playback stream.
    public var connectionMode: StreamMode {
        if microphoneEnabled && outputEnabled { return .duplex }
        if microphoneEnabled { return .microphone }
        return .playback
    }

    /// `microphoneEnabled && preferredInputKind != selection.kind` (`AudioPreferences.kt:21-22`).
    public func needsInputSelection(_ selection: MicrophoneSelection) -> Bool {
        microphoneEnabled && preferredInputKind != selection.kind
    }

    /// `preferredOutputKind != selection.preferenceKind` (`AudioPreferences.kt:24`); a nil preference forces
    /// reselection of every output.
    public func needsOutputSelection(_ selection: OutputSelection) -> Bool {
        preferredOutputKind != selection.preferenceKind
    }

    /// Exactly the eight keys (`AudioPreferences.kt:26-31`); a nil kind is written as `""`.
    public func fields() -> [String: StoredValue] {
        [
            Key.outputEnabled.rawValue: .bool(outputEnabled),
            Key.microphoneEnabled.rawValue: .bool(microphoneEnabled),
            Key.fastRecovery.rawValue: .bool(fastRecovery),
            Key.leStereo.rawValue: .bool(leStereo),
            Key.preferredInputKind.rawValue: .string(
                preferredInputKind.map { AudioPreferences.storageName(of: $0) } ?? ""),
            Key.preferredOutputKind.rawValue: .string(
                preferredOutputKind.map { AudioPreferences.storageName(of: $0) } ?? ""),
            Key.echoCancellation.rawValue: .bool(echoCancellation),
            Key.noiseReduction.rawValue: .bool(noiseReduction),
        ]
    }

    /// Strict decode (`AudioPreferences.kt:34-44`): a Bool key is honored only for a JSON boolean, otherwise its
    /// default. Kind keys: absent → `.builtIn` / `.default`; a string equal to an enum storage name → that kind;
    /// anything else (including `""`, non-strings and `null`) → nil. Unknown keys are ignored.
    public static func from(_ fields: [String: StoredValue]) -> AudioPreferences {
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            if case .bool(let value)? = fields[key.rawValue] { return value }
            return fallback
        }
        let inputKind: MicrophoneKind?
        if let stored = fields[Key.preferredInputKind.rawValue] {
            if case .string(let name) = stored {
                inputKind = MicrophoneKind.allCases.first { storageName(of: $0) == name }
            } else {
                inputKind = nil
            }
        } else {
            inputKind = .builtIn
        }
        let outputKind: OutputKind?
        if let stored = fields[Key.preferredOutputKind.rawValue] {
            if case .string(let name) = stored {
                outputKind = OutputKind.allCases.first { storageName(of: $0) == name }
            } else {
                outputKind = nil
            }
        } else {
            outputKind = .default
        }
        return AudioPreferences(
            outputEnabled: bool(.outputEnabled, true),
            microphoneEnabled: bool(.microphoneEnabled, false),
            fastRecovery: bool(.fastRecovery, true),
            leStereo: bool(.leStereo, true),
            preferredInputKind: inputKind,
            preferredOutputKind: outputKind,
            echoCancellation: bool(.echoCancellation, false),
            noiseReduction: bool(.noiseReduction, false))
    }

    /// Decodes the settings file. Missing data, unparsable JSON or a non-object top level → all defaults.
    public static func decodeJSON(_ data: Data?) -> AudioPreferences {
        guard let data,
            let fields = try? JSONDecoder().decode([String: StoredValue].self, from: data)
        else {
            return AudioPreferences()
        }
        return from(fields)
    }

    /// Encodes all eight keys as one JSON object (sorted keys). The store writes the whole object on every
    /// update, mirroring `AppAudioSettings.update` (`AppAudioSettings.kt:11-23`).
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields())
    }

    /// Stored enum name of a microphone kind (Kotlin `MicrophoneKind.name`): `BUILT_IN`, `WIRED`, `USB`,
    /// `SCO`, `LE`.
    public static func storageName(of kind: MicrophoneKind) -> String {
        switch kind {
        case .builtIn: return "BUILT_IN"
        case .wired: return "WIRED"
        case .usb: return "USB"
        case .sco: return "SCO"
        case .le: return "LE"
        }
    }

    /// Stored enum name of an output kind (Kotlin `OutputKind.name`): `DEFAULT`, `PHONE`, `WIRED`, `USB`,
    /// `BLUETOOTH`, `LE`, `HEARING_AID`, `OTHER`.
    public static func storageName(of kind: OutputKind) -> String {
        switch kind {
        case .default: return "DEFAULT"
        case .phone: return "PHONE"
        case .wired: return "WIRED"
        case .usb: return "USB"
        case .bluetooth: return "BLUETOOTH"
        case .le: return "LE"
        case .hearingAid: return "HEARING_AID"
        case .other: return "OTHER"
        }
    }
}
