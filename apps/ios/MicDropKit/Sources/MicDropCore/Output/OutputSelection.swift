import Foundation

/// The in-memory output choice of the app or of one session (`OutputSelection.kt:30-83`).
///
/// Android (`OutputSelection.kt:29-30`): "Port IDs are process-local. Stable Bluetooth address/profile can be saved
/// privately, but are never included in reports or exported options." iOS remembers an external pin's route identity
/// (uid, port type, kind) across launches in protected local storage (`RememberedAudioDevices`), also for USB and
/// general outputs; restoring it never verifies a route by itself. iOS identity is `(portType, uid)`; there is no port
/// ID and no masked-address handling (`BluetoothAudioIdentity` is not ported).
public struct OutputSelection: Hashable, Sendable {
    public var kind: OutputKind
    /// `""` for DEFAULT; `RouteOutput.PortType.builtInSpeaker` for PHONE.
    public var portType: String
    /// `""` for DEFAULT and PHONE (= any built-in speaker); non-empty for every external pin.
    public var uid: String
    /// Set only on the temporary "Use iPhone speaker" fallback.
    public var returnOnBluetooth: Bool

    public init(
        kind: OutputKind = .default, portType: String = "", uid: String = "",
        returnOnBluetooth: Bool = false
    ) {
        self.kind = kind
        self.portType = portType
        self.uid = uid
        self.returnOnBluetooth = returnOnBluetooth
    }

    /// Follow iPhone media output (`OutputSelection()`); used by `applyOutputChoice(.default)` (10).
    public static var `default`: OutputSelection { OutputSelection() }

    /// `kind != DEFAULT`.
    public var explicit: Bool { kind != .default }
    /// `kind == PHONE && returnOnBluetooth` (the "Use iPhone speaker" fallback).
    public var temporarySpeaker: Bool { kind == .phone && returnOnBluetooth }
    /// A temporary speaker is persisted as DEFAULT.
    public var preferenceKind: OutputKind { temporarySpeaker ? .default : kind }
    /// True while MicDrop follows the system route (DEFAULT or the temporary speaker): the system route picker is then
    /// usable wherever the output menu is. With a pinned output it is usable only while no session is retained (D042,
    /// `ControlsDeriver`).
    public var followsSystemRoute: Bool { !explicit || temporarySpeaker }

    /// Same kind and port type, and (PHONE with empty uid: any built-in speaker; else same non-empty uid).
    public func matches(_ output: RouteOutput?) -> Bool {
        guard let output, output.kind == kind, output.portType == portType else { return false }
        return (kind == .phone && uid.isEmpty) || (!uid.isEmpty && output.uid == uid)
    }

    /// Exactly one matching output for an explicit selection, else nil (`OutputSelection.kt:43-44`).
    public func resolve(_ outputs: [RouteOutput]) -> RouteOutput? {
        guard explicit else { return nil }
        let matching = outputs.filter { matches($0) }
        return matching.count == 1 ? matching[0] : nil
    }

    /// Every actual routed output must be the chosen one; DEFAULT accepts any non-empty route
    /// (`OutputSelection.kt:45-46`).
    public func verifies(_ outputs: [RouteOutput]) -> Bool {
        !outputs.isEmpty && (!explicit || outputs.allSatisfy { matches($0) })
    }

    /// Same kind, port type and uid (`OutputSelection.kt:48-50`, iOS identity).
    public func sameEndpoint(_ other: OutputSelection) -> Bool {
        kind == other.kind && portType == other.portType && uid == other.uid
    }

    /// "A service may accept the receiver's automatic return only while it still owns the temporary
    /// speaker choice. New explicit choices keep authority." (`OutputSelection.kt:52-55`)
    public func acceptsUpdate(_ other: OutputSelection) -> Bool {
        (sameEndpoint(other) && temporarySpeaker == other.temporarySpeaker) || (temporarySpeaker && !other.explicit)
    }

    /// Whether a session's accepted automatic update (`acceptsUpdate`) may also replace the saved output: only while
    /// the saved output is the session's previous or new endpoint (`PlaybackService.kt:246-251`,
    /// `MicrophoneService.kt:216-221`). "Do not overwrite a newer Windows choice saved for the next connection."
    /// Explicit local choices are saved regardless.
    public static func persistsSessionUpdate(
        saved: OutputSelection, previous: OutputSelection, update: OutputSelection
    ) -> Bool {
        saved.sameEndpoint(previous) || saved.sameEndpoint(update)
    }

    /// iOS refresh: DEFAULT -> self; PHONE while the speaker can be forced (`speakerPinnable`, computed by the provider
    /// from the arbiter's plan and the input) -> self; otherwise self iff the current route resolves the selection,
    /// else nil.
    public func refresh(_ outputs: [RouteOutput], speakerPinnable: Bool) -> OutputSelection? {
        if !explicit { return self }
        if kind == .phone && speakerPinnable { return self }
        return resolve(outputs) != nil ? self : nil
    }

    /// `OutputDevices.available` (`OutputDevices.kt:37-38`): `!explicit || refresh(...) != nil`.
    public func available(in outputs: [RouteOutput], speakerPinnable: Bool) -> Bool {
        !explicit || refresh(outputs, speakerPinnable: speakerPinnable) != nil
    }

    /// Copy-report state after `App output selection: ` (`StreamReceiver.kt:744-745`): `"<kind.label> · <restoring
    /// selected output | verifying | verified | iOS routing>"`.
    public func reportState(recovering: Bool, pending: Bool) -> String {
        let state: String
        if recovering {
            state = "restoring selected output"
        } else if pending {
            state = "verifying"
        } else if explicit {
            state = "verified"
        } else {
            state = "iOS routing"
        }
        return "\(kind.label) · \(state)"
    }

    /// `restored(PHONE).copy(returnOnBluetooth = true)` (`OutputSelection.kt:78`).
    public static func fallbackSpeaker() -> OutputSelection {
        var selection = restored(.phone)
        selection.returnOnBluetooth = true
        return selection
    }

    /// PHONE -> built-in speaker selection; anything else (including nil) -> DEFAULT.
    /// "An external port must be explicitly selected again." (`OutputSelection.kt:79-81`)
    public static func restored(_ kind: OutputKind?) -> OutputSelection {
        kind == .phone
            ? OutputSelection(kind: .phone, portType: RouteOutput.PortType.builtInSpeaker) : OutputSelection()
    }
}

/// Redacted text and reflection: `uid` may embed a Bluetooth MAC and must never reach a log, the copy report or a test
/// failure message. Only whether a uid is set is shown.
extension OutputSelection: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OutputSelection(kind: \(kind.wireLabel), portType: \(portType.isEmpty ? "none" : portType), "
            + "uid: \(uid.isEmpty ? "none" : "redacted"), returnOnBluetooth: \(returnOnBluetooth))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "kind": kind, "portType": portType, "uid": uid.isEmpty ? "none" : "redacted",
                "returnOnBluetooth": returnOnBluetooth,
            ],
            displayStyle: .struct)
    }
}
