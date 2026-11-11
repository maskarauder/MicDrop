import Foundation

/// The Windows host's snapshot rules (`G:internal/phonecontrol/validation.go:53-100`, `Snapshot.Validate`), checked on
/// the phone before a snapshot is sent. A snapshot the host rejects is a 400 on every heartbeat, including the
/// report-less retry, so the app omits `phone_control` instead (Android relies on construction alone).
///
/// The check runs on the wire form. It first decodes like Go's `DisallowUnknownFields` decoder, but stricter: only
/// the exact member names, no `null` members, integers only as integer literals. It then applies the `Validate`
/// rules in Go's order and finally measures the size of Go's `json.Marshal` re-encoding (`validation.go:95-97`),
/// including its HTML escaping (`<`, `>`, `&`, U+2028 and U+2029 each become a six-byte `\uXXXX`).
extension PhoneControl {
    /// Fixed labels, never data; the texts of Go's errors except `decode`, which the host reports as a 400
    /// "Invalid status update" before `Validate` runs.
    public enum HostRuleViolation: String, Error, Sendable, Equatable, CaseIterable {
        case decode = "undecodable phone settings snapshot"
        case snapshot = "invalid phone settings snapshot"
        case field = "invalid phone settings field"
        case boolean = "invalid boolean settings field"
        case integer = "invalid integer settings field"
        case choiceField = "invalid choice settings field"
        case choice = "invalid settings choice"
        case kind = "unknown phone settings field type"
        case value = "invalid phone settings value"
        case acknowledgment = "invalid phone settings acknowledgment"
        case tooLarge = "phone settings snapshot is too large"
    }

    /// Longest raw `value` in bytes (`validation.go:29`).
    static let maxValueBytes = 2_048
    /// Choices per field (`validation.go:75`).
    static let maxChoices = 32
    /// Longest choice value in UTF-8 bytes (`validation.go:80`).
    static let maxChoiceValueBytes = 256
    /// Longest acknowledgment message in UTF-8 bytes (`validation.go:92`).
    static let maxAckMessageBytes = 300

    /// The first rule `snapshot` (the `phone_control` object) breaks, or nil when the host accepts it.
    public static func hostValidationError(_ snapshot: ControlJSON) -> HostRuleViolation? {
        guard let decoded = HostSnapshot(snapshot) else { return .decode }
        return decoded.violation()
    }

    // MARK: Go json.Marshal size

