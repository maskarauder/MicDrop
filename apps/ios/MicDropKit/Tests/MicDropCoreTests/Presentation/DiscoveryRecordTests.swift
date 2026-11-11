import XCTest

@testable import MicDropCore

/// Port of `DiscoveryRecordTest.kt` record tests, the Windows producer contract (`internal/discovery/advertise.go`,
/// `advertise_test.go`) seen from the phone, and the parse bounds.
final class DiscoveryRecordTests: XCTestCase {
    private let pin = PresentationFixtures.pin
    private let client = PresentationFixtures.client
    private let host = DiscoveredHost(host: "192.168.1.20", port: 9844, keyHint: PresentationFixtures.pin)

    private func txt() -> [String: Data?] {
        ["v": Data("1".utf8), "p": Data("3".utf8), "id": Data(pin.utf8)]
    }

    /// `txt() + (key to value)`; a nil value is a DNS-SD key-only entry, not a removal.
    private func txt(_ key: String, _ value: Data?) -> [String: Data?] {
        var attributes = txt()
        attributes.updateValue(value, forKey: key)
        return attributes
    }

    private func parse(_ addresses: [String], port: Int = 9844, _ attributes: [String: Data?]? = nil)
        -> [DiscoveredHost]
    {
        DiscoveryRecord.parse(addresses: addresses, port: port, attributes: attributes ?? txt())
    }

    // MARK: DiscoveryRecordTest.kt

    func testAcceptsOnlyTheSupportedServiceAndWireSchema() {
        for type in ["_micdrop._tcp", "_micdrop._tcp.", "_micdrop._tcp.local.", "_MICDROP._TCP."] {
            XCTAssertTrue(DiscoveryRecord.acceptsType(type), type)
        }
        for type in ["", "_micdrop._udp", "_micdrop._tcp.example.com", "_http._tcp"] {
            XCTAssertFalse(DiscoveryRecord.acceptsType(type), type)
        }
        XCTAssertEqual(parse([host.host, host.host]), [host])
        var withoutID = txt()
        withoutID.removeValue(forKey: "id")
        let invalid: [[String: Data?]] = [
            withoutID,
            txt("secret", Data("private".utf8)),
            txt("v", Data("2".utf8)),
            txt("p", Data("2".utf8)),
            txt("id", nil),
            txt("p", nil),
            txt("id", Data(pin.uppercased().utf8)),
            txt("id", Data((pin + "a").utf8)),
            txt("id", Data(repeating: 0xFF, count: 64)),
        ]
        for (index, attributes) in invalid.enumerated() {
            XCTAssertEqual(parse([host.host], attributes), [], "invalid TXT #\(index)")
        }
    }

    func testRejectsHostnamesPublicAddressesIPv6AndInvalidPorts() {
        let invalid = [
            "localhost", "host.local", "8.8.8.8", "127.0.0.1", "0.0.0.0",
            "169.254.1.2", "224.0.0.251", "fc00::1", "::1", "192.168.001.20", "192.168.1.999",
        ]
        for address in invalid {
            XCTAssertEqual(parse([address]), [], address)
        }
        for port in [-1, 0, 65536] {
            XCTAssertEqual(parse([host.host], port: port), [], "port \(port)")
        }
        XCTAssertEqual(parse(["fc00::1", host.host]), [host])
        XCTAssertEqual(parse((1...8).map { "10.0.0.\($0)" }).count, 4)
    }

    func testAddressHintRetainsSavedTrustAndCannotEnrollOrDowngrade() throws {
        let saved = try PresentationFixtures.savedLink()
        let moved = try host.connection(for: saved)
        XCTAssertEqual(moved.endpoint.host.description, host.host)
        XCTAssertEqual(Int(moved.endpoint.port), host.port)
        XCTAssertEqual(moved.pin, saved.pin)
        XCTAssertEqual(moved.clientKey, saved.clientKey)
        XCTAssertEqual(moved.version, .paired)
        XCTAssertEqual(moved.token, "")
        XCTAssertNil(moved.remote, "discovery produces a LAN record")
        // Candidate creation does not mutate the saved connection.
        XCTAssertEqual(saved.endpoint.host.description, "10.0.0.20")
        XCTAssertEqual(saved.endpoint.port, 9845)

        let v2 = try ConnectionLink(
            version: .v2, endpoint: LANEndpoint(host: host.host, port: host.port),
            token: String(repeating: "a", count: 43), pin: HexPin.decode(pin), expiresAt: 2000,
            clientKey: "", remote: nil)
        XCTAssertFalse(host.matches(nil))
        XCTAssertFalse(host.matches(v2), "a v2 link with the same fingerprint is not a pairing")
        let otherKey = try ConnectionLink.paired(
            host: host.host, port: host.port, hostKey: PresentationFixtures.otherPin, clientKey: client)
        for untrusted in [v2, otherKey] {
            XCTAssertThrowsError(try host.connection(for: untrusted), "Discovery replaced saved trust") { error in
                XCTAssertEqual(error as? DiscoveredHost.ConnectionError, .notSavedHost)
            }
        }
    }

