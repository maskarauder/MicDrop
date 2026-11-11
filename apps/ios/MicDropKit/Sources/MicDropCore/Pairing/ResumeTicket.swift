import Crypto
import Foundation

/// Paused-playback resume ticket (Android `ResumeTicket.kt:7-12`).
///
/// Binds a lock-screen / media "Play" to the exact saved link: `id` is the session token at the time, `digest =
/// fingerprint(link)`. Persisted by the app's `PausedPlaybackStore` (owner) as `paused-playback.json`
/// `{"id":…,"digest":…,"fast":…}`: missing `id` or `digest` → no ticket; `fast` defaults to true and must be a JSON
/// boolean when present.
public struct ResumeTicket: Codable, Equatable, Sendable {
    public let id: String
    /// Lowercase hex SHA-256 of the trimmed saved link (64 characters).
    public let digest: String
    /// Fast-recovery flag of the paused session.
    public let fast: Bool

    public init(id: String, digest: String, fast: Bool = true) {
        self.id = id
        self.digest = digest
        self.fast = fast
    }

    /// Ticket for `link` (digest computed with `fingerprint`).
    public init(id: String, link: String, fast: Bool) {
        self.init(id: id, digest: ResumeTicket.fingerprint(link), fast: fast)
    }

    /// `digest == fingerprint(link)` (`ResumeTicket.kt:8`).
    public func matches(_ link: String) -> Bool {
        digest == ResumeTicket.fingerprint(link)
    }

    /// Lowercase hex SHA-256 of UTF-8 Kotlin-`trim(text)` (`ResumeTicket.kt:10-11`). Also used by
    /// `SessionDestination.digest` over the NUL-joined fields. Vector: `micdrop://v2/original-opaque-credential` →
    /// `617d5db28e72d3cf8bfa7079dec0a2e8c710026c5f5b1802ae64658834599ca9`.
    public static func fingerprint(_ text: String) -> String {
        let trimmed = ConnectionLink.trimmed(text)
        return HexPin.encode(SHA256.hash(data: Data(trimmed.utf8)))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case digest
        case fast
    }

    /// Strict decoding: `id` and `digest` required strings; `fast` optional JSON boolean
    /// (default true), never coerced (`PausedPlayback.kt:12-23`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        digest = try container.decode(String.self, forKey: .digest)
        fast = try container.decodeIfPresent(Bool.self, forKey: .fast) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(digest, forKey: .digest)
        try container.encode(fast, forKey: .fast)
    }
}
