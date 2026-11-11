import Foundation

/// In-memory identity of an explicitly selected Bluetooth (HFP) headset (`A/HeadsetEndpoint.kt`).
///
/// Android pins the communication sink `(id, type, address)` and has address-masking,
/// recreated-port and paired-address rules. On iOS the port `uid` is the identity and is not
/// redacted, so the endpoint is `(type, uid)` and only the ORIGINAL / PROFILE_MISSING /
/// IDENTITY_MISSING / AMBIGUOUS states are produced. Never log or upload `uid`; the only place it
/// is stored is the protected local `RememberedAudioDevices` file.
public struct HeadsetEndpoint: Equatable, Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// `HeadsetEndpointState` (`A/HeadsetEndpoint.kt:3-9`); raw values are the fixed
    /// "Last check" texts, verbatim. `.recreated` and `.addressMissing` are never produced
    /// on iOS and are kept only so the vocabulary matches Android.
    public enum State: String, CaseIterable, Sendable {
        case original = "original port available"
        case recreated = "same headset available on a recreated port"
        case profileMissing = "selected audio profile unavailable"
        case identityMissing = "original headset identity unavailable"
        case addressMissing = "original port missing; stable Bluetooth address unavailable"
        case ambiguous = "original headset identity ambiguous"

        /// `HeadsetEndpointState.text`.
        public var text: String { rawValue }
    }

    /// `HeadsetEndpointMatch` (`A/HeadsetEndpoint.kt:11`).
    public struct Match: Equatable, Sendable {
        public let port: AudioPortDescriptor?
        public let state: State

        public init(port: AudioPortDescriptor?, state: State) {
            self.port = port
            self.state = state
        }
    }

    /// `AVAudioSession.Port` raw value of the pinned port (always `"BluetoothHFP"` today).
    public let type: String
    /// Pinned `AVAudioSessionPortDescription.uid`; never empty.
    public let uid: String

    /// Pins `(type, uid)`; `nil` when `uid` is empty (then the Bluetooth choice is not offered).
    public init?(type: String, uid: String) {
        guard !uid.isEmpty else { return nil }
        self.type = type
        self.uid = uid
    }

    /// Pins the port chosen in the selector; `nil` when its `uid` is empty.
    public init?(port: AudioPortDescriptor) {
        self.init(type: port.type, uid: port.uid)
    }

    /// `inspect(devices)` (`A/HeadsetEndpoint.kt:39-51`) over iOS inputs:
    /// no input of the pinned type → `.profileMissing`; inputs of that type exist but none
    /// has the pinned uid → `.identityMissing`; exactly one → `.original` with the port;
    /// more than one with the pinned uid → `.ambiguous`.
    public func inspect(_ inputs: [AudioPortDescriptor]) -> Match {
        let profile = inputs.filter { $0.isInput && $0.type == type }
        if profile.isEmpty { return Match(port: nil, state: .profileMissing) }
        let matching = profile.filter { $0.uid == uid }
        switch matching.count {
        case 0: return Match(port: nil, state: .identityMissing)
        case 1: return Match(port: matching[0], state: .original)
        default: return Match(port: nil, state: .ambiguous)
        }
    }

    /// `resolve(devices)` = `inspect(devices).device`.
    public func resolve(_ inputs: [AudioPortDescriptor]) -> AudioPortDescriptor? {
        inspect(inputs).port
    }

    /// Same pinned port identity (type and uid), any direction. Callers that need an input
    /// or an output check `isInput` themselves (`MicrophoneSelection.matchesOutput`).
    public func matches(_ actual: AudioPortDescriptor?) -> Bool {
        guard let actual else { return false }
        return actual.type == type && actual.uid == uid
    }

    /// Redacted: never prints `uid`.
    public var description: String { "HeadsetEndpoint(type: \(type))" }

    public var debugDescription: String { description }

    /// Copy-report line: `Selected headset identity: port UID · Bluetooth permission: not required on iOS`. Identity
    /// values are never included.
    public static let identityText = "\(identityTextPrefix) port UID · Bluetooth permission: not required on iOS"

    /// First words of `identityText`; the terminal copy report replaces earlier lines with this
    /// prefix (`A/StreamReceiver.kt:796-800`).
    public static let identityTextPrefix = "Selected headset identity:"
}

/// Redacted reflection: the pinned port type only, never the uid.
extension HeadsetEndpoint: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["type": type], displayStyle: .struct)
    }
}

/// name for `HeadsetEndpoint.State`.
public typealias HeadsetEndpointState = HeadsetEndpoint.State
/// name for `HeadsetEndpoint.Match`.
public typealias HeadsetEndpointMatch = HeadsetEndpoint.Match
