import Foundation

/// Build identity of the iPhone app, read from its Info.plist.
///
/// The value domain matches Android's `BuildConfig`: `revision` is the first 12 lowercase hex characters of a
/// CI commit or `local` (`apps/android/app/build.gradle.kts:19-20`), and `versionName` satisfies the host's
/// environment string rules (at most 80 runes, no control characters; `internal/diagnostics/report.go:142-145`).
/// The app target provides `BuildInfo.current` from `Bundle.main` (`App/BuildInfo+Bundle.swift`).
public struct BuildInfo: Sendable, Equatable {
    public static let localRevision = "local"
    public static let fallbackVersionName = "0.1.0-dev"
    public static let revisionKey = "MicDropRevision"
    public static let versionNameKey = "MicDropVersionName"
    /// `PlaybackEnvironment.safe` keeps at most 80 characters (`K:PlaybackEnvironment.kt:36`).
    public static let versionNameLimit = 80

    /// Sanitized `MicDropVersionName`, at most 80 Unicode scalars, never empty.
    public let versionName: String
    /// `^[0-9a-f]{12}$` or `local`.
    public let revision: String

    /// Reads `MicDropVersionName` and `MicDropRevision`; a missing or non-string value uses the fallback.
    public init(infoDictionary: [String: Any]) {
        self.init(
            versionName: infoDictionary[Self.versionNameKey] as? String ?? "",
            revision: infoDictionary[Self.revisionKey] as? String ?? ""
        )
    }

    /// Applies the same validation as `init(infoDictionary:)`: an unexpanded `$(MICDROP_REVISION)`, uppercase
    /// hex or a 40-character commit becomes `local`; an empty sanitized name becomes `0.1.0-dev`.
    public init(versionName: String, revision: String) {
        let name = Self.sanitized(versionName)
        self.versionName = name.isEmpty ? Self.fallbackVersionName : name
        self.revision = Self.isRevision(revision) ? revision : Self.localRevision
    }

    /// `"Build <revision>"` (`strings.xml:38` `build_label`).
    public var buildLabel: String {
        "Build \(revision)"
    }

    /// `"MicDrop <versionName> · build <revision>"`, separator space, U+00B7, space
    /// (`K:MicDropApplication.kt:15`, `K:StreamReceiver.kt:143`, `K:PlaybackReport.kt:15`).
    public var reportHeader: String {
        "MicDrop \(versionName) \u{00B7} build \(revision)"
    }

    /// Drops Unicode general category Cc (C0, DEL and C1, the same set as Go `unicode.IsControl` and Kotlin
    /// `Char.isISOControl`), then keeps the first `limit` scalars.
    static func sanitized(_ text: String, limit: Int = BuildInfo.versionNameLimit) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars where scalar.properties.generalCategory != .control {
            guard count < limit else { break }
            scalars.append(scalar)
            count += 1
        }
        return String(scalars)
    }

    /// Exactly 12 characters from `0-9a-f`.
    static func isRevision(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 12
            && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
