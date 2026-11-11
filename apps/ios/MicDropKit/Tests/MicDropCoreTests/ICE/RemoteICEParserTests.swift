import Foundation
import XCTest

@testable import MicDropCore

final class RemoteICEParserTests: XCTestCase {
    private func body(_ servers: [[String: Any]], expiry: Any = 1_600, version: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "expires_at": expiry, "ice_servers": servers])
    }

    private func server(_ urls: [String], user: String = "user", password: String = "password") -> [String: Any] {
        ["urls": urls, "username": user, "credential": password]
    }

    private func invalid(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RemoteICEParser.parse(data, now: 1_000, forceRelay: false), file: file, line: line) {
            XCTAssertEqual($0 as? ICEProtocolError, .invalidConfiguration, file: file, line: line)
        }
    }

    func testOrderedSTUNTURNAndIPv6Servers() throws {
        let urls = ["turn:relay.example:3478?transport=udp", "turns:[2001:db8::1]:5349?transport=tcp"]
        let data = try body([["urls": ["stun:192.0.2.1:3478"]], server(urls)])
        let parsed = try RemoteICEParser.parse(data, now: 1_000, forceRelay: true)
        XCTAssertEqual(parsed.urls, ["stun:192.0.2.1:3478"] + urls)
        XCTAssertEqual(parsed.servers[0].username, "")
        XCTAssertEqual(parsed.servers[1].credential, "password")
        XCTAssertEqual(parsed.expiresAt, 1_600)
        XCTAssertTrue(parsed.hasTURN)
        XCTAssertFalse(String(reflecting: parsed).contains("password"))
        XCTAssertFalse(String(reflecting: parsed.servers[1]).contains("relay.example"))
    }

    func testExactLifetimeBoundsAndOverflowAreRejectedSafely() throws {
        for expiry in [1_061, 1_660] {
            XCTAssertNoThrow(try RemoteICEParser.parse(body([], expiry: expiry), now: 1_000, forceRelay: false))
        }
        for expiry in [Int64.min, 0, 1_060, 1_661, Int64.max] {
            invalid(try body([], expiry: expiry))
        }
        XCTAssertThrowsError(try RemoteICEParser.parse(body([], expiry: Int64.max), now: Int64.min, forceRelay: false))
    }

    func testStrictJSONAndIntegerFields() throws {
        for text in [
            "[]", "null", "{\"version\":1,\"expires_at\":1600,\"ice_servers\":[],\"extra\":0}",
            "{\"version\":1,\"version\":1,\"expires_at\":1600,\"ice_servers\":[]}",
            "{\"version\":1.0,\"expires_at\":1600,\"ice_servers\":[]}",
            "{\"version\":1,\"expires_at\":16e2,\"ice_servers\":[]}",
            "{\"version\":true,\"expires_at\":1600,\"ice_servers\":[]}",
            "{\"version\":1,\"expires_at\":1600,\"ice_servers\":[],}",
            "{\"version\":1,\"expires_at\":1600,\"ice_servers\":[]} trailing",
        ] { invalid(Data(text.utf8)) }
        invalid(Data([0xFF, 0xFE]))
        invalid(Data(repeating: 32, count: RemoteICEParser.maxBodyBytes + 1))
        invalid(try body([], version: 2))
    }

    func testServerShapeAndCredentialTypes() throws {
        let entries: [[String: Any]] = [
            [:], ["urls": []], ["urls": "stun:relay.example:3478"], ["urls": [123]],
            ["urls": ["stun:relay.example:3478"], "unknown": true],
            ["urls": ["stun:relay.example:3478"], "username": NSNull()],
            ["urls": ["stun:relay.example:3478"], "credential": 12],
        ]
        for entry in entries { invalid(try body([entry])) }
        for credential in ["a\u{0}b", "a\rb", "a\nb", String(repeating: "x", count: 513)] {
            invalid(try body([server(["turn:relay.example:3478?transport=udp"], user: credential)]))
            invalid(try body([server(["turn:relay.example:3478?transport=udp"], password: credential)]))
        }
        invalid(try body([server(["turn:relay.example:3478?transport=udp"], user: "")]))
        invalid(try body([server(["stun:relay.example:3478"])]))
        let maximum = String(repeating: "é", count: 256)
        XCTAssertNoThrow(
            try RemoteICEParser.parse(
                body([server(["turn:relay.example:3478?transport=udp"], user: maximum)]), now: 1_000, forceRelay: true))
        invalid(try body([server(["turn:relay.example:3478?transport=udp"], user: maximum + "a")]))
    }

    func testURLGrammarRejectsInjectionAmbiguityAndUnsupportedSchemes() throws {
        let invalidURLs = [
            "TURN:relay.example:3478?transport=udp", "https:relay.example:3478?transport=udp",
            "turn:relay.example:3478", "turn:relay.example:3478?transport=UDP",
            "turn:relay.example:3478?transport=udp&x=1", "turn:relay.example:3478??transport=udp",
            "turns:relay.example:5349?transport=udp", "turn:relay.example:0?transport=udp",
            "turn:relay.example:65536?transport=udp", "turn:relay.example:?transport=udp",
            "turn:relay.example:+3478?transport=udp", "turn:relay.example:3478/path?transport=udp",
            "turn:user@relay.example:3478?transport=udp", "turn:relay.example:3478#x?transport=udp",
            "turn:relay%2Eexample:3478?transport=udp", "turn:relay.example:3478?transport=udp\r\nx: y",
            "turn:relay.example:3478?transport=udp\u{0}", "turn:relay_example:3478?transport=udp",
            "turn:-relay.example:3478?transport=udp", "turn:relay-.example:3478?transport=udp",
            "turn:relay..example:3478?transport=udp", "turn:relay.example.:3478?transport=udp",
            "turn:rélais.example:3478?transport=udp", "turn:2001:db8::1:3478?transport=udp",
            "turn:[2001:::1]:3478?transport=udp", "turn:[2001:db8::1%en0]:3478?transport=udp",
            "turn:[not-ipv6]:3478?transport=udp", "turn::3478?transport=udp",
        ]
        for url in invalidURLs { invalid(try body([server([url])])) }
        invalid(try body([["urls": ["stun:relay.example:3478?transport=udp"]]]))
        invalid(try body([server(["turn:" + String(repeating: "a", count: 64) + ":3478?transport=udp"])]))
    }

    func testServerAndURLCountBounds() throws {
        let url = "turn:relay.example:3478?transport=udp"
        let eight = try body([server(Array(repeating: url, count: 8))])
        XCTAssertEqual(try RemoteICEParser.parse(eight, now: 1_000, forceRelay: false).servers.count, 8)
        invalid(try body([server(Array(repeating: url, count: 9))]))
        invalid(try body([server(Array(repeating: url, count: 8)), server([url])]))
        invalid(try body(Array(repeating: server([url]), count: 9)))
    }

    func testForcedRelayRequiresTURNAndUsesRetryableFailure() throws {
        let configurations: [[[String: Any]]] = [[], [["urls": ["stun:relay.example:3478"]]]]
        for servers in configurations {
            let data = try body(servers)
            XCTAssertNoThrow(try RemoteICEParser.parse(data, now: 1_000, forceRelay: false))
            XCTAssertThrowsError(try RemoteICEParser.parse(data, now: 1_000, forceRelay: true)) {
                XCTAssertEqual(($0 as? ControlIOError)?.kind, .iceUnavailable(.forcedRelayRequiresTURN))
                XCTAssertTrue(ConnectionFailure.retryableStatus($0))
            }
        }
    }
}
