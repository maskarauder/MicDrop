import Foundation
import MicDropCore
import XCTest

/// How the main screen renders devices restored from `RememberedAudioDevices` after a relaunch, and the iOS
/// version of D042's "Device missing?" help: the system picker row, its Stop captions and the dialog messages.
final class RememberedDeviceControlsTests: XCTestCase {
    private static let pin = PresentationFixtures.a2dp
    private static let usb = MicrophoneSelection(
        kind: .usb, portUID: "synthetic-usb", portType: MicrophoneKind.PortType.usbAudio)
    /// Every phase in which a retained session keeps a pinned output's picker off.
    private static let retainedPhases: [SessionPhase] = [
        .connecting, .playing, .recovering, .routeRecovering, .switching, .interrupted, .pausing, .paused,
    ]
    private static let choicePhases = SessionPhase.allCases.filter(\.acceptsOutputChoice)

    func testARestoredOutputThatIsNotTheRouteIsUnavailableAndKeepsTheSystemPicker() {
        let missing = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
            input.selectedOutput = Self.pin
            input.outputAvailable = false
        }
        XCTAssertFalse(missing.outputNeedsSelection, "the remembered pin is still the selection")
        XCTAssertEqual(
            missing.outputDeviceLabel, Strings.selectedOutput(OutputKind.bluetooth.label) + Strings.unavailableSuffix)
        XCTAssertTrue(missing.outputDeviceEnabled, "another output can be chosen explicitly")
        XCTAssertTrue(missing.systemOutputPickerEnabled, "the picker can make the remembered device the route")
        XCTAssertEqual(missing.systemOutputPickerCaption, Strings.routePickerUnavailablePinCaption)

