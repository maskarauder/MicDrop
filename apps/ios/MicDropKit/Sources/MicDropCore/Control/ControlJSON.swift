import Foundation

/// A JSON object from a control reply, read with Android org.json `opt*`/`get*` semantics ("decode leniently", risk
/// 10).
///
/// Parsing is portable and exact (no `JSONSerialization`, whose Bool/NSNumber bridging differs between Darwin and
/// Linux): numbers keep their literal text, object members keep their order, and a repeated key resolves to its
/// **last** occurrence (org.json `put` replaces). The top level must be an object; trailing whitespace is allowed (Go
/// appends `\n`), trailing data is not (step 8).
///
/// Lenient accessors mirror org.json:
/// - `int`/`int64` (`optInt`/`optLong`): a JSON number (truncated toward zero, saturating) or
///   a numeric string; anything else → default.
/// - `bool` (`optBoolean`): a JSON boolean or the string `true`/`false` (case-insensitive).
/// - `string` (`optString`): a JSON string; anything else → default (org.json would also
///   stringify numbers/booleans; no consumed field relies on that).
/// - `require*` (`get*`): same coercions, but missing/mistyped → `ControlResponseError(.invalidReply)`.
public struct ControlJSON: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public indirect enum Value: Sendable, Equatable {
        case null
        case bool(Bool)
        /// The JSON number literal exactly as received (or produced), e.g. `7`, `-1.5e3`.
        case number(String)
        case string(String)
        case array([Value])
        case object([Member])

        public static func int(_ value: Int) -> Value { .number(String(value)) }
        public static func int64(_ value: Int64) -> Value { .number(String(value)) }
        public static func uint64(_ value: UInt64) -> Value { .number(String(value)) }
        /// Non-finite values encode as `null`.
        public static func double(_ value: Double) -> Value { value.isFinite ? .number(String(value)) : .null }

        /// org.json `optLong` coercion (see type docs).
        public var integer: Int64? {
            switch self {
            case .number(let literal):
                if let exact = Int64(literal) { return exact }
                return Double(literal).map(Value.saturatingInt64)
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let exact = Int64(trimmed) { return exact }
                return Double(trimmed).map(Value.saturatingInt64)
            default:
                return nil
            }
        }

        /// A JSON number as `Double` (Kotlin `opt(key) as? Number`); strings are not coerced.
        public var doubleValue: Double? {
            if case .number(let literal) = self { return Double(literal) }
            return nil
        }

        /// org.json `optBoolean` coercion.
        public var boolean: Bool? {
            switch self {
            case .bool(let value):
                return value
            case .string(let text):
                switch text.lowercased() {
                case "true": return true
                case "false": return false
                default: return nil
                }
            default:
                return nil
            }
        }

        /// A JSON string value.
        public var text: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var isNull: Bool {
            if case .null = self { return true }
            return false
        }

