import AVFoundation
import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Remembered input/output devices across launches: `audio-devices.json` next to the kinds in the protected preferences
/// directory, built from the SDK port constants. Synthetic uids; no audio session state.
final class RememberedAudioDevicesStoreTests: XCTestCase {
    static let uid = "A1:B2:C3:D4:E5:F6-synthetic"
    static let pin = OutputSelection(
        kind: .bluetooth, portType: AVAudioSession.Port.bluetoothA2DP.rawValue, uid: uid)
    static let headsetPort = AudioPortDescriptor(
        uid: uid, type: AVAudioSession.Port.bluetoothHFP.rawValue, isInput: true, name: "Synthetic Headset")
    static let usbPort = AudioPortDescriptor(
        uid: "synthetic-usb", type: AVAudioSession.Port.usbAudio.rawValue, isInput: true, name: "Synthetic USB")
    static let builtInPort = AudioPortDescriptor(
        uid: "synthetic-built-in", type: AVAudioSession.Port.builtInMic.rawValue, isInput: true)

    static func temporaryDirectory(_ test: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func text(_ directory: URL, _ name: String) throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent(name)), as: UTF8.self)
    }

    func testRelaunchRestoresTheRememberedDevicesFromLocalStorage() throws {
        let directory = try Self.temporaryDirectory(self)
        let headset = try XCTUnwrap(MicrophoneSelection(port: Self.headsetPort))
        let store = AudioPreferencesStore(directory: directory)
        store.rememberOutput(Self.pin)
        store.rememberInput(headset)

        let relaunched = AudioPreferencesStore(directory: directory)
        XCTAssertEqual(relaunched.restoredOutputSelection(), Self.pin)
        XCTAssertEqual(relaunched.restoredMicrophoneSelection(), headset)
        let preferences = relaunched.load()
        XCTAssertEqual(preferences.preferredOutputKind, .bluetooth)
        XCTAssertEqual(preferences.preferredInputKind, .sco)
        XCTAssertFalse(preferences.microphoneEnabled, "remembering an input is not microphone consent")
        XCTAssertFalse(preferences.needsOutputSelection(relaunched.restoredOutputSelection()))

        let devices = try text(directory, RememberedAudioDevices.fileName)
        XCTAssertTrue(devices.contains(Self.uid), "the identity is kept in the local device file")
        XCTAssertFalse(devices.contains("Synthetic Headset"), "port names are not stored")
        let settings = try text(directory, AudioPreferences.fileName)
        XCTAssertFalse(settings.contains(Self.uid), "the settings keep kinds only")
    }

    /// Only Windows edits (phone settings exchange v1) change `selectionGeneration`, so the idle rows re-read the
    /// saved selections after one and otherwise keep idle-only state such as the temporary speaker. They save
    /// exactly what a local choice saves, so the next Connect and a new process restore them.
    func testOnlyWindowsSelectionsAdvanceTheSelectionGeneration() throws {
        let directory = try Self.temporaryDirectory(self)
        let store = AudioPreferencesStore(directory: directory)
        XCTAssertEqual(store.selectionGeneration, 0)
        store.rememberOutput(Self.pin)
        store.rememberInput(try XCTUnwrap(MicrophoneSelection(port: Self.usbPort)))
        store.rememberOutput(OutputSelection.fallbackSpeaker())
        XCTAssertEqual(store.selectionGeneration, 0, "local choices and verified session routes")

        let headset = try XCTUnwrap(MicrophoneSelection(port: Self.headsetPort))
        store.saveInputForNextConnection(headset)
        XCTAssertEqual(store.selectionGeneration, 1)
        XCTAssertEqual(store.restoredMicrophoneSelection(), headset)
        store.saveOutputForNextConnection(Self.pin)
        XCTAssertEqual(store.selectionGeneration, 2)
        XCTAssertEqual(store.restoredOutputSelection(), Self.pin)

        let relaunched = AudioPreferencesStore(directory: directory)
        XCTAssertEqual(relaunched.restoredMicrophoneSelection(), headset, "persisted like a local choice")
        XCTAssertEqual(relaunched.restoredOutputSelection(), Self.pin)
        XCTAssertEqual(relaunched.load().preferredOutputKind, .bluetooth)
        XCTAssertEqual(relaunched.selectionGeneration, 0, "process memory only")
    }

    /// `MainViewModel.windowsSelectionAdoption` (PSC change 10): the idle rows keep their selections, the temporary
    /// speaker included, while Windows saved nothing new or something still uses them (a retained session or a
    /// pending setup), and after Stop they adopt exactly the selections the next Connect restores, once.
    @MainActor
    func testTheIdleRowsAdoptWindowsSelectionsOnlyAfterTheSessionAndOnce() throws {
        let directory = try Self.temporaryDirectory(self)
        let store = AudioPreferencesStore(directory: directory)
        let adopted = store.selectionGeneration
        store.rememberOutput(OutputSelection.fallbackSpeaker())
        XCTAssertNil(
            MainViewModel.windowsSelectionAdoption(idle: true, adopted: adopted, settings: store),
            "Windows changed nothing: an idle temporary speaker is kept")

        let usb = try XCTUnwrap(MicrophoneSelection(port: Self.usbPort))
        store.saveInputForNextConnection(usb)
        store.saveOutputForNextConnection(Self.pin)
        XCTAssertNil(
            MainViewModel.windowsSelectionAdoption(idle: false, adopted: adopted, settings: store),
            "retained, or a setup is pending: the rows keep the session's selections")

        let adoption = try XCTUnwrap(
            MainViewModel.windowsSelectionAdoption(idle: true, adopted: adopted, settings: store))
        XCTAssertEqual(adoption.generation, store.selectionGeneration)
        XCTAssertEqual(adoption.output, Self.pin)
        XCTAssertEqual(adoption.output, store.restoredOutputSelection(), "what the next Connect uses")
        XCTAssertEqual(adoption.microphone, usb)
        XCTAssertEqual(adoption.microphone, store.restoredMicrophoneSelection())
        XCTAssertNil(
            MainViewModel.windowsSelectionAdoption(idle: true, adopted: adoption.generation, settings: store),
            "recorded once: later local choices are not overwritten again")
    }

    func testEveryOfferedSDKPortTypeWithADeviceIdentityCanBeRemembered() throws {
        let outputs: [(AVAudioSession.Port, OutputKind)] = [
            (.usbAudio, .usb), (.bluetoothA2DP, .bluetooth), (.bluetoothLE, .le),
            (.carAudio, .other), (.HDMI, .other), (.airPlay, .other), (.lineOut, .other),
        ]
        for (port, kind) in outputs {
            let selection = OutputSelection(kind: kind, portType: port.rawValue, uid: "synthetic-\(port.rawValue)")
            XCTAssertEqual(OutputKind.forPortType(port.rawValue), kind, port.rawValue)
            XCTAssertEqual(RememberedAudioDevices(output: selection).output, selection, port.rawValue)
        }
        // Wired headphones carry a port-wide uid (not one per device), so they ask for reselection after a relaunch.
        for port in [AVAudioSession.Port.builtInSpeaker, .builtInReceiver, .bluetoothHFP, .headphones] {
            let kind = OutputKind.forPortType(port.rawValue) ?? .other
            let selection = OutputSelection(kind: kind, portType: port.rawValue, uid: "synthetic")
            XCTAssertNil(RememberedAudioDevices(output: selection).output, port.rawValue)
        }
        XCTAssertEqual(OutputKind.forPortType(AVAudioSession.Port.headphones.rawValue), .wired)
        let inputs: [(AVAudioSession.Port, MicrophoneKind)] = [(.usbAudio, .usb), (.bluetoothHFP, .sco)]
        for (port, kind) in inputs {
            let selection = try XCTUnwrap(
                MicrophoneSelection(port: AudioPortDescriptor(uid: "synthetic", type: port.rawValue, isInput: true)))
            XCTAssertEqual(selection.kind, kind, port.rawValue)
            XCTAssertEqual(RememberedAudioDevices(input: selection).input, selection, port.rawValue)
        }
        let wiredPort = AudioPortDescriptor(
            uid: "synthetic", type: AVAudioSession.Port.headsetMic.rawValue, isInput: true)
        let wired = try XCTUnwrap(MicrophoneSelection(port: wiredPort))
        XCTAssertEqual(wired.kind, .wired)
        XCTAssertNil(RememberedAudioDevices(input: wired).input, "the wired headset microphone has a port-wide uid")
        XCTAssertNil(RememberedAudioDevices(input: MicrophoneSelection(port: Self.builtInPort)).input)
    }

    func testFollowingTheSystemOrTheBuiltInMicrophoneForgetsTheIdentity() throws {
        let directory = try Self.temporaryDirectory(self)
        let usb = try XCTUnwrap(MicrophoneSelection(port: Self.usbPort))
        let store = AudioPreferencesStore(directory: directory)
        store.rememberInput(usb)
        for selection in [OutputSelection(), OutputSelection.restored(.phone), OutputSelection.fallbackSpeaker()] {
            store.rememberOutput(Self.pin)
            store.rememberOutput(selection)
            let relaunched = AudioPreferencesStore(directory: directory)
            let expected = OutputSelection.restored(selection.preferenceKind)
            XCTAssertEqual(relaunched.restoredOutputSelection(), expected, "\(selection)")
            XCTAssertNil(relaunched.rememberedDevices().output, "\(selection)")
            XCTAssertEqual(relaunched.rememberedDevices().input, usb, "an output choice keeps the input")
        }
        store.rememberInput(MicrophoneSelection())
        let relaunched = AudioPreferencesStore(directory: directory)
        XCTAssertEqual(relaunched.restoredMicrophoneSelection(), MicrophoneSelection())
        XCTAssertTrue(relaunched.rememberedDevices().isEmpty)
        XCTAssertFalse(try text(directory, RememberedAudioDevices.fileName).contains(Self.uid))
    }

    func testAMismatchedOrCorruptedFileNeverRestoresAnotherDevice() throws {
        let directory = try Self.temporaryDirectory(self)
        let store = AudioPreferencesStore(directory: directory)
        store.rememberOutput(Self.pin)
        // The kind changed without its identity (an interrupted write): the kind alone asks for reselection.
        store.update { previous in
            var next = previous
            next.preferredOutputKind = .wired
            return next
        }
        let mismatched = AudioPreferencesStore(directory: directory)
        XCTAssertEqual(mismatched.restoredOutputSelection(), OutputSelection())
        XCTAssertTrue(mismatched.load().needsOutputSelection(mismatched.restoredOutputSelection()))

        store.update { previous in
            var next = previous
            next.preferredOutputKind = .bluetooth
            return next
        }
        let url = directory.appendingPathComponent(RememberedAudioDevices.fileName)
        let wrongProfile =
            "{\"outputKind\":\"BLUETOOTH\",\"outputPortType\":\"Headphones\",\"outputUID\":\"synthetic\"}"
        for contents in [wrongProfile, "not json", "[]"] {
            try Data(contents.utf8).write(to: url)
            let corrupted = AudioPreferencesStore(directory: directory)
            XCTAssertEqual(corrupted.restoredOutputSelection(), OutputSelection(), contents)
            XCTAssertTrue(corrupted.load().needsOutputSelection(corrupted.restoredOutputSelection()), contents)
        }
    }
}

