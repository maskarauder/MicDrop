// Remembered audio preferences: `Application Support/MicDrop/audio-settings.json` (Android `AppAudioSettings.kt`,
// `AudioPreferences.kt`).
//
// The model and its strict JSON coding are the `AudioPreferences` (MicDropCore). This store keeps one in-memory copy,
// serializes `update` (Android `AppAudioSettings.update` is synchronized) and rewrites **all eight keys** on every
// update, so a delayed callback updating one key cannot overwrite another control's change. Stop never resets
// preferences.
//
// iOS addition: the identities of explicit external output and input choices are remembered in `audio-devices.json`
// (`RememberedAudioDevices`) in the same directory, with the same protection and backup exclusion. `rememberOutput` /
// `rememberInput` write the identity first and the kind second under one lock, and a relaunch restores an identity only
// for the kind still saved. An interrupted or failed write therefore restores at most the previously saved choice (for
// example iPhone media output or the built-in microphone, when that was the saved kind), or asks for reselection; it
// never restores an identity the user replaced. The uid never leaves these files and process memory (no log,
// diagnostics or report).
//
// this type satisfies `AudioSettingsStore` requirements (`load() -> AudioPreferences`, `@discardableResult update(_:)
// -> AudioPreferences`, plus the iOS device-memory calls `restoredOutputSelection()`, `restoredMicrophoneSelection()`,
// `rememberOutput(_:)` and `rememberInput(_:)`); the protocol itself is declared by its owner, which adds the
// conformance.

import Foundation
import MicDropCore

final class AudioPreferencesStore: @unchecked Sendable {
    /// The process-wide store over `Application Support/MicDrop/audio-settings.json`.
    static let shared = AudioPreferencesStore()

    /// `AudioPreferences.fileName` (`"audio-settings.json"`).
    static var fileName: String { AudioPreferences.fileName }

    private let directoryOverride: URL?
    private let lock = NSLock()
    private var cached: AudioPreferences?
    private var cachedDevices: RememberedAudioDevices?
    private var generation: UInt64 = 0

    /// - Parameter directory: test override; nil = `AudioPreferencesStore.storageDirectory()`.
    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    /// Current preferences. First call reads the file: missing/unparsable → all defaults
    /// (`AudioPreferences.decodeJSON`, strict Bool and kind rules).
    func load() -> AudioPreferences {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// Loads the current values, applies `change`, writes all eight keys
    /// (`[.atomic, .completeFileProtectionUntilFirstUserAuthentication]`) and returns the result.
    /// A write failure keeps the new value in memory (Android `apply()` is fire-and-forget).
    @discardableResult
    func update(_ change: (AudioPreferences) -> AudioPreferences) -> AudioPreferences {
        lock.lock()
        defer { lock.unlock() }
        return updateLocked(change)
    }

    // MARK: - Remembered devices (`audio-devices.json`)

    /// The remembered device identities. First call reads the file: missing, unparsable or invalid → none
    /// (`RememberedAudioDevices.decodeJSON`).
    func rememberedDevices() -> RememberedAudioDevices {
        lock.lock()
        defer { lock.unlock() }
        return devicesLocked()
    }

    /// The output selection of a new process: the remembered pin while `preferredOutputKind` still names its
    /// kind, else `OutputSelection.restored(preferredOutputKind)` (`RememberedAudioDevices.restoredOutput`). It
    /// is a candidate only: availability, Connect and the session's route verification still require the
    /// current route to resolve exactly that identity.
    func restoredOutputSelection() -> OutputSelection {
        lock.lock()
        defer { lock.unlock() }
        return devicesLocked().restoredOutput(preferredKind: loadLocked().preferredOutputKind)
    }

    /// The input selection of a new process: the remembered input while `preferredInputKind` still names its
    /// kind, else the built-in microphone (`RememberedAudioDevices.restoredInput`). Grants no capture and no
    /// microphone consent.
    func restoredMicrophoneSelection() -> MicrophoneSelection {
        lock.lock()
        defer { lock.unlock() }
        return devicesLocked().restoredInput(preferredKind: loadLocked().preferredInputKind)
    }

    /// Records an output choice (or a session's verified output): its identity in `audio-devices.json`
    /// (cleared for iPhone media output, the iPhone speaker and the temporary speaker), then
    /// `preferredOutputKind = selection.preferenceKind`. Returns the preferences.
    @discardableResult
    func rememberOutput(_ selection: OutputSelection) -> AudioPreferences {
        lock.lock()
        defer { lock.unlock() }
        return rememberOutputLocked(selection)
    }

    /// Records an input choice: its identity in `audio-devices.json` (cleared for the built-in microphone),
    /// then `preferredInputKind = selection.kind`. Changes neither `microphoneEnabled` nor any session.
    @discardableResult
    func rememberInput(_ selection: MicrophoneSelection) -> AudioPreferences {
        lock.lock()
        defer { lock.unlock() }
        return rememberInputLocked(selection)
    }

    // MARK: - Windows edits (phone settings exchange v1)

    /// Counts the selections Windows saved for the next connection in this process (`saveInputForNextConnection`,
    /// `saveOutputForNextConnection`). Local choices and a session's verified routes never change it, so the idle
    /// rows re-read the saved selections only after a Windows edit (`MainActivity.kt:1273-1277`) and keep idle-only
    /// state such as the temporary speaker otherwise. Process memory only; any thread.
    var selectionGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// `audio.input` from Windows: `rememberInput` plus a new `selectionGeneration`. The running session keeps its
    /// input; the next Connect verifies the saved one.
    func saveInputForNextConnection(_ selection: MicrophoneSelection) {
        lock.lock()
        defer { lock.unlock() }
        _ = rememberInputLocked(selection)
        generation &+= 1
    }

    /// `audio.output` from Windows during a session without an output (microphone-only): `rememberOutput` plus a new
    /// `selectionGeneration`. Later automatic route updates of another session do not overwrite this choice (the
    /// controllers persist a verified route only while the saved output is that session's endpoint,
    /// `PlaybackService.kt:246-251`). A playback or duplex session applies a Windows choice through its controller's
    /// `setOutputSelection` instead, which saves it with `rememberOutput`.
    func saveOutputForNextConnection(_ selection: OutputSelection) {
        lock.lock()
        defer { lock.unlock() }
        _ = rememberOutputLocked(selection)
        generation &+= 1
    }

    /// Drops the in-memory copies (tests; the next read re-reads the files).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        cachedDevices = nil
    }

