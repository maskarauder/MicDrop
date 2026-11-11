import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// `phone-control.json`: the phone-local "Allow Windows to change phone settings" opt-in (D046).
final class PhoneControlPreferenceStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropOptIn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOffByDefaultSavedAtOnceAndReadByTheNextProcess() throws {
        let directory = try temporaryDirectory()
        let store = PhoneControlPreferenceStore(directory: directory)
        XCTAssertFalse(store.allowWindows())
        try store.setAllowWindows(true)
        XCTAssertTrue(store.allowWindows())
        XCTAssertTrue(PhoneControlPreferenceStore(directory: directory).allowWindows(), "a new process reads it")
        let url = directory.appendingPathComponent(PhoneControlPreferenceStore.fileName)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), #"{"allowWindows":true}"#)
        try store.setAllowWindows(false)
        XCTAssertFalse(PhoneControlPreferenceStore(directory: directory).allowWindows())
    }

    /// Only a JSON `true` enables Windows control; numbers, strings, `null`, other shapes and unreadable files are
    /// off.
    func testOnlyAJSONTrueEnablesIt() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(PhoneControlPreferenceStore.fileName)
        let off = [
            #"{"allowWindows":1}"#, #"{"allowWindows":"true"}"#, #"{"allowWindows":null}"#, #"{"allowWindows":false}"#,
            #"[true]"#, #"{}"#, "not json", "",
        ]
        for text in off {
            try Data(text.utf8).write(to: url)
            XCTAssertFalse(PhoneControlPreferenceStore(directory: directory).allowWindows(), text)
        }
        try Data(#"{"allowWindows":true,"other":1}"#.utf8).write(to: url)
        XCTAssertTrue(PhoneControlPreferenceStore(directory: directory).allowWindows())
    }

    /// A failed opt-in leaves Windows control off.
    func testAFailedOptInKeepsControlOff() throws {
        let store = PhoneControlPreferenceStore(directory: try temporaryDirectory().appendingPathComponent("missing"))
        XCTAssertThrowsError(try store.setAllowWindows(true))
        XCTAssertFalse(store.allowWindows())
    }

    /// Turning control off never fails open: a failed write still turns it off for the running session at once, and
    /// the stale `true` file is gone, so the next process reads off as well.
    func testAFailedOptOutStillTurnsControlOff() throws {
        let directory = try temporaryDirectory().appendingPathComponent("removed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PhoneControlPreferenceStore(directory: directory)
        try store.setAllowWindows(true)
        XCTAssertTrue(store.allowWindows())
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.setAllowWindows(false), "the write fails")
        XCTAssertFalse(store.allowWindows(), "off at once anyway")
        XCTAssertFalse(PhoneControlPreferenceStore(directory: directory).allowWindows())
    }
}
