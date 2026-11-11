import Foundation
import XCTest

@testable import MicDropCore

/// Port of `PhoneControlTest.kt` (all eight cases) plus the iPhone additions: the 1024-command boundary, revision
/// fixtures, the wire encoding and the label helper. Commands are `ControlJSON`, which keeps number literals
/// verbatim and resolves a repeated key to its last occurrence, like org.json.
final class PhoneControlTests: XCTestCase {
    private typealias Member = ControlJSON.Member

    private static let id = String(repeating: "a", count: 32)

    /// `PhoneControlTest.snapshot()`.
    private static func snapshot(enabled: Bool = true, value: Bool = true) -> PhoneSettingsSnapshot {
        PhoneSettingsSnapshot(enabled: enabled, settings: settings(value: value))
    }

    private static func settings(value: Bool = true) -> [PhoneSetting] {
        [
            .bool("audio.fast_recovery", "Fast recovery", group: .audio, value: value),
            .int("live.volume", "Android media volume", group: .live, value: 3, range: 0...15, effect: .live),
            .choice(
                "audio.input", "Microphone input", group: .audio, value: "phone",
                choices: [.init(value: "phone", label: "Phone"), .init(value: "headset", label: "Headset")]),
        ]
    }

    private static func command(
        _ current: PhoneSettingsSnapshot, _ changes: [Member], id: String = id, extra: [Member] = []
    ) -> ControlJSON {
        ControlJSON(
            members: [
                Member("id", .string(id)), Member("base_revision", .string(current.revision)),
                Member("changes", .object(changes)),
            ] + extra)
    }

    private static func fastRecovery(_ value: Bool) -> [Member] { [Member("audio.fast_recovery", .bool(value))] }

    private struct ApplyFailure: Error {}

    // MARK: - PhoneControlTest.kt

    func testDisabledOrStaleCommandsCannotChangeAnyPreference() {
        let current = Self.snapshot()
        let update = Self.command(current, Self.fastRecovery(false))
        var calls = 0
        let count: ([String: PhoneSetting.Value]) -> Void = { _ in calls += 1 }
        let disabled = PhoneControlSession().receive(
            update, current: { Self.snapshot(enabled: false) }, apply: count)
        XCTAssertEqual(disabled?.status, .rejected)
        XCTAssertEqual(disabled?.message, "Allow Windows settings changes on the phone first.")
        let stale = PhoneControlSession().receive(update, current: { Self.snapshot(value: false) }, apply: count)
        XCTAssertEqual(stale?.status, .rejected)
        XCTAssertEqual(stale?.message, "Phone settings changed. Reload and try again.")
        XCTAssertEqual(calls, 0)
        XCTAssertNotEqual(current.revision, Self.snapshot(enabled: false).revision)
    }

    func testValidatesTheWholePatchWithoutCoercionOrCaptureKeys() {
        let current = Self.snapshot()
        let invalid: [[Member]] = [
            [Member("live.volume", .number("16"))], [Member("live.volume", .number("-1"))],
            [Member("live.volume", .number("3.0"))], [Member("live.volume", .number("1e1"))],
            [Member("live.volume", .string("3"))], [Member("live.volume", .number("2147483648"))],
            [Member("live.volume", .number("+3"))], [Member("audio.fast_recovery", .string("false"))],
            [Member("audio.fast_recovery", .number("0"))], [Member("audio.fast_recovery", .array([.bool(false)]))],
            [Member("audio.fast_recovery", .object([]))], [Member("audio.input", .string("disconnected-headset"))],
            [Member("audio.input", .string("Phone"))], [Member("audio.microphone_enabled", .bool(true))],
            [Member("allowWindows", .bool(true))],
            [Member("audio.fast_recovery", .bool(false)), Member("unknown", .bool(true))], [],
            [Member("audio.fast_recovery", .null)],
        ]
        for changes in invalid {
            var called = false
            let ack = PhoneControlSession().receive(
                Self.command(current, changes), current: { current }, apply: { _ in called = true })
            let label = String(decoding: ControlJSON.Value.object(changes).encoded(), as: UTF8.self)
            let expected =
                changes.isEmpty ? PhoneControlSession.invalidChangesText : PhoneControlSession.invalidValueText
            XCTAssertEqual(ack?.status, .rejected, label)
            XCTAssertEqual(ack?.message, expected, label)
            XCTAssertFalse(called, label)
        }
    }

