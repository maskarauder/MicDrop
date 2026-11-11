// Resume ticket of a paused playback session: `Application Support/MicDrop/paused-playback.json` (Android
// `PausedPlayback.kt`).
//
// The ticket value type is the `ResumeTicket` (MicDropCore). The file holds `{"id": String, "digest": String, "fast":
// Bool}`; it contains no credential (the saved link in the Keychain is the only credential source; a digest mismatch
// cannot resume).
//
// Written at the first PLAYING of a v≥2 session and at `completePause` → PAUSED. Cleared by `beginConnection` (after
// validation), `stopSession`, a non-pausing `finish`, and by the UI on Forget / pairing / Change address / starting a
// microphone session (`MainActivity.kt`). Not cleared by termination or process death: the next launch restores PAUSED
// from it.

import Foundation
import MicDropCore

final class PausedPlaybackStore: @unchecked Sendable {
    /// The process-wide store over `Application Support/MicDrop/paused-playback.json`.
    static let shared = PausedPlaybackStore()

    /// File name inside `AudioPreferencesStore.storageDirectory()`.
    static let fileName = "paused-playback.json"

    private let directoryOverride: URL?
    private let lock = NSLock()
    /// `.some(nil)` = known absent; `nil` = not read yet.
    private var cached: ResumeTicket??

    /// - Parameter directory: test override; nil = `AudioPreferencesStore.storageDirectory()`.
    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    /// The stored ticket, nil when `id` or `digest` is missing (`PausedPlayback.ticket()`).
    func ticket() -> ResumeTicket? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let data = (try? fileURL()).flatMap { try? Data(contentsOf: $0) }
        let value = PausedPlaybackStore.decode(data)
        cached = .some(value)
        return value
    }

    /// Writes all three keys (`PausedPlayback.save`). A write failure keeps the ticket in memory
    /// for this process (parity: SharedPreferences `apply()`).
    func save(_ ticket: ResumeTicket) {
        lock.lock()
        defer { lock.unlock() }
        cached = .some(ticket)
        if let url = try? fileURL(), let data = try? PausedPlaybackStore.encode(ticket) {
            try? AudioPreferencesStore.writeProtected(data, to: url)
        }
    }

    /// Deletes the file (`PausedPlayback.clear` removes all keys). Idempotent.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cached = .some(nil)
        if let url = try? fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL() throws -> URL {
        let directory = try directoryOverride ?? AudioPreferencesStore.storageDirectory()
        return directory.appendingPathComponent(PausedPlaybackStore.fileName, isDirectory: false)
    }

    // MARK: - Strict coding (pure, testable)

    /// top level must be a JSON object; `id` and `digest` must be JSON strings, else no ticket; `fast` is honored only
    /// as a JSON boolean (numbers/strings/absent → default `true`). Extra keys are ignored. Missing/unparsable data →
    /// nil.
    static func decode(_ data: Data?) -> ResumeTicket? {
        guard let data,
            let fields = try? JSONDecoder().decode([String: AudioPreferences.StoredValue].self, from: data),
            case .string(let id)? = fields["id"],
            case .string(let digest)? = fields["digest"]
        else { return nil }
        var fast = true
        if case .bool(let value)? = fields["fast"] { fast = value }
        return ResumeTicket(id: id, digest: digest, fast: fast)
    }

    /// `{"digest":…,"fast":…,"id":…}` (sorted keys).
    static func encode(_ ticket: ResumeTicket) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ticket)
    }
}