    // MARK: Windows producer contract (`advertise.go`, `advertise_test.go`)

    /// `RecordFor(192.168.1.20, 9844, "ab"×32)` → instance `MicDrop-abababababab`, TXT `v=1 p=3 id=<key>`.
    func testWindowsAdvertisementIsAcceptedAsOneCandidate() {
        let record = ["v=1", "p=3", "id=" + pin]
        var attributes: [String: Data?] = [:]
        for entry in record {
            let parts = entry.split(separator: "=", maxSplits: 1)
            attributes.updateValue(Data(parts[1].utf8), forKey: String(parts[0]))
        }
        XCTAssertEqual(DiscoveryRecord.type, "_micdrop._tcp")
        XCTAssertTrue(DiscoveryRecord.acceptsType("_micdrop._tcp."))
        XCTAssertEqual(parse(["192.168.1.20"], attributes), [host])
        let instance = "MicDrop-" + String(pin.prefix(12))
        XCTAssertEqual(
            DiscoveryRecord.serviceKey(name: instance, type: "_micdrop._tcp.", domain: "local."),
            "MicDrop-abababababab/_micdrop._tcp./local.")
    }

    /// Every address, port and key `TestRecordRejectsInvalidEndpointAndIdentity` refuses to publish is also
    /// refused when a rogue advertiser sends it.
    func testEndpointsAndKeysWindowsRefusesAreRefused() {
        let key = String(repeating: "a", count: 64)
        let keyed = txt("id", Data(key.utf8))
        XCTAssertEqual(parse(["10.0.0.20"], keyed), [DiscoveredHost(host: "10.0.0.20", port: 9844, keyHint: key)])
        for address in ["", "0.0.0.0", "127.0.0.1", "8.8.8.8", "169.254.1.2", "224.0.0.251", "fc00::1", "::1"] {
            XCTAssertEqual(parse([address], keyed), [], address)
        }
        for port in [-1, 0, 65536] {
            XCTAssertEqual(parse(["10.0.0.20"], port: port, keyed), [], "port \(port)")
        }
        let badKeys = [
            "", String(key.prefix(63)), key + "a", String(repeating: "A", count: 64),
            String(repeating: "z", count: 64), key + "\n",
        ]
        for bad in badKeys {
            XCTAssertEqual(parse(["10.0.0.20"], txt("id", Data(bad.utf8))), [], bad.debugDescription)
        }
    }

    // MARK: Bounds and edge cases

    func testPrivateRangesAndPortBoundsAreAccepted() {
        for address in [
            "10.0.0.0", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.0.0", "192.168.255.255",
        ] {
            XCTAssertEqual(parse([address]).map(\.host), [address], address)
        }
        for port in [1, 65535] {
            XCTAssertEqual(parse([host.host], port: port).map(\.port), [port])
        }
        for address in [
            "172.15.255.255", "172.32.0.1", "192.169.0.1", "11.0.0.1", "100.64.0.1", " 192.168.1.20",
            "192.168.1.20 ", "192.168.1.20%en0", "192.168.1", "192.168.1.20.1", "\u{FF11}92.168.1.20",
            "192.168.1.020", "192.168.1.+2",
        ] {
            XCTAssertEqual(parse([address]), [], address.debugDescription)
        }
    }

