import AVFoundation
import Foundation
import MicDropCore

// Output route reading and the worker-initiated speaker override (item 7). Replaces Android `OutputRouting.kt` /
// `WebRtcOutputRouting`: iOS has no per-track routing, only the audio session's current route.

/// One entry of `AVAudioSession.currentRoute.outputs` with its port name.
///
/// `name` exists only for output-menu titles (`OutputChoice.list`). Like `output.uid` it can identify a personal
/// device: never log it, put it in diagnostics or the copy report, or send it to the host.
struct RouteOutputInfo: Hashable, Sendable {
    /// Identity `(portType, uid)` used by every selection/verification rule.
    let output: RouteOutput
    /// `AVAudioSessionPortDescription.portName` (UI titles only).
    let name: String
    /// Number of channels of the port (`channels?.count ?? 0`).
    let channels: Int
}

/// Current-route reader plus the speaker override used by the PHONE pin.
///
/// `currentOutputs()` may be called on any thread (worker, route-change fan-out, main actor). `overrideToSpeaker()` /
/// `clearSpeakerOverride()` are called **only by the session worker** (never from a callback) and go through
/// `AudioSessionArbiter`, the only caller of `RTCAudioSession.overrideOutputAudioPort` (item 1 and 7).
protocol AudioRouteInspecting: AnyObject, Sendable {
    /// `AVAudioSession.currentRoute.outputs` in OS order.
    func currentOutputs() -> [RouteOutputInfo]
    /// `overrideOutputAudioPort(.speaker)` is only valid in `.playAndRecord`: true iff the active session category is
    /// `.playAndRecord`.
    var speakerOverrideSupported: Bool { get }
    /// Force the built-in speaker (`overrideOutputAudioPort(.speaker)` under the configuration lock).
    func overrideToSpeaker() throws
    /// Remove a previous override (`overrideOutputAudioPort(.none)`).
    func clearSpeakerOverride() throws
}

extension AudioRouteInspecting {
    /// Identities of the current route outputs (`currentOutputs().map(\.output)`).
    func currentRouteOutputs() -> [RouteOutput] {
        currentOutputs().map { $0.output }
    }

    /// The whole current route is the built-in speaker ("route already is the speaker").
    var routeIsBuiltInSpeaker: Bool {
        let outputs = currentRouteOutputs()
        return !outputs.isEmpty && outputs.allSatisfy { $0.kind == .phone }
    }

    /// A Bluetooth media output (A2DP or LE; HFP has a nil kind) is in the current route.
    var bluetoothMediaInRoute: Bool {
        currentRouteOutputs().contains { $0.kind?.isBluetooth == true }
    }
}

/// Production `AudioRouteInspecting` over `AVAudioSession` reads and the arbiter's override
/// (`Output/AudioRouteInspector.swift`).
///
/// Reads use `AVAudioSession.sharedInstance()` directly (getters only; forbids only setters outside the arbiter). The
/// override closure is the arbiter's synchronous, worker-callable entry point; tests inject a fake closure and a fake
/// inspector.
final class AudioRouteInspector: AudioRouteInspecting, @unchecked Sendable {
    /// `true` → force the built-in speaker; `false` → clear the override. Throws the arbiter's error.
    typealias SpeakerOverride = (_ speaker: Bool) throws -> Void

    private let session: AVAudioSession
    private let applyOverride: SpeakerOverride

    init(session: AVAudioSession = AVAudioSession.sharedInstance(), applyOverride: @escaping SpeakerOverride) {
        self.session = session
        self.applyOverride = applyOverride
        assert(
            AudioRouteInspector.portTypeConstantsMatchSDK(),
            "RouteOutput.PortType raw values must equal the AVAudioSession.Port constants")
    }