        /// Foundation-style object graph for consumers that take `[String: Any]`
        /// (`String`, `Int64`/`Double`, `Bool`, `NSNull`, `[Any]`, `[String: Any]`).
        public var foundationObject: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let value): return value
            case .number(let literal):
                if let exact = Int64(literal) { return exact }
                return Double(literal) ?? 0
            case .string(let value): return value
            case .array(let values): return values.map { $0.foundationObject }
            case .object(let members):
                var dictionary: [String: Any] = [:]
                for member in members { dictionary[member.key] = member.value.foundationObject }
                return dictionary
            }
        }

        /// Compact UTF-8 encoding (no whitespace, `/` not escaped, number literals verbatim).
        public func encoded() -> Data {
            var bytes: [UInt8] = []
            encode(into: &bytes)
            return Data(bytes)
        }

        func encode(into out: inout [UInt8]) {
            switch self {
            case .null:
                out.append(contentsOf: Array("null".utf8))
            case .bool(let value):
                out.append(contentsOf: Array((value ? "true" : "false").utf8))
            case .number(let literal):
                out.append(contentsOf: Array(literal.utf8))
            case .string(let value):
                Value.encodeString(value, into: &out)
            case .array(let values):
                out.append(0x5B)
                for (index, value) in values.enumerated() {
                    if index > 0 { out.append(0x2C) }
                    value.encode(into: &out)
                }
                out.append(0x5D)
            case .object(let members):
                out.append(0x7B)
                for (index, member) in members.enumerated() {
                    if index > 0 { out.append(0x2C) }
                    Value.encodeString(member.key, into: &out)
                    out.append(0x3A)
                    member.value.encode(into: &out)
                }
                out.append(0x7D)
            }
        }

        private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

        /// JSON string escaping: `"`, `\`, and control characters; everything else raw UTF-8.
        static func encodeString(_ value: String, into out: inout [UInt8]) {
            out.append(0x22)
            for byte in value.utf8 {
                switch byte {
                case 0x22: out.append(contentsOf: [0x5C, 0x22])
                case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: out.append(contentsOf: [0x5C, 0x72])
                case 0x09: out.append(contentsOf: [0x5C, 0x74])
                case 0x08: out.append(contentsOf: [0x5C, 0x62])
                case 0x0C: out.append(contentsOf: [0x5C, 0x66])
                case 0x00...0x1F:
                    out.append(contentsOf: [
                        0x5C, 0x75, 0x30, 0x30, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)],
                    ])
                default:
                    out.append(byte)
                }
            }
            out.append(0x22)
        }

        /// Java `(long) double`: truncation toward zero, saturating, NaN → 0.
        private static func saturatingInt64(_ value: Double) -> Int64 {
            if value.isNaN { return 0 }
            if value >= 9_223_372_036_854_775_807.0 { return Int64.max }
            if value <= -9_223_372_036_854_775_808.0 { return Int64.min }
            return Int64(value)
        }
    }

    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: Value

        public init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// Members in document order (duplicates retained; lookups use the last one).
    public let members: [Member]

    public init(members: [Member]) {
        self.members = members
    }

    public init(dictionaryLiteral elements: (String, Value)...) {
        members = elements.map { Member($0.0, $0.1) }
    }

    /// Parses a UTF-8 JSON document whose top level is an object. Failure → `ControlResponseError(.invalidJSON)`
    /// (non-retryable).
    public init(bytes: [UInt8]) throws {
        var parser = Parser(bytes)
        guard case .object(let members) = try parser.document() else {
            throw ControlResponseError(.invalidJSON)
        }
        self.members = members
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    // MARK: Lookup

    /// The last member named `key` (org.json semantics for repeated keys).
    public subscript(key: String) -> Value? {
        members.last(where: { $0.key == key })?.value
    }

    /// org.json `has` (true also for an explicit `null`).
    public func contains(_ key: String) -> Bool {
        self[key] != nil
    }

    /// Distinct keys in first-occurrence order.
    public var keys: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for member in members where seen.insert(member.key).inserted { ordered.append(member.key) }
        return ordered
    }

    /// The object as a `Value`.
    public var value: Value { .object(members) }

    /// Foundation-style dictionary (see `Value.foundationObject`).
    public var dictionary: [String: Any] {
        (value.foundationObject as? [String: Any]) ?? [:]
    }

    // MARK: Lenient accessors (org.json opt*)

    public func int(_ key: String, default fallback: Int = 0) -> Int {
        guard let integer = self[key]?.integer else { return fallback }
        return Int(clamping: integer)
    }

    public func int64(_ key: String, default fallback: Int64) -> Int64 {
        self[key]?.integer ?? fallback
    }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        self[key]?.boolean ?? fallback
    }

    /// True iff the member is a JSON boolean (Kotlin `opt(key) is Boolean`).
    public func isBool(_ key: String) -> Bool {
        if case .bool(_)? = self[key] { return true }
        return false
    }

    public func string(_ key: String, default fallback: String = "") -> String {
        self[key]?.text ?? fallback
    }

    /// org.json `optJSONObject`.
    public func object(_ key: String) -> ControlJSON? {
        if case .object(let members)? = self[key] { return ControlJSON(members: members) }
        return nil
    }

    /// org.json `optJSONArray`.
    public func array(_ key: String) -> [Value]? {
        if case .array(let values)? = self[key] { return values }
        return nil
    }

    /// The compact encoding of one member's value (for `Codable` decoders of sub-objects).
    public func encodedValue(_ key: String) -> Data? {
        self[key]?.encoded()
    }

    // MARK: Strict accessors (org.json get*)

    public func requireInt(_ key: String) throws -> Int {
        Int(clamping: try requireInt64(key))
    }

    public func requireInt64(_ key: String) throws -> Int64 {
        guard let integer = self[key]?.integer else { throw ControlResponseError(.invalidReply) }
        return integer
    }

    public func requireString(_ key: String) throws -> String {
        guard let text = self[key]?.text else { throw ControlResponseError(.invalidReply) }
        return text
    }

    public func requireBool(_ key: String) throws -> Bool {
        guard let value = self[key]?.boolean else { throw ControlResponseError(.invalidReply) }
        return value
    }

    public func requireObject(_ key: String) throws -> ControlJSON {
        guard let object = object(key) else { throw ControlResponseError(.invalidReply) }
        return object
    }

    // MARK: Encoding

    /// Compact UTF-8 encoding of the object.
    public func encoded() -> Data {
        value.encoded()
    }

    public var encodedBytes: [UInt8] {
        var bytes: [UInt8] = []
        value.encode(into: &bytes)
        return bytes
    }

    // MARK: Parser (RFC 8259, depth-limited)

    private struct Parser {
        static let maxDepth = 128

        let bytes: [UInt8]
        var index = 0
        var depth = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func document() throws -> Value {
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw ControlResponseError(.invalidJSON) }
            return value
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        func peek() throws -> UInt8 {
            guard index < bytes.count else { throw ControlResponseError(.invalidJSON) }
            return bytes[index]
        }

        mutating func parseValue() throws -> Value {
            switch try peek() {
            case 0x7B: return try parseObject()
            case 0x5B: return try parseArray()
            case 0x22: return .string(try parseString())
            case 0x74:
                try literal("true")
                return .bool(true)
            case 0x66:
                try literal("false")
                return .bool(false)
            case 0x6E:
                try literal("null")
                return .null
            case 0x2D, 0x30...0x39:
                return .number(try parseNumber())
            default:
                throw ControlResponseError(.invalidJSON)
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                bytes[index..<(index + expected.count)].elementsEqual(expected)
            else {
                throw ControlResponseError(.invalidJSON)
            }
            index += expected.count
        }

        mutating func enter() throws {
            depth += 1
            guard depth <= Parser.maxDepth else { throw ControlResponseError(.invalidJSON) }
        }

        mutating func parseObject() throws -> Value {
            try enter()
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if try peek() == 0x7D {
                index += 1
                depth -= 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard try peek() == 0x22 else { throw ControlResponseError(.invalidJSON) }
                let key = try parseString()
                skipWhitespace()
                guard try peek() == 0x3A else { throw ControlResponseError(.invalidJSON) }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                members.append(Member(key, value))
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == 0x2C { continue }
                if next == 0x7D { break }
                throw ControlResponseError(.invalidJSON)
            }
            depth -= 1
            return .object(members)
        }

        mutating func parseArray() throws -> Value {
            try enter()
            index += 1
            var values: [Value] = []
            skipWhitespace()
            if try peek() == 0x5D {
                index += 1
                depth -= 1
                return .array(values)
            }
            while true {
                skipWhitespace()
                values.append(try parseValue())
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == 0x2C { continue }
                if next == 0x5D { break }
                throw ControlResponseError(.invalidJSON)
            }
            depth -= 1
            return .array(values)
        }

        mutating func parseString() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw ControlResponseError(.invalidJSON) }
                let byte = bytes[index]
                index += 1
                switch byte {
                case 0x22:
                    return String(decoding: out, as: UTF8.self)
                case 0x5C:
                    guard index < bytes.count else { throw ControlResponseError(.invalidJSON) }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: out.append(0x22)
                    case 0x5C: out.append(0x5C)
                    case 0x2F: out.append(0x2F)
                    case 0x62: out.append(0x08)
                    case 0x66: out.append(0x0C)
                    case 0x6E: out.append(0x0A)
                    case 0x72: out.append(0x0D)
                    case 0x74: out.append(0x09)
                    case 0x75: try appendUnicodeEscape(into: &out)
                    default: throw ControlResponseError(.invalidJSON)
                    }
                case 0x00...0x1F:
                    throw ControlResponseError(.invalidJSON)
                default:
                    out.append(byte)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw ControlResponseError(.invalidJSON) }
            var result: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41) + 10
                case 0x61...0x66: digit = UInt32(byte - 0x61) + 10
                default: throw ControlResponseError(.invalidJSON)
                }
                result = (result << 4) | digit
            }
            return result
        }

        /// `\uXXXX` with surrogate pairs; a lone surrogate becomes U+FFFD (Swift strings
        /// cannot hold one).
        mutating func appendUnicodeEscape(into out: inout [UInt8]) throws {
            let replacement: Unicode.Scalar = "\u{FFFD}"
            var code = try hex4()
            if (0xD800...0xDBFF).contains(code) {
                if index + 6 <= bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                    let resume = index
                    index += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = resume
                        code = replacement.value
                    }
                } else {
                    code = replacement.value
                }
            } else if (0xDC00...0xDFFF).contains(code) {
                code = replacement.value
            }
            var scalarText = ""
            scalarText.unicodeScalars.append(Unicode.Scalar(code) ?? replacement)
            out.append(contentsOf: Array(scalarText.utf8))
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count else { throw ControlResponseError(.invalidJSON) }
            if bytes[index] == 0x30 {
                index += 1
            } else if (0x31...0x39).contains(bytes[index]) {
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            } else {
                throw ControlResponseError(.invalidJSON)
            }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                let digits = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw ControlResponseError(.invalidJSON) }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                let digits = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw ControlResponseError(.invalidJSON) }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
