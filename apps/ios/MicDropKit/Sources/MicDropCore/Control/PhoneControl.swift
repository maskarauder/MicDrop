import Crypto
import Foundation

/// Phone settings exchange v1 (D046, `docs/PHONE_CONTROL_V1.md`; port of `A/PhoneControl.kt` with the host rules of
/// `G:internal/phonecontrol`). It runs only on an already authenticated, paired v3 session that negotiated it:
/// the phone advertises a bounded snapshot of its own settings on `POST /status`, and the host may answer with one
/// `phone_control_command` that the phone validates again before applying. Nothing here performs I/O, changes
/// pairing, consent or permissions, or starts a microphone or a session.
public enum PhoneControl {
    /// Request header of a v3 `/offer` that asks for the exchange (`A/PhoneControl.kt:81`, `types.go:8`).
    public static let header = "X-MicDrop-Phone-Control"
    /// Snapshot `version` and the reply's `phone_control_version` (`types.go:7`).
    public static let version = 1
    /// Go `phonecontrol.MaxBody`: the re-marshalled snapshot and the compact command each stay within 64 KiB.
    public static let maxBodyBytes = 64 * 1024
    /// Most advertised fields and most changes in one command (`validation.go:54,109`, `A/PhoneControl.kt:68`).
    public static let maxFields = 64
    /// Command IDs one receiver remembers; entries are never evicted (`A/PhoneControl.kt:56,62`).
    public static let historyLimit = 1_024
    /// Longest field or choice label in UTF-8 bytes (`validation.go:59,80`).
    public static let maxLabelBytes = 160
    /// Label used when a device name sanitizes to blank (`A/AppPhoneControl.kt:79`).
    public static let fallbackLabel = "Audio device"

    /// `PhoneControlSession.offerHeader` (`A/PhoneControl.kt:84`): `"1"` iff `version == 3 && path == "/offer"`. Sent
    /// whatever the local opt-in says; hosts before ignore it.
    public static func offerHeader(version: Int, path: String) -> String? {
        version == 3 && path == ControlRequest.Path.offer ? ControlRequest.Header.enabledValue : nil
    }

    /// Lowercase hex SHA-256 of the UTF-8 text (`A/PhoneControl.kt:90-91`). Used for revisions and for the app's
    /// salted choice tokens, so both share one implementation.
    public static func sha256Hex(_ text: String) -> String {
        HexPin.encode(SHA256.hash(data: Data(text.utf8)))
    }

    /// A device name as a snapshot label (`A/AppPhoneControl.kt:74-80`): control characters (Cc) removed, cut to
    /// at most 160 UTF-8 bytes on a scalar boundary, and `fallbackLabel` when nothing but whitespace remains.
    public static func label(_ text: String) -> String {
        var clean = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars where !isControl(scalar) {
            let size = String(scalar).utf8.count
            guard bytes + size <= maxLabelBytes else { break }
            bytes += size
            clean.append(scalar)
        }
        let result = String(clean)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackLabel : result
    }

    /// Go `unicode.IsControl` and Kotlin `Char.isISOControl`: U+0000-001F and U+007F-009F.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
    }

    /// Byte-wise equality (Go and Kotlin compare code units; Swift `==` uses canonical equivalence).
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

