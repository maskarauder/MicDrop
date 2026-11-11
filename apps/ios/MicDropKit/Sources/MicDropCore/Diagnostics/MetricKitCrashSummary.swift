import Foundation

/// Pure, bounded MetricKit exit summary (step 2). The app's `CrashReportCollector` (`MXMetricManagerSubscriber`) copies
/// the primitive fields of the newest `MXCrashDiagnostic` (else `MXHangDiagnostic`) into `Exit` and persists `text(_:)`
/// to `last-metrickit-exit.txt`. Keeping the parsing here makes it testable on Linux.
///
/// Never included: `virtualMemoryRegionInfo`, frame `address` values, `composedMessage`/`arguments`
/// of the Objective-C exception, or any thread other than the attributed one (Android
/// `NativeCrashTraceTest` rule: never substitute another thread).
public enum MetricKitCrashSummary {
    /// Input bound for `callStackTree.jsonRepresentation()`.
    public static let maxInputBytes = 2 * 1024 * 1024
    /// Threads inspected at most.
    public static let maxThreads = 128
    /// Frames kept from the attributed thread.
    public static let maxFrames = 24

    public enum Kind: String, Sendable, Equatable {
        case crash
        case hang
    }

    /// Primitive copy of one MetricKit diagnostic (no MetricKit types in MicDropCore).
    public struct Exit: Sendable, Equatable {
        public var kind: Kind
        /// RFC 3339 of `payload.timeStampEnd` (`DiagnosticTime.rfc3339`).
        public var recordedAt: String
        /// `MXCrashDiagnostic.exceptionType` (Mach exception number).
        public var exceptionType: Int?
        /// `MXCrashDiagnostic.exceptionCode`.
        public var exceptionCode: Int?
        /// `MXCrashDiagnostic.signal`.
        public var signal: Int?
        /// `metaData.applicationBuildVersion`.
        public var applicationBuildVersion: String?
        /// `metaData.osVersion`.
        public var osVersion: String?
        /// `MXCrashDiagnostic.terminationReason` (redacted with `CrashText.safe(_, 512)`).
        public var terminationReason: String?
        /// `exceptionReason.exceptionName` / `.className` (iOS 17 API).
        public var objectiveCExceptionName: String?
        public var objectiveCExceptionClassName: String?
        /// `MXHangDiagnostic.hangDuration` in milliseconds.
        public var hangDurationMs: Int64?
        /// `callStackTree.jsonRepresentation()`.
        public var callStackTreeJSON: Data?

        public init(
            kind: Kind, recordedAt: String, exceptionType: Int? = nil, exceptionCode: Int? = nil,
            signal: Int? = nil, applicationBuildVersion: String? = nil, osVersion: String? = nil,
            terminationReason: String? = nil, objectiveCExceptionName: String? = nil,
            objectiveCExceptionClassName: String? = nil, hangDurationMs: Int64? = nil,
            callStackTreeJSON: Data? = nil
        ) {
            self.kind = kind
            self.recordedAt = recordedAt
            self.exceptionType = exceptionType
            self.exceptionCode = exceptionCode
            self.signal = signal
            self.applicationBuildVersion = applicationBuildVersion
            self.osVersion = osVersion
            self.terminationReason = terminationReason
            self.objectiveCExceptionName = objectiveCExceptionName
            self.objectiveCExceptionClassName = objectiveCExceptionClassName
            self.hangDurationMs = hangDurationMs
            self.callStackTreeJSON = callStackTreeJSON
        }
    }

    /// Mach exception names.
    public static func machExceptionName(_ type: Int) -> String? {
        switch type {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return nil
        }
    }

    /// Signal names; others are printed numerically.
    public static func signalName(_ signal: Int) -> String? {
        switch signal {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        case 15: return "SIGTERM"
        default: return nil
        }
    }