    func testRetriesReturnTheSameAcknowledgmentWithoutApplyingAgain() {
        var current = Self.snapshot()
        let update = Self.command(current, Self.fastRecovery(false))
        let session = PhoneControlSession()
        var calls = 0
        func apply(_ patch: [String: PhoneSetting.Value]) {
            calls += 1
            current = Self.snapshot(value: patch["audio.fast_recovery"]?.boolValue ?? true)
        }
        let first = session.receive(update, current: { current }, apply: apply)
        XCTAssertEqual(first?.status, .applied)
        XCTAssertTrue(first?.message.contains("Stop and Connect") == true)
        XCTAssertEqual(session.receive(update, current: { current }, apply: { _ in calls += 1 }), first)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(current.fields(ack: session.acknowledgment)["ack"], first?.fields())
    }

    func testPermissionAndCapabilityChangesInvalidateTheEditorRevision() {
        let current = Self.snapshot()
        let removed = PhoneSettingsSnapshot(
            enabled: true, settings: current.settings.filter { $0.key != "live.volume" })
        let newDevice = PhoneSettingsSnapshot(
            enabled: true,
            settings: current.settings.map {
                guard $0.key == "audio.input" else { return $0 }
                return .choice(
                    $0.key, $0.label, group: $0.group, value: "phone",
                    choices: [.init(value: "phone", label: "Phone"), .init(value: "replacement", label: "Headset")])
            })
        let update = Self.command(current, [Member("audio.input", .string("headset"))])
        for changed in [removed, newDevice] {
            XCTAssertNotEqual(current.revision, changed.revision)
            let ack = PhoneControlSession().receive(
                update, current: { changed }, apply: { _ in XCTFail("Stale edit applied") })
            XCTAssertEqual(ack?.status, .rejected)
        }
        XCTAssertEqual(
            current.revision, PhoneSettingsSnapshot(enabled: true, settings: current.settings.reversed()).revision)
        XCTAssertTrue(PhoneControl.isLowercaseHex(current.revision, count: 64))
    }

    func testReorderedEarlierCommandsCannotApplyAgainAfterASettingWasRestored() {
        var current = Self.snapshot()
        let first = Self.command(current, Self.fastRecovery(false))
        let session = PhoneControlSession()
        var calls = 0
        func apply(_ patch: [String: PhoneSetting.Value]) {
            calls += 1
            current = Self.snapshot(value: patch["audio.fast_recovery"]?.boolValue ?? true)
        }
        let firstAck = session.receive(first, current: { current }, apply: apply)
        let second = Self.command(current, Self.fastRecovery(true), id: String(repeating: "b", count: 32))
        session.receive(second, current: { current }, apply: apply)
        XCTAssertEqual(Self.snapshot().revision, current.revision)
        XCTAssertEqual(session.receive(first, current: { current }, apply: apply), firstAck)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(current.settings.first?.value, .bool(true))
    }

    func testMalformedEnvelopeAndUnknownFieldsAreRejected() {
        let current = Self.snapshot()
        let changes = [Member("live.volume", .number("4"))]
        var reads = 0
        let read: () -> PhoneSettingsSnapshot = {
            reads += 1
            return current
        }
        let fail: ([String: PhoneSetting.Value]) -> Void = { _ in XCTFail("malformed command applied") }
        for id in ["bad", String(repeating: "A", count: 32), String(repeating: "a", count: 31), Self.id + "a"] {
            let command = Self.command(current, changes, id: id)
            XCTAssertNil(PhoneControlSession().receive(command, current: read, apply: fail), id)
        }
        let rest = Self.command(current, changes).members.dropFirst()
        let numeric = ControlJSON(members: [Member("id", .number("1"))] + rest)
        XCTAssertNil(PhoneControlSession().receive(numeric, current: read, apply: fail))
        let extra = Self.command(current, changes, extra: [Member("start_microphone", .bool(true))])
        let ack = PhoneControlSession().receive(extra, current: read, apply: fail)
        XCTAssertEqual(ack?.status, .rejected)
        XCTAssertEqual(ack?.message, PhoneControlSession.unsupportedText)
        let missing = ControlJSON(members: Array(Self.command(current, changes).members.dropLast()))
        XCTAssertEqual(
            PhoneControlSession().receive(missing, current: read, apply: fail)?.message,
            PhoneControlSession.unsupportedText)
        XCTAssertEqual(reads, 0, "the envelope is checked before the settings are read")
        XCTAssertEqual(PhoneControl.offerHeader(version: 3, path: "/offer"), "1")
        XCTAssertNil(PhoneControl.offerHeader(version: 2, path: "/offer"))
        XCTAssertNil(PhoneControl.offerHeader(version: 3, path: "/status"))
    }

