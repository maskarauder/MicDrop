import Foundation

/// One entry of the output menu (`OutputChoice`, `OutputDevices.kt:8`).
public struct OutputChoice: Identifiable, Hashable, Sendable {
    public let selection: OutputSelection
    public let title: String

    public init(selection: OutputSelection, title: String) {
        self.selection = selection
        self.title = title
    }

    /// Titles are unique within one list (per-kind numbering) and never contain a uid.
    public var id: String { title }

    /// Product-name limit for titles (`OutputDevices.kt:47`).
    public static let nameLimit = 60

    /// iOS choice list (port of `OutputDevices.choices`, `OutputDevices.kt:39-53`):
    /// 1. `iPhone media output` (DEFAULT), always;
    /// 2. `iPhone speaker 1` iff `speakerPinnable` or the route already is the built-in speaker;
    /// 3. each current-route output with a non-nil, non-PHONE kind and a non-empty uid, in route
    ///    order, titled `"<kind.label> <n>"` + `" · <sanitized name>"` unless the name is empty,
    ///    where n = (choices already of that kind) + 1.
    /// The system route picker is a separate UI element, not a choice.
    public static func list(route: [(output: RouteOutput, name: String)], speakerPinnable: Bool) -> [OutputChoice] {
        var choices = [OutputChoice(selection: OutputSelection(), title: OutputKind.default.label)]
        let onSpeaker = !route.isEmpty && route.allSatisfy { $0.output.kind == .phone }
        if speakerPinnable || onSpeaker {
            choices.append(
                OutputChoice(selection: OutputSelection.restored(.phone), title: "\(OutputKind.phone.label) 1"))
        }
        for entry in route {
            guard let kind = entry.output.kind, kind != .phone, !entry.output.uid.isEmpty else { continue }
            let number = choices.filter { $0.selection.kind == kind }.count + 1
            let name = sanitizedName(entry.name)
            let title = "\(kind.label) \(number)" + (name.isEmpty ? "" : " · \(name)")
            choices.append(
                OutputChoice(
                    selection: OutputSelection(kind: kind, portType: entry.output.portType, uid: entry.output.uid),
                    title: title))
        }
        return choices
    }

    /// Port name with ISO control characters (U+0000-U+001F, U+007F-U+009F) removed, first 60
    /// characters (`OutputDevices.kt:47`). Grapheme-based prefix so a title never splits a character.
    public static func sanitizedName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !(scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)) {
            scalars.append(scalar)
        }
        return String(String(scalars).prefix(nameLimit))
    }
}