/// One advertised setting (`A/PhoneControl.kt:5-20`, Go `phonecontrol.Field`). JSON members, in order: `key`,
/// `label`, `group`, `kind`, `value`, `effect`, then `minimum`/`maximum` only when set, then `choices` only when
/// non-empty. The host decodes with `DisallowUnknownFields`, so no other member may be added.
public struct PhoneSetting: Sendable, Equatable {
    public enum Group: String, Sendable, Equatable, CaseIterable {
        case audio = "Audio"
        case advanced = "Advanced"
        case live = "Live"
    }

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case bool
        case int
        case choice
    }

    /// When an applied value takes effect: `live` in the running session, `next_connection` after Stop and
    /// Connect.
    public enum Effect: String, Sendable, Equatable, CaseIterable {
        case live
        case nextConnection = "next_connection"
    }

    /// A setting value: a JSON boolean, a JSON integer (Int32 range on the wire) or a JSON string.
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)

        public var boolValue: Bool? {
            if case .bool(let value) = self { return value }
            return nil
        }

        public var intValue: Int? {
            if case .int(let value) = self { return value }
            return nil
        }

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        /// Kotlin `toString()` of the value for the revision text.
        var canonical: String {
            switch self {
            case .bool(let value): return value ? "true" : "false"
            case .int(let value): return String(value)
            case .string(let value): return value
            }
        }

        var json: DiagnosticJSON {
            switch self {
            case .bool(let value): return .bool(value)
            case .int(let value): return .int(Int64(value))
            case .string(let value): return .string(value)
            }
        }
    }

    public struct Choice: Sendable, Equatable {
        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public let key: String
    public let label: String
    public let group: Group
    public let kind: Kind
    public let value: Value
    public let effect: Effect
    public let minimum: Int?
    public let maximum: Int?
    public let choices: [Choice]

    public init(
        key: String, label: String, group: Group, kind: Kind, value: Value, effect: Effect = .nextConnection,
        minimum: Int? = nil, maximum: Int? = nil, choices: [Choice] = []
    ) {
        self.key = key
        self.label = label
        self.group = group
        self.kind = kind
        self.value = value
        self.effect = effect
        self.minimum = minimum
        self.maximum = maximum
        self.choices = choices
    }

    /// A `bool` field.
    public static func bool(
        _ key: String, _ label: String, group: Group, value: Bool, effect: Effect = .nextConnection
    ) -> PhoneSetting {
        PhoneSetting(key: key, label: label, group: group, kind: .bool, value: .bool(value), effect: effect)
    }

    /// An `int` field with inclusive bounds.
    public static func int(
        _ key: String, _ label: String, group: Group, value: Int, range: ClosedRange<Int>,
        effect: Effect = .nextConnection
    ) -> PhoneSetting {
        PhoneSetting(
            key: key, label: label, group: group, kind: .int, value: .int(value), effect: effect,
            minimum: range.lowerBound, maximum: range.upperBound)
    }

    /// A `choice` field whose value is one of `choices`.
    public static func choice(
        _ key: String, _ label: String, group: Group, value: String, choices: [Choice],
        effect: Effect = .nextConnection
    ) -> PhoneSetting {
        PhoneSetting(
            key: key, label: label, group: group, kind: .choice, value: .string(value), effect: effect,
            choices: choices)
    }

    /// The wire object (`A/PhoneControl.kt:9-13`).
    public func fields() -> DiagnosticJSON {
        var members: [(key: String, value: DiagnosticJSON)] = [
            (key: "key", value: .string(key)), (key: "label", value: .string(label)),
            (key: "group", value: .string(group.rawValue)), (key: "kind", value: .string(kind.rawValue)),
            (key: "value", value: value.json), (key: "effect", value: .string(effect.rawValue)),
        ]
        if let minimum { members.append((key: "minimum", value: .int(Int64(minimum)))) }
        if let maximum { members.append((key: "maximum", value: .int(Int64(maximum)))) }
        if !choices.isEmpty {
            let list = choices.map { choice -> DiagnosticJSON in
                .object([(key: "value", value: .string(choice.value)), (key: "label", value: .string(choice.label))])
            }
            members.append((key: "choices", value: .array(list)))
        }
        return .object(members)
    }

    /// `accepts(value)` (`A/PhoneControl.kt:14-19`) on a received command value, without coercion:
    /// - `bool`: only a JSON boolean (never the strings `"true"`/`"false"`);
    /// - `int`: only an integer literal `-?(0|[1-9][0-9]*)` that fits Int32 (Kotlin `is Int`) and lies within
    ///   `minimum...maximum`, so `16` outside the range, `3.0`, `1e1`, `"3"` and `2147483648` are rejected;
    /// - `choice`: only a JSON string equal, byte for byte, to one choice value.
    /// `null`, arrays and objects are never accepted.
    public func accepts(_ candidate: ControlJSON.Value) -> Bool {
        accepted(candidate) != nil
    }

    /// The typed value of an accepted command value, or nil (see `accepts(_:)`).
    public func accepted(_ candidate: ControlJSON.Value) -> Value? {
        switch (kind, candidate) {
        case (.bool, .bool(let flag)):
            return .bool(flag)
        case (.int, .number(let literal)):
            guard PhoneSetting.isIntegerLiteral(literal), let number = Int32(literal), let minimum, let maximum,
                minimum <= Int(number), Int(number) <= maximum
            else { return nil }
            return .int(Int(number))
        case (.choice, .string(let text)):
            return choices.contains { PhoneControl.sameBytes($0.value, text) } ? .string(text) : nil
        default:
            return nil
        }
    }

    /// `-?(0|[1-9][0-9]*)`: a JSON integer literal without fraction, exponent or sign other than `-`.
    static func isIntegerLiteral(_ literal: String) -> Bool {
        var digits = Substring(literal)
        if digits.first == "-" { digits = digits.dropFirst() }
        guard let first = digits.utf8.first, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return false
        }
        return first != 0x30 || digits.utf8.count == 1
    }
}