    func testTXTValuesAreComparedAsBoundedBytes() {
        XCTAssertEqual(parse([host.host], txt("V", Data("1".utf8))), [], "keys are case-sensitive")
        let invalidValues: [(String, Data)] = [
            ("v", Data()),
            ("v", Data("1 ".utf8)),
            ("v", Data("01".utf8)),
            ("v", Data([0x31, 0x00])),
            ("p", Data("\u{00E9}".utf8)),
            ("p", Data([0x33, 0x80])),
            ("v", Data(repeating: 0x31, count: 65)),
            ("id", Data((pin + "0").utf8)),
            ("id", Data(String(pin.prefix(63)).utf8)),
            ("id", Data((String(pin.prefix(63)) + "\u{00E9}").utf8)),
        ]
        for (key, value) in invalidValues {
            var attributes = txt()
            attributes.updateValue(value, forKey: key)
            XCTAssertEqual(parse([host.host], attributes), [], "\(key)=\(Array(value))")
        }
        // A key-only entry for an extra key, and an extra key with a valid-looking value.
        XCTAssertEqual(parse([host.host], txt("x", nil)), [])
        XCTAssertEqual(parse([host.host], [:]), [])
        // The maximum value length is accepted (the 64-byte `id`).
        XCTAssertEqual(DiscoveryRecord.maxTXTValueBytes, pin.utf8.count)
        XCTAssertEqual(parse([host.host]), [host])
    }

    func testOnlyTheFirstEightAddressesAreConsideredAndFourKept() {
        let invalidEight = Array(repeating: "8.8.8.8", count: 8)
        XCTAssertEqual(parse(invalidEight + [host.host]), [], "the ninth address is never considered")
        XCTAssertEqual(parse(Array(repeating: host.host, count: 8) + ["10.0.0.1"]), [host])
        XCTAssertEqual(
            parse(["10.0.0.2", "10.0.0.1", "10.0.0.2", "8.8.8.8", "10.0.0.3"]).map(\.host),
            ["10.0.0.2", "10.0.0.1", "10.0.0.3"], "order kept, duplicates removed")
        XCTAssertEqual(
            parse((1...6).map { "10.0.1.\($0)" }).map(\.host), ["10.0.1.1", "10.0.1.2", "10.0.1.3", "10.0.1.4"])
        XCTAssertEqual(parse([]), [])
        XCTAssertTrue(parse([host.host]).allSatisfy { $0.keyHint == pin && $0.port == 9844 })
    }

    func testServiceTypeComparisonTrimsDotsAndFoldsOnlyASCII() {
        for type in ["_micdrop._tcp...", "_MicDrop._Tcp.Local", "_micdrop._tcp.local", "_micdrop._tcp.LOCAL.."] {
            XCTAssertTrue(DiscoveryRecord.acceptsType(type), type)
        }
        for type in [
            ".", "._micdrop._tcp", " _micdrop._tcp", "_micdrop._tcp ", "_micdrop._tcp.local.x", "_micdrop._tcp.lan",
            "_micdrop", "_micdrop._tcp.local.local",
            // U+0131 / U+0130 lookalikes: Kotlin's ignoreCase folds them, DNS-SD types are ASCII (documented).
            "_m\u{0131}cdrop._tcp", "_M\u{0130}CDROP._TCP",
            // Fullwidth letters never fold to ASCII.
            "_\u{FF4D}icdrop._tcp",
        ] {
            XCTAssertFalse(DiscoveryRecord.acceptsType(type), type.debugDescription)
        }
    }

    func testServiceKeyLowercasesOnlyTheDomain() {
        XCTAssertEqual(
            DiscoveryRecord.serviceKey(name: "MicDrop-ABC Desk", type: "_micdrop._tcp.", domain: "Local."),
            "MicDrop-ABC Desk/_micdrop._tcp./local.")
        XCTAssertNotEqual(
            DiscoveryRecord.serviceKey(name: "MicDrop-a", type: "_micdrop._tcp.", domain: "local."),
            DiscoveryRecord.serviceKey(name: "MicDrop-A", type: "_micdrop._tcp.", domain: "local."))
    }

    func testLimitsAndTimeoutMatchAndroid() {
        XCTAssertEqual(DiscoveryRecord.domain, "local.")
        XCTAssertEqual(DiscoveryRecord.maxServices, 8)
        XCTAssertEqual(DiscoveryRecord.maxHosts, 16)
        XCTAssertEqual(DiscoveryRecord.maxAddressesConsidered, 8)
        XCTAssertEqual(DiscoveryRecord.maxAddressesPerService, 4)
        XCTAssertEqual(DiscoveryRecord.maxTXTValueBytes, 64)
        XCTAssertEqual(DiscoveryRecord.maxServiceKeyLength, 256)
        XCTAssertEqual(DiscoveryRecord.txtKeys, ["v", "p", "id"])
        XCTAssertEqual(DiscoveryRecord.searchTimeoutMs, 30_000)
        XCTAssertEqual(DiscoveryRecord.searchTimeout, .seconds(30))
    }
}
