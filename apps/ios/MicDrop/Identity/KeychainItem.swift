// One generic-password Keychain item ("Persistence", `KeychainItem`).
//
// Android stores the identity in AndroidKeyStore and the saved link in an AES-GCM
// `AtomicFile` envelope (`SavedConnections.kt:27,67-91`, `ConnectionEnvelope.kt`). On iOS the
// Keychain already encrypts at rest and binds to the device, so the envelope is not used.

import Foundation
import Security

/// A `kSecClassGenericPassword` item identified by service + account.
///
/// Every item is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (readable while
/// locked after first unlock: lock-screen Play, interruption resume, background recovery; never
/// migrated to another device) and `kSecAttrSynchronizable = false` (never iCloud).
///
/// All calls are synchronous and may block briefly; `CredentialVault` serializes them.
public struct KeychainItem: Sendable, Hashable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// The phone identity record.
    public static let phoneIdentity = KeychainItem(
        service: "com.maskarauder.micdrop.identity.v1",
        account: "phone-identity")
    /// The single saved connection link, UTF-8, 1…4096 bytes.
    public static let savedConnection = KeychainItem(
        service: "com.maskarauder.micdrop.saved-connection.v1",
        account: "last-connection")

    /// Keychain failures. `status` carries the raw `OSStatus`.
    public enum Failure: Error, Sendable, Equatable {
        /// `SecItem*` returned a status other than success / not-found (for example `errSecInteractionNotAllowed`
        /// before first unlock, or `errSecMissingEntitlement` −34018 after a re-sign with a different team/bundle ID).
        case status(OSStatus)
        /// A successful query returned something other than `Data`.
        case unexpectedResult
        /// The read-back after a write did not return exactly the written bytes
        /// (parity with `check(readLink() == text)`, `SavedConnections.kt:174`).
        case readBackMismatch
        /// The item was still present after a successful delete.
        case stillPresent
    }

    // MARK: Queries

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// True when the item exists, **including** when it exists but cannot be read (any status other
    /// than success / `errSecItemNotFound` counts as present, matching `SavedConnections.kt:105`
    /// which treats an exception as present).
    public func exists() -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status != errSecItemNotFound
    }

    /// The item's data; `nil` for `errSecItemNotFound`; throws `Failure.status` for any other status ("exists but
    /// unreadable", — never auto-delete).
    public func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Failure.unexpectedResult }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.status(status)
        }
    }

    /// Update-or-add (`SecItemUpdate`, then `SecItemAdd` on `errSecItemNotFound`), then read back and compare bytes.
    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            try addItem(data)
        default:
            throw Failure.status(status)
        }
        try verifyReadBack(data)
    }

    /// Add only (fails with `Failure.status(errSecDuplicateItem)` if the item exists), then read back and compare. Used
    /// for atomic identity creation: "create only when the item is absent".
    public func add(_ data: Data) throws {
        try addItem(data)
        try verifyReadBack(data)
    }

    /// Deletes the item; succeeds when it was already absent; then confirms `errSecItemNotFound` on a re-query
    /// (`forget()`).
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
        if try read() != nil { throw Failure.stillPresent }
    }

    // MARK: Private

    private func addItem(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    private func verifyReadBack(_ data: Data) throws {
        guard try read() == data else { throw Failure.readBackMismatch }
    }
}