/// The phone's current settings as advertised to Windows (`A/PhoneControl.kt:22-36`, Go `phonecontrol.Snapshot`).
public struct PhoneSettingsSnapshot: Sendable, Equatable {
    /// The phone-local opt-in and a live session binding (`A/AppPhoneControl.kt:138`).
    public let enabled: Bool
    public let settings: [PhoneSetting]
    /// Lowercase hex SHA-256 of the length-delimited canonical descriptors (`A/PhoneControl.kt:25-31`). It covers
    /// `enabled`, keys, kinds, values, effects, bounds and choices (values and labels), but not field labels or
    /// groups, so availability or choice changes make a stale Windows editor's command fail.
    public let revision: String

    public init(enabled: Bool, settings: [PhoneSetting]) {
        self.enabled = enabled
        self.settings = settings
        revision = PhoneControl.sha256Hex(PhoneSettingsSnapshot.canonical(enabled: enabled, settings: settings))
    }

    /// `part(enabled)` followed, for each setting sorted by key (UTF-16 order, stable like Kotlin `sortedBy`), by
    /// `part(key) part(kind) part(value) part(effect) part(minimum) part(maximum)` and `part(value) part(label)` per
    /// choice, where `part(x) = "<UTF-16 length>:<x>"` and an absent bound is `null`.
    static func canonical(enabled: Bool, settings: [PhoneSetting]) -> String {
        func part(_ text: String) -> String { "\(text.utf16.count):\(text)" }
        let sorted = settings.enumerated().sorted { lhs, rhs in
            if lhs.element.key.utf16.elementsEqual(rhs.element.key.utf16) { return lhs.offset < rhs.offset }
            return lhs.element.key.utf16.lexicographicallyPrecedes(rhs.element.key.utf16)
        }
        func bound(_ value: Int?) -> String { part(value.map { String($0) } ?? "null") }
        var text = part(enabled ? "true" : "false")
        for (_, setting) in sorted {
            text += part(setting.key) + part(setting.kind.rawValue) + part(setting.value.canonical)
            text += part(setting.effect.rawValue) + bound(setting.minimum) + bound(setting.maximum)
            for choice in setting.choices { text += part(choice.value) + part(choice.label) }
        }
        return text
    }

    /// `{"version":1,"revision":…,"enabled":…,"fields":[…],"ack"?:…}` (`A/PhoneControl.kt:33-35`): the
    /// `phone_control` member of `POST /status`.
    public func fields(ack: PhoneControlAck? = nil) -> DiagnosticJSON {
        var members: [(key: String, value: DiagnosticJSON)] = [
            (key: "version", value: .int(Int64(PhoneControl.version))), (key: "revision", value: .string(revision)),
            (key: "enabled", value: .bool(enabled)), (key: "fields", value: .array(settings.map { $0.fields() })),
        ]
        if let ack { members.append((key: "ack", value: ack.fields())) }
        return .object(members)
    }
}

/// A command acknowledgment carried in the next snapshot (`A/PhoneControl.kt:38-40`, Go `phonecontrol.Ack`).
public struct PhoneControlAck: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, CaseIterable {
        case applied
        case rejected
    }

    /// The command's 32-hex `id`.
    public let id: String
    public let status: Status
    public let message: String

    public init(id: String, status: Status, message: String) {
        self.id = id
        self.status = status
        self.message = message
    }

    /// `{"id":…,"status":…,"message":…}`.
    public func fields() -> DiagnosticJSON {
        .object([
            (key: "id", value: .string(id)), (key: "status", value: .string(status.rawValue)),
            (key: "message", value: .string(message)),
        ])
    }
}

/// Command validation for one receiver (`A/PhoneControl.kt:42-78`). Owned by one session and used only on the main
/// actor (not thread-safe). A new session starts with an empty history, so it can neither replay nor acknowledge an
/// earlier session's command.
public final class PhoneControlSession {
    public static let limitText = "Settings update limit reached. Stop and Connect to make more changes."
    public static let unsupportedText = "Unsupported settings command."
    public static let disabledText = "Allow Windows settings changes on the phone first."
    public static let staleText = "Phone settings changed. Reload and try again."
    public static let invalidChangesText = "Invalid settings changes."
    public static let invalidValueText = "A setting is unavailable or its value is invalid."
    public static let savedText = "Saved. Next-connection settings apply after Stop and Connect."
    public static let liveText = "Live settings requested."
    public static let failedText = "Some settings could not be applied. Reload the phone settings."
    /// The exact command envelope (Go `phonecontrol.Update`).
    public static let envelopeKeys: Set<String> = ["id", "base_revision", "changes"]