    /// Production wiring: the override goes through `AudioSessionArbiter.setSpeakerOverride(_:)` (synchronous on the
    /// arbiter's private serial queue, callable from the session worker; item 7). `AudioRouteInspector()` uses the
    /// process-wide arbiter; a session should pass `dependencies.arbiter` (the same instance in production).
    convenience init(arbiter: AudioSessionArbiter = AudioSessionArbiter.shared) {
        self.init(applyOverride: { speaker in try arbiter.setSpeakerOverride(speaker) })
    }

    func currentOutputs() -> [RouteOutputInfo] {
        AudioRouteInspector.outputs(of: session.currentRoute)
    }

    var speakerOverrideSupported: Bool {
        session.category == .playAndRecord
    }

    func overrideToSpeaker() throws {
        try applyOverride(true)
    }

    func clearSpeakerOverride() throws {
        try applyOverride(false)
    }

    // MARK: - Pure mapping helpers (also used by OutputRouteObserver for the previous route)

    /// `route.outputs` mapped to `RouteOutputInfo` in OS order.
    static func outputs(of route: AVAudioSessionRouteDescription) -> [RouteOutputInfo] {
        route.outputs.map { info($0) }
    }

    /// `route.outputs` identities in OS order (previous-route parsing).
    static func routeOutputs(of route: AVAudioSessionRouteDescription) -> [RouteOutput] {
        route.outputs.map { routeOutput($0) }
    }

    /// `(portType.rawValue, uid)` of one port description.
    static func routeOutput(_ port: AVAudioSessionPortDescription) -> RouteOutput {
        RouteOutput(portType: port.portType.rawValue, uid: port.uid)
    }

    /// Identity, name and channel count of one port description.
    static func info(_ port: AVAudioSessionPortDescription) -> RouteOutputInfo {
        RouteOutputInfo(output: routeOutput(port), name: port.portName, channels: port.channels?.count ?? 0)
    }

    /// SDK constant ↔ MicDropCore raw value pairs that the pure mapping depends on
    /// (core-output API note 2: MicDropCore cannot import AVFoundation, so the app checks them).
    static let portTypeConstants: [(sdk: AVAudioSession.Port, core: String)] = [
        (.builtInSpeaker, RouteOutput.PortType.builtInSpeaker),
        (.builtInReceiver, RouteOutput.PortType.builtInReceiver),
        (.headphones, RouteOutput.PortType.headphones),
        (.usbAudio, RouteOutput.PortType.usbAudio),
        (.bluetoothA2DP, RouteOutput.PortType.bluetoothA2DP),
        (.bluetoothLE, RouteOutput.PortType.bluetoothLE),
        (.bluetoothHFP, RouteOutput.PortType.bluetoothHFP),
        (.HDMI, RouteOutput.PortType.hdmi),
        (.lineOut, RouteOutput.PortType.lineOut),
        (.airPlay, RouteOutput.PortType.airPlay),
        (.carAudio, RouteOutput.PortType.carAudio),
        (.lineIn, RouteOutput.PortType.lineIn),
        (.builtInMic, RouteOutput.PortType.builtInMic),
        (.headsetMic, RouteOutput.PortType.headsetMic),
    ]

    /// Every pair has equal raw values (asserted in DEBUG and in the simulator tests).
    static func portTypeConstantsMatchSDK() -> Bool {
        portTypeConstants.allSatisfy { $0.sdk.rawValue == $0.core }
    }
}

/// `AVAudioSession.Port` spellings of the pure MicDropCore mapping (names `OutputKind.forPort` / `routeLabel`; API note
/// 2).
extension OutputKind {
    /// Media-output kind of an iOS port (table); nil = not a media output.
    static func forPort(_ port: AVAudioSession.Port) -> OutputKind? {
        forPortType(port.rawValue)
    }

    /// Fixed Go route label (`report.go:96`) of an iOS port; nil for input-only ports.
    static func routeLabel(_ port: AVAudioSession.Port) -> String? {
        routeLabel(portType: port.rawValue)
    }
}
