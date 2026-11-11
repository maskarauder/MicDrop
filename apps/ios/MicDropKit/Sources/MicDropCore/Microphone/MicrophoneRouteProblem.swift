import Foundation

/// Microphone route problems (`A/ConnectionFailure.kt:30-36`) with iOS details. Raw values are the Android enum names
/// (logs/tests only; never on the wire).
///
/// `ConnectionFailure.describe` (02) renders any `MicrophoneRouteError` as code `MICROPHONE_ROUTE` with
/// `problem.detail`, and any error at stage `inputRoute` with `MicrophoneRouteProblem.unverified.detail`.
public enum MicrophoneRouteProblem: String, CaseIterable, Sendable {
    /// Android Nearby-devices permission. Never raised on iOS (no Bluetooth permission).
    case bluetoothPermission = "BLUETOOTH_PERMISSION"
    /// Selected port absent at preflight / prepare / activation.
    case unavailable = "UNAVAILABLE"
    /// Active call (`CXCallObserver`), activation refused with `insufficientPriority` /
    /// `cannotInterruptOthers`, or the session is inactive when recovery reasserts the route.
    case inUse = "IN_USE"
    /// The route did not match within its deadline.
    case unverified = "UNVERIFIED"
    /// Android LE Audio stereo. Never raised on iOS (no LE Audio input).
    case leStereoUnavailable = "LE_STEREO_UNAVAILABLE"

    /// User-visible detail; iOS texts per /, Android verbatim otherwise.
    public var detail: String {
        switch self {
        case .bluetoothPermission:
            return
                "Allow Nearby devices permission for MicDrop to identify and recover your selected headset. You can still use the phone or a wired microphone without it."
        case .unavailable:
            return
                "The selected microphone is unavailable. Tap Microphone input, choose a connected input and start again."
        case .inUse:
            return
                "iPhone is in a call or another app is using audio. End that session before selecting a Bluetooth microphone."
        case .unverified:
            return
                "iOS could not verify the selected microphone route. Check the headset connection, choose an available input and start again."
        case .leStereoUnavailable:
            return
                "Android could not provide verified stereo output on the selected LE Audio headset. Turn off LE Audio stereo playback to try mono compatibility, or choose the phone microphone for media playback."
        }
    }
}

/// `MicrophoneRouteException(problem)` (`A/ConnectionFailure.kt:37`). Thrown by microphone preflight/routing and caught
/// by the UI connect path (10: `showConnectionFailure(problem.detail)`). Classification: not retryable; `describe` code
/// `MICROPHONE_ROUTE`; `SessionFailure.from` → `input_unverified` (`le_stereo_unavailable` for `.leStereoUnavailable`,
/// never produced on iOS). No message is derived from it except `problem.detail`.
public struct MicrophoneRouteError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let problem: MicrophoneRouteProblem

    public init(_ problem: MicrophoneRouteProblem) {
        self.problem = problem
    }

    public init(problem: MicrophoneRouteProblem) {
        self.problem = problem
    }

    /// `problem.detail`.
    public var detail: String { problem.detail }

    /// Fixed label (never device identity).
    public var description: String { "MicrophoneRouteError(\(problem.rawValue))" }
}
