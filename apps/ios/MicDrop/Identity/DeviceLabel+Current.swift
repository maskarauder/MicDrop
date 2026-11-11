// Pairing device label for `/pair`.
//
// `DeviceLabel` and `sanitize(_:fallback:)` are owned by (MicDropCore); only the device-reading `current()` lives in
// the app. `UIDevice.current.name`/`.model` are generic ("iPhone") since iOS 16 without a restricted entitlement, so
// the hardware identifier is used.

import Foundation
import MicDropCore

extension DeviceLabel {
    /// `machine = environment["SIMULATOR_MODEL_IDENTIFIER"]` (if non-empty) else `utsname.machine`; `raw =
    /// machine.isEmpty ? "iPhone" : "iPhone (" + machine + ")"`; sanitized to Go's `^[A-Za-z0-9 ._()-]{1,64}$`
    /// (`internal/pairing/manager.go:28`) with fallback `"iPhone"`. Example: `iPhone15,2` → `iPhone (iPhone15_2)`.
    public static func current() -> String {
        current(environment: ProcessInfo.processInfo.environment, machine: hardwareMachineIdentifier())
    }

    /// Testable form of `current()`: picks the identifier; the wrapping and sanitizing are MicDropCore's
    /// `label(machine:)` (one implementation).
    static func current(environment: [String: String], machine: String) -> String {
        let simulator = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        return label(machine: simulator.isEmpty ? machine : simulator)
    }
}

/// `uname()` `utsname.machine`, e.g. `iPhone15,2`; empty if unavailable.
private func hardwareMachineIdentifier() -> String {
    var info = utsname()
    guard uname(&info) == 0 else { return "" }
    return withUnsafeBytes(of: &info.machine) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
