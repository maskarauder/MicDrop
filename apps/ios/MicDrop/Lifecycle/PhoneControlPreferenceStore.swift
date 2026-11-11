import Foundation
import MicDropCore

/// The phone-local opt-in "Allow Windows to change phone settings" (D046; Android `AppPhoneControlSettings`,
/// `A/AppPhoneControl.kt:12-19`) in `Application Support/MicDrop/phone-control.json` (`{"allowWindows": Bool}`),
/// with the protection and backup exclusion of `audio-settings.json`.
///
/// Off by default; only a JSON `true` enables it, and a missing, unreadable or mistyped file means off. The phone
/// settings adapter reads it on every snapshot and again before applying a Windows command, so a change applies to
/// a running session at its next heartbeat. It never grants pairing, microphone consent or permissions, and it
/// cannot start a session or capture. Contains no device identity, address or credential.
final class PhoneControlPreferenceStore: @unchecked Sendable {
    static let shared = PhoneControlPreferenceStore()

    /// File name inside `AudioPreferencesStore.storageDirectory()`.
    static let fileName = "phone-control.json"
    /// The single persisted key (Android's `phone-control` preferences key).
    static let key = "allowWindows"

    private let directory: URL?
    private let lock = NSLock()
    private var cached: Bool?

    /// - Parameter directory: test override; nil = `AudioPreferencesStore.storageDirectory()`.
    init(directory: URL? = nil) { self.directory = directory }

    /// The saved opt-in; the first call reads the file. Any thread.
    func allowWindows() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let data = (try? fileURL()).flatMap { try? Data(contentsOf: $0) }
        let value = PhoneControlPreferenceStore.decode(data)
        cached = value
        return value
    }

    /// Saves at once (not through the Connection settings sheet). Turning control on takes effect only after a
    /// successful write, so a failed save leaves it off. Turning it off never fails open: it is off in memory before
    /// the write, and when the write fails the file is removed instead (a missing file means off); the error is still
    /// thrown so the toggle shows the failure.
    func setAllowWindows(_ allow: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if !allow { cached = false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode([PhoneControlPreferenceStore.key: allow])
            try AudioPreferencesStore.writeProtected(data, to: fileURL())
        } catch {
            if !allow, let url = try? fileURL() { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        cached = allow
    }

    /// Strict decode: true only for a top-level object whose `allowWindows` is the JSON boolean `true`.
    static func decode(_ data: Data?) -> Bool {
        guard let data, let fields = try? JSONDecoder().decode([String: AudioPreferences.StoredValue].self, from: data)
        else { return false }
        return fields[key] == .bool(true)
    }

    private func fileURL() throws -> URL {
        let base = try directory ?? AudioPreferencesStore.storageDirectory()
        return base.appendingPathComponent(PhoneControlPreferenceStore.fileName, isDirectory: false)
    }
}
