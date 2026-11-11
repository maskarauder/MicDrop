import Foundation

/// Strict JSON object reader for link payloads and the `/pair` reply.
///
/// Android uses lenient `org.json` and compensates with exact key counts and `is Int` / `is Boolean` checks; Go always
/// emits canonical JSON. iOS is strict: a top-level object, duplicate keys rejected, strings must be JSON strings,
/// integers must be integer literals (no `.`, `e`, `E`, never booleans), booleans must be `true`/`false`. This never
/// rejects anything Go produces.
public struct StrictJSONObject: Equatable, Sendable {
    /// A parsed JSON value. Numbers keep the integer/non-integer distinction of the literal.
    public indirect enum Value: Equatable, Sendable {
        case string(String)
        /// An integer literal (`-?(0|[1-9][0-9]*)`) that fits `Int64`.
        case integer(Int64)
        /// Any other number literal (fraction, exponent, or an integer outside `Int64`).
        case number(Double)
        case bool(Bool)
        case null
        case array([Value])
        case object(StrictJSONObject)
    }

    /// Parse or access failure. Never carries input text (payloads may hold credentials).
    public enum Failure: Error, Equatable, Sendable {
        case invalidUTF8
        /// Grammar error at a byte offset (RFC 8259 grammar, no comments, no single quotes,
        /// no trailing commas, no leading zeros, no unescaped control characters, no lone
        /// surrogate escapes).
        case syntax(offset: Int)
        case notAnObject
        case duplicateKey
        case tooDeep
        case missingKey(String)
        case wrongType(String)
        case unexpectedKeys
    }

    /// Maximum nesting depth accepted by the parser (links are flat; replies are flat).
    public static let maxDepth = 16

    /// Members by key.
    public let members: [String: Value]
    /// Keys in document order (used for re-encoding).
    public let orderedKeys: [String]

