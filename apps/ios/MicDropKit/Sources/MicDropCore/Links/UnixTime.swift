import Foundation

/// Wall-clock Unix seconds for link expiry.
///
/// Android: `System.currentTimeMillis() / 1000` (`PairingClient.kt:15`, `LanInvitation.kt:10`).
/// Expired means `now >= expires_at`; at exactly `expires_at` a link is expired.
public enum UnixTime {
    /// Largest accepted `expires_at` (9999-12-31T23:59:59Z; `PairingClient.kt:38`, `LanInvitation.kt:58,67`).
    public static let maxExpiry: Int64 = 253_402_300_799

    /// Accepted `expires_at` range `1…253402300799`.
    public static let expiryRange: ClosedRange<Int64> = 1...253_402_300_799

    /// `floor(Date().timeIntervalSince1970)`.
    public static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970.rounded(.down))
    }
}
