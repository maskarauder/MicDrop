import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// The Connection settings sheet's Save (`ConnectionPolicySave`) against Windows edits that land while the sheet is
/// open (phone settings exchange v1). Temporary stores only; no audio session or native media.
final class ConnectionPolicySaveTests: XCTestCase {
    private typealias Fixture = PhoneControlFixture
    private typealias Key = PhoneControlAdapter.Key

    /// Open the sheet, let Windows change other fields, edit one connection and one Advanced audio field locally and
    /// Save: both sets of changes are kept, and the Windows keep-alive edit still waits for the next connection.
    @MainActor
    func testSaveKeepsWindowsEditsMadeWhileTheSheetWasOpen() throws {
        let fixture = try Fixture(self)
        let opened = fixture.connection.load()
        let openedAudio = fixture.advanced.load()
        XCTAssertTrue(fixture.advanced.liveKeepMicrophoneActive())

        let adapter = fixture.adapter()
        adapter.receiveOnMain(
            Fixture.command(
                1, base: adapter.current().revision,
                [
                    (Key.recoveryOrder, .string("LAN_FIRST")), (Key.timeout(.lanStatus), .int(3_000)),
                    (Key.keepMicrophoneActive, .bool(false)),
                ]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.savedText)

        let shown = try ConnectionPreferences(initialOrder: .rendezvousFirst, timeouts: [.setup: 60_000])
        let shownAudio = try AdvancedAudioPreferences(bluetoothRecoveryMs: 7_500)
        try ConnectionPolicySave.commit(
            connection: shown, audio: shownAudio, opened: opened, openedAudio: openedAudio, restored: false,
            store: fixture.connection, audioStore: fixture.advanced)

        for connection in [fixture.connection.load(), ConnectionPreferencesStore(directory: fixture.directory).load()] {
            XCTAssertEqual(connection.initialOrder, .rendezvousFirst, "the local edit")
            XCTAssertEqual(connection[.setup], 60_000, "the local edit")
            XCTAssertEqual(connection.recoveryOrder, .lanFirst, "the Windows edit")
            XCTAssertEqual(connection[.lanStatus], 3_000, "the Windows edit")
        }
        let saved = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false, bluetoothRecoveryMs: 7_500)
        XCTAssertEqual(fixture.advanced.load(), saved)
        XCTAssertEqual(AdvancedAudioPreferencesStore(directory: fixture.directory).load(), saved)
        XCTAssertTrue(
            fixture.advanced.liveKeepMicrophoneActive(),
            "saving other values does not make the Windows keep-alive edit live in the running session")
    }

    /// A keep-alive the user changes in the sheet applies to the running session at once, as before.
    func testALocalKeepAliveChangeStillAppliesAtOnce() throws {
        let stores = try Self.stores(self)
        let opened = stores.connection.load()
        let openedAudio = stores.advanced.load()
        try ConnectionPolicySave.commit(
            connection: opened, audio: try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false),
            opened: opened, openedAudio: openedAudio, restored: false, store: stores.connection,
            audioStore: stores.advanced)
        XCTAssertFalse(stores.advanced.load().keepMicrophoneActiveWhileMuted)
        XCTAssertFalse(stores.advanced.liveKeepMicrophoneActive())
        XCTAssertEqual(stores.connection.load(), ConnectionPreferences())
    }

    /// After **Restore defaults** every shown value is written, also over a Windows edit, and the default keep-alive
    /// applies at once.
    func testRestoreDefaultsWritesEveryShownValue() throws {
        let stores = try Self.stores(self)
        try stores.advanced.save(try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false))
        let opened = stores.connection.load()
        let openedAudio = stores.advanced.load()
        try stores.connection.save(try ConnectionPreferences(recoveryOrder: .lanFirst, timeouts: [:], maxRestarts: 7))
        try stores.advanced.saveForNextConnection(try AdvancedAudioPreferences(bluetoothRecoveryMs: 90_000))
        XCTAssertFalse(stores.advanced.liveKeepMicrophoneActive())

        try ConnectionPolicySave.commit(
            connection: ConnectionPreferences(), audio: AdvancedAudioPreferences(), opened: opened,
            openedAudio: openedAudio, restored: true, store: stores.connection, audioStore: stores.advanced)
        XCTAssertEqual(stores.connection.load(), ConnectionPreferences())
        XCTAssertEqual(stores.advanced.load(), AdvancedAudioPreferences())
        XCTAssertTrue(stores.advanced.liveKeepMicrophoneActive())
    }

    /// A failed Advanced audio write changes neither file; the next Save merges again.
    func testAFailedSaveWritesNothing() throws {
        let directory = try Self.stores(self).directory.appendingPathComponent("missing", isDirectory: true)
        let connection = ConnectionPreferencesStore(directory: directory)
        let advanced = AdvancedAudioPreferencesStore(directory: directory)
        let shown = try ConnectionPreferences(initialOrder: .rendezvousFirst, timeouts: [:])
        XCTAssertThrowsError(
            try ConnectionPolicySave.commit(
                connection: shown, audio: try AdvancedAudioPreferences(bluetoothRecoveryMs: 7_500),
                opened: ConnectionPreferences(), openedAudio: AdvancedAudioPreferences(), restored: false,
                store: connection, audioStore: advanced))
        XCTAssertEqual(connection.load(), ConnectionPreferences())
        XCTAssertEqual(advanced.load(), AdvancedAudioPreferences())
    }

    private struct Stores {
        let directory: URL
        let connection: ConnectionPreferencesStore
        let advanced: AdvancedAudioPreferencesStore
    }

    private static func stores(_ test: XCTestCase) throws -> Stores {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropPolicySave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Stores(
            directory: directory, connection: ConnectionPreferencesStore(directory: directory),
            advanced: AdvancedAudioPreferencesStore(directory: directory))
    }
}
