import Foundation

/// DNS-SD record rules for `_micdrop._tcp` (`DiscoveryRecord.kt:14-35`; producer `internal/discovery/advertise.go`).
public enum DiscoveryRecord {
    /// Service type browsed (`advertise.go:13`).
    public static let type = "_micdrop._tcp"
    /// Browse domain used by the iOS browser.
    public static let domain = "local."
    /// Services tracked/resolved at once (`DiscoveryRecord.kt:16`).
    public static let maxServices = 8
    /// Distinct endpoints displayed (`DiscoveryRecord.kt:17`).
    public static let maxHosts = 16
    /// Addresses considered per resolved service (`DiscoveryRecord.kt:29`).
    public static let maxAddressesConsidered = 8
    /// Hosts kept per service (`DiscoveryRecord.kt:34`, `DiscoveryRecord.kt:50`).
    public static let maxAddressesPerService = 4
    /// Maximum TXT value length in bytes (`DiscoveryRecord.kt:23`).
    public static let maxTXTValueBytes = 64
    /// Maximum service-key length in UTF-16 code units (`DiscoveryRecord.kt:44`).
    public static let maxServiceKeyLength = 256
    /// The exact TXT key set (`advertise.go:30`).
    public static let txtKeys: Set<String> = ["v", "p", "id"]
    /// Search timeout (`LanDiscovery.kt:45`).
    public static let searchTimeoutMs: Int64 = 30_000
    public static let searchTimeout: Duration = .milliseconds(30_000)

    /// `type.trimEnd('.')` equals `_micdrop._tcp` or `_micdrop._tcp.local`, ignoring ASCII letter case
    /// (`DiscoveryRecord.kt:18-19`).
    ///
    /// Compared byte-wise with only `A-Z` folded. Kotlin's `equals(…, ignoreCase = true)` also folds U+0130 and
    /// U+0131 onto `i`; DNS-SD service types are ASCII (RFC 6763 §7) and `NWBrowser` reports only the browsed
    /// type, so the stricter rule rejects nothing a conforming advertiser can send.
    public static func acceptsType(_ type: String) -> Bool {
        var bytes = Array(type.utf8)
        while bytes.last == 0x2E { bytes.removeLast() }  // trimEnd('.')
        let folded = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        return folded.elementsEqual(Self.type.utf8) || folded.elementsEqual((Self.type + ".local").utf8)
    }

    /// Key that identifies one browse result in `DiscoveryIndex` on iOS: `"<name>/<type>/<lowercased domain>"`.
    /// NWBrowser reports one result per service with its interfaces, so the key has no interface part (Android keys
    /// `serviceName/networkHandle`, `LanDiscovery.kt:79-80`).
    public static func serviceKey(name: String, type: String, domain: String) -> String {
        "\(name)/\(type)/\(domain.lowercased())"
    }

    /// Validates an untrusted resolved record (`DiscoveryRecord.kt:21-35`).
    ///
    /// `attributes` maps every TXT key to its value; `nil` is a DNS-SD key-only entry (no `=`).
    /// Returns `[]` unless the key set is exactly `v`, `p`, `id` (case-sensitive), every value is present and
    /// at most 64 bytes, `v` is the byte `1`, `p` the byte `3` and `id` matches `^[0-9a-f]{64}$`. Values are
    /// compared as bytes: Android decodes US-ASCII (any byte >= 0x80 becomes U+FFFD), so a non-ASCII byte can
    /// never satisfy those rules there either. Then the first 8 addresses are de-duplicated in order, each kept
    /// only if `LANEndpoint(host:port:)` accepts it, and at most 4 are returned.
    public static func parse(addresses: [String], port: Int, attributes: [String: Data?]) -> [DiscoveredHost] {
        guard Set(attributes.keys) == txtKeys else { return [] }
        var values: [String: [UInt8]] = [:]
        for (key, value) in attributes {
            guard let value, value.count <= maxTXTValueBytes else { return [] }
            values[key] = Array(value)
        }
        guard values["v"] == [0x31], values["p"] == [0x33], let id = values["id"], isLowercaseHex64(id) else {
            return []
        }
        let key = String(decoding: id, as: UTF8.self)

        var seen = Set<String>()
        var hosts: [DiscoveredHost] = []
        for address in addresses.prefix(maxAddressesConsidered) where seen.insert(address).inserted {
            guard (try? LANEndpoint(host: address, port: port)) != nil else { continue }
            hosts.append(DiscoveredHost(host: address, port: port, keyHint: key))
            if hosts.count == maxAddressesPerService { break }
        }
        return hosts
    }

    /// `^[0-9a-f]{64}$` over bytes (never `Character.isHexDigit`, which accepts uppercase and full-width digits).
    private static func isLowercaseHex64(_ bytes: [UInt8]) -> Bool {
        bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
