// Remembered input and output devices across launches. Android saves a stable Bluetooth address and profile in private,
// backup-excluded preferences (`AudioDevicePreferences.kt`); the iPhone saves the route uid instead and also remembers
// USB and general (other) outputs and USB microphones, never wired ports. The strict JSON coding of `Application
// Support/MicDrop/audio-devices.json` is here; the file store (`AudioPreferencesStore`, the protection and backup
// exclusion of `audio-settings.json`) is app-side and writes an identity before the kind it belongs to.

import Foundation

/// The route identity of the explicitly selected external output and microphone input: the opaque
/// `AVAudioSessionPortDescription.uid`, its port type and its kind. iPhone media output, the iPhone speaker, the
/// temporary speaker and the built-in microphone carry no identity, and wired ports only a port-wide one; none of
/// them is stored.
///
/// A remembered device is a candidate, not a route. `restoredOutput(preferredKind:)` and
/// `restoredInput(preferredKind:)` return it only while the audio preferences still name its kind. The UI
/// availability, the Connect preflight and the session's route verification then accept it only when the
/// current route resolves exactly that identity (`OutputSelection.refresh`, `MicrophoneSelection.resolveInput` /
/// `refreshBluetooth`). A missing, duplicated or changed identity stays unavailable and gated until the same
/// device is the route again or the user chooses another device; nothing is substituted by name or kind, and
/// nothing falls back to the speaker or the built-in microphone. Restoring starts no session and no capture and
/// is not microphone consent: `microphoneEnabled`, the record permission and Connect still decide.
///
/// A uid can embed a Bluetooth address. It stays in this file and in process memory; `description` and the
/// mirror show kinds only, and no log, diagnostics text or report includes it.
public struct RememberedAudioDevices: Equatable, Sendable {
    /// File name inside `Application Support/MicDrop/`.
    public static let fileName = "audio-devices.json"
    /// Longest remembered uid in UTF-8 bytes. A longer uid is not remembered, so after a relaunch the kind alone
    /// asks for an explicit reselection.
    public static let uidLimit = 512

    /// The persisted keys. A device without an identity has none of its three keys.
    public enum Key: String, CaseIterable, Sendable {
        case outputKind = "outputKind"
        case outputPortType = "outputPortType"
        case outputUID = "outputUID"
        case inputKind = "inputKind"
        case inputPortType = "inputPortType"
        case inputUID = "inputUID"
    }

    /// External output pin (USB, Bluetooth, Bluetooth LE or other output) with its uid.
    public let output: OutputSelection?
    /// USB or Bluetooth HFP microphone with its uid; an HFP input carries its `HeadsetEndpoint`.
    public let input: MicrophoneSelection?

    /// Keeps only what `rememberable(output:)` / `rememberable(input:)` accept; anything else is dropped.
    public init(output: OutputSelection? = nil, input: MicrophoneSelection? = nil) {
        self.output = output.flatMap { RememberedAudioDevices.rememberable(output: $0) }
        self.input = input.flatMap { RememberedAudioDevices.rememberable(input: $0) }
    }

    /// Nothing remembered.
    public var isEmpty: Bool { output == nil && input == nil }

    // MARK: - Rules

    /// The stored form of an output choice: an explicit kind other than PHONE (so never the temporary speaker) and
    /// WIRED, a port type that maps to that kind (`OutputKind.forPortType`) and a non-empty uid within `uidLimit`;
    /// `returnOnBluetooth` is dropped. Nil for everything else.
    ///
    /// Wired headphones (`Headphones`) and the wired headset microphone (`MicrophoneWired`) report a port-wide uid
    /// on iOS rather than one per device, so remembering them would accept any wired device after a relaunch,
    /// which is substitution by kind. They are never stored: after a relaunch their kind alone asks for an
    /// explicit reselection (`AudioPreferences.needsOutputSelection` / `needsInputSelection`).
    public static func rememberable(output selection: OutputSelection) -> OutputSelection? {
        guard selection.explicit, selection.kind != .phone, selection.kind != .wired,
            OutputKind.forPortType(selection.portType) == selection.kind, validUID(selection.uid)
        else { return nil }
        return OutputSelection(kind: selection.kind, portType: selection.portType, uid: selection.uid)
    }

    /// The stored form of an input choice: USB or HFP (never built-in, never the unselectable LE, never the wired
    /// headset microphone; see `rememberable(output:)`), with an identity whose port type maps to that kind and a
    /// non-empty uid within `uidLimit`. The identity is the pinned `HeadsetEndpoint` when present, else
    /// `(portType, portUID)`. Nil for everything else.
    public static func rememberable(input selection: MicrophoneSelection) -> MicrophoneSelection? {
        let kind = selection.kind
        guard kind != .builtIn, kind != .wired, kind.isSelectableOnIOS else { return nil }
        let portType = selection.headsetEndpoint?.type ?? selection.portType
        let uid = selection.headsetEndpoint?.uid ?? selection.portUID ?? ""
        guard MicrophoneKind(portTypeRaw: portType) == kind, validUID(uid) else { return nil }
        return MicrophoneSelection(
            kind: kind, portUID: uid, portType: portType,
            headsetEndpoint: kind.isBluetooth ? HeadsetEndpoint(type: portType, uid: uid) : nil)
    }