/// A restored identity is matched against the current route by the app's output provider, input inventory and both
/// session controllers: missing, changed or duplicated identities stay unavailable, nothing is substituted, the same
/// device is used again, and a relaunch starts no audio, capture or consent.
final class RememberedDeviceRestoreTests: XCTestCase {
    private typealias Fixture = RememberedAudioDevicesStoreTests

    private static let headphones = RouteOutput(portType: Fixture.pin.portType, uid: Fixture.uid)
    private static let otherHeadphones = RouteOutput(portType: Fixture.pin.portType, uid: "synthetic-other")
    private static let speaker = RouteOutput(
        portType: AVAudioSession.Port.builtInSpeaker.rawValue, uid: "synthetic-speaker")

    private final class Clock: MonotonicClock, @unchecked Sendable {
        func nowMs() -> Int64 { 1_000 }
    }

    /// The current route as `AVAudioSession` would report it (`.playback`: the speaker cannot be forced).
    private final class Inspector: AudioRouteInspecting, @unchecked Sendable {
        let route = Locked<[RouteOutput]>([])
        func currentOutputs() -> [RouteOutputInfo] {
            route.value.map { RouteOutputInfo(output: $0, name: "Synthetic", channels: 2) }
        }
        var speakerOverrideSupported: Bool { false }
        func overrideToSpeaker() throws {}
        func clearSpeakerOverride() throws {}
    }

