// Credential vault: the single owner of every Keychain call for the phone identity and the saved connection ("Thread
// model").
//
// Android performs all Keystore/file IO on one worker (`SavedConnections.kt:24-28`); here an actor offers the async API
// used by `SavedConnectionStore`, and a lock-protected core also backs the synchronous `nonisolated` accessors the
// session worker thread needs (worker-side APIs are synchronous; `SessionDependencies.tls` is `(ConnectionLink) throws
// -> ControlTLSSetup`).

import Foundation
import MicDropCore
import MicDropIdentity

public actor CredentialVault {
    /// The process-wide vault over the real Keychain items.
    public static let shared = CredentialVault()

    /// Maximum saved-link size in UTF-8 bytes (`ConnectionEnvelope.kt:15`).
    public static let maxSavedLinkBytes = 4096

    let core: Core

    /// - Parameters:
    ///   - identityItem / savedLinkItem: Keychain items (tests inject unique services).
    ///   - defaults: holds the install sentinel key.
    ///   - now: wall clock for certificate creation/re-issue.
    ///   - secureEnclaveAvailable: false forces the software-key fallback (tests, Simulator).
    public init(
        identityItem: KeychainItem = .phoneIdentity,
        savedLinkItem: KeychainItem = .savedConnection,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        secureEnclaveAvailable: @escaping @Sendable () -> Bool = { CredentialVault.secureEnclaveIsAvailable() }
    ) {
        self.core = Core(
            identityItem: identityItem, savedLinkItem: savedLinkItem, defaults: defaults,
            now: now, secureEnclaveAvailable: secureEnclaveAvailable)
    }

    /// Result of reading and validating the saved connection at startup (table).
    public enum SavedConnectionLoad: Sendable, Equatable {
        /// A validated link (version ≥ 2; for v3 the identity loaded with its `client_key`).
        case saved(String)
        /// No saved item. `identityPresent` = identity item exists (an exception counts as present,
        /// `SavedConnections.kt:105`).
        case absent(identityPresent: Bool)
        /// The saved item exists but the Keychain query failed (Android: file exists but open failed)
        /// → `Saved connection could not be read. Tap Forget and connect again.`
        case unreadable
        /// Any other failure (UTF-8/size, parse, v1, identity missing/mismatched/invalid)
        /// → `Saved connection or phone identity could not be read. Tap Forget before pairing again.`
        case invalid
    }

    /// Saved-link validation failures (`SavedConnections.kt:161-165`).
    public enum SavedLinkError: Error, Sendable, Equatable {
        /// Not 1…4096 UTF-8 bytes (`ConnectionEnvelope.kt:15`).
        case size
        /// Stored bytes are not valid UTF-8.
        case encoding
        /// Version 1 links are never saved (`SavedConnections.kt:121-122,163`).
        case legacyVersion
    }

    // MARK: Phone identity (operations table)

    /// `exists()`: identity item present, even if unreadable (then `true`).
    public func identityExists() throws -> Bool {
        core.locked { core.identityExistsUnlocked() }
    }

    /// `ensure()`: create the identity only when the item is **absent** (Secure Enclave when
    /// available, else software key), then re-read and verify. Present but unreadable/invalid →
    /// throws `PhoneIdentityError.unreadable`/`.mismatch` (never replaced).
    public func ensureIdentity() throws -> PhoneIdentity {
        try core.locked { try core.ensureIdentityUnlocked() }
    }

    /// `manager(expected)`: load and require stored certificate SPKI == key fingerprint == `fingerprint`; re-issues an
    /// expiring/out-of-window certificate from the same key.
    public func loadIdentity(expecting fingerprint: String) throws -> PhoneIdentity {
        try core.locked { try core.loadIdentityUnlocked(expecting: fingerprint) }
    }

    /// Synchronous `loadIdentity(expecting:)` for the session worker thread. Serialized with the actor's operations by
    /// the core lock. Blocks; never call from the main thread in a loop.
    public nonisolated func loadIdentityBlocking(expecting fingerprint: String) throws -> PhoneIdentity {
        try core.locked { try core.loadIdentityUnlocked(expecting: fingerprint) }
    }

    /// Identity to install for `link`'s TLS: `nil` for v1/v2 (no client certificate,
    /// `LanInvitation.kt:15`), the identity matching `link.clientKey` for paired v3. Synchronous,
    /// for `SessionDependencies.tls` and the transports (`ControlTLS.setup(for:identity:)`).
    public nonisolated func identity(for link: ConnectionLink) throws -> PhoneIdentity? {
        guard link.version.rawValue == 3 else { return nil }
        return try loadIdentityBlocking(expecting: link.clientKey)
    }

    // MARK: Saved connection

    /// Reads the saved link: `nil` when absent; throws `KeychainItem.Failure` when the item exists
    /// but cannot be read, `SavedLinkError` for bad size/encoding.
    public func readSavedLink() throws -> String? {
        try core.locked { try core.readSavedLinkUnlocked() }
    }

    /// `writeLink`: validate (`validateSaved`), write, read back and compare
    /// (`SavedConnections.kt:167-175`).
    public func writeSavedLink(_ link: String) throws {
        try core.locked { try core.writeSavedLinkUnlocked(link) }
    }

    /// `validateSaved`: parse; version ≥ 2; for v3 load the identity expecting `client_key`
    /// (`SavedConnections.kt:161-165`).
    public func validateSaved(_ link: String) throws -> ConnectionLink {
        try core.locked { try core.validateSavedUnlocked(link) }
    }

    /// Startup load (`SavedConnections.kt:93-117`): read + validate.
    public func loadSavedConnection() -> SavedConnectionLoad {
        core.locked { core.loadSavedConnectionUnlocked() }
    }

    /// Forget (`SavedConnections.kt:140-159`): delete the saved link, then the phone identity, and
    /// confirm both are gone. Both deletions are attempted; the first error is rethrown.
    public func forgetAll() throws {
        try core.locked { try core.forgetAllUnlocked() }
    }

    // MARK: Install sentinel

    /// Applies the install sentinel once per process (idempotent; every other operation also applies it first, so
    /// calling this at launch is optional). Returns `true` when this process performed the first-launch wipe.
    @discardableResult
    public nonisolated func applyInstallSentinelIfNeeded() -> Bool {
        core.locked { core.wipedAtLaunch }
    }

    /// `SecureEnclave.isAvailable` when CryptoKit exists, else `false`.
    public nonisolated static func secureEnclaveIsAvailable() -> Bool {
        #if canImport(CryptoKit)
            return SecureEnclaveSigner.isAvailable
        #else
            return false
        #endif
    }
}

