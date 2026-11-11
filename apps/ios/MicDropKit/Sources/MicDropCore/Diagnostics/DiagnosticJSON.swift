import Foundation

/// Explicit JSON value used for every diagnostics wire body.
///
/// Integers, unsigned integers and doubles are separate cases so Go `int`/`int64`/`uint64` fields never
/// receive `2.0` (`G:internal/diagnostics/report.go` rejects non-integer numbers for integer fields), and
/// non-finite doubles are never encoded (`K:PlaybackMetrics.kt:106`). Objects keep insertion order, which
/// mirrors Android's `linkedMapOf`; the host ignores key order (its duplicate digest re-encodes the value).
public enum DiagnosticJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([DiagnosticJSON])
    /// Ordered members. Keys are expected to be unique; the encoder writes them as given.
    case object([(key: String, value: DiagnosticJSON)])

    /// Thrown by `init(encoding:)` when an `Encodable` value cannot be represented honestly (non-finite floating-point
    /// value, unsupported container shape). The worker reacts like Android's `JSONException`:
    /// `ReportDelivery.unavailable()` and no `android` body (step 2).
    public struct EncodingFailure: Error, Sendable, Equatable {
        public let codingPath: String
        public let reason: String
        public init(codingPath: String, reason: String) {
            self.codingPath = codingPath
            self.reason = reason
        }
    }

    /// Converts an `Encodable` value (another owner's wire snapshot, e.g. `OutputControlSnapshot`,
    /// `MicrophoneSnapshot`, `RecoverySnapshot`) into a `DiagnosticJSON` tree without going through
    /// `JSONSerialization`, so integer/double typing is kept.
    ///
    /// Mapping: signed integers → `.int`; unsigned integers → `.int` when they fit in `Int64`, else `.uint`;
    /// `Double` → `.double`; `Float` → `.double` of its shortest decimal text (`0.1` stays `0.1`); `Bool` →
    /// `.bool`; `String` → `.string`; `encodeNil` → `.null`. Keyed containers keep first-encode order and a
    /// repeated key replaces the earlier value in place. Nested containers and super-encoders follow
    /// `JSONEncoder` (`superEncoder()` writes under `"super"`; one that receives nothing becomes `{}`).
    /// `encodeIfPresent(nil, …)` omits the key, exactly like `JSONEncoder`.
    ///
    /// Throws `EncodingFailure` for a non-finite `Double`/`Float`, for a value written twice through one
    /// single-value container, for a container requested on a position that already holds another shape,
    /// and when the top-level value encodes nothing.
    public init<T: Encodable>(encoding value: T) throws {
        let state = TreeState()
        let root = TreeSlot()
        try value.encode(to: TreeEncoder(slot: root, codingPath: [], state: state))
        if let failure = state.failure { throw failure }
        if case .empty = root.content {
            throw EncodingFailure(codingPath: "", reason: "\(T.self) did not encode any value")
        }
        self = root.resolved()
    }
}

// MARK: - Encodable → DiagnosticJSON tree (private Encoder)

extension DiagnosticJSON {
    /// One value position. Containers hand out references, so nested containers and super-encoders may be
    /// filled after their parent registered them (Foundation `JSONEncoder` semantics).
    fileprivate final class TreeSlot {
        enum Content {
            case empty
            case value(DiagnosticJSON)
            case object(TreeObject)
            case array(TreeArray)
        }

        var content: Content = .empty

        init() {}

        init(_ value: DiagnosticJSON) {
            content = .value(value)
        }

        /// A position nothing was written to (an unused super-encoder) resolves to `{}` like `JSONEncoder`.
        func resolved() -> DiagnosticJSON {
            switch content {
            case .empty:
                return .object([])
            case .value(let value):
                return value
            case .object(let object):
                return .object(object.members.map { (key: $0.key, value: $0.slot.resolved()) })
            case .array(let array):
                return .array(array.slots.map { $0.resolved() })
            }
        }
    }

    /// Ordered object storage: first-encode order, a repeated key replaces its value in place.
    fileprivate final class TreeObject {
        private(set) var members: [(key: String, slot: TreeSlot)] = []
        private var positions: [String: Int] = [:]

        func set(_ key: String, _ slot: TreeSlot) {
            if let position = positions[key] {
                members[position].slot = slot
            } else {
                positions[key] = members.count
                members.append((key: key, slot: slot))
            }
        }

        func slot(forKey key: String) -> TreeSlot? {
            positions[key].map { members[$0].slot }
        }
    }