    private final class Permission: MicrophonePermissionProviding, @unchecked Sendable {
        let current = Locked(MicrophonePermissions.Status.granted)
        var status: MicrophonePermissions.Status { current.value }
        func request() async -> Bool { current.value == .granted }
    }

    @MainActor
    private final class Lease: MicrophoneSessionController.BackgroundLease {
        private(set) var isHeld = false
        func begin() { isHeld = true }
        func end() { isHeld = false }
    }

    private final class Receiver: StreamReceiving {
        init(_ callbacks: SessionCallbacks) {}
        func start() {}
        func close(_ reason: StopReason) {}
        func setOutputEnabled(_ enabled: Bool) {}
        func setOutputSelection(_ s: OutputSelection) {}
        func setOutputFocus(_ p: OutputPause?) {}
        func setMicrophoneMuted(_ muted: Bool) {}
        var microphoneMuteRequested: Bool { true }
        func matchesOutputSelection(_ s: OutputSelection) -> Bool { false }
        func matchesOutputState(pause: OutputPause?, protectedSpeaker: Bool) -> Bool { false }
        func mediaOutputBecomingNoisy() -> Bool { false }
        func outputSwitchPending() -> Bool { false }
        func expireBackgroundSetup() {}
    }

    /// What the fakes saw.
    @MainActor
    private final class Calls {
        var activations = 0
        var configurations: [SessionConfiguration] = []
        var inputs: [AudioPortDescriptor] = []
    }

