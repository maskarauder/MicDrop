// Phone identity load/create errors (Android `AndroidIdentity.kt`).
//
// `PhoneIdentity` and `IdentityProtection` are declared once, in MicDropIdentity
// (`MicDropKit/Sources/MicDropIdentity/PhoneIdentity.swift`), because MicDropTransport's
// `ControlTLS.setup(for:identity:)` consumes them; the app owns only the Keychain-backed loading
// (`CredentialVault`) and this error type.

import Foundation
import MicDropIdentity

/// Identity load/create failures, classified as `SETUP_FAILED` (non-retryable, `session_exception`).
/// An unreadable or mismatched identity is never silently replaced; the user must Forget
/// (`docs/PAIRING.md`).
public enum PhoneIdentityError: Error, Sendable, Equatable {
    /// No identity item exists (Android: alias absent).
    case absent
    /// The item exists but cannot be decoded, its key cannot be reconstructed, or its certificate
    /// cannot be parsed or re-issued.
    case unreadable
    /// Stored certificate SPKI, key fingerprint and the expected `client_key` disagree
    /// (`AndroidIdentity.kt:59`).
    case mismatch
    /// A new identity could not be created: Secure Enclave key generation or self-signing
    /// failed, or the record would exceed the stored-record bound. Nothing was stored, so the
    /// next pairing attempt tries again (Android: Keystore generation throws inside `ensure()`).
    case creationFailed
    /// An unexpected Keychain status (`OSStatus` value) other than success / not-found.
    case keychain(Int32)
}
