import Foundation

/// Session audio mode (`A/StreamMode.kt`).
///
/// Kotlin's `microphone` / `playback` properties are `hasMicrophone` / `hasPlayback` here:
/// Swift does not allow an instance property with the same name as the `microphone` case.
/// `direction` is the wire label (`audio_direction`).
public enum StreamMode: String, Sendable, Equatable, CaseIterable, Codable {
    case playback
    case microphone
    case duplex

    /// Sent when a fresh offer does not confirm the requested mode (`A/StreamReceiver.kt:388`),
    /// code `.modeNotConfirmed`.
    public static let modeNotConfirmedMessage =
        "Windows did not confirm the requested audio mode. Update both apps and select a cable endpoint for microphone return."

    /// Kotlin `microphone`: the phone sends its microphone (microphone and duplex).
    public var hasMicrophone: Bool { self != .playback }

    /// Kotlin `playback`: Windows desktop audio plays on the phone (playback and duplex).
    public var hasPlayback: Bool { self != .microphone }

    /// Wire `audio_direction`: `desktop_playback` / `phone_microphone` / `duplex`.
    public var direction: String {
        switch self {
        case .playback: return "desktop_playback"
        case .microphone: return "phone_microphone"
        case .duplex: return "duplex"
        }
    }

    /// `Reconnect` for playback, `Connect` for microphone and duplex (`:15-17`).
    public var reconnectAction: String {
        self == .playback ? "Reconnect" : "Connect"
    }

    /// `usesMediaOutput(input) = playback && (!microphone || !input.bluetooth)` (`:12`): a
    /// Bluetooth (HFP) microphone owns a coupled communication route.
    public func usesMediaOutput(_ input: MicrophoneKind) -> Bool {
        hasPlayback && (!hasMicrophone || !input.isBluetooth)
    }

    /// Convenience for a `MicrophoneSelection` (uses its `kind`).
    public func usesMediaOutput(_ selection: MicrophoneSelection) -> Bool {
        usesMediaOutput(selection.kind)
    }

    /// `endedMessage(reason)` (`:19-29`) with the iOS microphone texts of: playback → `reason.message`;
    /// microphone/duplex: FOCUS "Stopped after another app took audio.", OUTPUT "Stopped because the audio output was
    /// disconnected. Choose an output.", SERVICE "Microphone session stopped by iOS.", FAILURE "Connection ended.",
    /// each followed by `" Tap Connect when ready."`; other reasons → `reason.message`. The strings are owned by (07);
    /// this delegates to `StopReason.endedMessage(microphone:reconnectAction:)`.
    public func endedMessage(_ reason: StopReason) -> String {
        reason.endedMessage(microphone: hasMicrophone, reconnectAction: reconnectAction)
    }

    /// Ordered `/offer` body fields (`:31-37`): `version`, then `microphone_return_version: 1`
    /// (microphone modes), then `duplex_version: 1` (duplex). Microphone modes require v3
    /// (`require`) → `StreamModeError`.
    public func offerFields(version: Int) throws -> [(key: String, value: Int)] {
        guard !hasMicrophone || version == 3 else { throw StreamModeError() }
        var fields: [(key: String, value: Int)] = [("version", version)]
        if hasMicrophone { fields.append(("microphone_return_version", 1)) }
        if self == .duplex { fields.append(("duplex_version", 1)) }
        return fields
    }

    /// Mode confirmation (`:39-43`): playback needs mic 0, duplex 0 and direction `""` or
    /// `desktop_playback`; microphone needs 1/0/`phone_microphone`; duplex 1/1/`duplex`.
    public func acceptsOffer(microphoneVersion: Int, duplexVersion: Int, direction: String) -> Bool {
        switch self {
        case .playback:
            return microphoneVersion == 0 && duplexVersion == 0 && (direction.isEmpty || direction == self.direction)
        case .microphone:
            return microphoneVersion == 1 && duplexVersion == 0 && direction == self.direction
        case .duplex:
            return microphoneVersion == 1 && duplexVersion == 1 && direction == self.direction
        }
    }

    /// Session failure for an `/offer` `HTTPFailure` before rethrowing (`A/StreamReceiver.kt:1216-1224`): duplex + 400
    /// → duplex-unsupported text / `.modeNotConfirmed`; microphone modes + 409 → not-configured text /
    /// `.hostMicrophoneGate`; otherwise nil.
    public func offerFailure(status: Int) -> (message: String, code: SessionFailure)? {
        if self == .duplex && status == 400 {
            return (
                "Windows does not support duplex. Update both apps, then enable Play desktop audio and Send microphone and tap Connect again.",
                .modeNotConfirmed
            )
        }
        if hasMicrophone && status == 409 {
            return (
                "Windows microphone return is not configured. Restart Windows with --paired and --microphone-device using the cable render ID from bridge-devices.",
                .hostMicrophoneGate
            )
        }
        return nil
    }
}

/// `StreamMode.offerFields` was asked for a microphone mode on a link older than v3 (Kotlin `require` →
/// `IllegalArgumentException`; `SETUP_FAILED`, `session_exception`).
public struct StreamModeError: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "StreamModeError(microphoneRequiresPairedLink)" }
}
