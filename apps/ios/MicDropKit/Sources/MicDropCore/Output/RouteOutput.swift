import Foundation

/// Identity of one entry of `AVAudioSession.currentRoute.outputs` (replaces Android `OutputDevice`,
/// `OutputSelection.kt:27`). Equality = `(portType, uid)`.
///
/// `uid` may embed a Bluetooth MAC. Never log, display or transmit it; the only copy outside process memory is a chosen
/// pin in the protected local `RememberedAudioDevices` file. `description` redacts it.
public struct RouteOutput: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// `AVAudioSession.Port.rawValue` of the port description.
    public let portType: String
    /// `AVAudioSessionPortDescription.uid`.
    public let uid: String

    public init(portType: String, uid: String) {
        self.portType = portType
        self.uid = uid
    }

    /// Media-output kind of this port, nil when it is not a media output.
    public var kind: OutputKind? { OutputKind.forPortType(portType) }

    /// Go route label of this port (`report.go:96`), nil for input-only ports.
    public var routeLabel: String? { OutputKind.routeLabel(portType: portType) }

    /// Redacted: never includes `uid`.
    public var description: String { "RouteOutput(\(portType))" }
    public var debugDescription: String { description }

    /// `AVAudioSession.Port` raw values used by the pure mapping (MicDropCore cannot import
    /// AVFoundation). The app target must keep these equal to the SDK constants
    /// (`AVAudioSession.Port.builtInSpeaker.rawValue == RouteOutput.PortType.builtInSpeaker`, ...);
    /// `AudioRouteInspector` (app-output) asserts this at start-up.
    public enum PortType {
        public static let builtInSpeaker = "Speaker"
        public static let builtInReceiver = "Receiver"
        public static let headphones = "Headphones"
        public static let usbAudio = "USBAudio"
        public static let bluetoothA2DP = "BluetoothA2DPOutput"
        public static let bluetoothLE = "BluetoothLE"
        public static let bluetoothHFP = "BluetoothHFP"
        public static let hdmi = "HDMIOutput"
        public static let displayPort = "DisplayPort"
        public static let lineOut = "LineOut"
        public static let airPlay = "AirPlay"
        public static let carAudio = "CarAudio"
        public static let thunderbolt = "Thunderbolt"
        public static let pci = "PCI"
        public static let fireWire = "Firewire"
        public static let avb = "AVB"
        public static let virtual = "Virtual"
        // Input-only ports (never in `currentRoute.outputs`; mapped to nil).
        public static let lineIn = "LineIn"
        public static let builtInMic = "MicrophoneBuiltIn"
        public static let headsetMic = "MicrophoneWired"
    }
}

/// Redacted reflection (`dump`, debugger summaries, default printing of containing values): the mirror exposes
/// `portType` only, never `uid`.
extension RouteOutput: CustomReflectable {
    public var customMirror: Mirror {
        Mirror(self, children: ["portType": portType], displayStyle: .struct)
    }
}