    private struct Unexpected: Error {}

    private static func link() throws -> String {
        try ConnectionLink.paired(
            host: "192.168.1.2", port: 8443, hostKey: String(repeating: "ab", count: 32),
            clientKey: String(repeating: "cd", count: 32)
        ).pairedRecord()
    }

    @MainActor
    private static func outputs(_ inspector: Inspector) -> OutputChoices {
        OutputChoices(inspector: inspector, pinContext: { OutputChoices.PinContext(plan: .playback(), input: nil) })
    }

    @MainActor
    func testTheOutputProviderUsesARestoredPinOnlyWhileTheRouteResolvesIt() {
        let inspector = Inspector()
        let outputs = Self.outputs(inspector)
        let restored = RememberedAudioDevices(output: Fixture.pin).restoredOutput(preferredKind: .bluetooth)

        inspector.route.value = [Self.speaker]
        XCTAssertNil(outputs.refresh(restored), "missing: never the speaker instead")
        XCTAssertFalse(outputs.available(restored))
        inspector.route.value = [Self.otherHeadphones]
        XCTAssertNil(outputs.refresh(restored), "another device of the same kind is not substituted")
        XCTAssertFalse(outputs.choices().contains { $0.selection == restored })
        XCTAssertTrue(
            outputs.choices().contains { $0.selection.kind == .bluetooth }, "the other device can be chosen explicitly")
        inspector.route.value = [Self.headphones, Self.headphones]
        XCTAssertNil(outputs.refresh(restored), "a duplicated identity is ambiguous")
        inspector.route.value = [Self.headphones]
        XCTAssertEqual(outputs.refresh(restored), restored, "the same device is the route again")
        XCTAssertTrue(outputs.available(restored))
        XCTAssertTrue(outputs.choices().contains { $0.selection == restored })
    }

