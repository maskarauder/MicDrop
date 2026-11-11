import AVFoundation
import Foundation
import MicDropCore

/// iOS source of the report `environment` facts (port of `PlaybackEnvironment.kt`).
///
/// The host rejects every non-null environment that is not Android-shaped (`api` 31…1000), so the report encoder
/// (`PlaybackReport.json`) sends `"environment": null` unless the offer advertised `environment_platform_version == 1`.
/// This type still builds the snapshot every report because the copy text (`EnvironmentSnapshot.text`) always shows it.
///
/// Semantic difference (documented in the copy text): Android `expected_routes` is the OS
/// *prediction* for media attributes; iOS reports the session's *current* route outputs.
/// Neither proves audibility.
///
/// The host string rules (drop Unicode `Cc`, at most 80 scalars) and the route-list rules (label set, distinct, sorted,
/// at most 16, nil when empty) live in `EnvironmentSnapshot`; this type only reads the platform values and maps them to
/// labels.
enum PlaybackEnvironment {
    /// Builds the environment snapshot (iOS mapping). Never fabricates Android fields: manufacturer `Apple`, model =
    /// hardware identifier, `os_release` = iOS version, screen state unknown (not part of the snapshot),
    /// `battery_saver` = Low Power Mode. Every iOS query used here is infallible, so the result is always non-nil; the
    /// optional return mirrors Android, whose caller substitutes `null` when the snapshot throws. Safe to call from the
    /// session worker thread (no UIKit, only property reads on `AVAudioSession`).
    static func snapshot(
        session: AVAudioSession = .sharedInstance(),
        build: BuildInfo = .current
    ) -> EnvironmentSnapshot? {
        EnvironmentSnapshot(
            appVersion: build.versionName,
            revision: build.revision,
            manufacturer: "Apple",
            model: safe(hardwareModel()),
            osRelease: safe(osRelease()),
            expectedRoutes: routeLabels(session.currentRoute.outputs.map { $0.portType }),
            audioMode: audioModeLabel(session.mode),
            batterySaver: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Go `routes` label for an output port (iOS output port mapping). Never `hearing aid` (iOS cannot distinguish MFi
    /// hearing aids from other LE outputs). `.displayPort` maps to `other`.
    static func routeLabel(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInSpeaker: return "phone speaker"
        case .builtInReceiver: return "earpiece"
        case .headphones: return "wired headphones"
        case .usbAudio: return "USB audio"
        case .bluetoothA2DP: return "Bluetooth A2DP media"
        case .bluetoothHFP: return "Bluetooth SCO voice"
        case .bluetoothLE: return "Bluetooth LE audio"
        case .HDMI: return "HDMI"
        case .lineOut: return "line output"
        default: return "other"
        }
    }

    /// Distinct labels sorted by plain string comparison; nil when there are no outputs
    /// (`PlaybackEnvironment.kt:17-19`: `distinct().sorted().takeIf { it.isNotEmpty() }`), via
    /// `EnvironmentSnapshot.normalizedRoutes` (which also enforces the host's 16-entry bound).
    static func routeLabels(_ ports: [AVAudioSession.Port]) -> [String]? {
        EnvironmentSnapshot.normalizedRoutes(ports.map(routeLabel))
    }

    /// `audio_mode` from this app's own `AVAudioSession.mode`: `.default` → `normal`;
    /// `.voiceChat`/`.videoChat`/`.gameChat` → `communication`; anything else → `other`. Never `ringtone`; no
    /// CallKit-based `call` detection in v1.
    static func audioModeLabel(_ mode: AVAudioSession.Mode) -> String {
        switch mode {
        case .default: return "normal"
        case .voiceChat, .videoChat, .gameChat: return "communication"
        default: return "other"
        }
    }

    /// Hardware identifier (e.g. `iPhone16,1`): `SIMULATOR_MODEL_IDENTIFIER` when running in the simulator (simulator
    /// architecture rule), else `utsname.machine`. Unsanitized; empty if `uname` fails.
    static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// iOS version in `UIDevice.systemVersion` form (`17.5`, `17.5.1`), read from
    /// `ProcessInfo.operatingSystemVersion` so it is callable off the main actor.
    static func osRelease() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Drops Unicode control scalars (general category Cc = Go `unicode.IsControl`) and keeps the
    /// first `limit` scalars (`PlaybackEnvironment.kt:36`, host rule ≤ 80 runes); delegates to
    /// `EnvironmentSnapshot.sanitized`.
    static func safe(_ value: String, limit: Int = EnvironmentSnapshot.stringLimit) -> String {
        EnvironmentSnapshot.sanitized(value, limit: limit)
    }
}
