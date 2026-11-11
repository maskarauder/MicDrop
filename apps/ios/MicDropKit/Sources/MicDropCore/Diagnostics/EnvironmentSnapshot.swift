import Foundation

/// Phone/build facts for the report `environment` object and the copy-report header (`K:PlaybackReport.kt:3-21`).
///
/// Wire use is gated: current hosts reject any non-null environment without an Android API level
/// (`G:internal/diagnostics/report.go:147`), so `PlaybackReport` sends `"environment": null` unless the host advertised
/// `environment_platform_version == 1`. The copy text always uses these facts. Produced by the app's
/// `PlaybackEnvironment` from `utsname`, `UIDevice`, `AVAudioSession` and `ProcessInfo`; the initializer re-applies the
/// host string rules.
public struct EnvironmentSnapshot: Sendable, Equatable {
    /// Route label set shared with `output.route` (`G:internal/diagnostics/report.go:96`). iOS never produces `hearing
    /// aid` (port mapping).
    public static let routeLabels: Set<String> = [
        "phone speaker", "earpiece", "wired headphones", "USB audio", "Bluetooth A2DP media",
        "Bluetooth SCO voice", "Bluetooth LE audio", "hearing aid", "HDMI", "line output", "other",
    ]
    /// `audio_mode` vocabulary (`report.go:147`).
    public static let audioModes: Set<String> = ["normal", "communication", "call", "ringtone", "other"]
    /// Host limit for each environment string (runes).
    public static let stringLimit = 80
    /// Host limit for `expected_routes`.
    public static let routeLimit = 16

    /// `MicDropVersionName` (BuildInfo.current.versionName).
    public let appVersion: String
    /// 12 lowercase hex of `GITHUB_SHA` or `local` (BuildInfo.current.revision).
    public let revision: String
    /// Always `Apple` on iOS (required on iOS).
    public let manufacturer: String
    /// `utsname.machine`, e.g. `iPhone16,1`.
    public let model: String
    /// `UIDevice.current.systemVersion`, e.g. `17.5.1` (`os_release`).
    public let osRelease: String
    /// Current route output labels: distinct, sorted, `nil` when empty (current route, not a prediction).
    public let expectedRoutes: [String]?
    /// `normal` / `communication` / `call` / `other` (never `ringtone` on iOS).
    public let audioMode: String
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled`.
    public let batterySaver: Bool

    /// Sanitizes every string (drop Unicode `Cc`, keep 80 scalars), filters/sorts/deduplicates routes to the
    /// label set (at most 16; `nil` if none remain) and maps an unknown `audioMode` to `other`.
    public init(
        appVersion: String, revision: String, manufacturer: String, model: String, osRelease: String,
        expectedRoutes: [String]?, audioMode: String, batterySaver: Bool
    ) {
        self.appVersion = Self.sanitized(appVersion)
        self.revision = Self.sanitized(revision)
        self.manufacturer = Self.sanitized(manufacturer)
        self.model = Self.sanitized(model)
        self.osRelease = Self.sanitized(osRelease)
        self.expectedRoutes = expectedRoutes.flatMap { Self.normalizedRoutes($0) }
        self.audioMode = Self.audioModes.contains(audioMode) ? audioMode : "other"
        self.batterySaver = batterySaver
    }

    /// Host string rule (`report.go:142-145`, `K:PlaybackEnvironment.kt:36`): drop scalars whose general category is
    /// `Cc` (= Go `unicode.IsControl`: C0, DEL) and keep the first `limit` scalars.
    public static func sanitized(_ value: String, limit: Int = EnvironmentSnapshot.stringLimit) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            guard count < limit else { break }
            scalars.append(scalar)
            count += 1
        }
        return String(scalars)
    }

    /// Distinct, sorted (plain string order) route labels restricted to `routeLabels`, at most 16;
    /// `nil` when empty (`K:PlaybackEnvironment.kt:17-19`).
    public static func normalizedRoutes(_ labels: [String]) -> [String]? {
        let routes = Array(Set(labels.filter { routeLabels.contains($0) })).sorted().prefix(routeLimit)
        return routes.isEmpty ? nil : Array(routes)
    }

    /// iOS environment object: `platform: "ios"`, `os_release`, no `android_release`/`api`, `screen_on: null`. Only
    /// sent when `DiagnosticsCapabilities.platformEnvironment` is true.
    public func json() -> DiagnosticJSON {
        .object([
            (key: "platform", value: .string("ios")),
            (key: "app_version", value: .string(appVersion)),
            (key: "revision", value: .string(revision)),
            (key: "manufacturer", value: .string(manufacturer)),
            (key: "model", value: .string(model)),
            (key: "os_release", value: .string(osRelease)),
            (key: "expected_routes", value: .strings(expectedRoutes)),
            (key: "audio_mode", value: .string(audioMode)),
            (key: "screen_on", value: .null),
            (key: "battery_saver", value: .bool(batterySaver)),
        ])
    }

    /// Copy-report environment block with the iOS substitutions of (Android: `K:PlaybackReport.kt:14-20`).
    /// `desktopPlayback` defaults to `!microphone`.
    public func text(microphone: Bool = false, desktopPlayback: Bool? = nil) -> String {
        let playback = desktopPlayback ?? !microphone
        var lines: [String] = []
        lines.append("MicDrop \(appVersion) · build \(revision)")
        lines.append("Phone: \(manufacturer) \(model) · iOS \(osRelease)")
        lines.append(
            "Current iOS output route: \(expectedRoutes?.joined(separator: ", ") ?? "unavailable") (confirm by listening)"
        )
        lines.append("Audio mode: \(audioMode) · Screen on: unavailable · Low Power Mode: \(batterySaver)")
        if microphone {
            lines.append(
                "Microphone return: explicit consent · Playback: \(playback ? "background audio session" : "off")")
        } else {
            lines.append("Microphone: off · Playback: background audio session")
        }
        return lines.joined(separator: "\n")
    }
}
