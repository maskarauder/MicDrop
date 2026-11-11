import Foundation

/// Bounded, ticketed index of discovered services (`DiscoveryRecord.kt:37-58`).
///
/// Tickets distinguish a removed/reappearing service from late browse/resolve callbacks: an update carrying
/// an old ticket is ignored. Not thread-safe; `LanDiscovery` uses it on the main actor only.
///
/// Service keys compare with Swift `String` equality (canonical equivalence), the same equality as the per-key
/// maps of `LanDiscovery`; Kotlin compares UTF-16 units, so two advertised names that differ only in Unicode
/// normalization are one service here and two on Android. Every other rule is Android's.
public final class DiscoveryIndex {
    public struct Ticket: Hashable, Sendable {
        public let service: String
        public let serial: Int64
        public init(service: String, serial: Int64) {
            self.service = service
            self.serial = serial
        }
    }

    private struct Entry {
        let ticket: Ticket
        var hosts: [DiscoveredHost] = []
    }

    /// Insertion order of `entries` (Kotlin `linkedMapOf`).
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    /// Never reset (not even by `clear()`), so a ticket from before a clear can never match again.
    private var serial: Int64 = 0

    public init() {}

    /// nil if `service` is blank (Kotlin `isBlank()`), longer than 256 UTF-16 units, already present, or 8
    /// services are tracked; otherwise a fresh ticket (`DiscoveryRecord.kt:44-48`).
    public func claim(_ service: String) -> Ticket? {
        if ControlsDeriver.isBlank(service) || service.utf16.count > DiscoveryRecord.maxServiceKeyLength
            || entries[service] != nil || entries.count >= DiscoveryRecord.maxServices
        {
            return nil
        }
        serial += 1
        let ticket = Ticket(service: service, serial: serial)
        entries[service] = Entry(ticket: ticket)
        order.append(service)
        return ticket
    }

    /// True only for the current ticket of its service (`DiscoveryRecord.kt:50`).
    public func contains(_ ticket: Ticket) -> Bool {
        entries[ticket.service]?.ticket == ticket
    }

    /// Replaces the hosts of a current ticket with at most 4 of `hosts`; stale tickets are ignored
    /// (`DiscoveryRecord.kt:51-53`).
    public func update(_ ticket: Ticket, hosts: [DiscoveredHost]) {
        guard contains(ticket) else { return }
        entries[ticket.service]?.hosts = Array(hosts.prefix(DiscoveryRecord.maxAddressesPerService))
    }

    /// Removes a service and returns its ticket, if any (`DiscoveryRecord.kt:54`).
    @discardableResult
    public func remove(_ service: String) -> Ticket? {
        guard let entry = entries.removeValue(forKey: service) else { return nil }
        order.removeAll { $0 == service }
        return entry.ticket
    }

    /// Drops every service; the serial keeps counting (`DiscoveryRecord.kt:55`).
    public func clear() {
        entries.removeAll()
        order.removeAll()
    }

    /// All hosts in service insertion order, de-duplicated (first occurrence kept), sorted by
    /// (`keyHint`, `host`, `port`) and cut to 16 (`DiscoveryRecord.kt:56-57`). Strings sort by UTF-16 code
    /// units like Kotlin `compareTo` (identical to byte order for the ASCII values `parse` produces).
    public func hosts() -> [DiscoveredHost] {
        var seen = Set<DiscoveredHost>()
        var all: [DiscoveredHost] = []
        for service in order {
            for host in entries[service]?.hosts ?? [] where seen.insert(host).inserted {
                all.append(host)
            }
        }
        all.sort { a, b in
            if !a.keyHint.utf16.elementsEqual(b.keyHint.utf16) {
                return a.keyHint.utf16.lexicographicallyPrecedes(b.keyHint.utf16)
            }
            if !a.host.utf16.elementsEqual(b.host.utf16) {
                return a.host.utf16.lexicographicallyPrecedes(b.host.utf16)
            }
            return a.port < b.port
        }
        return Array(all.prefix(DiscoveryRecord.maxHosts))
    }
}