    func testOnlyNegotiatedStatusExchangesReceiveTheSettingsBodyBudget() {
        XCTAssertEqual(ControlRequest.bodyLimit(path: "/status", negotiated: true), 160 * 1024)
        XCTAssertEqual(ControlRequest.bodyLimit(path: "/status", negotiated: false), 96 * 1024)
        for path in ["/offer", "/answer", "/recover-offer", "/recover-answer", "/stop", "/microphone"] {
            XCTAssertEqual(ControlRequest.bodyLimit(path: path, negotiated: true), 96 * 1024, path)
            XCTAssertEqual(ControlRequest.bodyLimit(path: path, negotiated: false), 96 * 1024, path)
        }
        XCTAssertEqual(ControlRequest.bodyLimit(path: "/status", negotiated: false), StatusBody.maxBytes)
    }

    func testANewReceiverCannotReplayTheOldReceiversAcknowledgment() {
        let current = Self.snapshot()
        let update = Self.command(current, [Member("live.volume", .number("4"))])
        let old = PhoneControlSession()
        XCTAssertEqual(old.receive(update, current: { current }, apply: { _ in })?.status, .applied)
        let replacement = PhoneControlSession()
        XCTAssertNil(replacement.acknowledgment)
        let disabled = PhoneSettingsSnapshot(enabled: false, settings: current.settings)
        let ack = replacement.receive(
            update, current: { disabled }, apply: { _ in XCTFail("replayed into a new session") })
        XCTAssertEqual(ack?.status, .rejected)
    }

    // MARK: - iPhone additions

    /// History holds 1024 IDs and never evicts: the 1024th command is stored, the 1025th is refused with the limit
    /// text, and a stored ID still replays its acknowledgment.
    func testHistoryLimitRefusesNewCommandsButKeepsReplays() {
        var current = Self.snapshot()
        let session = PhoneControlSession()
        var calls = 0
        func id(_ index: Int) -> String {
            let hex = String(index, radix: 16)
            return String(repeating: "0", count: 32 - hex.count) + hex
        }
        func apply(_ patch: [String: PhoneSetting.Value]) {
            calls += 1
            current = Self.snapshot(value: patch["audio.fast_recovery"]?.boolValue ?? true)
        }
        var acks: [PhoneControlAck?] = []
        for index in 0..<PhoneControl.historyLimit {
            let command = Self.command(current, Self.fastRecovery(index % 2 == 1), id: id(index))
            acks.append(session.receive(command, current: { current }, apply: apply))
        }
        XCTAssertEqual(calls, PhoneControl.historyLimit)
        XCTAssertEqual(session.historyCount, PhoneControl.historyLimit)
        XCTAssertEqual(acks.last??.status, .applied)
        let refuse: ([String: PhoneSetting.Value]) -> Void = { _ in XCTFail("applied beyond the history limit") }
        let latest = current
        let over = session.receive(
            Self.command(latest, Self.fastRecovery(false), id: id(5000)), current: { latest }, apply: refuse)
        XCTAssertEqual(over?.status, .rejected)
        XCTAssertEqual(over?.message, "Settings update limit reached. Stop and Connect to make more changes.")
        XCTAssertEqual(session.acknowledgment, over)
        XCTAssertEqual(session.historyCount, PhoneControl.historyLimit)
        XCTAssertEqual(
            session.receive(Self.command(latest, [], id: id(5000)), current: { latest }, apply: refuse), over,
            "an unstored ID is refused again")
        let replay = session.receive(
            Self.command(latest, Self.fastRecovery(true), id: id(0)), current: { latest }, apply: refuse)
        XCTAssertEqual(replay, acks.first ?? nil)
        XCTAssertEqual(session.acknowledgment, replay)
        XCTAssertEqual(calls, PhoneControl.historyLimit)
    }

