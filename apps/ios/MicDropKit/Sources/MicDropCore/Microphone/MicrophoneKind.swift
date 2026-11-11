import Foundation

/// Microphone input kinds (`A/MicrophoneSelection.kt:5-19`).
///
/// The raw value is the persisted preference name (`preferredInputKind` in `audio-settings.json`): exactly the Android
/// enum names. `label` is the fixed wire/UI route label validated by the host (`G/diagnostics/report.go:97`).
///
/// iOS has no public LE Audio microphone input: `.le` exists only so a persisted `LE`
/// preference decodes (and therefore forces explicit reselection); no port maps to it.
public enum MicrophoneKind: String, CaseIterable, Sendable {
    case builtIn = "BUILT_IN"
    case wired = "WIRED"
    case usb = "USB"
    case sco = "SCO"
    case le = "LE"

    /// Raw `AVAudioSession.Port` values of the input ports that map to a kind. MicDropCore cannot import AVFoundation;
    /// the app builds `AudioPortDescriptor` from `port.portType.rawValue`, and its tests assert these constants equal
    /// `AVAudioSession.Port.builtInMic/.headsetMic/.usbAudio/.bluetoothHFP.rawValue`.
    public enum PortType {
        public static let builtInMic = "MicrophoneBuiltIn"
        public static let headsetMic = "MicrophoneWired"
        public static let usbAudio = "USBAudio"
        public static let bluetoothHFP = "BluetoothHFP"
    }

    /// Route label used for `microphone.route` when no microphone kind applies.
    public static let unavailableRouteLabel = "unavailable"

    /// The five host-accepted microphone labels, in `MicrophoneKind` order
    /// (`G/diagnostics/report.go:97` `microphoneRoutes`).
    public static let routeLabels: [String] = MicrophoneKind.allCases.map { $0.label }

    /// Fixed wire + UI label (`A/MicrophoneSelection.kt:6-7`), verbatim.
    public var label: String {
        switch self {
        case .builtIn: return "built-in microphone"
        case .wired: return "wired headset microphone"
        case .usb: return "USB microphone"
        case .sco: return "Bluetooth SCO microphone"
        case .le: return "Bluetooth LE microphone"
        }
    }

    /// `MicrophoneKind.bluetooth` (`A/MicrophoneSelection.kt:5-7`): SCO and LE.
    public var isBluetooth: Bool { self == .sco || self == .le }

    /// Kotlin-name alias of `isBluetooth` (`kind.bluetooth` in the Android source).
    public var bluetooth: Bool { isBluetooth }

    /// Every kind except `.le` can be offered on iOS.
    public var isSelectableOnIOS: Bool { self != .le }

    /// The `AVAudioSession.Port` raw value of this kind's input port; `nil` for `.le`.
    public var portTypeRaw: String? {
        switch self {
        case .builtIn: return PortType.builtInMic
        case .wired: return PortType.headsetMic
        case .usb: return PortType.usbAudio
        case .sco: return PortType.bluetoothHFP
        case .le: return nil
        }
    }

    /// `MicrophoneKind.forType` (`A/MicrophoneSelection.kt:10-17`) over iOS port types:
    /// `.builtInMic` → builtIn, `.headsetMic` → wired, `.usbAudio` → usb,
    /// `.bluetoothHFP` → sco. Everything else (A2DP, BLE output, line in, car audio,
    /// continuity microphone, speakers, unknown) is not an input kind.
    public init?(portTypeRaw: String) {
        switch portTypeRaw {
        case PortType.builtInMic: self = .builtIn
        case PortType.headsetMic: self = .wired
        case PortType.usbAudio: self = .usb
        case PortType.bluetoothHFP: self = .sco
        default: return nil
        }
    }

    /// `microphone.route` label for an actual routed port type: the kind label, or `"unavailable"` when the port is
    /// absent or not a microphone kind.
    public static func routeLabel(portTypeRaw: String?) -> String {
        guard let portTypeRaw, let kind = MicrophoneKind(portTypeRaw: portTypeRaw) else {
            return unavailableRouteLabel
        }
        return kind.label
    }
}
