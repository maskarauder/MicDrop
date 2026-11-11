import Foundation
import MicDropCore

/// Advanced audio settings (`AdvancedAudioPreferences`) in `Application Support/MicDrop/advanced-audio-settings.json`,
/// with the protection and backup exclusion of `audio-settings.json`. Contains no device identity, address or
/// credential.
///
/// `bluetoothRecoveryMs` is read once at Connect. `keepMicrophoneActiveWhileMuted` has two values:
/// - the saved value (`load()`), shown by the Connection settings sheet and used by the next connection;
/// - the live value (`liveKeepMicrophoneActive()`), which a running session reads through `SessionDependencies` at
///   its next background/foreground step.
/// A local Save (`save(_:)`) sets both, so it applies at once. A Windows edit (`saveForNextConnection(_:)`, phone
/// settings exchange v1) sets only the saved value: the running session keeps its keep-alive, so Windows can never
/// start a muted background capture in the current session (D046, `PHONE_CONTROL_V1.md`: beginning capture stays
/// phone-local) and the "Saved. Next-connection settings apply after Stop and Connect." acknowledgment stays true.
/// `reloadLive()` at each explicit microphone Connect (not an input switch or a duplex resume) makes the saved value
/// live.
final class AdvancedAudioPreferencesStore: @unchecked Sendable {
    static let shared = AdvancedAudioPreferencesStore()
    private let directory: URL?
    private let lock = NSLock()
    private var cached: AdvancedAudioPreferences?
    /// The running sessions' keep-alive; nil until first read (then the saved value of this process's first read).
    private var live: Bool?

    /// - Parameter directory: test override; nil = `AudioPreferencesStore.storageDirectory()`.
    init(directory: URL? = nil) { self.directory = directory }

    /// Saved preferences, including Windows edits held for the next connection; the first call reads the file
    /// (missing or invalid values → their defaults). Any thread.
    func load() -> AdvancedAudioPreferences {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// The keep-alive a running session applies now (`SessionDependencies.keepMicrophoneActiveWhileMuted`). Any thread.
    func liveKeepMicrophoneActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let live { return live }
        let value = loadLocked().keepMicrophoneActiveWhileMuted
        live = value
        return value
    }

    /// A local Save: writes both keys (`[.atomic, .completeFileProtectionUntilFirstUserAuthentication]`) and applies
    /// the keep-alive to a running session at once. The in-memory values change only after a successful write, so a
    /// failed Save leaves the running policy unchanged.
    func save(_ preferences: AdvancedAudioPreferences) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeLocked(preferences)
        live = preferences.keepMicrophoneActiveWhileMuted
    }

    /// A Windows edit (phone settings exchange v1): writes both keys like `save(_:)` but leaves the live keep-alive
    /// unchanged; the next microphone Connect (`reloadLive()`) or a new process uses the saved value.
    func saveForNextConnection(_ preferences: AdvancedAudioPreferences) throws {
        lock.lock()
        defer { lock.unlock() }
        if live == nil { live = loadLocked().keepMicrophoneActiveWhileMuted }
        try writeLocked(preferences)
    }

    /// At a microphone Connect, before the session is configured: the saved keep-alive (also one Windows saved for
    /// the next connection) becomes live.
    func reloadLive() {
        lock.lock()
        defer { lock.unlock() }
        live = loadLocked().keepMicrophoneActiveWhileMuted
    }

    private func loadLocked() -> AdvancedAudioPreferences {
        if let cached { return cached }
        let data = (try? fileURL()).flatMap { try? Data(contentsOf: $0) }
        let value = AdvancedAudioPreferences.decodeJSON(data)
        cached = value
        return value
    }

    private func writeLocked(_ preferences: AdvancedAudioPreferences) throws {
        try AudioPreferencesStore.writeProtected(preferences.encodedJSON(), to: fileURL())
        cached = preferences
    }

    private func fileURL() throws -> URL {
        let base = try directory ?? AudioPreferencesStore.storageDirectory()
        return base.appendingPathComponent(AdvancedAudioPreferences.fileName, isDirectory: false)
    }
}