    /// The output selection of a new process: the remembered pin while its kind is the persisted
    /// `preferredOutputKind`, else `OutputSelection.restored(preferredKind)`. For an external kind without a
    /// matching identity that is DEFAULT, which `AudioPreferences.needsOutputSelection` keeps gated until an
    /// explicit reselection.
    public func restoredOutput(preferredKind: OutputKind?) -> OutputSelection {
        if let output, output.kind == preferredKind { return output }
        return OutputSelection.restored(preferredKind)
    }

    /// The input selection of a new process: the remembered input while its kind is the persisted
    /// `preferredInputKind`, else the built-in microphone. For another persisted kind,
    /// `AudioPreferences.needsInputSelection` keeps an enabled microphone gated until an explicit reselection.
    public func restoredInput(preferredKind: MicrophoneKind?) -> MicrophoneSelection {
        if let input, input.kind == preferredKind { return input }
        return MicrophoneSelection()
    }

    /// After an output choice (or a session's verified output): its identity when rememberable, else none, so
    /// DEFAULT, PHONE, the temporary speaker and wired headphones forget the previous pin. The remembered input is
    /// kept.
    public func remembering(output selection: OutputSelection) -> RememberedAudioDevices {
        RememberedAudioDevices(output: selection, input: input)
    }

    /// After an input choice: its identity when rememberable, else none (the built-in and wired microphones forget
    /// the previous input). The remembered output is kept.
    public func remembering(input selection: MicrophoneSelection) -> RememberedAudioDevices {
        RememberedAudioDevices(output: output, input: selection)
    }

    private static func validUID(_ uid: String) -> Bool {
        !uid.isEmpty && uid.utf8.count <= uidLimit
    }

    // MARK: - Storage

    /// The keys of the remembered devices: kinds by their persisted enum names (`OutputKind.persistedName`,
    /// `AudioPreferences.storageName(of:)`), port types and uids verbatim. The store rewrites the whole file.
    public func fields() -> [String: AudioPreferences.StoredValue] {
        var fields: [String: AudioPreferences.StoredValue] = [:]
        if let output {
            fields[Key.outputKind.rawValue] = .string(output.kind.persistedName)
            fields[Key.outputPortType.rawValue] = .string(output.portType)
            fields[Key.outputUID.rawValue] = .string(output.uid)
        }
        if let input {
            fields[Key.inputKind.rawValue] = .string(AudioPreferences.storageName(of: input.kind))
            fields[Key.inputPortType.rawValue] = .string(input.portType)
            fields[Key.inputUID.rawValue] = .string(input.portUID ?? "")
        }
        return fields
    }

    /// Strict decode: a device is restored only when its three keys are JSON strings, the kind is an exact enum
    /// name and the result passes `rememberable` (kind/port-type agreement, uid bounds). Anything else (a missing
    /// or non-string key, an unknown kind, an empty or oversized uid, a port type of another kind) leaves that
    /// device unremembered; unknown keys are ignored.
    public static func from(_ fields: [String: AudioPreferences.StoredValue]) -> RememberedAudioDevices {
        func string(_ key: Key) -> String? {
            if case .string(let value)? = fields[key.rawValue] { return value }
            return nil
        }
        var output: OutputSelection?
        if let name = string(.outputKind), let kind = OutputKind(persistedName: name),
            let portType = string(.outputPortType), let uid = string(.outputUID)
        {
            output = OutputSelection(kind: kind, portType: portType, uid: uid)
        }
        var input: MicrophoneSelection?
        if let name = string(.inputKind),
            let kind = MicrophoneKind.allCases.first(where: { AudioPreferences.storageName(of: $0) == name }),
            let portType = string(.inputPortType), let uid = string(.inputUID)
        {
            input = MicrophoneSelection(
                kind: kind, portUID: uid, portType: portType,
                headsetEndpoint: kind.isBluetooth ? HeadsetEndpoint(type: portType, uid: uid) : nil)
        }
        return RememberedAudioDevices(output: output, input: input)
    }

    /// Missing data, unparsable JSON or a non-object top level → nothing remembered.
    public static func decodeJSON(_ data: Data?) -> RememberedAudioDevices {
        guard let data, let fields = try? JSONDecoder().decode([String: AudioPreferences.StoredValue].self, from: data)
        else {
            return RememberedAudioDevices()
        }
        return from(fields)
    }

    /// The remembered devices as one JSON object (sorted keys); `{}` when nothing is remembered.
    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields())
    }
}

/// Redacted text and reflection: kinds only, never a uid (also not in `dump` or test failure messages).
extension RememberedAudioDevices: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "RememberedAudioDevices(output: \(outputLabel), input: \(inputLabel))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["output": outputLabel, "input": inputLabel], displayStyle: .struct)
    }

    private var outputLabel: String { output?.kind.wireLabel ?? "none" }
    private var inputLabel: String { input?.kind.rawValue ?? "none" }
}
