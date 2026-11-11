import Foundation

/// User silence ("Play desktop audio") vs temporary route hold (`AudioOutputGate.kt`).
///
/// "User silence is independent of a temporary route hold; verification cannot undo that silence." Value type, mutated
/// under the session audio lock.
public struct AudioOutputGate: Equatable, Sendable {
    /// The user's request (not effective audibility); reported as `output_control.requested_enabled`.
    public private(set) var enabled: Bool
    private var held: Bool
    private var stopped = false

    public init(enabled: Bool = true, held: Bool = false) {
        self.enabled = enabled
        self.held = held
    }

    /// Session construction (`StreamReceiver.kt:54-55`): enabled iff requested and the mode plays;
    /// held for playback modes when the microphone is a Bluetooth headset or the selection is
    /// explicit (pins start held until verified; DEFAULT is held by `DefaultOutputPolicy` instead).
    /// - Parameter bluetoothMicrophone: `mode.microphone && microphoneKind.isBluetooth`.
    public static func session(
        initiallyEnabled: Bool, playback: Bool, bluetoothMicrophone: Bool,
        selection: OutputSelection
    ) -> AudioOutputGate {
        AudioOutputGate(
            enabled: initiallyEnabled && playback,
            held: playback && (bluetoothMicrophone || selection.explicit))
    }

    /// `stopped || held || !enabled`.
    public var muted: Bool { stopped || held || !enabled }

    /// User request; ignored after `stop()`.
    public mutating func request(_ value: Bool) {
        if !stopped { enabled = value }
    }

    /// Temporary hold (route change, verification pending).
    public mutating func hold() { held = true }

    /// Route verified: releases the hold only; never changes user silence.
    public mutating func verified() { held = false }

    /// Permanent: later `request(true)` / `verified()` cannot unmute.
    public mutating func stop() { stopped = true }
}
