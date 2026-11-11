import MicDropCore
import NIOCore

/// The strict, bounded, incremental HTTP/1.x response parser shared by LAN and remote (port of
/// `RemoteHttp.readResponse`, `RemoteHttp.kt:66-106`).
///
/// Error classes: framing errors (steps 1-3, 5-7) are `ControlIOError(.protocolViolation(text))` with the fixed
/// internal texts of `Violation` (retryable `NETWORK_IO`); a status ≠ 200 throws `HTTPFailure(status:)` immediately
/// after the header block is valid (body never read); a transport EOF before the response is complete throws
/// `SignalingStreamEnded`. JSON decoding of the body is the caller's job (`ControlTransport.send` returns raw bytes).
public enum StrictHTTPResponse {
    /// Total header-section bytes incl. every CR LF (`MAX_HEADER`, `RemoteHttp.kt:72`).
    public static let maxHeaderBytes = 8192
    /// Default body cap (`MAX_BODY = 96 * 1024`); `/pair` uses 1024 and a negotiated phone-control `/status` 163 840
    /// (`ControlRequest.bodyBudget`, `RemoteHttp.kt:88,126,132`). Both transports pass the request's
    /// `maxResponseBytes`.
    public static let maxBody = 98_304

    /// Fixed internal violation texts (never shown to the user; `RemoteHttp.kt:66-106`).
    public enum Violation: String, Sendable, Equatable, CaseIterable {
        /// header bytes > 8192, or a clean EOF inside the header section.
        case headers = "Invalid HTTP response headers"
        /// a line ending in a bare LF.
        case line = "Invalid HTTP line"
        /// status line not `HTTP/1\.[01] ([0-9]{3})(?: .*)?`.
        case status = "Invalid HTTP status"
        /// header name not `^[A-Za-z0-9-]+$` (or no colon).
        case header = "Invalid HTTP header"
        /// a repeated (case-insensitive) header name.
        case duplicateHeader = "Duplicate HTTP header"
        /// any `Transfer-Encoding` header on a 200.
        case transferEncoding = "Unsupported HTTP transfer encoding"
        /// `Content-Length` not an integer in `0...maxBody` (Kotlin `toIntOrNull`).
        case bodySize = "Invalid HTTP body size"
        /// clean EOF before `Content-Length` bytes arrived.
        case truncated = "Truncated HTTP response"
        /// close-delimited body larger than `maxBody`.
        case bodyTooLarge = "HTTP body too large"

        /// `ControlIOError(.protocolViolation(rawValue))`.
        public var error: ControlIOError {
            ControlIOError(.protocolViolation(rawValue))
        }
    }

    /// A completed 200 response (status ≠ 200 never produces an outcome; it throws `HTTPFailure`).
    public enum Outcome: Sendable, Equatable {
        case complete(body: [UInt8])
    }

    /// Incremental parser; feed decrypted inner bytes as they arrive (one buffer or byte by byte
    /// gives identical results).
    public struct Parser: Sendable {
        /// The body cap for this request (`ControlRequest.maxResponseBytes`).
        public let maxBody: Int
        /// The parsed status code once the status line was accepted.
        public private(set) var status: Int?
        /// Lowercased header name → trimmed value, once parsed.
        public private(set) var headers: [String: String] = [:]
        /// `true` after `.complete` was returned (later input is ignored, never read past
        /// `Content-Length`, commit `8c13639`).
        public private(set) var isComplete = false

        private var phase: Phase = .statusLine
        private var headerBytes = 0
        private var line: [UInt8] = []
        private var body: [UInt8] = []
        private var contentLength: Int?

        private enum Phase: Sendable {
            case statusLine
            case headerLines
            case body
            case done
        }

        public init(maxBody: Int = StrictHTTPResponse.maxBody) {
            self.maxBody = maxBody
        }

