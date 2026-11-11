import Foundation

/// The `SessionStopRetry` destination digest (`A/StreamReceiver.kt:78-81`): `ResumeTicket.fingerprint` (lowercase hex
/// SHA-256 of the trimmed UTF-8 text) over the NUL-joined fields `[version, host, port, hex(pin), clientKey, token,
/// expiresAt, remote.url ?? "", remote.token ?? ""]`. It binds a remembered Stop to the pinned host, the phone identity
/// and the connection credentials. Memory-only; never logged.
public enum SessionDestination {
    public static func digest(_ link: ConnectionLink) -> String {
        digest(fields: [
            String(link.version.rawValue),
            link.endpoint.host.description,
            String(link.endpoint.port),
            HexPin.encode(link.pin),
            link.clientKey,
            link.token,
            String(link.expiresAt),
            link.remote?.url ?? "",
            link.remote?.token ?? "",
        ])
    }

    /// Digest of already-extracted fields (tests; identical joining rule).
    public static func digest(fields: [String]) -> String {
        ResumeTicket.fingerprint(fields.joined(separator: "\u{0000}"))
    }
}