    /// Frames of the attributed thread from `callStackTree.jsonRepresentation()`, formatted WITHOUT indentation: `#<i>
    /// pc <hex offsetIntoBinaryTextSegment> <binary> build-id=<binaryUUID hex>` (callers indent by two spaces; step 2,
    /// Android `NativeCrashTrace.kt:41,64-66`).
    ///
    /// - Input over `maxInputBytes` or not one RFC 8259 JSON object → `nil`.
    /// - Only the first `maxThreads` entries of `callStacks` are inspected; the first one whose
    ///   `threadAttributed` is the JSON literal `true` is used. None → `nil`: another thread is never
    ///   substituted (Android `NativeCrashTraceTest` rule).
    /// - Frame 0 is `callStackRootFrames[0]`, each next frame is `subFrames[0]`, at most `maxFrames`. An
    ///   attributed thread without an object root frame yields `[]` (callers print "unavailable").
    /// - `pc`: `offsetIntoBinaryTextSegment` as lowercase hex (a negative integer is shown as its 64-bit
    ///   two's complement, like Android's unsigned `rel_pc`); missing or non-integer → `pc unavailable`.
    /// - Binary: last path component of `binaryName`, `CrashText.safe(_, limit: 256)`; empty → `unavailable`.
    /// - `build-id`: `binaryUUID` without dashes when it is 1…128 hex digits (lowercased), else omitted.
    /// - `address` and `virtualMemoryRegionInfo` are never read.
    ///
    /// The parser is iterative (a flat node table), so a deep stack-overflow trace cannot exhaust the
    /// thread stack while it is decoded.
    public static func frames(fromCallStackTreeJSON data: Data) -> [String]? {
        guard data.count <= maxInputBytes, let table = try? CallStackJSON([UInt8](data)) else { return nil }
        let root = 0
        guard table.kind(root) == .object, let stacks = table.member(root, "callStacks"),
            table.kind(stacks) == .array
        else { return nil }
        var attributed: Int?
        var inspected = 0
        var stack = table.firstChild(stacks)
        while let current = stack, inspected < maxThreads {
            inspected += 1
            if table.kind(current) == .object, let flag = table.member(current, "threadAttributed"),
                table.kind(flag) == .trueValue
            {
                attributed = current
                break
            }
            stack = table.nextSibling(current)
        }
        guard let thread = attributed else { return nil }
        var lines: [String] = []
        var frame = table.member(thread, "callStackRootFrames").flatMap { table.firstElement($0) }
        while let current = frame, lines.count < maxFrames, table.kind(current) == .object {
            lines.append(frameLine(table, current, index: lines.count))
            frame = table.member(current, "subFrames").flatMap { table.firstElement($0) }
        }
        return lines
    }

    private static func frameLine(_ table: CallStackJSON, _ frame: Int, index: Int) -> String {
        let pc = table.member(frame, "offsetIntoBinaryTextSegment").flatMap { table.unsignedHex($0) } ?? "unavailable"
        var binary = table.member(frame, "binaryName").flatMap { table.string($0) } ?? ""
        if let slash = binary.lastIndex(of: "/") {
            binary = String(binary[binary.index(after: slash)...])
        }
        binary = CrashText.safe(binary, limit: 256)
        var line = "#\(index) pc \(pc) \(binary.isEmpty ? "unavailable" : binary)"
        if let uuid = table.member(frame, "binaryUUID").flatMap({ table.string($0) }), let build = buildID(uuid) {
            line += " build-id=\(build)"
        }
        return line
    }

    /// `binaryUUID` without dashes, lowercased, when it is 1…128 hex digits.
    private static func buildID(_ uuid: String) -> String? {
        let hex = String.UnicodeScalarView(uuid.unicodeScalars.filter { $0 != "-" })
        guard (1...128).contains(hex.count), hex.allSatisfy({ $0.properties.isASCIIHexDigit }) else { return nil }
        return String(hex).lowercased()
    }