        /// Consumes all readable bytes of `buffer` (up to the end of a known-length body).
        /// - Returns: `.complete` once the full 200 body is known, else `nil` (need more).
        /// - Throws: `HTTPFailure(status:)` for status ≠ 200 (as soon as the header block ends);
        ///   `Violation.*.error` for framing errors.
        public mutating func feed(_ buffer: inout ByteBuffer) throws -> Outcome? {
            if isComplete { return .complete(body: body) }
            while buffer.readableBytes > 0 {
                if phase == .body {
                    let count = min(buffer.readableBytes, contentLength.map { $0 - body.count } ?? buffer.readableBytes)
                    guard count <= maxBody - body.count else { throw Violation.bodyTooLarge.error }
                    body.append(contentsOf: buffer.readBytes(length: count) ?? [])
                    if contentLength == body.count {
                        phase = .done
                        isComplete = true
                        return .complete(body: body)
                    }
                } else {
                    guard let byte: UInt8 = buffer.readInteger() else { break }
                    headerBytes += 1
                    guard headerBytes <= StrictHTTPResponse.maxHeaderBytes else { throw Violation.headers.error }
                    if byte != 10 {
                        line.append(byte)
                        continue
                    }
                    guard line.last == 13 else { throw Violation.line.error }
                    line.removeLast()
                    try acceptLine()
                    line.removeAll(keepingCapacity: true)
                    if phase == .body, contentLength == 0 {
                        phase = .done
                        isComplete = true
                        return .complete(body: [])
                    }
                }
            }
            return nil
        }

        /// `feed` over plain bytes (tests, byte-by-byte vectors).
        public mutating func feed(_ bytes: [UInt8]) throws -> Outcome? {
            var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            return try feed(&buffer)
        }

        /// `true` once a 200 header block was accepted and the body is still being read.
        public var readingBody: Bool {
            phase == .body
        }

        /// `true` iff a clean TLS close (close_notify) would complete the response now, i.e. a 200
        /// with no `Content-Length` whose body is being read to EOF.
        public var canCompleteOnCleanEOF: Bool {
            phase == .body && contentLength == nil && status == 200
        }

        /// End of input (step 7).
        /// - Parameter cleanEOF: `true` when the inner TLS saw `close_notify` (Engine "inbound done"),
        ///   `false` for a transport EOF (`NIOSSLError.uncleanShutdown`, tunnel closed).
        /// - Returns: `.complete` for a close-delimited 200 body ended by a clean EOF.
        /// - Throws: clean EOF in headers → `.headers`; clean EOF inside a length body → `.truncated`;
        ///   transport EOF before completion → `SignalingStreamEnded()`.
        public mutating func finish(cleanEOF: Bool) throws -> Outcome {
            if isComplete { return .complete(body: body) }
            guard cleanEOF else { throw SignalingStreamEnded() }
            guard phase == .body else { throw Violation.headers.error }
            guard contentLength == nil else { throw Violation.truncated.error }
            phase = .done
            isComplete = true
            return .complete(body: body)
        }

        private mutating func acceptLine() throws {
            if phase == .statusLine {
                guard line.count >= 12,
                    Array(line.prefix(7)) == Array("HTTP/1.".utf8), [48, 49].contains(line[7]), line[8] == 32,
                    line[9...11].allSatisfy({ (48...57).contains($0) }),
                    line.count == 12 || (line[12] == 32 && !line[13...].contains(13))
                else { throw Violation.status.error }
                status = Int(line[9] - 48) * 100 + Int(line[10] - 48) * 10 + Int(line[11] - 48)
                phase = .headerLines
            } else if line.isEmpty {
                guard status == 200 else { throw HTTPFailure(status: status ?? 0) }
                guard headers["transfer-encoding"] == nil else { throw Violation.transferEncoding.error }
                if let value = headers["content-length"] {
                    let bytes = Array(value.utf8)
                    let digits = (bytes.first == 43 || bytes.first == 45) ? bytes.dropFirst() : bytes[...]
                    guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                        let length = Int32(value), length >= 0, Int(length) <= maxBody
                    else { throw Violation.bodySize.error }
                    contentLength = Int(length)
                }
                phase = .body
            } else {
                guard let colon = line.firstIndex(of: 58), colon > 0,
                    line[..<colon].allSatisfy({
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    })
                else { throw Violation.header.error }
                let key = String(decoding: line[..<colon], as: UTF8.self).lowercased()
                guard headers[key] == nil else { throw Violation.duplicateHeader.error }
                var value = line[(colon + 1)...]
                while let first = value.first, first <= 32 { value = value.dropFirst() }
                while let last = value.last, last <= 32 { value = value.dropLast() }
                headers[key] = String(String.UnicodeScalarView(value.map { UnicodeScalar($0) }))
            }
        }
    }
}