    /// Every remembered acknowledgment by command ID, at most `PhoneControl.historyLimit`, never evicted: a
    /// delayed earlier command can therefore never apply after a later edit.
    private var history: [String: PhoneControlAck] = [:]
    /// The acknowledgment the next snapshot carries.
    public private(set) var acknowledgment: PhoneControlAck?

    public init() {}

    /// Number of remembered command IDs.
    public var historyCount: Int { history.count }

    /// `receive(command, current, apply)` in Android's exact order and texts:
    /// 1. `id` not a string of 32 `[a-f0-9]` → nil (no acknowledgment);
    /// 2. a remembered `id` → its stored acknowledgment, without applying again (the host repeats a pending command
    ///    on every 200 `/status` until it is acknowledged or expires);
    /// 3. `PhoneControl.historyLimit` IDs remembered → `limitText`;
    /// 4. top-level keys other than exactly `id`, `base_revision`, `changes` → `unsupportedText`;
    /// 5. `current().enabled` false → `disabledText`;
    /// 6. `base_revision` not a string equal to the current revision → `staleText`;
    /// 7. `changes` not an object, empty, or with more than 64 distinct keys → `invalidChangesText` (a repeated key
    ///    resolves to its last occurrence, like org.json);
    /// 8. a key outside the current schema, or a value `PhoneSetting.accepts` rejects → `invalidValueText`;
    /// 9. `apply(patch)` returns → `applied` with `savedText` if any applied key has effect `next_connection`, else
    ///    `liveText`; `apply` throws → `rejected` with `failedText`.
    /// `current` is read once, after the envelope checks. Every outcome after step 2 updates `acknowledgment` and is
    /// remembered while fewer than `historyLimit` IDs are stored.
    @discardableResult
    public func receive(
        _ command: ControlJSON, current: () -> PhoneSettingsSnapshot,
        apply: ([String: PhoneSetting.Value]) throws -> Void
    ) -> PhoneControlAck? {
        guard let id = command["id"]?.text, PhoneControlSession.isCommandID(id) else { return nil }
        if let stored = history[id] {
            acknowledgment = stored
            return stored
        }
        func remember(_ status: PhoneControlAck.Status, _ message: String) -> PhoneControlAck {
            let ack = PhoneControlAck(id: id, status: status, message: message)
            acknowledgment = ack
            if history.count < PhoneControl.historyLimit { history[id] = ack }
            return ack
        }
        guard history.count < PhoneControl.historyLimit else {
            return remember(.rejected, PhoneControlSession.limitText)
        }
        guard Set(command.keys) == PhoneControlSession.envelopeKeys else {
            return remember(.rejected, PhoneControlSession.unsupportedText)
        }
        let snapshot = current()
        guard snapshot.enabled else { return remember(.rejected, PhoneControlSession.disabledText) }
        guard let base = command["base_revision"]?.text, base == snapshot.revision else {
            return remember(.rejected, PhoneControlSession.staleText)
        }
        guard let changes = command.object("changes"), !changes.keys.isEmpty,
            changes.keys.count <= PhoneControl.maxFields
        else {
            return remember(.rejected, PhoneControlSession.invalidChangesText)
        }
        let schema = Dictionary(snapshot.settings.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var patch: [String: PhoneSetting.Value] = [:]
        for key in changes.keys {
            guard let setting = schema[key], let candidate = changes[key], let value = setting.accepted(candidate)
            else {
                return remember(.rejected, PhoneControlSession.invalidValueText)
            }
            patch[key] = value
        }
        do {
            try apply(patch)
        } catch {
            return remember(.rejected, PhoneControlSession.failedText)
        }
        let nextConnection = patch.keys.contains { schema[$0]?.effect == .nextConnection }
        return remember(.applied, nextConnection ? PhoneControlSession.savedText : PhoneControlSession.liveText)
    }

    /// `[a-f0-9]{32}` (`A/PhoneControl.kt:52`; Go `commandID`).
    public static func isCommandID(_ text: String) -> Bool {
        let bytes = text.utf8
        return bytes.count == 32 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
