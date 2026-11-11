import Foundation

/// The user's concrete microphone choice (`A/MicrophoneSelection.kt:25-72`).
///
/// iOS fields: `kind`, `portUID` (nil for the built-in microphone), `portType` (raw
/// `AVAudioSession.Port`), `headsetEndpoint` (Bluetooth only). Android's `leStereo` is not
/// carried (the persisted `leStereo` preference is kept untouched but never read on iOS).
/// `kind` is persisted as `preferredInputKind`; iOS also remembers the identity of an explicit
/// wired/USB/HFP choice across launches (`RememberedAudioDevices`, protected local storage only),
/// where Android keeps the port in process memory (`A/MainActivity.kt:1353-1357`).
/// `description` and the mirror never show the uid.
public struct MicrophoneSelection: Equatable, Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public var kind: MicrophoneKind
    /// `AVAudioSessionPortDescription.uid` of the chosen port; `nil` for `.builtIn`.
    public var portUID: String?
    /// Raw `AVAudioSession.Port` of the chosen port (`"MicrophoneBuiltIn"` by default).
    public var portType: String
    /// Pinned headset identity (Bluetooth selections only); written only to `RememberedAudioDevices`.
    public var headsetEndpoint: HeadsetEndpoint?

    /// `MicrophoneSelection()` = built-in microphone. `portType` defaults to the kind's
    /// port type (`""` for `.le`, which no iOS port produces).
    public init(
        kind: MicrophoneKind = .builtIn, portUID: String? = nil, portType: String? = nil,
        headsetEndpoint: HeadsetEndpoint? = nil
    ) {
        self.kind = kind
        self.portUID = portUID
        self.portType = portType ?? kind.portTypeRaw ?? ""
        self.headsetEndpoint = headsetEndpoint
    }

    /// Selection for one selectable input port (selector): `nil` when the port is not an input, not a microphone kind,
    /// or a Bluetooth port without a uid. Bluetooth selections carry a `HeadsetEndpoint` built from the port.
    public init?(port: AudioPortDescriptor) {
        guard port.isInput, let kind = MicrophoneKind(portTypeRaw: port.type), kind.isSelectableOnIOS else {
            return nil
        }
        if kind.isBluetooth {
            guard let endpoint = HeadsetEndpoint(port: port) else { return nil }
            self.init(kind: kind, portUID: port.uid, portType: port.type, headsetEndpoint: endpoint)
        } else if kind == .builtIn {
            self.init()
        } else {
            self.init(kind: kind, portUID: port.uid, portType: port.type)
        }
    }

    /// The default built-in selection (`MicrophoneSelection()`; `.builtIn`).
    public static let builtIn = MicrophoneSelection()

    /// `kind.bluetooth`.
    public var isBluetooth: Bool { kind.isBluetooth }

    /// `voiceInput` (`A/MicrophoneSelection.kt:33`); on iOS only HFP (`.sco`) is a voice input.
    public var voiceInput: Bool { kind == .sco }

    /// `outputChannels` (`:34`): 1 for a voice input, else 2. Used for Bluetooth duplex output verification; the
    /// non-Bluetooth echo-cancellation mono output is an `AudioSessionPlan` property, not a selection property.
    public var outputChannels: Int { voiceInput ? 1 : 2 }

    /// `acceptsOutputChannels(channels)` (`:35`).
    public func acceptsOutputChannels(_ channels: Int) -> Bool { channels == outputChannels }

    /// `supportsOutputChannels(advertised)` (`:36-37`): true when nothing positive is
    /// advertised, or `outputChannels` is among the advertised counts.
    public func supportsOutputChannels(_ advertised: [Int]) -> Bool {
        !advertised.contains(where: { $0 > 0 }) || advertised.contains(outputChannels)
    }

    /// `sameDevice(other)` (`:38-39`): kind, uid and port type equal.
    public func sameDevice(_ other: MicrophoneSelection) -> Bool {
        kind == other.kind && portUID == other.portUID && portType == other.portType
    }

    /// `resolveInput(inputs)` (`:56-67`). Candidates are inputs of this kind. builtIn → first candidate; wired/usb →
    /// the single candidate with the selected uid and type (zero or more than one → nil: never another attached input);
    /// Bluetooth → the pinned endpoint's ORIGINAL port only (never "first of several Bluetooth microphones").
    public func resolveInput(_ inputs: [AudioPortDescriptor]) -> AudioPortDescriptor? {
        let candidates = inputs.filter { $0.isInput && MicrophoneKind(portTypeRaw: $0.type) == kind }
        switch kind {
        case .builtIn:
            return candidates.first
        case .wired, .usb:
            let matching = candidates.filter { $0.uid == portUID && $0.type == portType }
            return matching.count == 1 ? matching[0] : nil
        case .sco, .le:
            guard let endpoint = pinnedEndpoint else { return nil }
            return endpoint.resolve(candidates)
        }
    }

    /// `matchesInput(actual, expected)` (`:69-71`) with the selection's pinned port as the
    /// expected one: actual exists, is an input of this kind, and (builtIn or the same uid and
    /// type as the pinned port). For Bluetooth the pinned port is the `HeadsetEndpoint`
    /// (identity), else `(portType, portUID)`. `MicrophoneRouting` (app) adds the Bluetooth
    /// communication-route check.
    public func matchesInput(_ actual: AudioPortDescriptor?) -> Bool {
        guard let actual, actual.isInput, MicrophoneKind(portTypeRaw: actual.type) == kind else { return false }
        if kind == .builtIn { return true }
        guard let expected = expectedPort else { return false }
        return actual.uid == expected.uid && actual.type == expected.type
    }

    /// Bluetooth duplex output check (`:41-43`): actual exists, is an output whose type is the pinned port type
    /// (`.bluetoothHFP`, a type of this kind) and carries the pinned headset uid. The "same uid for HFP input and
    /// output" assumption is device-validated; the current-route pairing fallback lives in `MicrophoneRouting` (app).
    public func matchesOutput(_ actual: AudioPortDescriptor?) -> Bool {
        guard kind.isBluetooth, let actual, !actual.isInput, let expected = expectedPort,
            MicrophoneKind(portTypeRaw: actual.type) == kind
        else { return false }
        return actual.type == expected.type && actual.uid == expected.uid
    }

    /// `refreshBluetooth(devices)` (`:47-54`): only for a previously explicit headset;
    /// resolves through the pinned endpoint over `inputs` and returns a copy with the
    /// endpoint retained (and the resolved uid), or nil. Grants no capture intent and is
    /// never written to saved state.
    public func refreshBluetooth(_ inputs: [AudioPortDescriptor]) -> MicrophoneSelection? {
        guard kind.isBluetooth, let endpoint = pinnedEndpoint, let chosen = endpoint.resolve(inputs) else {
            return nil
        }
        guard chosen.type == portType, MicrophoneKind(portTypeRaw: chosen.type) == kind else { return nil }
        var copy = self
        copy.portUID = chosen.uid
        copy.headsetEndpoint = endpoint
        return copy
    }

    /// The endpoint used for Bluetooth resolution: the pinned one, or (for a selection
    /// built without one) the `(portType, portUID)` pair (nil for an empty uid). Never a
    /// "first match".
    private var pinnedEndpoint: HeadsetEndpoint? {
        if let headsetEndpoint { return headsetEndpoint }
        guard let portUID else { return nil }
        return HeadsetEndpoint(type: portType, uid: portUID)
    }

    /// The port an actual route must equal (Kotlin `expected`): the pinned headset identity
    /// when present, else `(portType, portUID)`; nil without a uid.
    private var expectedPort: (type: String, uid: String)? {
        if let headsetEndpoint { return (type: headsetEndpoint.type, uid: headsetEndpoint.uid) }
        guard let portUID else { return nil }
        return (type: portType, uid: portUID)
    }

    /// Redacted: kind only (never the uid).
    public var description: String { "MicrophoneSelection(kind: \(kind.rawValue))" }

    public var debugDescription: String { description }
}

/// Redacted reflection (`dump`, debugger summaries, default printing of containing values): whether a uid or headset
/// pin is set, never its value.
extension MicrophoneSelection: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "kind": kind.rawValue, "portType": portType, "portUID": portUID == nil ? "none" : "redacted",
                "headsetEndpoint": headsetEndpoint == nil ? "none" : "redacted",
            ],
            displayStyle: .struct)
    }
}