    /// Identity first, kind second (see the type comment).
    private func rememberOutputLocked(_ selection: OutputSelection) -> AudioPreferences {
        writeDevicesLocked(devicesLocked().remembering(output: selection))
        return updateLocked { previous in
            var next = previous
            next.preferredOutputKind = selection.preferenceKind
            return next
        }
    }

    private func rememberInputLocked(_ selection: MicrophoneSelection) -> AudioPreferences {
        writeDevicesLocked(devicesLocked().remembering(input: selection))
        return updateLocked { previous in
            var next = previous
            next.preferredInputKind = selection.kind
            return next
        }
    }

    private func updateLocked(_ change: (AudioPreferences) -> AudioPreferences) -> AudioPreferences {
        let next = change(loadLocked())
        cached = next
        if let url = try? fileURL(), let data = try? next.encodedJSON() {
            try? AudioPreferencesStore.writeProtected(data, to: url)
        }
        return next
    }

    private func devicesLocked() -> RememberedAudioDevices {
        if let cachedDevices { return cachedDevices }
        let data = (try? devicesURL()).flatMap { try? Data(contentsOf: $0) }
        let value = RememberedAudioDevices.decodeJSON(data)
        cachedDevices = value
        return value
    }

    /// Keeps `devices` in memory and rewrites the file. If the write fails, the old file is removed instead,
    /// so a later process cannot restore an identity the user replaced; that process then asks for
    /// reselection.
    private func writeDevicesLocked(_ devices: RememberedAudioDevices) {
        cachedDevices = devices
        guard let url = try? devicesURL() else { return }
        do {
            try AudioPreferencesStore.writeProtected(devices.encodedJSON(), to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func devicesURL() throws -> URL {
        let directory = try directoryOverride ?? AudioPreferencesStore.storageDirectory()
        return directory.appendingPathComponent(RememberedAudioDevices.fileName, isDirectory: false)
    }

    private func loadLocked() -> AudioPreferences {
        if let cached { return cached }
        let data = (try? fileURL()).flatMap { try? Data(contentsOf: $0) }
        let value = AudioPreferences.decodeJSON(data)
        cached = value
        return value
    }

    private func fileURL() throws -> URL {
        let directory = try directoryOverride ?? AudioPreferencesStore.storageDirectory()
        return directory.appendingPathComponent(AudioPreferences.fileName, isDirectory: false)
    }

    // MARK: - Shared storage helpers (also used by PausedPlaybackStore)

    /// `Library/Application Support/MicDrop/`, created on demand with file protection
    /// `completeUntilFirstUserAuthentication` (readable while locked for lock-screen Play and background interruption
    /// resume) and `isExcludedFromBackup = true` (Android `allowBackup=false`).
    static func storageDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        var directory = base.appendingPathComponent("MicDrop", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    /// Atomic write with `.completeFileProtectionUntilFirstUserAuthentication`.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