    fileprivate final class TreeArray {
        var slots: [TreeSlot] = []
    }

    /// Container-shape misuse cannot throw from the non-throwing `Encoder` methods; it is recorded here and
    /// thrown by `init(encoding:)` once encoding returns. The first failure wins.
    fileprivate final class TreeState {
        private(set) var failure: EncodingFailure?

        func record(_ codingPath: [CodingKey], _ reason: String) {
            if failure == nil {
                failure = EncodingFailure(codingPath: DiagnosticJSON.render(codingPath), reason: reason)
            }
        }
    }

    fileprivate struct TreeKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init(intValue: Int) {
            self.stringValue = "Index \(intValue)"
            self.intValue = intValue
        }

        static let superKey = TreeKey(stringValue: "super")
    }

    /// `a.b[2].c` style path for `EncodingFailure.codingPath` (key names only, never values).
    fileprivate static func render(_ codingPath: [CodingKey]) -> String {
        var text = ""
        for key in codingPath {
            if let index = key.intValue, key is TreeKey {
                text += "[\(index)]"
            } else {
                text += text.isEmpty ? key.stringValue : "." + key.stringValue
            }
        }
        return text
    }

    fileprivate static func signedValue<T: FixedWidthInteger & SignedInteger>(_ value: T) -> DiagnosticJSON {
        .int(Int64(value))
    }

    fileprivate static func unsignedValue<T: FixedWidthInteger & UnsignedInteger>(_ value: T) -> DiagnosticJSON {
        if let exact = Int64(exactly: value) { return .int(exact) }
        return .uint(UInt64(value))
    }

    fileprivate static func doubleValue(_ value: Double, _ codingPath: [CodingKey]) throws -> DiagnosticJSON {
        guard value.isFinite else {
            throw EncodingFailure(codingPath: render(codingPath), reason: "non-finite floating-point value")
        }
        return .double(value)
    }

    fileprivate static func floatValue(_ value: Float, _ codingPath: [CodingKey]) throws -> DiagnosticJSON {
        guard value.isFinite else {
            throw EncodingFailure(codingPath: render(codingPath), reason: "non-finite floating-point value")
        }
        // `Double(Float(0.1))` is 0.10000000149011612; the Float's shortest text keeps `0.1` (JSONEncoder parity).
        return .double(Double("\(value)") ?? Double(value))
    }

    fileprivate struct TreeEncoder: Encoder {
        let slot: TreeSlot
        let codingPath: [CodingKey]
        let state: TreeState

        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            let object: TreeObject
            switch slot.content {
            case .empty:
                object = TreeObject()
                slot.content = .object(object)
            case .object(let existing):
                object = existing
            case .value, .array:
                state.record(codingPath, "keyed container requested where another value was already encoded")
                object = TreeObject()
            }
            return KeyedEncodingContainer(TreeKeyedContainer<Key>(object: object, codingPath: codingPath, state: state))
        }

        func unkeyedContainer() -> UnkeyedEncodingContainer {
            let array: TreeArray
            switch slot.content {
            case .empty:
                array = TreeArray()
                slot.content = .array(array)
            case .array(let existing):
                array = existing
            case .value, .object:
                state.record(codingPath, "unkeyed container requested where another value was already encoded")
                array = TreeArray()
            }
            return TreeUnkeyedContainer(array: array, codingPath: codingPath, state: state)
        }

        func singleValueContainer() -> SingleValueEncodingContainer {
            TreeSingleValueContainer(slot: slot, codingPath: codingPath, state: state)
        }
    }

    fileprivate struct TreeKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let object: TreeObject
        let codingPath: [CodingKey]
        let state: TreeState

        private func put(_ value: DiagnosticJSON, _ key: Key) {
            object.set(key.stringValue, TreeSlot(value))
        }

        mutating func encodeNil(forKey key: Key) throws { put(.null, key) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { put(.bool(value), key) }
        mutating func encode(_ value: String, forKey key: Key) throws { put(.string(value), key) }
        mutating func encode(_ value: Double, forKey key: Key) throws {
            put(try DiagnosticJSON.doubleValue(value, codingPath + [key]), key)
        }
        mutating func encode(_ value: Float, forKey key: Key) throws {
            put(try DiagnosticJSON.floatValue(value, codingPath + [key]), key)
        }
        mutating func encode(_ value: Int, forKey key: Key) throws { put(DiagnosticJSON.signedValue(value), key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { put(DiagnosticJSON.signedValue(value), key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { put(DiagnosticJSON.signedValue(value), key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { put(DiagnosticJSON.signedValue(value), key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { put(DiagnosticJSON.signedValue(value), key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { put(DiagnosticJSON.unsignedValue(value), key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { put(DiagnosticJSON.unsignedValue(value), key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws {
            put(DiagnosticJSON.unsignedValue(value), key)
        }
        mutating func encode(_ value: UInt32, forKey key: Key) throws {
            put(DiagnosticJSON.unsignedValue(value), key)
        }
        mutating func encode(_ value: UInt64, forKey key: Key) throws {
            put(DiagnosticJSON.unsignedValue(value), key)
        }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            let child = TreeSlot()
            object.set(key.stringValue, child)
            try value.encode(to: TreeEncoder(slot: child, codingPath: codingPath + [key], state: state))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type, forKey key: Key
        ) -> KeyedEncodingContainer<NestedKey> {
            TreeEncoder(slot: nestedSlot(key, keyed: true), codingPath: codingPath + [key], state: state)
                .container(keyedBy: keyType)
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            TreeEncoder(slot: nestedSlot(key, keyed: false), codingPath: codingPath + [key], state: state)
                .unkeyedContainer()
        }

        mutating func superEncoder() -> Encoder {
            let child = TreeSlot()
            object.set(TreeKey.superKey.stringValue, child)
            return TreeEncoder(slot: child, codingPath: codingPath + [TreeKey.superKey], state: state)
        }

        mutating func superEncoder(forKey key: Key) -> Encoder {
            let child = TreeSlot()
            object.set(key.stringValue, child)
            return TreeEncoder(slot: child, codingPath: codingPath + [key], state: state)
        }

        /// A second nested container of the same shape for the same key continues the first one.
        private func nestedSlot(_ key: Key, keyed: Bool) -> TreeSlot {
            if let existing = object.slot(forKey: key.stringValue) {
                switch existing.content {
                case .object where keyed, .array where !keyed:
                    return existing
                default:
                    break
                }
            }
            let child = TreeSlot()
            object.set(key.stringValue, child)
            return child
        }
    }

    fileprivate struct TreeUnkeyedContainer: UnkeyedEncodingContainer {
        let array: TreeArray
        let codingPath: [CodingKey]
        let state: TreeState

        var count: Int { array.slots.count }

        private var nextPath: [CodingKey] { codingPath + [TreeKey(intValue: array.slots.count)] }

        private func append(_ value: DiagnosticJSON) {
            array.slots.append(TreeSlot(value))
        }

        mutating func encodeNil() throws { append(.null) }
        mutating func encode(_ value: Bool) throws { append(.bool(value)) }
        mutating func encode(_ value: String) throws { append(.string(value)) }
        mutating func encode(_ value: Double) throws { append(try DiagnosticJSON.doubleValue(value, nextPath)) }
        mutating func encode(_ value: Float) throws { append(try DiagnosticJSON.floatValue(value, nextPath)) }
        mutating func encode(_ value: Int) throws { append(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int8) throws { append(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int16) throws { append(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int32) throws { append(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int64) throws { append(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: UInt) throws { append(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt8) throws { append(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt16) throws { append(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt32) throws { append(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt64) throws { append(DiagnosticJSON.unsignedValue(value)) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            let path = nextPath
            let child = TreeSlot()
            array.slots.append(child)
            try value.encode(to: TreeEncoder(slot: child, codingPath: path, state: state))
        }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type
        ) -> KeyedEncodingContainer<NestedKey> {
            let path = nextPath
            let child = TreeSlot()
            array.slots.append(child)
            return TreeEncoder(slot: child, codingPath: path, state: state).container(keyedBy: keyType)
        }

        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            let path = nextPath
            let child = TreeSlot()
            array.slots.append(child)
            return TreeEncoder(slot: child, codingPath: path, state: state).unkeyedContainer()
        }

        mutating func superEncoder() -> Encoder {
            let path = nextPath
            let child = TreeSlot()
            array.slots.append(child)
            return TreeEncoder(slot: child, codingPath: path, state: state)
        }
    }

    fileprivate struct TreeSingleValueContainer: SingleValueEncodingContainer {
        let slot: TreeSlot
        let codingPath: [CodingKey]
        let state: TreeState

        private func requireEmpty() throws {
            guard case .empty = slot.content else {
                throw EncodingFailure(
                    codingPath: DiagnosticJSON.render(codingPath),
                    reason: "single value container already holds a value")
            }
        }

        private func store(_ value: DiagnosticJSON) throws {
            try requireEmpty()
            slot.content = .value(value)
        }

        mutating func encodeNil() throws { try store(.null) }
        mutating func encode(_ value: Bool) throws { try store(.bool(value)) }
        mutating func encode(_ value: String) throws { try store(.string(value)) }
        mutating func encode(_ value: Double) throws { try store(try DiagnosticJSON.doubleValue(value, codingPath)) }
        mutating func encode(_ value: Float) throws { try store(try DiagnosticJSON.floatValue(value, codingPath)) }
        mutating func encode(_ value: Int) throws { try store(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int8) throws { try store(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int16) throws { try store(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int32) throws { try store(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: Int64) throws { try store(DiagnosticJSON.signedValue(value)) }
        mutating func encode(_ value: UInt) throws { try store(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt8) throws { try store(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt16) throws { try store(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt32) throws { try store(DiagnosticJSON.unsignedValue(value)) }
        mutating func encode(_ value: UInt64) throws { try store(DiagnosticJSON.unsignedValue(value)) }

        mutating func encode<T: Encodable>(_ value: T) throws {
            try requireEmpty()
            try value.encode(to: TreeEncoder(slot: slot, codingPath: codingPath, state: state))
        }
    }
}

// MARK: - Construction helpers

extension DiagnosticJSON {
    /// Metric/peak values: `nil` or non-finite becomes `null` (`K:PlaybackMetrics.kt:106`).
    public static func number(_ value: Double?) -> DiagnosticJSON {
        guard let value, value.isFinite else { return .null }
        return .double(value)
    }

    /// Nullable Go `*bool` field (emit `null` exactly where Android does).
    public static func nullable(_ value: Bool?) -> DiagnosticJSON {
        value.map { .bool($0) } ?? .null
    }

    /// Nullable Go integer pointer field.
    public static func nullable(_ value: Int64?) -> DiagnosticJSON {
        value.map { .int($0) } ?? .null
    }

    /// Nullable Go integer pointer field (e.g. `http_status`).
    public static func nullable(_ value: Int?) -> DiagnosticJSON {
        value.map { .int(Int64($0)) } ?? .null
    }

    /// Nullable string field.
    public static func nullable(_ value: String?) -> DiagnosticJSON {
        value.map { .string($0) } ?? .null
    }

    /// Nullable nested object.
    public static func nullable(_ value: DiagnosticJSON?) -> DiagnosticJSON {
        value ?? .null
    }

    /// String array or `null` (e.g. `expected_routes`).
    public static func strings(_ values: [String]?) -> DiagnosticJSON {
        guard let values else { return .null }
        return .array(values.map { .string($0) })
    }

    /// Returns an object with `(key, value)` appended. Non-object values are returned unchanged.
    /// Used to add `microphone.processing` (`K:PlaybackReport.kt:49-51`).
    public func appending(_ key: String, _ value: DiagnosticJSON) -> DiagnosticJSON {
        guard case .object(var members) = self else { return self }
        members.append((key: key, value: value))
        return .object(members)
    }
}

// MARK: - Inspection (tests, delivery bookkeeping)

extension DiagnosticJSON {
    /// First member named `key` of an object; `nil` for other cases or a missing key.
    public subscript(_ key: String) -> DiagnosticJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    /// Member keys in order for an object, else `nil`.
    public var keys: [String]? {
        guard case .object(let members) = self else { return nil }
        return members.map { $0.key }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Equatable (manual: tuple payloads cannot synthesize)

extension DiagnosticJSON: Equatable {
    public static func == (lhs: DiagnosticJSON, rhs: DiagnosticJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.uint(let a), .uint(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for index in a.indices where a[index].key != b[index].key || a[index].value != b[index].value {
                return false
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Encoding (compact UTF-8, no whitespace)

extension DiagnosticJSON {
    /// Compact UTF-8 JSON bytes for a request body.
    public func encoded() -> Data {
        Data(encodedString().utf8)
    }

    /// Compact JSON text. Doubles use Swift's shortest round-trip description (`64.0`, `1e-05`), which is
    /// valid JSON; non-finite doubles are written as `null` (never reached through `number(_:)`).
    public func encodedString() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .uint(let value):
            out += String(value)
        case .double(let value):
            out += value.isFinite ? "\(value)" : "null"
        case .string(let value):
            Self.writeString(value, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(member.key, into: &out)
                out += ":"
                member.value.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
