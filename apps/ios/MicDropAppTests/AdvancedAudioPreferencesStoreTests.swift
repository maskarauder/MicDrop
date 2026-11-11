import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// `advanced-audio-settings.json` persistence (protected Application Support storage in production).
final class AdvancedAudioPreferencesStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testSavedSettingsSurviveRelaunchAndInvalidValuesUseDefaults() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(AdvancedAudioPreferencesStore(directory: directory).load(), AdvancedAudioPreferences())
        let store = AdvancedAudioPreferencesStore(directory: directory)
        let custom = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 45_500)
        try store.save(custom)
        XCTAssertEqual(store.load(), custom)
        XCTAssertEqual(AdvancedAudioPreferencesStore(directory: directory).load(), custom, "a new process reads it")

        let url = directory.appendingPathComponent(AdvancedAudioPreferences.fileName)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("uid"), "no device identity is stored")
        try Data("{\"keepMicrophoneActiveWhileMuted\":1,\"bluetoothRecoveryMs\":999999}".utf8).write(to: url)
        XCTAssertEqual(AdvancedAudioPreferencesStore(directory: directory).load(), AdvancedAudioPreferences())
    }

    func testAFailedSaveKeepsThePreviousPolicy() throws {
        let directory = try temporaryDirectory()
        let store = AdvancedAudioPreferencesStore(directory: directory.appendingPathComponent("missing"))
        let custom = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 5_000)
        XCTAssertThrowsError(try store.save(custom))
        XCTAssertEqual(store.load(), AdvancedAudioPreferences(), "a running session keeps reading the old value")
        XCTAssertTrue(store.liveKeepMicrophoneActive())
        XCTAssertThrowsError(try store.saveForNextConnection(custom))
        XCTAssertEqual(store.load(), AdvancedAudioPreferences())
    }

    /// The next-connection latch of phone settings exchange v1: a Windows edit reaches the file and `load()` but not
    /// the live keep-alive of the running session; a local Save applies at once; the next microphone Connect
    /// (`reloadLive`) and a new process use the saved value.
    func testWindowsEditsOfTheKeepAliveWaitForTheNextConnection() throws {
        let directory = try temporaryDirectory()
        let store = AdvancedAudioPreferencesStore(directory: directory)
        let off = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 30_000)
        try store.save(off)
        XCTAssertFalse(store.liveKeepMicrophoneActive(), "a local Save applies to the running session")

        let on = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: true, bluetoothRecoveryMs: 30_000)
        try store.saveForNextConnection(on)
        XCTAssertEqual(store.load(), on, "the sheet and the next Connect read the Windows value")
        XCTAssertEqual(AdvancedAudioPreferencesStore(directory: directory).load(), on, "written to the file")
        XCTAssertFalse(store.liveKeepMicrophoneActive(), "the running session keeps its keep-alive")
        store.reloadLive()
        XCTAssertTrue(store.liveKeepMicrophoneActive(), "the next microphone Connect applies it")

        try store.save(off)
        XCTAssertFalse(store.liveKeepMicrophoneActive(), "a later local Save still applies at once")
        XCTAssertFalse(
            AdvancedAudioPreferencesStore(directory: directory).liveKeepMicrophoneActive(),
            "a new process starts from the saved value")

        let fresh = AdvancedAudioPreferencesStore(directory: directory)
        try fresh.saveForNextConnection(on)
        XCTAssertFalse(fresh.liveKeepMicrophoneActive(), "the live value is fixed before the first Windows write")
    }

    func testTheSessionReadsTheBluetoothWindowAtConnectWithinBounds() throws {
        let link = try ConnectionLink(
            version: .paired, endpoint: LANEndpoint(host: "192.168.1.2", port: 8443), token: "",
            pin: Array(repeating: 1, count: 32), expiresAt: 0, clientKey: String(repeating: "a", count: 64),
            remote: nil)
        func configuration(_ window: Int64?) -> SessionConfiguration {
            let processing = MicrophoneProcessing()
            let plan = AudioSessionPlan.make(mode: .duplex, input: .builtIn, processing: processing)
            guard let window else {
                return SessionConfiguration(
                    link: link, linkText: "test-only", mode: .duplex, reconnect: false, fastRecovery: true,
                    baseline: nil, initiallyOutputEnabled: true, outputSelection: OutputSelection(),
                    protectedDefaultSpeaker: false, microphoneSelection: .builtIn, initiallyMicrophoneMuted: true,
                    processing: processing, plan: plan)
            }
            return SessionConfiguration(
                link: link, linkText: "test-only", mode: .duplex, reconnect: false, fastRecovery: true,
                baseline: nil, initiallyOutputEnabled: true, outputSelection: OutputSelection(),
                protectedDefaultSpeaker: false, microphoneSelection: .builtIn, initiallyMicrophoneMuted: true,
                processing: processing, plan: plan, bluetoothRecoveryMs: window)
        }
        XCTAssertEqual(configuration(nil).bluetoothRecoveryMs, 20_000)
        XCTAssertEqual(configuration(45_000).bluetoothRecoveryMs, 45_000)
        XCTAssertEqual(configuration(1).bluetoothRecoveryMs, 5_000, "an unvalidated value is clamped")
        XCTAssertEqual(configuration(.max).bluetoothRecoveryMs, 120_000)
    }
}
