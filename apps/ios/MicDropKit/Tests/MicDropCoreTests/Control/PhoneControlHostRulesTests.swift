import Foundation
import XCTest

@testable import MicDropCore

/// The phone-side port of Go `Snapshot.Validate` (`internal/phonecontrol/validation.go:53-100`), including
/// `TestSnapshotAndPatchRejectInvalidValues` (`state_test.go:64-90`) and the size the host measures on Go's
/// `json.Marshal` output.
final class PhoneControlHostRulesTests: XCTestCase {
    private typealias Member = ControlJSON.Member
    private typealias Value = ControlJSON.Value

    private static func choice(_ value: String, _ label: String) -> Value {
        .object([Member("value", .string(value)), Member("label", .string(label))])
    }

    private static func ack(_ id: String, _ status: String, _ message: String) -> Value {
        .object([Member("id", .string(id)), Member("status", .string(status)), Member("message", .string(message))])
    }

    /// Go `testSnapshot()` choices.
    private static let goChoices = [choice("default", "Android default"), choice("headphones", "Headphones")]

    /// Go `testSnapshot()` fields.
    private static let goFields: [Value] = [
        .object([
            Member("key", .string("audio.fast")), Member("label", .string("Fast recovery")),
            Member("group", .string("Audio")), Member("kind", .string("bool")), Member("value", .bool(true)),
            Member("effect", .string("next_connection")),
        ]),
        .object([
            Member("key", .string("live.volume")), Member("label", .string("Volume")), Member("group", .string("Live")),
            Member("kind", .string("int")), Member("value", .int(5)), Member("effect", .string("live")),
            Member("minimum", .int(0)), Member("maximum", .int(10)),
        ]),
        .object([
            Member("key", .string("audio.output")), Member("label", .string("Output")),
            Member("group", .string("Audio")), Member("kind", .string("choice")), Member("value", .string("default")),
            Member("effect", .string("next_connection")), Member("choices", .array(goChoices)),
        ]),
    ]

    /// Go `testSnapshot()` on the wire.
    private static func goSnapshot() -> [Member] {
        [
            Member("version", .int(1)), Member("revision", .string(String(repeating: "a", count: 64))),
            Member("enabled", .bool(true)), Member("fields", .array(goFields)),
        ]
    }

    private static func violation(_ members: [Member]) -> PhoneControl.HostRuleViolation? {
        PhoneControl.hostValidationError(ControlJSON(members: members))
    }

    /// Replaces (or with `nil` removes) member `key` of an object value, keeping its position.
    private static func setting(_ value: Value, _ key: String, _ replacement: Value?) -> Value {
        guard case .object(let members) = value else { return value }
        var updated = members.filter { $0.key != key }
        if let replacement {
            let index = members.firstIndex(where: { $0.key == key }).map { min($0, updated.count) } ?? updated.count
            updated.insert(Member(key, replacement), at: index)
        }
        return .object(updated)
    }

    /// `goSnapshot()` with top-level member `key` replaced (or removed).
    private static func top(_ key: String, _ value: Value?) -> [Member] {
        guard case .object(let members) = setting(.object(goSnapshot()), key, value) else { return [] }
        return members
    }

    /// `goSnapshot()` with field `index` changed by `change`.
    private static func field(_ index: Int, _ change: (Value) -> Value) -> [Member] {
        var fields = goFields
        fields[index] = change(fields[index])
        return top("fields", .array(fields))
    }

    /// The violation of `goSnapshot()` with member `key` of field `index` replaced (or removed).
    private static func changed(_ index: Int, _ key: String, _ value: Value?) -> PhoneControl.HostRuleViolation? {
        violation(field(index) { setting($0, key, value) })
    }

    func testGoFixtureIsValid() {
        XCTAssertNil(Self.violation(Self.goSnapshot()))
    }

    /// `TestSnapshotAndPatchRejectInvalidValues`: every snapshot mutation is refused.
    func testEveryGoInvalidSnapshotIsRefused() {
        let duplicateField = Self.top("fields", .array(Self.goFields + [Self.goFields[0]]))
        let cases: [(String, PhoneControl.HostRuleViolation?, PhoneControl.HostRuleViolation)] = [
            ("version++", Self.violation(Self.top("version", .int(2))), .snapshot),
            ("revision", Self.violation(Self.top("revision", .string("not a revision"))), .snapshot),
            ("duplicate field", Self.violation(duplicateField), .field),
            ("null value", Self.changed(0, "value", .null), .value),
            ("string bool", Self.changed(0, "value", .string("false")), .value),
            ("control label", Self.changed(0, "label", .string("label\nsecond line")), .field),
            ("unknown kind", Self.changed(0, "kind", .string("script")), .kind),
            ("unknown group", Self.changed(0, "group", .string("Permissions")), .field),
            ("fractional int", Self.changed(1, "value", .number("1.5")), .value),
            ("missing maximum", Self.changed(1, "maximum", nil), .integer),
            ("unknown choice", Self.changed(2, "value", .string("missing")), .value),
            ("duplicate choice", Self.changed(2, "choices", .array(Self.goChoices + [Self.goChoices[0]])), .choice),
            ("bad ack id", Self.violation(Self.top("ack", Self.ack("bad", "applied", "Done"))), .acknowledgment),
        ]
        for (name, actual, expected) in cases {
            XCTAssertEqual(actual, expected, name)
        }
    }

