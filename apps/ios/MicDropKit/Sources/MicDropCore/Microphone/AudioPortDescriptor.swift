import Foundation

/// Platform-neutral description of one `AVAudioSessionPortDescription`, the iOS counterpart of Android's
/// `MicrophoneDevice(id, type, source, address)` (`A/MicrophoneSelection.kt:21-23`).
///
/// `uid` and `name` exist only for local comparisons and selector titles. They are never logged or uploaded, and a
/// descriptor is never serialized (the uid of an explicitly chosen port is stored only in `RememberedAudioDevices`);
/// `description` and the mirror therefore omit both so string interpolation and `dump` cannot leak them.
public struct AudioPortDescriptor: Equatable, Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// `AVAudioSessionPortDescription.uid` (the port identity on iOS; there is no separate id).
    public let uid: String
    /// `AVAudioSession.Port` raw value (`portType.rawValue`), e.g. `"BluetoothHFP"`.
    public let type: String
    /// `true` for `availableInputs` / `currentRoute.inputs`, `false` for `currentRoute.outputs`.
    public let isInput: Bool
    /// `portName`; used only for selector titles after control-character removal.
    public let name: String

    public init(uid: String, type: String, isInput: Bool, name: String = "") {
        self.uid = uid
        self.type = type
        self.isInput = isInput
        self.name = name
    }

    /// `MicrophoneKind.forType(type)`; direction is not considered (callers check `isInput`).
    public var microphoneKind: MicrophoneKind? { MicrophoneKind(portTypeRaw: type) }

    /// Redacted: type and direction only (never `uid` or `name`).
    public var description: String {
        "AudioPortDescriptor(type: \(type), \(isInput ? "input" : "output"))"
    }

    public var debugDescription: String { description }
}

/// Redacted reflection: type and direction only (never `uid` or `name`).
extension AudioPortDescriptor: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["type": type, "isInput": isInput], displayStyle: .struct)
    }
}
