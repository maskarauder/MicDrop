import MicDropCore
import NIOCore
import XCTest

@testable import MicDropTransport

final class StrictHTTPResponseTests: XCTestCase {
    func testEverySplitCompletesAtContentLengthAndLeavesTrailingBytesUnread() throws {
        let bytes = Array("HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc".utf8)
        for split in 0...bytes.count {
            var parser = StrictHTTPResponse.Parser()
            let first = try parser.feed(Array(bytes[..<split]))
            var remainder = ByteBufferAllocator().buffer(capacity: bytes.count)
            remainder.writeBytes(bytes[split...])
            remainder.writeString("trailing")
            let result = try parser.feed(&remainder)
            XCTAssertEqual(result ?? first, .complete(body: Array("abc".utf8)))
            XCTAssertEqual(remainder.readString(length: remainder.readableBytes), "trailing")
        }
    }

    func testCloseDelimitedRequiresAuthenticatedEOF() throws {
        let response = Array("HTTP/1.1 200 OK\r\n\r\n{}".utf8)
        var clean = StrictHTTPResponse.Parser()
        XCTAssertNil(try clean.feed(response))
        XCTAssertTrue(clean.canCompleteOnCleanEOF)
        XCTAssertEqual(try clean.finish(cleanEOF: true), .complete(body: [123, 125]))
        var ragged = StrictHTTPResponse.Parser()
        _ = try ragged.feed(response)
        XCTAssertThrowsError(try ragged.finish(cleanEOF: false)) { XCTAssertTrue($0 is SignalingStreamEnded) }
    }

    func testTruncationDistinguishesCleanAndTransportEOF() throws {
        for response in ["HTTP/1.1 200", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"] {
            var parser = StrictHTTPResponse.Parser()
            _ = try parser.feed(Array(response.utf8))
            var ragged = parser
            XCTAssertThrowsError(try ragged.finish(cleanEOF: false)) { XCTAssertTrue($0 is SignalingStreamEnded) }
            XCTAssertThrowsError(try parser.finish(cleanEOF: true)) { XCTAssertTrue($0 is ControlIOError) }
        }
    }

    func testInvalidFramingAndBoundsAreRejected() {
        let cases: [(String, StrictHTTPResponse.Violation)] = [
            ("HTTP/1.1 200 OK\n\n", .line),
            ("HTTP/2.0 200 OK\r\n\r\n", .status),
            ("HTTP/1.1 200 bad\rreason\r\n\r\n", .status),
            ("HTTP/1.1 200 OK\r\nBad_Name: x\r\n\r\n", .header),
            ("HTTP/1.1 200 OK\r\nX: 1\r\nx: 2\r\n\r\n", .duplicateHeader),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", .transferEncoding),
            ("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n", .bodySize),
            ("HTTP/1.1 200 OK\r\nContent-Length: 2147483648\r\n\r\n", .bodySize),
            ("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", .bodySize),
            ("HTTP/1.1 200 OK\r\n\r\nabcd", .bodyTooLarge),
            ("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 8192), .headers),
        ]
        for (text, violation) in cases {
            var parser = StrictHTTPResponse.Parser(maxBody: 3)
            XCTAssertThrowsError(try parser.feed(Array(text.utf8))) {
                XCTAssertEqual($0 as? ControlIOError, violation.error)
            }
        }
    }

    /// `RemoteHttpBodyLimitTest.largerDeclaredBodiesNeedTheNegotiatedBudgetAndRemainBounded`: a declaration above
    /// 96 KiB needs the negotiated `/status` budget, and that budget stays bounded.
    func testLargerDeclaredBodiesNeedTheNegotiatedBudgetAndRemainBounded() throws {
        let budget = ControlRequest.bodyLimit(path: ControlRequest.Path.status, negotiated: true)
        XCTAssertEqual(budget, 163_840)
        func header(_ length: Int) -> [UInt8] { Array("HTTP/1.0 200 OK\r\nContent-Length: \(length)\r\n\r\n".utf8) }
        for size in [98_305, budget] {
            var standard = StrictHTTPResponse.Parser()
            XCTAssertThrowsError(try standard.feed(header(size)), "\(size)") {
                XCTAssertEqual($0 as? ControlIOError, StrictHTTPResponse.Violation.bodySize.error)
            }
            // The declaration is allowed; the intentionally absent payload is then truncated.
            var negotiated = StrictHTTPResponse.Parser(maxBody: budget)
            XCTAssertNil(try negotiated.feed(header(size)), "\(size)")
            XCTAssertThrowsError(try negotiated.finish(cleanEOF: true), "\(size)") {
                XCTAssertEqual($0 as? ControlIOError, StrictHTTPResponse.Violation.truncated.error)
            }
        }
        var over = StrictHTTPResponse.Parser(maxBody: budget)
        XCTAssertThrowsError(try over.feed(header(budget + 1))) {
            XCTAssertEqual($0 as? ControlIOError, StrictHTTPResponse.Violation.bodySize.error)
        }
    }

    /// `RemoteHttpBodyLimitTest.closeDelimitedBodiesCannotBypassEitherLimit`.
    func testCloseDelimitedBodiesCannotBypassEitherLimit() {
        for budget in [98_304, 163_840] {
            var parser = StrictHTTPResponse.Parser(maxBody: budget)
            let response = Array("HTTP/1.0 200 OK\r\n\r\n".utf8) + [UInt8](repeating: 0x20, count: budget + 1)
            XCTAssertThrowsError(try parser.feed(response), "\(budget)") {
                XCTAssertEqual($0 as? ControlIOError, StrictHTTPResponse.Violation.bodyTooLarge.error)
            }
        }
    }

    func testNon200StopsAfterValidHeadersWithoutReadingBody() throws {
        var parser = StrictHTTPResponse.Parser()
        var bytes = ByteBufferAllocator().buffer(capacity: 100)
        bytes.writeString("HTTP/1.0 403 Forbidden\r\nContent-Length: nonsense\r\n\r\nprivate body")
        XCTAssertThrowsError(try parser.feed(&bytes)) { XCTAssertEqual($0 as? HTTPFailure, HTTPFailure(403)) }
        XCTAssertEqual(bytes.readString(length: bytes.readableBytes), "private body")
    }

    func testSignedLengthAndNonASCIIHeaderValuePreserveKotlinParsing() throws {
        var parser = StrictHTTPResponse.Parser()
        let response =
            Array("HTTP/1.1 200\r\nX: ".utf8) + [0xFF]
            + Array(" \r\nContent-Length: +0\r\n\r\n".utf8)
        XCTAssertEqual(try parser.feed(response), .complete(body: []))
        XCTAssertEqual(parser.headers["x"], "ÿ")
    }
}