    func testTheInputInventoryUsesARestoredInputOnlyWhileItIsListed() throws {
        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))
        let restored = RememberedAudioDevices(input: headset).restoredInput(preferredKind: .sco)
        let otherHeadset = AudioPortDescriptor(
            uid: "synthetic-other", type: AVAudioSession.Port.bluetoothHFP.rawValue, isInput: true)
        let builtIn = Fixture.builtInPort
        for inputs in [[builtIn], [builtIn, otherHeadset], [Fixture.headsetPort, Fixture.headsetPort]] {
            XCTAssertEqual(
                MicrophoneInventory.availability(restored, inputs: inputs, bluetoothVisible: true), .unavailable)
            XCTAssertNil(MicrophoneInventory.refresh(restored, inputs: inputs, bluetoothVisible: true))
        }
        let present = [builtIn, Fixture.headsetPort]
        XCTAssertEqual(MicrophoneInventory.availability(restored, inputs: present, bluetoothVisible: true), .available)
        XCTAssertEqual(MicrophoneInventory.refresh(restored, inputs: present, bluetoothVisible: true), headset)
        // Without an HFP listing the route check at Connect decides, as for a fresh choice.
        XCTAssertEqual(MicrophoneInventory.availability(restored, inputs: [builtIn], bluetoothVisible: false), .unknown)

        let usb = try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))
        let restoredUSB = RememberedAudioDevices(input: usb).restoredInput(preferredKind: .usb)
        XCTAssertNil(
            MicrophoneInventory.refresh(restoredUSB, inputs: [builtIn], bluetoothVisible: true),
            "never the built-in microphone instead")
        XCTAssertEqual(
            MicrophoneInventory.refresh(restoredUSB, inputs: [builtIn, Fixture.usbPort], bluetoothVisible: true), usb)
        let choices = MicrophoneChoice.list(ports: [builtIn, Fixture.usbPort], includeBluetooth: true)
        XCTAssertTrue(choices.contains { $0.selection.sameDevice(restoredUSB) }, "the selector shows it as chosen")
    }

    /// D042 on iOS: a Paused playback session keeps the microphone menu, but the inventory reads only the current
    /// category and hides HFP inputs, so the dialog carries the Stop footer. After Stop the headset is listed.
    @MainActor
    func testARetainedPlaybackSessionHidesHeadsetInputsAndShowsTheStopFooter() throws {
        let retained = Locked(true)
        let ports = [Fixture.builtInPort, Fixture.headsetPort]
        let inventory = MicrophoneInventory(
            sources: MicrophoneInventory.Sources(
                currentInputs: { ports },
                currentCategoryListsBluetooth: { true },
                idleInputs: { retained.value ? nil : ports }))
        inventory.sessionState = { MicrophoneInventory.SessionState(retained: retained.value, microphoneInput: nil) }
        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))

        func render(_ phase: SessionPhase, choices: [MicrophoneChoice]) -> ControlsRender {
            ControlsDeriver.derive(
                ControlsInput(
                    session: SessionView(phase: phase),
                    saved: ControlsInput.SavedState(message: "", working: false), inputChoices: choices))
        }

        let paused = try inventory.choices()
        XCTAssertFalse(paused.contains { $0.selection.sameDevice(headset) }, "HFP inputs are hidden while retained")
        let pausedRender = render(.paused, choices: paused)
        XCTAssertTrue(pausedRender.inputButtonEnabled)
        XCTAssertTrue(
            pausedRender.inputDialogMessage.hasSuffix("\n" + Strings.microphoneDialogBluetoothFooter),
            pausedRender.inputDialogMessage)

        retained.value = false
        let stopped = try inventory.choices()
        XCTAssertTrue(stopped.contains { $0.selection.sameDevice(headset) }, "after Stop the headset is listed")
        XCTAssertEqual(render(.idle, choices: stopped).inputDialogMessage, Strings.microphoneDialogMessage)
    }

    @MainActor
    func testPlaybackRelaunchUsesARestoredPinOnlyWhenItsDeviceIsTheRoute() throws {
        let directory = try Fixture.temporaryDirectory(self)
        AudioPreferencesStore(directory: directory).rememberOutput(Fixture.pin)
        let inspector = Inspector()
        let outputs = Self.outputs(inspector)
        let calls = Calls()
        let clock = Clock()
        let lease = BackgroundExecutionLease.Backend(begin: { _, _ in 1 }, end: { _ in })
        let controller = PlaybackSessionController(
            dependencies: PlaybackSessionController.Dependencies(
                arbiter: AudioSessionArbiter(owner: AudioSessionOwner()),
                preferences: AudioPreferencesStore(directory: directory),
                pausedPlayback: PausedPlaybackStore(directory: directory),
                controlLog: ControlEventLog(clock: clock), clock: clock,
                makeReceiver: { configuration, callbacks in
                    calls.configurations.append(configuration)
                    return Receiver(callbacks)
                },
                outputAvailable: { outputs.available($0) }, outputRefresh: { outputs.refresh($0) },
                loadSavedLink: { nil }, rememberLink: { _ in },
                makeLease: { name, onExpire in
                    BackgroundExecutionLease(name: name, backend: lease, onExpire: onExpire)
                },
                prepareAudio: { plan, completion in
                    calls.activations += 1
                    completion(.success(AudioSessionArbiter.Activation(id: .max, plan: plan)))
                }))
        XCTAssertEqual(controller.view.outputSelection, Fixture.pin, "the remembered pin is restored")
        XCTAssertEqual(calls.activations, 0, "a relaunch starts no audio")

        let link = try Self.link()
        inspector.route.value = [Self.speaker]
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: false, outputEnabled: true,
            outputSelection: controller.view.outputSelection)
        XCTAssertEqual(controller.view.phase, .ended)
        XCTAssertEqual(controller.view.message, SessionLifecycle.Messages.outputReselect)
        XCTAssertEqual(calls.activations, 0, "a missing device never activates audio or plays elsewhere")
        XCTAssertTrue(calls.configurations.isEmpty)

        inspector.route.value = [Self.headphones]
        controller.connect(
            text: link, fastRecovery: true, baseline: nil, reconnect: false, outputEnabled: true,
            outputSelection: controller.view.outputSelection)
        XCTAssertEqual(calls.activations, 1)
        XCTAssertEqual(calls.configurations.last?.outputSelection, Fixture.pin, "the same device is used again")
        controller.stop()
    }

    @MainActor
    func testMicrophoneRelaunchRestoresWithoutCaptureOrConsent() throws {
        let directory = try Fixture.temporaryDirectory(self)
        let usb = try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))
        let saved = AudioPreferencesStore(directory: directory)
        saved.rememberOutput(Fixture.pin)
        saved.rememberInput(usb)

        let store = AudioPreferencesStore(directory: directory)
        let inspector = Inspector()
        let outputs = Self.outputs(inspector)
        let calls = Calls()
        let permission = Permission()
        let controller = MicrophoneSessionController(
            dependencies: MicrophoneSessionController.Dependencies(
                clock: Clock(), permission: permission,
                inputAvailable: { selection in
                    MicrophoneInventory.availability(selection, inputs: calls.inputs, bluetoothVisible: true)
                        != .unavailable
                },
                outputAvailable: { selection, _ in outputs.available(selection) },
                refreshOutput: { selection, _ in outputs.refresh(selection) },
                loadPreferences: { store.load() },
                updatePreferences: { change in _ = store.update(change) },
                activateAudio: { _, _ in calls.activations += 1 },
                deactivateAudio: {},
                makeReceiver: { _, _ in throw Unexpected() },
                rememberConnection: { _ in },
                makeLease: { _ in Lease() },
                observesApplicationState: false,
                restoredOutput: { store.restoredOutputSelection() },
                rememberOutput: { _ = store.rememberOutput($0) },
                rememberInput: { _ = store.rememberInput($0) }))
        XCTAssertEqual(controller.view.session.outputSelection, Fixture.pin)
        XCTAssertFalse(controller.view.ownsSession)
        XCTAssertEqual(calls.activations, 0, "a relaunch starts no capture")
        let input = store.restoredMicrophoneSelection()
        XCTAssertEqual(input, usb)
        XCTAssertFalse(store.load().microphoneEnabled)

        let link = try Self.link()
        func connect() throws {
            try controller.connect(
                text: link, mode: .microphone, input: input, outputEnabled: false, fastRecovery: true,
                outputSelection: controller.view.session.outputSelection)
        }
        calls.inputs = [Fixture.builtInPort]
        XCTAssertThrowsError(try connect()) { error in
            XCTAssertEqual(error as? MicrophoneRouteError, MicrophoneRouteError(.unavailable))
        }
        calls.inputs = [Fixture.builtInPort, Fixture.usbPort, Fixture.usbPort]
        XCTAssertThrowsError(try connect(), "a duplicated identity is ambiguous")
        calls.inputs = [Fixture.builtInPort, Fixture.usbPort]
        permission.current.value = .denied
        XCTAssertThrowsError(try connect()) { error in
            XCTAssertEqual(
                error as? MicrophoneSessionController.PreflightError, .permissionDenied,
                "a remembered input is not permission")
        }
        XCTAssertEqual(calls.activations, 0)
        XCTAssertFalse(controller.view.ownsSession)

        permission.current.value = .granted
        try connect()
        XCTAssertEqual(calls.activations, 1, "the same device is used after an explicit Connect")
        XCTAssertEqual(controller.view.input, usb)
        controller.stop()
    }
}