    func testAcknowledgmentBounds() {
        let id = String(repeating: "0", count: 32)
        XCTAssertNil(Self.violation(Self.top("ack", Self.ack(id, "rejected", String(repeating: "m", count: 300)))))
        for invalid in [
            Self.ack(id, "applied", ""), Self.ack(id, "applied", String(repeating: "m", count: 301)),
            Self.ack(id, "done", "x"), Self.ack(String(repeating: "A", count: 32), "applied", "x"),
            Self.ack(String(repeating: "0", count: 31), "applied", "x"), Self.ack(id, "applied", "line\u{85}"),
        ] {
            XCTAssertEqual(Self.violation(Self.top("ack", invalid)), .acknowledgment)
        }
    }

    func testFieldBounds() {
        let bounds: [(Value?, Value?, PhoneControl.HostRuleViolation?)] = [
            (.int(-2_147_483_648), .int(2_147_483_647), nil), (.int(-2_147_483_649), .int(10), .integer),
            (.int(0), .int(2_147_483_648), .integer), (.int(11), .int(10), .integer), (nil, .int(10), .integer),
            (.number("0.0"), .int(10), .decode), (.null, .int(10), .decode),
        ]
        for (minimum, maximum, expected) in bounds {
            let members = Self.field(1) { Self.setting(Self.setting($0, "minimum", minimum), "maximum", maximum) }
            XCTAssertEqual(Self.violation(members), expected, String(describing: (minimum, maximum)))
        }
        let manyChoices = (1..<32).map { Self.choice("v\($0)", "L") }
        XCTAssertNil(Self.changed(2, "choices", .array([Self.choice("default", "L")] + manyChoices)))
        XCTAssertEqual(
            Self.changed(2, "choices", .array([Self.choice("default", "L"), Self.choice("x", "L")] + manyChoices)),
            .choiceField)
        XCTAssertEqual(Self.changed(2, "choices", .array([])), .choiceField)
        XCTAssertEqual(Self.changed(2, "choices", .array([Self.choice("default", "")])), .choice)
        XCTAssertEqual(Self.changed(0, "minimum", .int(0)), .boolean)
        XCTAssertEqual(Self.changed(0, "key", .string("Audio.fast")), .field)
        XCTAssertEqual(Self.changed(0, "key", .string("a" + String(repeating: "b", count: 64))), .field)
        XCTAssertNil(Self.changed(0, "key", .string("a" + String(repeating: "b", count: 63))))
        XCTAssertEqual(Self.changed(0, "effect", .string("now")), .field)
        XCTAssertEqual(Self.changed(0, "label", .string(String(repeating: "l", count: 161))), .field)
        XCTAssertNil(Self.changed(0, "label", .string(String(repeating: "\u{E9}", count: 80))))
        XCTAssertEqual(Self.changed(1, "value", .number("11")), .value)
        XCTAssertEqual(Self.changed(1, "value", .number("1e1")), .value)
        XCTAssertEqual(Self.changed(2, "value", .string(String(repeating: "x", count: 2_047))), .value)
        XCTAssertEqual(Self.violation(Self.top("fields", .array([]))), .snapshot)
        XCTAssertEqual(Self.violation(Self.top("version", .number("1.0"))), .decode)
    }

    /// The host decodes with `DisallowUnknownFields`; the phone also refuses `null` and mistyped members.
    func testUnknownOrMistypedMembersFailTheDecode() {
        XCTAssertEqual(Self.violation(Self.goSnapshot() + [Member("extra", .bool(true))]), .decode)
        XCTAssertEqual(Self.violation(Self.top("enabled", .string("true"))), .decode)
        XCTAssertEqual(Self.violation(Self.top("ack", .null)), .decode)
        XCTAssertEqual(Self.changed(0, "volume", .int(1)), .decode)
        XCTAssertEqual(Self.violation(Self.top("fields", .array([.null]))), .decode)
        let extra: Value = .object([Member("value", .string("default")), Member("id", .string("x"))])
        XCTAssertEqual(Self.changed(2, "choices", .array([extra])), .decode)
    }

