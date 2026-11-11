import Foundation

/// One row of the microphone selector (`A/MicrophoneRouting.kt:13`, `:249-268`).
public struct MicrophoneChoice: Identifiable, Equatable, Sendable {
    public let selection: MicrophoneSelection
    public let title: String

    public init(selection: MicrophoneSelection, title: String) {
        self.selection = selection
        self.title = title
    }

    /// Titles are unique by construction (per-kind numbering), so the title identifies a row
    /// without exposing the port uid.
    public var id: String { title }

    /// First row, always present (`A/MicrophoneRouting.kt:252`).
    public static let builtInTitle = "Built-in phone microphone"

    /// Selector footer while a retained session hides Bluetooth inputs (a non-Bluetooth microphone session, or a
    /// playback session, Paused included; D042): HFP inputs cannot be listed without rerouting live audio.
    public static let bluetoothUnavailableFooter = "Stop to choose a Bluetooth headset microphone."

    /// Port selector names keep at most this many characters (`A/MicrophoneRouting.kt:261`).
    public static let nameLimit = 60

    /// `choices(context)` (`A/MicrophoneRouting.kt:249-268`) over iOS ports, verbatim order:
    /// 1. always `Built-in phone microphone`;
    /// 2. direct inputs (wired, USB) in `ports` order, then Bluetooth HFP inputs (only when
    ///    `includeBluetooth`, i.e. the current category exposes HFP and changing it would not
    ///    reroute a live non-Bluetooth session; Bluetooth ports with an empty uid are skipped).
    /// Title: `"<kind.label> <n>"` + (name empty ? "" : `" · <name>"`), `n` = existing rows of
    /// the same kind + 1, name = `displayName(port.name)`.
    public static func list(ports: [AudioPortDescriptor], includeBluetooth: Bool) -> [MicrophoneChoice] {
        var choices = [MicrophoneChoice(selection: MicrophoneSelection(), title: builtInTitle)]
        let direct = ports.filter { port in
            guard port.isInput, let kind = MicrophoneKind(portTypeRaw: port.type) else { return false }
            return kind == .wired || kind == .usb
        }
        let bluetooth =
            includeBluetooth
            ? ports.filter { $0.isInput && MicrophoneKind(portTypeRaw: $0.type) == .sco }
            : []
        for port in direct + bluetooth {
            guard let selection = MicrophoneSelection(port: port) else { continue }
            let name = displayName(port.name)
            let number = choices.filter { $0.selection.kind == selection.kind }.count + 1
            let title = "\(selection.kind.label) \(number)" + (name.isEmpty ? "" : " · \(name)")
            choices.append(MicrophoneChoice(selection: selection, title: title))
        }
        return choices
    }

    /// `productName.filter { !it.isISOControl() }.take(60)`: removes U+0000–U+001F and
    /// U+007F–U+009F, then keeps the first 60 characters. (Swift counts grapheme clusters
    /// where Kotlin counts UTF-16 units; Swift never splits a surrogate pair.)
    public static func displayName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !(scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)) {
            scalars.append(scalar)
        }
        return String(String(scalars).prefix(nameLimit))
    }
}