    /// Persisted summary text (step 2). Unknown numbers print without a name; missing values print `unavailable`.
    /// Crash: crashing-thread frames or `Crashing thread stack: unavailable`. Hang: duration line.
    public static func text(_ exit: Exit) -> String {
        func named(_ value: Int?, _ name: (Int) -> String?) -> String {
            guard let value else { return "unavailable" }
            return name(value).map { "\($0)(\(value))" } ?? String(value)
        }
        func plain(_ value: String?, _ limit: Int) -> String {
            guard let value, !value.isEmpty else { return "unavailable" }
            return CrashText.safe(value, limit: limit)
        }
        var lines: [String] = []
        lines.append("Exit recorded at: \(exit.recordedAt)")
        let code = exit.exceptionCode.map { String($0) } ?? "unavailable"
        lines.append(
            "Exit reason: \(exit.kind.rawValue) · Exception: \(named(exit.exceptionType, machExceptionName)) code \(code) · Signal: \(named(exit.signal, signalName))"
        )
        lines.append(
            "Crashed app build (MetricKit): \(plain(exit.applicationBuildVersion, 80)) · iOS \(plain(exit.osVersion, 128))"
        )
        lines.append("Termination: \(plain(exit.terminationReason, 512))")
        if let name = exit.objectiveCExceptionName {
            let className = exit.objectiveCExceptionClassName.map { CrashText.symbol($0, limit: 256) } ?? "unavailable"
            lines.append("Objective-C exception: \(CrashText.symbol(name, limit: 256)) (\(className))")
        }
        switch exit.kind {
        case .crash:
            if let json = exit.callStackTreeJSON, let frames = frames(fromCallStackTreeJSON: json), !frames.isEmpty {
                lines.append("Crashing thread: attributed")
                lines.append(contentsOf: frames.map { "  " + $0 })
            } else {
                lines.append("Crashing thread stack: unavailable")
            }
        case .hang:
            let duration = exit.hangDurationMs.map { String($0) } ?? "unavailable"
            lines.append("Hang duration: \(duration) ms. Hang trace is not copied by this action.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Bounded call-stack JSON reader

extension MetricKitCrashSummary {
    /// RFC 8259 reader into a flat node table. Parsing and reading never recurse, so the nesting depth of a
    /// MetricKit tree (two levels per frame) cannot exhaust the thread stack; tokens stay byte ranges and
    /// only the few frame fields that are read get decoded.
    fileprivate struct CallStackJSON {
        enum Kind: UInt8 {
            case object, array, string, number, trueValue, falseValue, null
        }

        private struct Node {
            var kind: Kind
            /// Token bytes: a string including its quotes, or a number literal (unused for containers).
            var start: Int32
            var end: Int32
            /// Key token (quotes included) when the parent is an object, else -1.
            var keyStart: Int32 = -1
            var keyEnd: Int32 = -1
            var firstChild: Int32 = -1
            var lastChild: Int32 = -1
            var nextSibling: Int32 = -1
        }

        private enum Expect {
            case value, valueOrClose, key, keyOrClose, colon, commaOrClose
        }

        struct Malformed: Error {}

        private let bytes: [UInt8]
        private var nodes: [Node] = []

        /// Parses exactly one JSON value (surrounding whitespace allowed). Node 0 is the top-level value.
        init(_ bytes: [UInt8]) throws {
            guard bytes.count < Int(Int32.max) else { throw Malformed() }
            self.bytes = bytes
            try parse()
        }

        func kind(_ node: Int) -> Kind {
            nodes[node].kind
        }

        func firstChild(_ node: Int) -> Int? {
            let child = nodes[node].firstChild
            return child < 0 ? nil : Int(child)
        }

        func nextSibling(_ node: Int) -> Int? {
            let sibling = nodes[node].nextSibling
            return sibling < 0 ? nil : Int(sibling)
        }

        /// First element of an array node.
        func firstElement(_ node: Int) -> Int? {
            kind(node) == .array ? firstChild(node) : nil
        }

        /// Member `name` of an object node; a repeated key resolves to its last occurrence.
        func member(_ object: Int, _ name: String) -> Int? {
            guard kind(object) == .object else { return nil }
            let wanted = Array(name.utf8)
            var found: Int?
            var child = firstChild(object)
            while let current = child {
                let node = nodes[current]
                if node.keyStart >= 0, keyEquals(Int(node.keyStart), Int(node.keyEnd), wanted) {
                    found = current
                }
                child = nextSibling(current)
            }
            return found
        }

        /// Decoded value of a string node (invalid UTF-8 and lone surrogates become U+FFFD).
        func string(_ node: Int) -> String? {
            guard kind(node) == .string else { return nil }
            return decodeString(Int(nodes[node].start), Int(nodes[node].end))
        }

        /// Lowercase hex of an integer number node: non-negative literals as `UInt64`, negative ones as the
        /// 64-bit two's complement. Fractions, exponents and out-of-range literals → `nil`.
        func unsignedHex(_ node: Int) -> String? {
            guard kind(node) == .number else { return nil }
            let literal = bytes[Int(nodes[node].start)..<Int(nodes[node].end)]
            guard !literal.contains(where: { $0 == 0x2E || $0 == 0x65 || $0 == 0x45 }) else { return nil }
            let text = String(decoding: literal, as: UTF8.self)
            if text.hasPrefix("-") {
                guard let value = Int64(text) else { return nil }
                return String(UInt64(bitPattern: value), radix: 16)
            }
            guard let value = UInt64(text) else { return nil }
            return String(value, radix: 16)
        }

        // MARK: Parsing

        private mutating func parse() throws {
            let count = bytes.count
            var index = 0
            var open: [Int] = []
            var expect = Expect.value
            var key: (start: Int, end: Int)?
            var done = false
            while true {
                index = skipWhitespace(index)
                if done {
                    guard index == count else { throw Malformed() }
                    return
                }
                guard index < count else { throw Malformed() }
                let byte = bytes[index]
                switch expect {
                case .value, .valueOrClose:
                    if expect == .valueOrClose, byte == 0x5D {
                        index += 1
                        open.removeLast()
                        if open.isEmpty { done = true } else { expect = .commaOrClose }
                        continue
                    }
                    let start = index
                    let kind: Kind
                    switch byte {
                    case 0x7B:
                        kind = .object
                        index += 1
                    case 0x5B:
                        kind = .array
                        index += 1
                    case 0x22:
                        kind = .string
                        index = try scanString(index)
                    case 0x74:
                        kind = .trueValue
                        index = try literal(Array("true".utf8), index)
                    case 0x66:
                        kind = .falseValue
                        index = try literal(Array("false".utf8), index)
                    case 0x6E:
                        kind = .null
                        index = try literal(Array("null".utf8), index)
                    case 0x2D, 0x30...0x39:
                        kind = .number
                        index = try scanNumber(index)
                    default:
                        throw Malformed()
                    }
                    let node = append(kind, start, index, key: key, parent: open.last)
                    key = nil
                    switch kind {
                    case .object:
                        open.append(node)
                        expect = .keyOrClose
                    case .array:
                        open.append(node)
                        expect = .valueOrClose
                    default:
                        if open.isEmpty { done = true } else { expect = .commaOrClose }
                    }
                case .key, .keyOrClose:
                    if expect == .keyOrClose, byte == 0x7D {
                        index += 1
                        open.removeLast()
                        if open.isEmpty { done = true } else { expect = .commaOrClose }
                        continue
                    }
                    guard byte == 0x22 else { throw Malformed() }
                    let end = try scanString(index)
                    key = (start: index, end: end)
                    index = end
                    expect = .colon
                case .colon:
                    guard byte == 0x3A else { throw Malformed() }
                    index += 1
                    expect = .value
                case .commaOrClose:
                    guard let top = open.last else { throw Malformed() }
                    let isObject = nodes[top].kind == .object
                    if byte == 0x2C {
                        index += 1
                        expect = isObject ? .key : .value
                        continue
                    }
                    guard byte == (isObject ? 0x7D : 0x5D) else { throw Malformed() }
                    index += 1
                    open.removeLast()
                    if open.isEmpty { done = true } else { expect = .commaOrClose }
                }
            }
        }

        private mutating func append(
            _ kind: Kind, _ start: Int, _ end: Int, key: (start: Int, end: Int)?, parent: Int?
        ) -> Int {
            let index = nodes.count
            var node = Node(kind: kind, start: Int32(start), end: Int32(end))
            if let key {
                node.keyStart = Int32(key.start)
                node.keyEnd = Int32(key.end)
            }
            nodes.append(node)
            if let parent {
                let last = nodes[parent].lastChild
                if last < 0 {
                    nodes[parent].firstChild = Int32(index)
                } else {
                    nodes[Int(last)].nextSibling = Int32(index)
                }
                nodes[parent].lastChild = Int32(index)
            }
            return index
        }

        private func skipWhitespace(_ start: Int) -> Int {
            var index = start
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return index
                }
            }
            return index
        }

        private func literal(_ word: [UInt8], _ start: Int) throws -> Int {
            guard start + word.count <= bytes.count, bytes[start..<(start + word.count)].elementsEqual(word) else {
                throw Malformed()
            }
            return start + word.count
        }

        /// Index after the closing quote; rejects raw control characters and invalid escapes.
        private func scanString(_ start: Int) throws -> Int {
            var index = start + 1
            while index < bytes.count {
                switch bytes[index] {
                case 0x22:
                    return index + 1
                case 0x5C:
                    guard index + 1 < bytes.count else { throw Malformed() }
                    switch bytes[index + 1] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 2
                    case 0x75:
                        guard index + 5 < bytes.count, bytes[(index + 2)...(index + 5)].allSatisfy(Self.isHex) else {
                            throw Malformed()
                        }
                        index += 6
                    default:
                        throw Malformed()
                    }
                case 0x00...0x1F:
                    throw Malformed()
                default:
                    index += 1
                }
            }
            throw Malformed()
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
        private func scanNumber(_ start: Int) throws -> Int {
            var index = start
            if bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count else { throw Malformed() }
            if bytes[index] == 0x30 {
                index += 1
            } else if (0x31...0x39).contains(bytes[index]) {
                index = digits(index)
            } else {
                throw Malformed()
            }
            if index < bytes.count, bytes[index] == 0x2E {
                let after = digits(index + 1)
                guard after > index + 1 else { throw Malformed() }
                index = after
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                var next = index + 1
                if next < bytes.count, bytes[next] == 0x2B || bytes[next] == 0x2D { next += 1 }
                let after = digits(next)
                guard after > next else { throw Malformed() }
                index = after
            }
            return index
        }

        private func digits(_ start: Int) -> Int {
            var index = start
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }

        private static func hexValue(_ byte: UInt8) -> UInt32 {
            switch byte {
            case 0x30...0x39: return UInt32(byte - 0x30)
            case 0x41...0x46: return UInt32(byte - 0x41) + 10
            default: return UInt32(byte - 0x61) + 10
            }
        }

        // MARK: Decoding

        private func keyEquals(_ start: Int, _ end: Int, _ wanted: [UInt8]) -> Bool {
            let raw = bytes[(start + 1)..<(end - 1)]
            if !raw.contains(0x5C) { return raw.elementsEqual(wanted) }
            return Array(decodeString(start, end).utf8) == wanted
        }

        /// Decodes the string token `bytes[start..<end]` (quotes included; already validated by `scanString`).
        private func decodeString(_ start: Int, _ end: Int) -> String {
            var utf8: [UInt8] = []
            var index = start + 1
            let stop = end - 1
            while index < stop {
                let byte = bytes[index]
                guard byte == 0x5C else {
                    utf8.append(byte)
                    index += 1
                    continue
                }
                let escape = bytes[index + 1]
                index += 2
                switch escape {
                case 0x62: utf8.append(0x08)
                case 0x66: utf8.append(0x0C)
                case 0x6E: utf8.append(0x0A)
                case 0x72: utf8.append(0x0D)
                case 0x74: utf8.append(0x09)
                case 0x75:
                    var unit = codeUnit(at: index)
                    index += 4
                    // A high surrogate combines with a directly following `\uDC00`…`\uDFFF`.
                    if (0xD800...0xDBFF).contains(unit), index + 6 <= stop, bytes[index] == 0x5C,
                        bytes[index + 1] == 0x75
                    {
                        let low = codeUnit(at: index + 2)
                        if (0xDC00...0xDFFF).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            index += 6
                        }
                    }
                    let scalar = Unicode.Scalar(unit) ?? "\u{FFFD}"
                    utf8.append(contentsOf: String(scalar).utf8)
                default:
                    // `"`, `\` and `/` stand for themselves.
                    utf8.append(escape)
                }
            }
            return String(decoding: utf8, as: UTF8.self)
        }

        private func codeUnit(at index: Int) -> UInt32 {
            bytes[index..<(index + 4)].reduce(0) { $0 << 4 | Self.hexValue($1) }
        }
    }
}