    // MARK: - Size measured like Go's json.Marshal

    func testGoEscapingCountsHTMLCharactersAsSixBytes() {
        XCTAssertEqual(PhoneControl.goEscapedBytes(String(repeating: "&", count: 160)), 960)
        XCTAssertEqual(PhoneControl.goEscapedBytes("<>"), 12)
        XCTAssertEqual(PhoneControl.goEscapedBytes("\u{2028}\u{2029}"), 12)
        XCTAssertEqual(PhoneControl.goEscapedBytes(#"a"\"#), 5)
        XCTAssertEqual(PhoneControl.goEscapedBytes("\n\u{1}"), 8)
        XCTAssertEqual(PhoneControl.goEscapedBytes("\u{E9}\u{1F600}"), 6)
        // `"a&b<U+2028>"`: 8 raw bytes, plus 5 for `&` and 3 for the separator.
        XCTAssertEqual(PhoneControl.goCompactedBytes(Array("\"a&b\u{2028}\"".utf8)), 16)
        XCTAssertEqual(PhoneControl.goCompactedBytes(Array("\"\u{2029}\"".utf8)), 8)
        XCTAssertEqual(PhoneControl.goCompactedBytes(Array("true".utf8)), 4)
    }

    /// A snapshot whose own compact encoding fits 64 KiB can still exceed the host's limit once Go escapes `&`.
    func testSizeLimitUsesGoMarshalEscaping() throws {
        func snapshot(label: String) -> PhoneSettingsSnapshot {
            let choices = (0..<32).map { PhoneSetting.Choice(value: String(format: "%02d", $0), label: label) }
            let settings = (0..<10).map {
                PhoneSetting.choice("audio.c\($0)", label, group: .audio, value: "00", choices: choices)
            }
            return PhoneSettingsSnapshot(enabled: true, settings: settings)
        }
        let plain = snapshot(label: String(repeating: "a", count: 160))
        let escaped = snapshot(label: String(repeating: "&", count: 160))
        XCTAssertEqual(plain.fields().encoded().count, escaped.fields().encoded().count)
        XCTAssertLessThanOrEqual(escaped.fields().encoded().count, PhoneControl.maxBodyBytes)
        XCTAssertNil(plain.hostValidationError())
        XCTAssertEqual(escaped.hostValidationError(), .tooLarge)
    }

    /// Without characters Go escapes differently, the measured size is the phone's own compact encoding: the members
    /// appear in Go's struct order and empty optional members are omitted on both sides.
    func testMeasuredSizeMatchesTheCompactEncodingWithoutHTMLEscapes() throws {
        let orders: [PhoneSetting.Choice] = [
            .init(value: "LAN_FIRST", label: "LAN first"), .init(value: "RENDEZVOUS_FIRST", label: "Rendezvous first"),
        ]
        let snapshot = PhoneSettingsSnapshot(
            enabled: false,
            settings: [
                .bool("audio.fast_recovery", "Fast \"buffer\" recovery\\", group: .audio, value: true),
                .int("advanced.offset", "Offset (ms)", group: .advanced, value: -3, range: -10...10),
                .choice(
                    "advanced.initial_order", "Initial connection order", group: .advanced, value: "LAN_FIRST",
                    choices: orders),
                .bool(
                    "live.output_enabled", "Audio output enabled \u{E9}\u{1F600}", group: .live, value: false,
                    effect: .live),
            ])
        let ack = PhoneControlAck(id: String(repeating: "f", count: 32), status: .rejected, message: "Invalid.")
        for acknowledgment in [nil, ack] {
            let encoded = snapshot.fields(ack: acknowledgment).encoded()
            let decoded = try XCTUnwrap(PhoneControl.HostSnapshot(ControlJSON(data: encoded)))
            XCTAssertEqual(decoded.marshalledBytes(), encoded.count)
            XCTAssertNil(decoded.violation())
        }
        // Each `&`, `<` or `>` costs five more bytes on the host than in the phone's encoding.
        let html = PhoneSettingsSnapshot(
            enabled: true,
            settings: [
                .choice(
                    "audio.input", "In & <out>", group: .audio, value: "a&b",
                    choices: [.init(value: "a&b", label: "A & B")])
            ])
        let encoded = html.fields().encoded()
        let decoded = try XCTUnwrap(PhoneControl.HostSnapshot(ControlJSON(data: encoded)))
        XCTAssertEqual(decoded.marshalledBytes(), encoded.count + 5 * 6)
    }
}