    /// Parses one JSON object from UTF-8 bytes. Leading/trailing JSON whitespace is allowed
    /// (Go's `json.Encoder` appends `\n`); anything else after the object is rejected.
    ///
    /// Order of checks: the whole input must be well-formed UTF-8 (RFC 3629: no overlong forms,
    /// no surrogates, nothing above U+10FFFF; a byte-order mark is not skipped) → `.invalidUTF8`;
    /// then one RFC 8259 value followed only by whitespace (space, tab, LF, CR) → `.syntax`;
    /// a nesting depth above `maxDepth` → `.tooDeep`; a repeated member name in any object →
    /// `.duplicateKey`; a well-formed value that is not an object → `.notAnObject`.
    public init(utf8 bytes: [UInt8]) throws {
        guard StrictJSONObject.isWellFormedUTF8(bytes) else {
            throw Failure.invalidUTF8
        }
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 1)
        parser.skipWhitespace()
        guard parser.index == bytes.count else {
            throw Failure.syntax(offset: parser.index)
        }
        guard case .object(let object) = value else {
            throw Failure.notAnObject
        }
        self = object
    }

    /// Parses one JSON object from `data` (see `init(utf8:)`).
    public init(data: Data) throws {
        try self.init(utf8: [UInt8](data))
    }

    /// Builds an object from already-parsed members (used by the parser and by tests).
    /// Throws `.duplicateKey` when a key repeats.
    public init(orderedMembers: [(String, Value)]) throws {
        var members: [String: Value] = [:]
        var keys: [String] = []
        keys.reserveCapacity(orderedMembers.count)
        for (key, value) in orderedMembers {
            guard members[key] == nil else {
                throw Failure.duplicateKey
            }
            members[key] = value
            keys.append(key)
        }
        self.members = members
        self.orderedKeys = keys
    }

    /// The set of member names.
    public var keys: Set<String> { Set(orderedKeys) }

    /// Number of members (Android `JSONObject.length()`).
    public var count: Int { orderedKeys.count }

    /// The raw value for `key`, if present.
    public func value(_ key: String) -> Value? { members[key] }

    /// Requires the exact member set (Android: `json.length() == N` plus a getter per key).
    public func requireKeys(_ expected: Set<String>) throws {
        guard count == expected.count, keys == expected else {
            throw Failure.unexpectedKeys
        }
    }

    /// A JSON string member (no coercion from numbers, unlike `org.json getString`).
    public func string(_ key: String) throws -> String {
        guard let value = members[key] else { throw Failure.missingKey(key) }
        guard case .string(let text) = value else { throw Failure.wrongType(key) }
        return text
    }

    /// A JSON integer-literal member that fits `Int64` (callers then check the field range).
    public func integer(_ key: String) throws -> Int64 {
        guard let value = members[key] else { throw Failure.missingKey(key) }
        guard case .integer(let number) = value else { throw Failure.wrongType(key) }
        return number
    }

    /// A JSON boolean member (`force_relay`, `RemoteConnection.kt:32`).
    public func bool(_ key: String) throws -> Bool {
        guard let value = members[key] else { throw Failure.missingKey(key) }
        guard case .bool(let flag) = value else { throw Failure.wrongType(key) }
        return flag
    }

    /// A nested JSON object member.
    public func object(_ key: String) throws -> StrictJSONObject {
        guard let value = members[key] else { throw Failure.missingKey(key) }
        guard case .object(let object) = value else { throw Failure.wrongType(key) }
        return object
    }

    /// Compact encoding in document order (no spaces; `/` is not escaped, like Go).
    public func encoded() -> String {
        var output = "{"
        for (index, key) in orderedKeys.enumerated() {
            if index > 0 { output += "," }
            output += StrictJSONObject.quote(key)
            output += ":"
            output += StrictJSONObject.encodeValue(members[key] ?? .null)
        }
        output += "}"
        return output
    }

    /// Compact JSON object text with members in the given order, e.g. the `/pair` body
    /// `{"version":1,"secret":…,"label":…}` (`PairingClient.kt:66-67`) or a saved paired
    /// record (`LanInvitation.kt:24-25`). Keys are not checked for duplicates.
    public static func encode(_ members: KeyValuePairs<String, Value>) -> String {
        var output = "{"
        var first = true
        for (key, value) in members {
            if !first { output += "," }
            first = false
            output += quote(key)
            output += ":"
            output += encodeValue(value)
        }
        output += "}"
        return output
    }

    /// A JSON string literal: escapes `"`, `\` and C0 controls; everything else verbatim.
    public static func quote(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    // MARK: - Parsing

    /// RFC 3629 well-formedness: rejects stray continuation bytes, overlong encodings (E0 80–9F, F0 80–8F), UTF-16
    /// surrogates (ED A0–BF), scalars above U+10FFFF and truncated sequences. (Android decodes with replacement
    /// characters; iOS is strict,.)
    static func isWellFormedUTF8(_ bytes: [UInt8]) -> Bool {
        var index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let length: Int
            var scalar: UInt32
            switch lead {
            case 0xC2...0xDF:
                length = 2
                scalar = UInt32(lead & 0x1F)
            case 0xE0...0xEF:
                length = 3
                scalar = UInt32(lead & 0x0F)
            case 0xF0...0xF4:
                length = 4
                scalar = UInt32(lead & 0x07)
            default:
                return false
            }
            guard index + length <= count else {
                return false
            }
            for offset in 1..<length {
                let byte = bytes[index + offset]
                guard byte & 0xC0 == 0x80 else {
                    return false
                }
                scalar = scalar << 6 | UInt32(byte & 0x3F)
            }
            switch length {
            case 3:
                guard scalar >= 0x800, !(0xD800...0xDFFF).contains(scalar) else {
                    return false
                }
            case 4:
                guard scalar >= 0x1_0000, scalar <= 0x10_FFFF else {
                    return false
                }
            default:
                break  // a C2…DF lead already guarantees U+0080 or above
            }
            index += length
        }
        return true
    }

    /// Recursive-descent RFC 8259 parser over already-validated UTF-8. Depth is bounded by
    /// `maxDepth`, so recursion is bounded.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private var syntaxError: Failure { .syntax(offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private func isDigit(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return byte >= 0x30 && byte <= 0x39
        }

        /// One value; `depth` is the nesting level an object or array here would have (the
        /// top-level value is depth 1).
        mutating func parseValue(depth: Int) throws -> Value {
            guard let byte = peek() else {
                throw syntaxError
            }
            switch byte {
            case 0x7B:  // {
                return .object(try parseObject(depth: depth))
            case 0x5B:  // [
                return .array(try parseArray(depth: depth))
            case 0x22:  // "
                return .string(try parseString())
            case 0x74:  // t
                try expectLiteral(Parser.trueLiteral)
                return .bool(true)
            case 0x66:  // f
                try expectLiteral(Parser.falseLiteral)
                return .bool(false)
            case 0x6E:  // n
                try expectLiteral(Parser.nullLiteral)
                return .null
            case 0x2D, 0x30...0x39:  // - 0-9
                return try parseNumber()
            default:
                throw syntaxError
            }
        }

        private static let trueLiteral: [UInt8] = Array("true".utf8)
        private static let falseLiteral: [UInt8] = Array("false".utf8)
        private static let nullLiteral: [UInt8] = Array("null".utf8)

        private mutating func expectLiteral(_ literal: [UInt8]) throws {
            for expected in literal {
                guard index < bytes.count, bytes[index] == expected else {
                    throw syntaxError
                }
                index += 1
            }
        }

        private mutating func parseObject(depth: Int) throws -> StrictJSONObject {
            guard depth <= StrictJSONObject.maxDepth else {
                throw Failure.tooDeep
            }
            index += 1  // {
            var members: [(String, Value)] = []
            var seen = Set<String>()
            skipWhitespace()
            if peek() == 0x7D {  // }
                index += 1
                return try StrictJSONObject(orderedMembers: [])
            }
            while true {
                skipWhitespace()
                guard peek() == 0x22 else {
                    throw syntaxError
                }
                let key = try parseString()
                guard seen.insert(key).inserted else {
                    throw Failure.duplicateKey
                }
                skipWhitespace()
                guard peek() == 0x3A else {  // :
                    throw syntaxError
                }
                index += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append((key, value))
                skipWhitespace()
                switch peek() {
                case 0x2C:  // ,
                    index += 1
                case 0x7D:  // }
                    index += 1
                    return try StrictJSONObject(orderedMembers: members)
                default:
                    throw syntaxError
                }
            }
        }

        private mutating func parseArray(depth: Int) throws -> [Value] {
            guard depth <= StrictJSONObject.maxDepth else {
                throw Failure.tooDeep
            }
            index += 1  // [
            var items: [Value] = []
            skipWhitespace()
            if peek() == 0x5D {  // ]
                index += 1
                return items
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                switch peek() {
                case 0x2C:  // ,
                    index += 1
                case 0x5D:  // ]
                    index += 1
                    return items
                default:
                    throw syntaxError
                }
            }
        }

        /// A string literal starting at `"`. Raw bytes below 0x20 are rejected; escapes are the
        /// eight RFC 8259 short forms and `\uXXXX` (a high surrogate must be followed by an
        /// escaped low surrogate; a lone surrogate is rejected).
        private mutating func parseString() throws -> String {
            index += 1  // opening quote
            var output: [UInt8] = []
            while true {
                guard let byte = peek() else {
                    throw syntaxError
                }
                switch byte {
                case 0x22:  // closing quote
                    index += 1
                    return String(decoding: output, as: UTF8.self)
                case 0x5C:  // backslash
                    index += 1
                    guard let escape = peek() else {
                        throw syntaxError
                    }
                    switch escape {
                    case 0x22, 0x5C, 0x2F:  // " \ /
                        output.append(escape)
                        index += 1
                    case 0x62:  // b
                        output.append(0x08)
                        index += 1
                    case 0x66:  // f
                        output.append(0x0C)
                        index += 1
                    case 0x6E:  // n
                        output.append(0x0A)
                        index += 1
                    case 0x72:  // r
                        output.append(0x0D)
                        index += 1
                    case 0x74:  // t
                        output.append(0x09)
                        index += 1
                    case 0x75:  // u
                        index += 1
                        let scalar = try parseUnicodeEscape()
                        UTF8.encode(scalar) { output.append($0) }
                    default:
                        throw syntaxError
                    }
                case 0x00...0x1F:
                    throw syntaxError
                default:
                    output.append(byte)
                    index += 1
                }
            }
        }

        /// The scalar of `XXXX` (after `\u`), combining a surrogate pair `\uD8xx\uDCxx`.
        private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let unit = try parseHex4()
            switch unit {
            case 0xD800...0xDBFF:
                guard peek() == 0x5C, index + 1 < bytes.count, bytes[index + 1] == 0x75 else {
                    throw syntaxError
                }
                index += 2
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw syntaxError
                }
                let value = 0x1_0000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(value) else {
                    throw syntaxError
                }
                return scalar
            case 0xDC00...0xDFFF:
                throw syntaxError
            default:
                guard let scalar = Unicode.Scalar(unit) else {
                    throw syntaxError
                }
                return scalar
            }
        }

        private mutating func parseHex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = peek() else {
                    throw syntaxError
                }
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default: throw syntaxError
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`. Without fraction and exponent and
        /// within `Int64` → `.integer`; otherwise `.number`.
        private mutating func parseNumber() throws -> Value {
            let start = index
            if peek() == 0x2D {  // -
                index += 1
            }
            guard let first = peek() else {
                throw syntaxError
            }
            if first == 0x30 {
                index += 1
            } else if first >= 0x31 && first <= 0x39 {
                while isDigit(peek()) { index += 1 }
            } else {
                throw syntaxError
            }
            var integral = true
            if peek() == 0x2E {  // .
                integral = false
                index += 1
                guard isDigit(peek()) else {
                    throw syntaxError
                }
                while isDigit(peek()) { index += 1 }
            }
            if peek() == 0x65 || peek() == 0x45 {  // e E
                integral = false
                index += 1
                if peek() == 0x2B || peek() == 0x2D {  // + -
                    index += 1
                }
                guard isDigit(peek()) else {
                    throw syntaxError
                }
                while isDigit(peek()) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if integral, let integer = Int64(text) {
                return .integer(integer)
            }
            if let number = Double(text) {
                return .number(number)
            }
            // Grammatically valid but not representable: keep the sign (never an integer).
            return .number(bytes[start] == 0x2D ? -Double.infinity : Double.infinity)
        }
    }

    private static func encodeValue(_ value: Value) -> String {
        switch value {
        case .string(let text):
            return quote(text)
        case .integer(let number):
            return String(number)
        case .number(let number):
            return number.isFinite ? "\(number)" : "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            return "[" + items.map { encodeValue($0) }.joined(separator: ",") + "]"
        case .object(let object):
            return object.encoded()
        }
    }
}