    /// Regression guard reproduced independently from `PhoneControl.kt:25-31` (not a wire requirement: Go only checks
    /// `^[0-9a-f]{64}$` and echoes the value).
    func testRevisionFixtures() {
        XCTAssertEqual(
            PhoneSettingsSnapshot.canonical(enabled: true, settings: Self.settings()),
            "4:true" + "19:audio.fast_recovery4:bool4:true15:next_connection4:null4:null"
                + "11:audio.input6:choice5:phone15:next_connection4:null4:null5:phone5:Phone7:headset7:Headset"
                + "11:live.volume3:int1:34:live1:02:15")
        XCTAssertEqual(Self.snapshot().revision, "06c77b09b584dd98bec5a452801c0277bc7633ec601b93c8ecd2ffdb35011f6e")
        XCTAssertEqual(
            Self.snapshot(enabled: false).revision, "ac2ad0ba8efab64d38470a50ff70791271656c262f1afb4c6a3423f1c7364d64")
        XCTAssertEqual(
            PhoneControl.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Field labels and groups are not hashed; values, effects, bounds and choice labels are.
    func testRevisionCoversDescriptorsButNotFieldLabels() {
        let base = Self.snapshot()
        func revision(_ change: (PhoneSetting) -> PhoneSetting) -> String {
            PhoneSettingsSnapshot(enabled: true, settings: base.settings.map(change)).revision
        }
        func relabel(_ setting: PhoneSetting) -> PhoneSetting {
            PhoneSetting(
                key: setting.key, label: "Renamed", group: .advanced, kind: setting.kind, value: setting.value,
                effect: setting.effect, minimum: setting.minimum, maximum: setting.maximum, choices: setting.choices)
        }
        XCTAssertEqual(revision(relabel), base.revision)
        XCTAssertNotEqual(
            revision {
                guard $0.key == "live.volume" else { return $0 }
                return .int($0.key, $0.label, group: .live, value: 3, range: 0...14, effect: .live)
            }, base.revision)
        XCTAssertNotEqual(
            revision {
                guard $0.key == "live.volume" else { return $0 }
                return .int($0.key, $0.label, group: .live, value: 3, range: 0...15)
            }, base.revision)
        XCTAssertNotEqual(
            revision {
                guard $0.key == "audio.input" else { return $0 }
                return .choice(
                    $0.key, $0.label, group: .audio, value: "phone",
                    choices: [.init(value: "phone", label: "Phone"), .init(value: "headset", label: "Wired headset")])
            }, base.revision)
    }

    func testSnapshotWireMembersAreInAndroidOrder() {
        let ack = PhoneControlAck(id: Self.id, status: .applied, message: "Live settings requested.")
        let text = String(decoding: Self.snapshot().fields(ack: ack).encoded(), as: UTF8.self)
        let revision = "06c77b09b584dd98bec5a452801c0277bc7633ec601b93c8ecd2ffdb35011f6e"
        XCTAssertEqual(
            text,
            #"{"version":1,"revision":"\#(revision)","enabled":true,"#
                + #""fields":[{"key":"audio.fast_recovery","label":"Fast recovery","group":"Audio","kind":"bool","#
                + #""value":true,"effect":"next_connection"},{"key":"live.volume","label":"Android media volume","#
                + #""group":"Live","kind":"int","value":3,"effect":"live","minimum":0,"maximum":15},"#
                + #"{"key":"audio.input","label":"Microphone input","group":"Audio","kind":"choice","value":"phone","#
                + #""effect":"next_connection","choices":[{"value":"phone","label":"Phone"},"#
                + #"{"value":"headset","label":"Headset"}]}],"#
                + #""ack":{"id":"\#(Self.id)","status":"applied","message":"Live settings requested."}}"#)
        XCTAssertEqual(Self.snapshot().fields().keys, ["version", "revision", "enabled", "fields"])
    }

    func testOutcomesAndChangeLimits() {
        let current = Self.snapshot()
        func receive(_ changes: [Member], apply: ([String: PhoneSetting.Value]) throws -> Void = { _ in })
            -> PhoneControlAck?
        {
            PhoneControlSession().receive(Self.command(current, changes), current: { current }, apply: apply)
        }
        XCTAssertEqual(receive([Member("live.volume", .number("0"))])?.message, PhoneControlSession.liveText)
        XCTAssertEqual(receive([Member("live.volume", .number("-0"))])?.status, .applied)
        let mixed = receive([Member("live.volume", .number("15")), Member("audio.input", .string("headset"))])
        XCTAssertEqual(mixed?.message, PhoneControlSession.savedText)
        // A repeated key resolves to its last occurrence.
        var applied: [String: PhoneSetting.Value] = [:]
        let invalidThenValid = [
            Member("audio.fast_recovery", .string("x")), Member("audio.fast_recovery", .bool(false)),
        ]
        XCTAssertEqual(receive(invalidThenValid) { applied = $0 }?.status, .applied)
        XCTAssertEqual(applied, ["audio.fast_recovery": .bool(false)])
        let validThenInvalid = Array(invalidThenValid.reversed())
        XCTAssertEqual(receive(validThenInvalid)?.message, PhoneControlSession.invalidValueText)
        // 64 distinct keys reach the schema check; 65 are refused as a whole.
        let keys = (0...64).map { Member("audio.k\($0)", .bool(true)) }
        XCTAssertEqual(receive(Array(keys.prefix(64)))?.message, PhoneControlSession.invalidValueText)
        XCTAssertEqual(receive(keys)?.message, PhoneControlSession.invalidChangesText)
        let notObject = ControlJSON(
            members: [
                Member("id", .string(Self.id)), Member("base_revision", .string(current.revision)),
                Member("changes", .array([])),
            ])
        XCTAssertEqual(
            PhoneControlSession().receive(notObject, current: { current }, apply: { _ in })?.message,
            PhoneControlSession.invalidChangesText)
        let numericRevision = ControlJSON(
            members: [
                Member("id", .string(Self.id)), Member("base_revision", .number("1")),
                Member("changes", .object(Self.fastRecovery(false))),
            ])
        XCTAssertEqual(
            PhoneControlSession().receive(numericRevision, current: { current }, apply: { _ in })?.message,
            PhoneControlSession.staleText)
    }

    func testAFailedApplyIsRememberedAsRejected() {
        let current = Self.snapshot()
        let session = PhoneControlSession()
        var calls = 0
        let update = Self.command(current, Self.fastRecovery(false))
        func failing(_ patch: [String: PhoneSetting.Value]) throws {
            calls += 1
            throw ApplyFailure()
        }
        let ack = session.receive(update, current: { current }, apply: failing)
        XCTAssertEqual(ack, PhoneControlAck(id: Self.id, status: .rejected, message: PhoneControlSession.failedText))
        XCTAssertEqual(session.receive(update, current: { current }, apply: { _ in calls += 1 }), ack)
        XCTAssertEqual(calls, 1)
    }

    func testAcceptsIsStrictPerKind() {
        let int = PhoneSetting.int("advanced.max", "Max", group: .advanced, value: 1, range: -5...Int(Int32.max))
        XCTAssertEqual(int.accepted(.number("2147483647")), .int(2_147_483_647))
        XCTAssertNil(int.accepted(.number("2147483648")))
        XCTAssertEqual(int.accepted(.number("-5")), .int(-5))
        XCTAssertNil(int.accepted(.number("-6")))
        XCTAssertNil(int.accepted(.number("01")))
        XCTAssertNil(int.accepted(.number("1E1")))
        let unbounded = PhoneSetting(key: "advanced.x", label: "X", group: .advanced, kind: .int, value: .int(1))
        XCTAssertNil(unbounded.accepted(.number("1")), "an int without bounds accepts nothing")
        let bool = PhoneSetting.bool("audio.x", "X", group: .audio, value: true)
        XCTAssertEqual(bool.accepted(.bool(false)), .bool(false))
        XCTAssertNil(bool.accepted(.string("true")))
        XCTAssertNil(bool.accepted(.null))
        let decomposed = "e\u{301}"
        let choice = PhoneSetting.choice(
            "audio.y", "Y", group: .audio, value: "\u{E9}", choices: [.init(value: "\u{E9}", label: "E")])
        XCTAssertEqual(choice.accepted(.string("\u{E9}")), .string("\u{E9}"))
        XCTAssertNil(choice.accepted(.string(decomposed)), "choices compare bytes, not canonical equivalence")
    }

    func testLabelsAreSanitizedAndBounded() {
        XCTAssertEqual(PhoneControl.label("AirPods\u{0}\n Pro\u{85}"), "AirPods Pro")
        XCTAssertEqual(PhoneControl.label(String(repeating: "\u{E9}", count: 100)).utf8.count, 160)
        let ascii = String(repeating: "a", count: 159)
        XCTAssertEqual(PhoneControl.label(ascii + "\u{1F600}"), ascii, "a scalar that does not fit is dropped whole")
        XCTAssertEqual(PhoneControl.label(" \t\u{1}"), "Audio device")
        XCTAssertEqual(PhoneControl.label(""), PhoneControl.fallbackLabel)
    }
}
