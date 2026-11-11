import Foundation

/// Media-output category of a selection or of one current-route output.
///
/// Port of `OutputKind` (`OutputSelection.kt:5-25`), labels.
///
/// - `rawValue` is the **wire label** (`output_control.selection`, Go allow-list
///   `internal/diagnostics/output_control.go:20`; Android `name.lowercase()`), per port-rules.
/// - `persistedName` is the Android enum `name` stored in `audio-settings.json`
/// (`preferredOutputKind`, / `AppAudioSettings.kt:21`). Persistence must use `persistedName` / `init?(persistedName:)`,
/// never `rawValue`.
public enum OutputKind: String, CaseIterable, Sendable {
    case `default` = "default"
    case phone = "phone"
    case wired = "wired"
    case usb = "usb"
    case bluetooth = "bluetooth"
    case le = "le"
    /// Never produced on iOS (Made-for-iPhone hearing aids report `.bluetoothLE`); kept for parity.
    case hearingAid = "hearing_aid"
    case other = "other"

    /// iOS UI label: DEFAULT/PHONE adapted, others verbatim.
    public var label: String {
        switch self {
        case .default: return "iPhone media output"
        case .phone: return "iPhone speaker"
        case .wired: return "wired headphones"
        case .usb: return "USB audio output"
        case .bluetooth: return "Bluetooth media output"
        case .le: return "Bluetooth LE output"
        case .hearingAid: return "hearing aid output"
        case .other: return "audio output"
        }
    }

    /// Wire label (`default|phone|wired|usb|bluetooth|le|hearing_aid|other`). Same as `rawValue`.
    public var wireLabel: String { rawValue }

    /// Android enum name used for persistence (`DEFAULT`, `HEARING_AID`, ...).
    public var persistedName: String {
        switch self {
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

    /// Exact enum-name lookup (`OutputKind.entries.firstOrNull { it.name == value }`,
    /// `AudioPreferences.kt:41-42`). `""` and unknown names return nil.
    public init?(persistedName: String) {
        guard let kind = OutputKind.allCases.first(where: { $0.persistedName == persistedName }) else { return nil }
        self = kind
    }

    /// `bluetooth` = kind in {BLUETOOTH, LE, HEARING_AID} (`OutputSelection.kt:10`).
    public var isBluetooth: Bool { self == .bluetooth || self == .le || self == .hearingAid }

    /// iOS `AVAudioSession.Port` raw value -> kind (table; replaces `forType`). `nil` = not a media output (earpiece,
    /// HFP, input-only ports): never offered and an actual route containing it counts as unknown. Unknown output port
    /// types map to `.other`.
    public static func forPortType(_ portType: String) -> OutputKind? {
        switch portType {
        case RouteOutput.PortType.builtInSpeaker: return .phone
        case RouteOutput.PortType.builtInReceiver: return nil
        case RouteOutput.PortType.headphones: return .wired
        case RouteOutput.PortType.usbAudio: return .usb
        case RouteOutput.PortType.bluetoothA2DP: return .bluetooth
        case RouteOutput.PortType.bluetoothLE: return .le
        case RouteOutput.PortType.bluetoothHFP: return nil
        case RouteOutput.PortType.lineIn, RouteOutput.PortType.builtInMic, RouteOutput.PortType.headsetMic:
            return nil
        default: return .other
        }
    }

    /// The Go route allow-list (`internal/diagnostics/report.go:96`, `routes`) in its order. Every
    /// non-nil `routeLabel(portType:)` is a member; `hearing aid` is never produced on iOS.
    public static let hostRouteLabels = [
        "phone speaker", "earpiece", "wired headphones", "USB audio", "Bluetooth A2DP media",
        "Bluetooth SCO voice", "Bluetooth LE audio", "hearing aid", "HDMI", "line output", "other",
    ]

    /// Fixed diagnostics route label from the Go allow-list (`report.go:96`),. Returns nil for input-only port types
    /// (not an output).
    public static func routeLabel(portType: String) -> String? {
        switch portType {
        case RouteOutput.PortType.builtInSpeaker: return "phone speaker"
        case RouteOutput.PortType.builtInReceiver: return "earpiece"
        case RouteOutput.PortType.headphones: return "wired headphones"
        case RouteOutput.PortType.usbAudio: return "USB audio"
        case RouteOutput.PortType.bluetoothA2DP: return "Bluetooth A2DP media"
        case RouteOutput.PortType.bluetoothLE: return "Bluetooth LE audio"
        case RouteOutput.PortType.bluetoothHFP: return "Bluetooth SCO voice"
        case RouteOutput.PortType.hdmi, RouteOutput.PortType.displayPort: return "HDMI"
        case RouteOutput.PortType.lineOut: return "line output"
        case RouteOutput.PortType.lineIn, RouteOutput.PortType.builtInMic, RouteOutput.PortType.headsetMic:
            return nil
        default: return "other"
        }
    }
}