// MARK: - Core (lock-protected implementation shared by actor and nonisolated entry points)

extension CredentialVault {
    /// All Keychain logic. Every public entry takes `lock` exactly once via `locked(_:)` and calls
    /// `…Unlocked` helpers, which never re-take it (`NSLock` is not recursive).
    final class Core: @unchecked Sendable {
        let identityItem: KeychainItem
        let savedLinkItem: KeychainItem
        let defaults: UserDefaults
        let now: @Sendable () -> Date
        let secureEnclaveAvailable: @Sendable () -> Bool

        private let lock = NSLock()
        /// Set once the sentinel ran in this process (successful or not); it never runs twice per process so it cannot
        /// delete a pairing created after launch.
        private var sentinelChecked = false
        /// Last identity loaded or created, reused by `loadIdentityUnlocked` while `now` stays
        /// inside its reuse window; cleared by forget and by the sentinel.
        var cached: CachedIdentity?

        init(
            identityItem: KeychainItem, savedLinkItem: KeychainItem, defaults: UserDefaults,
            now: @escaping @Sendable () -> Date, secureEnclaveAvailable: @escaping @Sendable () -> Bool
        ) {
            self.identityItem = identityItem
            self.savedLinkItem = savedLinkItem
            self.defaults = defaults
            self.now = now
            self.secureEnclaveAvailable = secureEnclaveAvailable
        }

        /// Runs `body` under the lock, after applying the install sentinel if not yet done.
        func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            if !sentinelChecked { _ = runInstallSentinelUnlocked() }
            return try body()
        }

        // MARK: Identity

        func identityExistsUnlocked() -> Bool {
            identityItem.exists()
        }

        // ensureIdentityUnlocked() and loadIdentityUnlocked(expecting:) are in
        // CredentialVault+Identity.swift.

        // MARK: Saved link

        func readSavedLinkUnlocked() throws -> String? {
            guard let data = try savedLinkItem.read() else { return nil }
            guard (1...CredentialVault.maxSavedLinkBytes).contains(data.count) else { throw SavedLinkError.size }
            guard let text = String(data: data, encoding: .utf8) else { throw SavedLinkError.encoding }
            return text
        }

        func writeSavedLinkUnlocked(_ link: String) throws {
            _ = try validateSavedUnlocked(link)
            let data = Data(link.utf8)
            guard (1...CredentialVault.maxSavedLinkBytes).contains(data.count) else { throw SavedLinkError.size }
            try savedLinkItem.write(data)
        }

        func validateSavedUnlocked(_ link: String) throws -> ConnectionLink {
            let connection = try ConnectionLink.parse(link)
            guard connection.version.rawValue >= 2 else { throw SavedLinkError.legacyVersion }
            if connection.version.rawValue == 3 {
                _ = try loadIdentityUnlocked(expecting: connection.clientKey)
            }
            return connection
        }

        func loadSavedConnectionUnlocked() -> SavedConnectionLoad {
            let text: String?
            do {
                text = try readSavedLinkUnlocked()
            } catch is KeychainItem.Failure {
                return .unreadable
            } catch {
                return .invalid
            }
            guard let text else { return .absent(identityPresent: identityExistsUnlocked()) }
            do {
                _ = try validateSavedUnlocked(text)
                return .saved(text)
            } catch {
                return .invalid
            }
        }

        func forgetAllUnlocked() throws {
            cached = nil
            var firstError: Error?
            do { try savedLinkItem.delete() } catch { firstError = error }
            do { try identityItem.delete() } catch { firstError = firstError ?? error }
            if let firstError { throw firstError }
        }

        // MARK: Install sentinel

        /// True when this process performed the wipe (read under the lock).
        private(set) var wipedAtLaunch = false

        /// if `UserDefaults.bool(forKey: "micdrop.install.v1") == false`, delete the identity and saved-connection
        /// items, then set the key. Deletion errors (not only not-found) are ignored and the key is set anyway, so a
        /// later launch can never delete a pairing created after this one; a surviving unreadable item then surfaces as
        /// the needs-Forget state. MicDrop has no background launch modes, so this runs after first unlock.
        @discardableResult
        private func runInstallSentinelUnlocked() -> Bool {
            sentinelChecked = true
            guard !defaults.bool(forKey: CredentialVault.InstallSentinel.defaultsKey) else { return false }
            try? savedLinkItem.delete()
            try? identityItem.delete()
            cached = nil
            defaults.set(true, forKey: CredentialVault.InstallSentinel.defaultsKey)
            wipedAtLaunch = true
            return true
        }
    }

    /// Install sentinel constants.
    public enum InstallSentinel {
        /// `UserDefaults.standard` key; removed with the app, kept across Sideloadly re-signs.
        public static let defaultsKey = "micdrop.install.v1"
    }
}