    /// Bytes Go's `json.Marshal` writes for `text` inside the quotes: `"` and `\` 2, `\b \f \n \r \t` 2, other
    /// controls below U+0020 6, `<` `>` `&` 6, U+2028/U+2029 6, everything else its UTF-8 length.
    static func goEscapedBytes(_ text: String) -> Int {
        var total = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: total += 2
            case 0x00..<0x20, 0x3C, 0x3E, 0x26, 0x2028, 0x2029: total += 6
            default: total += String(scalar).utf8.count
            }
        }
        return total
    }

    /// Go `appendCompact(raw, escapeHTML: true)` length of an already compact raw value: each `<`, `>`, `&` grows
    /// by 5 bytes and each U+2028/U+2029 (`E2 80 A8/A9`) by 3.
    static func goCompactedBytes(_ raw: [UInt8]) -> Int {
        var total = raw.count
        var index = 0
        while index < raw.count {
            let byte = raw[index]
            if byte == 0x3C || byte == 0x3E || byte == 0x26 {
                total += 5
            } else if byte == 0xE2, index + 2 < raw.count, raw[index + 1] == 0x80, raw[index + 2] & ~1 == 0xA8 {
                total += 3
                index += 2
            }
            index += 1
        }
        return total
    }

    /// `boundedText(value, maximum, empty)` (`validation.go:16-26`): at most `maximum` UTF-8 bytes, non-empty
    /// unless `empty`, and no control character (Go `unicode.IsControl`).
    static func boundedText(_ value: String, maximum: Int, empty: Bool) -> Bool {
        if !empty && value.isEmpty { return false }
        guard value.utf8.count <= maximum else { return false }
        return !value.unicodeScalars.contains(where: isControl)
    }

    /// `^[a-z][a-z0-9_.]{0,63}$` (`validation.go:12`).
    static func isFieldKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard let first = bytes.first, (1...64).contains(bytes.count), (0x61...0x7A).contains(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F || byte == 0x2E
        }
    }

    /// `^[0-9a-f]{count}$`.
    static func isLowercaseHex(_ text: String, count: Int) -> Bool {
        let bytes = text.utf8
        return bytes.count == count && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

extension PhoneSettingsSnapshot {
    /// `PhoneControl.hostValidationError` of exactly the `phone_control` member `fields(ack:)` sends.
    public func hostValidationError(ack: PhoneControlAck? = nil) -> PhoneControl.HostRuleViolation? {
        guard let json = try? ControlJSON(data: fields(ack: ack).encoded()) else { return .decode }
        return PhoneControl.hostValidationError(json)
    }
}

// MARK: - Decoded snapshot

extension PhoneControl {
    /// Go `phonecontrol.Snapshot` as the host decodes it. Missing members take Go's zero values; unknown members,
    /// `null` members and mistyped members fail the decode. Internal so tests can check the measured size.
    struct HostSnapshot {
        struct Field {
            var key = ""
            var label = ""
            var group = ""
            var kind = ""
            /// Go `json.RawMessage`: nil when the member is missing.
            var value: ControlJSON.Value?
            var effect = ""
            var minimum: Int64?
            var maximum: Int64?
            var choices: [(value: String, label: String)] = []
        }

        struct Ack {
            var id = ""
            var status = ""
            var message = ""
        }

        var version: Int64 = 0
        var revision = ""
        var enabled = false
        var fields: [Field] = []
        var ack: Ack?

        init?(_ json: ControlJSON) {
            for member in json.members {
                switch (member.key, member.value) {
                case ("version", .number(let literal)):
                    guard let value = Self.integer(literal) else { return nil }
                    version = value
                case ("revision", .string(let text)):
                    revision = text
                case ("enabled", .bool(let flag)):
                    enabled = flag
                case ("fields", .array(let items)):
                    var decoded: [Field] = []
                    for item in items {
                        guard case .object(let members) = item, let field = Self.field(members) else { return nil }
                        decoded.append(field)
                    }
                    fields = decoded
                case ("ack", .object(let members)):
                    guard let value = Self.ack(members) else { return nil }
                    ack = value
                default:
                    return nil
                }
            }
        }

        /// Go `int` decoding of a JSON number: an integer literal within Int64.
        static func integer(_ literal: String) -> Int64? {
            PhoneSetting.isIntegerLiteral(literal) ? Int64(literal) : nil
        }

        static func field(_ members: [ControlJSON.Member]) -> Field? {
            var field = Field()
            for member in members {
                switch (member.key, member.value) {
                case ("key", .string(let text)): field.key = text
                case ("label", .string(let text)): field.label = text
                case ("group", .string(let text)): field.group = text
                case ("kind", .string(let text)): field.kind = text
                case ("effect", .string(let text)): field.effect = text
                case ("value", let value): field.value = value
                case ("minimum", .number(let literal)):
                    guard let value = integer(literal) else { return nil }
                    field.minimum = value
                case ("maximum", .number(let literal)):
                    guard let value = integer(literal) else { return nil }
                    field.maximum = value
                case ("choices", .array(let items)):
                    var choices: [(value: String, label: String)] = []
                    for item in items {
                        guard case .object(let members) = item, let choice = Self.choice(members) else { return nil }
                        choices.append(choice)
                    }
                    field.choices = choices
                default:
                    return nil
                }
            }
            return field
        }

        static func choice(_ members: [ControlJSON.Member]) -> (value: String, label: String)? {
            var choice = (value: "", label: "")
            for member in members {
                switch (member.key, member.value) {
                case ("value", .string(let text)): choice.value = text
                case ("label", .string(let text)): choice.label = text
                default: return nil
                }
            }
            return choice
        }

        static func ack(_ members: [ControlJSON.Member]) -> Ack? {
            var ack = Ack()
            for member in members {
                switch (member.key, member.value) {
                case ("id", .string(let text)): ack.id = text
                case ("status", .string(let text)): ack.status = text
                case ("message", .string(let text)): ack.message = text
                default: return nil
                }
            }
            return ack
        }

        /// `Snapshot.Validate` (`validation.go:53-100`), in Go's order.
        func violation() -> PhoneControl.HostRuleViolation? {
            guard version == Int64(PhoneControl.version), PhoneControl.isLowercaseHex(revision, count: 64),
                (1...PhoneControl.maxFields).contains(fields.count)
            else { return .snapshot }
            var seen = Set<String>()
            for field in fields {
                guard PhoneControl.isFieldKey(field.key), !seen.contains(field.key),
                    PhoneControl.boundedText(field.label, maximum: PhoneControl.maxLabelBytes, empty: false),
                    PhoneSetting.Group.allCases.contains(where: { $0.rawValue == field.group }),
                    PhoneSetting.Effect.allCases.contains(where: { $0.rawValue == field.effect })
                else { return .field }
                seen.insert(field.key)
                switch field.kind {
                case PhoneSetting.Kind.bool.rawValue:
                    guard field.minimum == nil, field.maximum == nil, field.choices.isEmpty else { return .boolean }
                case PhoneSetting.Kind.int.rawValue:
                    guard let minimum = field.minimum, let maximum = field.maximum, minimum <= maximum,
                        minimum >= Int64(Int32.min), maximum <= Int64(Int32.max), field.choices.isEmpty
                    else { return .integer }
                case PhoneSetting.Kind.choice.rawValue:
                    guard field.minimum == nil, field.maximum == nil,
                        (1...PhoneControl.maxChoices).contains(field.choices.count)
                    else { return .choiceField }
                    var values = Set<[UInt8]>()
                    for choice in field.choices {
                        guard
                            PhoneControl.boundedText(
                                choice.value, maximum: PhoneControl.maxChoiceValueBytes, empty: true),
                            PhoneControl.boundedText(choice.label, maximum: PhoneControl.maxLabelBytes, empty: false),
                            values.insert(Array(choice.value.utf8)).inserted
                        else { return .choice }
                    }
                default:
                    return .kind
                }
                guard Self.validValue(field) else { return .value }
            }
            if let ack {
                guard PhoneControl.isLowercaseHex(ack.id, count: 32),
                    PhoneControlAck.Status.allCases.contains(where: { $0.rawValue == ack.status }),
                    PhoneControl.boundedText(ack.message, maximum: PhoneControl.maxAckMessageBytes, empty: false)
                else { return .acknowledgment }
            }
            return marshalledBytes() > PhoneControl.maxBodyBytes ? .tooLarge : nil
        }

        /// `validValue(field, field.Value)` (`validation.go:28-51`).
        static func validValue(_ field: Field) -> Bool {
            guard let value = field.value else { return false }
            let raw = value.encoded()
            guard !raw.isEmpty, raw.count <= PhoneControl.maxValueBytes else { return false }
            switch (field.kind, value) {
            case (PhoneSetting.Kind.bool.rawValue, .bool):
                return true
            case (PhoneSetting.Kind.int.rawValue, .number(let literal)):
                guard let number = integer(literal), let minimum = field.minimum, let maximum = field.maximum else {
                    return false
                }
                return minimum <= number && number <= maximum
            case (PhoneSetting.Kind.choice.rawValue, .string(let text)):
                return field.choices.contains { PhoneControl.sameBytes($0.value, text) }
            default:
                return false
            }
        }

        /// Length of Go's `json.Marshal(s)`: struct members in declaration order, `minimum`, `maximum`, `choices` and
        /// `ack` omitted when empty, strings HTML-escaped and each raw `value` compacted with HTML escaping.
        func marshalledBytes() -> Int {
            func text(_ value: String) -> Int { PhoneControl.goEscapedBytes(value) + 2 }
            func literal(_ value: String) -> Int { value.utf8.count }
            var total = literal(#"{"version":"#) + literal(String(version)) + literal(#","revision":"#) + text(revision)
            total += literal(#","enabled":"#) + literal(enabled ? "true" : "false") + literal(#","fields":["#)
            for (index, field) in fields.enumerated() {
                if index > 0 { total += 1 }
                total += literal(#"{"key":"#) + text(field.key) + literal(#","label":"#) + text(field.label)
                total += literal(#","group":"#) + text(field.group) + literal(#","kind":"#) + text(field.kind)
                let raw = [UInt8](field.value?.encoded() ?? Data())
                total += literal(#","value":"#) + PhoneControl.goCompactedBytes(raw)
                total += literal(#","effect":"#) + text(field.effect)
                if let minimum = field.minimum { total += literal(#","minimum":"#) + literal(String(minimum)) }
                if let maximum = field.maximum { total += literal(#","maximum":"#) + literal(String(maximum)) }
                if !field.choices.isEmpty {
                    total += literal(#","choices":["#) + field.choices.count - 1 + literal("]")
                    for choice in field.choices {
                        total += literal(#"{"value":"#) + text(choice.value)
                        total += literal(#","label":"#) + text(choice.label)
                        total += literal("}")
                    }
                }
                total += literal("}")
            }
            total += literal("]")
            if let ack {
                total += literal(#","ack":{"id":"#) + text(ack.id) + literal(#","status":"#) + text(ack.status)
                total += literal(#","message":"#) + text(ack.message) + literal("}")
            }
            return total + literal("}")
        }
    }
}
