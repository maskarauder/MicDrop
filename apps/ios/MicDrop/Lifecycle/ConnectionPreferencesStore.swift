import Foundation
import MicDropCore

/// Connection policy for the next session. Contains no host addresses, credentials or device IDs.
final class ConnectionPreferencesStore: @unchecked Sendable {
    static let shared = ConnectionPreferencesStore()
    private let directory: URL?
    private let lock = NSLock()
    private var cached: ConnectionPreferences?

    init(directory: URL? = nil) { self.directory = directory }

    func load() -> ConnectionPreferences {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let data = (try? fileURL()).flatMap { try? Data(contentsOf: $0) }
        let value = ConnectionPreferences.decodeJSON(data)
        cached = value
        return value
    }

    func save(_ preferences: ConnectionPreferences) throws {
        lock.lock()
        defer { lock.unlock() }
        try AudioPreferencesStore.writeProtected(preferences.encodedJSON(), to: fileURL())
        cached = preferences
    }

    private func fileURL() throws -> URL {
        let base = try directory ?? AudioPreferencesStore.storageDirectory()
        return base.appendingPathComponent(ConnectionPreferences.fileName, isDirectory: false)
    }
}
