import Foundation

@testable import MicDropCore

/// Builders shared by the core-presentation tests. The name is prefixed so it stays unique in the
/// `MicDropCoreTests` module that every MicDropCore owner adds tests to.
enum PresentationFixtures {
    /// `DiscoveryRecordTest.kt` vectors: host key `ab`×32, client key `cd`×32.
    static let pin = String(repeating: "ab", count: 32)
    static let client = String(repeating: "cd", count: 32)
    static let otherPin = String(repeating: "f", count: 64)

    static let noSavedConnection = "No saved connection. Paste a Windows link."
    static let pairedMessage =
        "Paired Windows: 192.168.1.20:9844\nSaved for this phone. Connect uses the audio and microphone options below."
    static let waitingMessage =
        "Waiting for Windows approval.\nRequest ID: 0123456789ab\n"
        + "In the Windows app, open Phones, check that this request ID matches, then select Approve."
    static let destination = "Windows: 192.168.1.20:9844"

    /// The saved store finished loading and holds nothing (`working == false`).
    static let emptySaved = ControlsInput.SavedState(message: noSavedConnection, working: false)
    /// A loaded v3 pairing.
    static let pairedSaved = ControlsInput.SavedState(
        message: pairedMessage, available: true, present: true, working: false, pairing: false, paired: true)
    /// A pairing poll in progress.
    static let pairingSaved = ControlsInput.SavedState(
        message: waitingMessage, available: false, present: false, working: true, pairing: true, paired: false)

    static let scoInput = MicrophoneSelection(kind: .sco, portUID: "hfp-headset")
    static let wiredInput = MicrophoneSelection(kind: .wired, portUID: "wired-headset")
    static let leInput = MicrophoneSelection(kind: .le, portUID: "le-headset")

    static let speakerPin = OutputSelection.restored(.phone)
    static let a2dp = OutputSelection(kind: .bluetooth, portType: "BluetoothA2DPOutput", uid: "a2dp-1")

    /// The cold screen after the saved store loaded: nothing retained, nothing pending.
    static func idle(_ configure: (inout ControlsInput) -> Void = { _ in }) -> ControlsInput {
        var input = ControlsInput(saved: emptySaved)
        configure(&input)
        return input
    }

    /// `ControlsDeriver.derive(idle(configure))`.
    static func derive(_ configure: (inout ControlsInput) -> Void = { _ in }) -> ControlsRender {
        ControlsDeriver.derive(idle(configure))
    }

    static func session(
        _ phase: SessionPhase, message: String = SessionView.readyMessage,
        destination: String = PresentationFixtures.destination, outputEnabled: Bool = true,
        outputSelection: OutputSelection = OutputSelection(), outputPause: OutputPause? = nil,
        networkStatus: String = ""
    ) -> SessionView {
        SessionView(
            phase: phase, message: message, destination: destination, outputEnabled: outputEnabled,
            outputSelection: outputSelection, outputPause: outputPause, networkStatus: networkStatus)
    }

    static func mic(
        _ phase: SessionPhase, mode: StreamMode = .microphone, muted: Bool = false, changing: Bool = false,
        input: MicrophoneSelection = MicrophoneSelection(), message: String = SessionView.readyMessage,
        outputSelection: OutputSelection = OutputSelection(), outputPause: OutputPause? = nil
    ) -> MicrophoneView {
        MicrophoneView(
            session: session(phase, message: message, outputSelection: outputSelection, outputPause: outputPause),
            muted: muted, changing: changing, mode: mode, input: input)
    }

    static let pairedHost = DiscoveredHost(host: "192.168.1.20", port: 9844, keyHint: pin)
    static let unknownHost = DiscoveredHost(host: "192.168.1.30", port: 9844, keyHint: otherPin)

    /// `LanInvitation.paired("10.0.0.20", 9845, pin, client)` (`DiscoveryRecordTest.kt:41`).
    static func savedLink() throws -> ConnectionLink {
        try ConnectionLink.paired(host: "10.0.0.20", port: 9845, hostKey: pin, clientKey: client)
    }
}
