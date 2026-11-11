import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// **Advanced > Allow Windows to change phone settings** (phone settings exchange v1, D046): the toggle's
/// model over `PhoneControlPreferenceStore`, and its effect on the running session's settings snapshot.
final class PhoneControlOptInTests: XCTestCase {
    private typealias Fixture = PhoneControlFixture

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropOptInToggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Off by default; each change is saved at once (no sheet Save) and read by a new process.
    @MainActor
    func testTheToggleIsOffByDefaultAndSavesEachChangeAtOnce() throws {
        let directory = try temporaryDirectory()
        let store = PhoneControlPreferenceStore(directory: directory)
        let optIn = PhoneControlOptIn(store: store)
        XCTAssertFalse(optIn.allowed)
        XCTAssertFalse(optIn.saveFailed)
        optIn.set(true)
        XCTAssertTrue(optIn.allowed)
        XCTAssertTrue(store.allowWindows(), "the settings adapter reads the same store")
        XCTAssertTrue(PhoneControlPreferenceStore(directory: directory).allowWindows(), "saved to the file")
        XCTAssertTrue(PhoneControlOptIn(store: PhoneControlPreferenceStore(directory: directory)).allowed)
        optIn.set(false)
        XCTAssertFalse(optIn.allowed)
        XCTAssertFalse(PhoneControlPreferenceStore(directory: directory).allowWindows())
    }

    /// A failed opt-in keeps control off for the toggle and for Windows and shows the failure text; a second failure
    /// in a row still re-renders the toggle (`saveAttempt`) and keeps it off, and the next successful change clears
    /// the text.
    @MainActor
    func testAFailedSaveKeepsControlOffAndTheToggleInStep() throws {
        let directory = try temporaryDirectory().appendingPathComponent("missing", isDirectory: true)
        let store = PhoneControlPreferenceStore(directory: directory)
        let optIn = PhoneControlOptIn(store: store)
        XCTAssertEqual(optIn.saveAttempt, 0)
        optIn.set(true)
        XCTAssertFalse(optIn.allowed)
        XCTAssertTrue(optIn.saveFailed)
        XCTAssertFalse(store.allowWindows())
        XCTAssertEqual(optIn.saveAttempt, 1)
        optIn.set(true)
        XCTAssertFalse(optIn.allowed, "a second failure in a row")
        XCTAssertTrue(optIn.saveFailed)
        XCTAssertEqual(optIn.saveAttempt, 2, "a new toggle identity although nothing else changed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        optIn.set(true)
        XCTAssertTrue(optIn.allowed)
        XCTAssertFalse(optIn.saveFailed)
    }

    /// Turning the option off takes effect even when the write fails: the toggle and the session's settings
    /// adapter read off at once, so Windows sees `enabled: false` on the next heartbeat.
    @MainActor
    func testAFailedOptOutStillTurnsWindowsControlOff() throws {
        let directory = try temporaryDirectory().appendingPathComponent("removed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PhoneControlPreferenceStore(directory: directory)
        let optIn = PhoneControlOptIn(store: store)
        optIn.set(true)
        XCTAssertTrue(optIn.allowed)
        try FileManager.default.removeItem(at: directory)
        optIn.set(false)
        XCTAssertFalse(optIn.allowed)
        XCTAssertTrue(optIn.saveFailed, "the failure is still shown")
        XCTAssertFalse(store.allowWindows(), "what the adapter reads for the next snapshot")
    }

    /// Turning the option off during a session reaches Windows on the next heartbeat: the snapshot's `enabled`
    /// and revision change, so it is sent at once despite the 5 s de-duplication and clears a pending Windows edit;
    /// a command against the old revision is then refused without being applied. Turning it on again re-enables
    /// Windows editing with the next snapshot.
    @MainActor
    func testTurningItOffDuringASessionSendsADisabledSnapshotAtOnce() throws {
        let fixture = try Fixture(self)
        let optIn = PhoneControlOptIn(store: fixture.optIn)
        XCTAssertTrue(optIn.allowed, "the fixture opted in")
        let adapter = fixture.adapter()
        let enabled = try XCTUnwrap(adapter.snapshotOnMain())
        XCTAssertEqual(enabled["enabled"], .bool(true))
        XCTAssertNil(adapter.snapshotOnMain(), "unchanged within 5 s")
        let editorRevision = adapter.current().revision

        optIn.set(false)
        let disabled = try XCTUnwrap(adapter.snapshotOnMain(), "sent on the next heartbeat")
        XCTAssertEqual(disabled["enabled"], .bool(false))
        XCTAssertNotEqual(disabled["revision"], enabled["revision"])
        XCTAssertNil(adapter.current().hostValidationError())
        adapter.receiveOnMain(
            Fixture.command(1, base: editorRevision, [(PhoneControlAdapter.Key.fastRecovery, .bool(false))]))
        XCTAssertEqual(adapter.acknowledgment?.status, .rejected)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.disabledText)
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertTrue(fixture.audio.load().fastRecovery)

        optIn.set(true)
        let reenabled = try XCTUnwrap(adapter.snapshotOnMain())
        XCTAssertEqual(reenabled["enabled"], .bool(true))
        XCTAssertEqual(reenabled["revision"], enabled["revision"])
    }
}
