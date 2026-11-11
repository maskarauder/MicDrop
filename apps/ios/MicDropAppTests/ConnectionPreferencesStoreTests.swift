import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

final class ConnectionPreferencesStoreTests: XCTestCase {
    func testSavedSettingsSurviveNewStoreAndInvalidValuesUseDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionPreferencesStore(directory: directory)
        let preferences = try ConnectionPreferences(
            initialOrder: .rendezvousFirst, recoveryOrder: .lanFirst, timeouts: [.recovery: 60_000], maxRestarts: 4)
        try store.save(preferences)
        XCTAssertEqual(ConnectionPreferencesStore(directory: directory).load(), preferences)
        let url = directory.appendingPathComponent(ConnectionPreferences.fileName)
        try Data("{\"RECOVERY\":false,\"initialOrder\":99}".utf8).write(to: url)
        XCTAssertEqual(ConnectionPreferencesStore(directory: directory).load(), ConnectionPreferences())
    }
}