        let returned = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
            input.selectedOutput = Self.pin
            input.outputAvailable = true
        }
        XCTAssertFalse(returned.outputNeedsSelection)
        XCTAssertEqual(returned.outputDeviceLabel, Strings.selectedOutput(OutputKind.bluetooth.label))
        XCTAssertTrue(
            returned.systemOutputPickerEnabled, "an idle pin keeps the picker without choosing iPhone media output")
        XCTAssertEqual(returned.systemOutputPickerCaption, Strings.routePickerIdlePinCaption)

        let following = PresentationFixtures.derive { input in input.outputAvailable = false }
        XCTAssertTrue(following.systemOutputPickerEnabled)
        XCTAssertNil(following.systemOutputPickerCaption)
    }

    func testAnIdlePinKeepsThePickerWithoutChangingTheSelection() {
        let pins: [(OutputSelection, OutputKind)] = [(Self.pin, .bluetooth), (PresentationFixtures.speakerPin, .phone)]
        for (pin, kind) in pins {
            for available in [true, false] {
                let render = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.prefs = AudioPreferences(preferredOutputKind: kind)
                    input.selectedOutput = pin
                    input.outputAvailable = available
                }
                let label = "\(kind) available=\(available)"
                XCTAssertTrue(render.idle, label)
                XCTAssertFalse(render.outputNeedsSelection, label)
                XCTAssertEqual(
                    render.outputDeviceLabel,
                    Strings.selectedOutput(kind.label) + (available ? "" : Strings.unavailableSuffix), label)
                XCTAssertTrue(render.systemOutputPickerEnabled, label)
                XCTAssertEqual(
                    render.systemOutputPickerCaption,
                    available ? Strings.routePickerIdlePinCaption : Strings.routePickerUnavailablePinCaption, label)
            }
        }
    }

    func testALiveSessionOrSetupKeepsThePickerOffForAPin() {
        for phase in Self.retainedPhases {
            for available in [true, false] {
                let playback = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
                    input.session = PresentationFixtures.session(phase, outputSelection: Self.pin)
                    input.selectedOutput = Self.pin
                    input.outputAvailable = available
                }
                let duplex = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
                    input.mic = PresentationFixtures.mic(phase, mode: .duplex, outputSelection: Self.pin)
                    input.selectedOutput = Self.pin
                    input.outputAvailable = available
                }
                let microphone = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
                    input.mic = PresentationFixtures.mic(phase, mode: .microphone, outputSelection: Self.pin)
                    input.selectedOutput = Self.pin
                    input.outputAvailable = available
                }
                for (name, render) in [("playback", playback), ("duplex", duplex), ("microphone", microphone)] {
                    let label = "\(name) \(phase) available=\(available)"
                    XCTAssertFalse(render.systemOutputPickerEnabled, label)
                    XCTAssertEqual(render.systemOutputPickerCaption, Strings.routePickerPinnedCaption, label)
                }
            }
        }

        let setups: [(String, (inout ControlsInput) -> Void)] = [
            ("pending Connect", { $0.pendingConnect = true }),
            ("pairing continuation", { $0.pairingIntentPending = true }),
            ("local output test", { $0.localProbeRunning = true }),
            ("saved connection loading", { $0.saved = ControlsInput.SavedState() }),
        ]
        for (name, configure) in setups {
            for available in [true, false] {
                let render = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
                    input.selectedOutput = Self.pin
                    input.outputAvailable = available
                    configure(&input)
                }
                let label = "\(name) available=\(available)"
                XCTAssertFalse(render.idle, label)
                XCTAssertFalse(render.systemOutputPickerEnabled, label)
                XCTAssertEqual(render.systemOutputPickerCaption, Strings.routePickerPinnedCaption, label)
            }
        }
    }

    func testABluetoothHeadsetMicrophoneSessionDisablesThePicker() {
        for phase in Self.choicePhases {
            for output in [OutputSelection(), Self.pin] {
                for mode in [StreamMode.duplex, .microphone] {
                    let render = PresentationFixtures.derive { input in
                        input.saved = PresentationFixtures.pairedSaved
                        input.mic = PresentationFixtures.mic(
                            phase, mode: mode, input: PresentationFixtures.scoInput, outputSelection: output)
                        input.selectedOutput = output
                    }
                    let label = "\(mode) \(phase) pinned=\(output.explicit)"
                    XCTAssertFalse(render.systemOutputPickerEnabled, label)
                    XCTAssertEqual(render.systemOutputPickerCaption, Strings.routePickerHeadsetCaption, label)
                }
            }
            let builtIn = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.mic = PresentationFixtures.mic(phase, mode: .duplex)
            }
            XCTAssertTrue(builtIn.systemOutputPickerEnabled, "built-in microphone duplex \(phase)")
            XCTAssertNil(builtIn.systemOutputPickerCaption, "built-in microphone duplex \(phase)")
        }
    }

    func testFollowingTheSystemRouteKeepsThePickerDuringASession() {
        XCTAssertTrue(Self.choicePhases.contains(.paused))
        for phase in Self.choicePhases {
            for output in [OutputSelection(), OutputSelection.fallbackSpeaker()] {
                let render = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.session = PresentationFixtures.session(phase, outputSelection: output)
                    input.selectedOutput = output
                }
                let label = "\(phase) temporarySpeaker=\(output.temporarySpeaker)"
                XCTAssertTrue(render.systemOutputPickerEnabled, label)
                XCTAssertNil(render.systemOutputPickerCaption, label)
            }
        }
    }

    func testTheOutputDialogExplainsMissingDevicesAndRepeatsTheStopCaption() {
        let base = Strings.outputDialogMessage
        XCTAssertEqual(PresentationFixtures.derive().outputDialogMessage, base, "idle, following iPhone media output")
        for available in [true, false] {
            let idlePin = PresentationFixtures.derive { input in
                input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
                input.selectedOutput = Self.pin
                input.outputAvailable = available
            }
            XCTAssertEqual(idlePin.outputDialogMessage, base, "idle pin, picker enabled (available=\(available))")
        }
        for phase in [SessionPhase.playing, .paused] {
            let playback = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.session = PresentationFixtures.session(phase, outputSelection: Self.pin)
                input.selectedOutput = Self.pin
            }
            XCTAssertEqual(
                playback.outputDialogMessage, base + "\n\n" + Strings.routePickerPinnedCaption, "playback \(phase)")
            let duplex = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.mic = PresentationFixtures.mic(phase, mode: .duplex, outputSelection: Self.pin)
                input.selectedOutput = Self.pin
            }
            XCTAssertEqual(
                duplex.outputDialogMessage, base + "\n\n" + Strings.routePickerPinnedCaption, "duplex \(phase)")
            let headset = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.mic = PresentationFixtures.mic(phase, mode: .duplex, input: PresentationFixtures.scoInput)
            }
            XCTAssertEqual(
                headset.outputDialogMessage, base + "\n\n" + Strings.routePickerHeadsetCaption, "headset \(phase)")
            let following = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.session = PresentationFixtures.session(phase)
            }
            XCTAssertEqual(following.outputDialogMessage, base, "following iPhone media output \(phase)")
        }
    }

    func testTheMicrophoneDialogShowsTheStopFooterWheneverBluetoothInputsAreHidden() {
        let footer = "\n" + Strings.microphoneDialogBluetoothFooter
        XCTAssertEqual(PresentationFixtures.derive().inputDialogMessage, Strings.microphoneDialogMessage, "idle")

        // A Paused playback session is idle for the menu, but the inventory hides HFP inputs while it is retained.
        let paused = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.session = PresentationFixtures.session(.paused)
        }
        XCTAssertTrue(paused.inputButtonEnabled, "a Paused playback session still offers the menu")
        XCTAssertEqual(paused.inputDialogMessage, Strings.microphoneDialogMessage + footer)
        let playing = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.session = PresentationFixtures.session(.playing)
        }
        XCTAssertEqual(playing.inputDialogMessage, Strings.microphoneDialogMessage + footer)

        for phase in [SessionPhase.playing, .paused] {
            for mode in [StreamMode.duplex, .microphone] {
                let headset = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.mic = PresentationFixtures.mic(phase, mode: mode, input: PresentationFixtures.scoInput)
                }
                XCTAssertEqual(headset.inputDialogMessage, Strings.microphoneDialogMessage, "headset \(mode) \(phase)")
                let builtIn = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.mic = PresentationFixtures.mic(phase, mode: mode)
                }
                XCTAssertEqual(
                    builtIn.inputDialogMessage, Strings.microphoneDialogMessage + footer, "built-in \(mode) \(phase)")
            }
        }
    }

    func testMissingDeviceTextsAreTheSpecifiedStrings() {
        XCTAssertEqual(
            Strings.outputDialogMessage,
            "iOS lets MicDrop list only outputs in the current iPhone route. If a connected device is missing, "
                + "make it the iPhone output with AirPlay & Bluetooth output…, then choose it here to remember it. "
                + "Your current MicDrop choice stays saved.")
        XCTAssertEqual(
            Strings.routePickerIdlePinCaption,
            "Your selected output stays saved. If a connected device is missing from Choose media output, "
                + "make it the iPhone output with the system picker, then choose it there.")
        XCTAssertEqual(
            Strings.routePickerPinnedCaption,
            "While a session or setup is in progress, a selected output ignores the system picker. "
                + "Tap Stop to use it; your choice stays saved. After choosing your device, tap Connect explicitly. "
                + "Microphone capture will not restart automatically.")
        XCTAssertEqual(
            Strings.routePickerHeadsetCaption,
            "The selected headset microphone owns the audio route, and the system picker would move it. "
                + "Tap Stop to use the picker, then tap Connect explicitly.")
        XCTAssertEqual(
            Strings.routePickerUnavailablePinCaption,
            "The selected output is not the current iPhone output. "
                + "Use the system picker to switch to it, or choose another media output.")
        XCTAssertEqual(
            Strings.microphoneDialogMessage,
            "Connect Bluetooth headsets in iOS Settings, then choose them here. "
                + "A media output does not necessarily support microphone input.")
        XCTAssertEqual(Strings.microphoneDialogBluetoothFooter, "Stop to choose a Bluetooth headset microphone.")
        XCTAssertTrue(PresentationFixtures.derive().inputDialogMessage.hasPrefix(Strings.microphoneDialogMessage))
    }

    func testAnExternalKindWithoutARestoredIdentityStillAsksForReselection() {
        let output = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(preferredOutputKind: .bluetooth)
            input.selectedOutput = OutputSelection()
        }
        XCTAssertTrue(output.outputNeedsSelection)
        XCTAssertEqual(output.outputDeviceLabel, Strings.chooseOutput)

        let input = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(microphoneEnabled: true, preferredInputKind: .usb)
            input.selectedMicrophone = MicrophoneSelection()
        }
        XCTAssertEqual(input.inputButtonLabel, Strings.microphoneInput)
        XCTAssertEqual(input.micToggleHelp, Strings.microphoneReselect)
    }

    func testARestoredInputThatIsMissingIsUnavailableAndImpliesNoConsent() {
        let missing = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(preferredInputKind: .usb)
            input.selectedMicrophone = Self.usb
            input.inputAvailable = false
        }
        XCTAssertEqual(
            missing.inputButtonLabel, Strings.selectedMicrophone(MicrophoneKind.usb.label) + Strings.unavailableSuffix)
        XCTAssertFalse(missing.micChecked, "a remembered input does not turn Send microphone on")
        XCTAssertEqual(missing.micToggleHelp, Strings.microphoneHelp)

        let returned = PresentationFixtures.derive { input in
            input.prefs = AudioPreferences(microphoneEnabled: true, preferredInputKind: .usb)
            input.selectedMicrophone = Self.usb
            input.inputAvailable = true
        }
        XCTAssertEqual(returned.inputButtonLabel, Strings.selectedMicrophone(MicrophoneKind.usb.label))
        XCTAssertEqual(returned.micToggleHelp, Strings.microphoneHelp, "no reselection for the same device")
    }
}
