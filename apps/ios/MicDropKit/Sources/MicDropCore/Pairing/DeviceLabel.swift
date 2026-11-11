import Foundation

/// The pairing label sent in `POST /pair` (one implementation, the UI's `PairingLabel` is deleted).
///
/// Go accepts `^[A-Za-z0-9 ._()-]{1,64}$` (`internal/pairing/manager.go:28`). The app-side `DeviceLabel.current()`
/// (owner) reads `ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]` (if non-empty) else
/// `utsname.machine` and returns `label(machine:)`.
public enum DeviceLabel {
    /// Fallback label (Android `"Android"`).
    public static let fallback = "iPhone"

    /// Maximum label length in Unicode scalars.
    public static let maxLength = 64

    /// `machine.isEmpty ? "iPhone" : "iPhone (" + machine + ")"`, sanitized
    /// (`iPhone15,2` → `iPhone (iPhone15_2)`).
    public static func label(machine: String) -> String {
        sanitize(machine.isEmpty ? fallback : "iPhone (" + machine + ")")
    }

    /// Replaces every Unicode scalar outside `[A-Za-z0-9 ._()-]` with `_`, keeps the first 64
    /// scalars; an empty or all-space result, or one not matching the Go regex, becomes
    /// `fallback` (Android `MainActivity.kt:966`).
    public static func sanitize(_ raw: String, fallback: String = DeviceLabel.fallback) -> String {
        var view = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars.prefix(maxLength) {
            view.append(isAllowed(scalar) ? scalar : "_")
        }
        let label = String(view)
        guard isValid(label), label.unicodeScalars.contains(where: { $0 != " " }) else {
            return fallback
        }
        return label
    }

    /// Full match of `^[A-Za-z0-9 ._()-]{1,64}$`.
    public static func isValid(_ label: String) -> Bool {
        let scalars = label.unicodeScalars
        let count = scalars.count
        return count >= 1 && count <= maxLength && scalars.allSatisfy(isAllowed)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:  // A-Z a-z 0-9
            return true
        case 0x20, 0x2E, 0x5F, 0x28, 0x29, 0x2D:  // space . _ ( ) -
            return true
        default:
            return false
        }
    }
}
