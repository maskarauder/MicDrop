import Foundation
import MicDropCore
import XCTest

@testable import MicDrop

/// Temporary preference stores, fixed device lists, a recording controller binding and a session wait for one
/// `PhoneControlAdapter`. No audio session, route change or native media is involved; uids are synthetic.
final class PhoneControlFixture: @unchecked Sendable {
    final class Clock: MonotonicClock, @unchecked Sendable {
        let time = Locked<Int64>(1_000)
        func nowMs() -> Int64 { time.value }
        func advance(_ milliseconds: Int64) { time.withLock { $0 += milliseconds } }
    }

    struct Refused: Error {}

    static let builtInPort = AudioPortDescriptor(
        uid: "synthetic-built-in", type: MicrophoneKind.PortType.builtInMic, isInput: true)
    static let usbPort = AudioPortDescriptor(
        uid: "synthetic-usb-uid", type: MicrophoneKind.PortType.usbAudio, isInput: true, name: "Synthetic USB")
    static let headsetPort = AudioPortDescriptor(
        uid: "A1:B2:C3:D4:E5:F6-synthetic", type: MicrophoneKind.PortType.bluetoothHFP, isInput: true,
        name: "Synthetic Headset")
    static let wiredPort = AudioPortDescriptor(
        uid: "synthetic-wired-uid", type: MicrophoneKind.PortType.headsetMic, isInput: true, name: "Synthetic Wired")
    static let speaker = RouteOutput(portType: RouteOutput.PortType.builtInSpeaker, uid: "synthetic-speaker")
    static let headphones = RouteOutput(portType: RouteOutput.PortType.headphones, uid: "synthetic-headphones")
    static let bluetooth = RouteOutput(
        portType: RouteOutput.PortType.bluetoothA2DP, uid: "11:22:33:44:55:66-synthetic")
    static let bluetoothPin = OutputSelection(kind: .bluetooth, portType: bluetooth.portType, uid: bluetooth.uid)
    static let wiredOutput = OutputSelection(kind: .wired, portType: headphones.portType, uid: headphones.uid)

    /// The live settings each controller reports (`phoneLiveSettings`): playback, duplex with a USB microphone,
    /// duplex with a Bluetooth headset microphone, and microphone-only.
    static let playback = PhoneLiveSettings(outputEnabled: true, output: OutputSelection(), outputAppliesLive: true)
    static let duplex = PhoneLiveSettings(
        outputEnabled: true, microphoneMuted: false, output: OutputSelection(), outputAppliesLive: true)
    static let headsetDuplex = PhoneLiveSettings(
        outputEnabled: true, microphoneMuted: false, output: OutputSelection(), outputAppliesLive: false)
    static let microphoneOnly = PhoneLiveSettings(microphoneMuted: false)

    /// The temporary directory of every store file.
    let directory: URL
    let audio: AudioPreferencesStore
    let connection: ConnectionPreferencesStore
    let advanced: AdvancedAudioPreferencesStore
    let optIn: PhoneControlPreferenceStore
    let inventory: MicrophoneInventory

    /// `availableInputs` of the current category (nil: the query failed).
    let ports = Locked<[AudioPortDescriptor]?>([builtInPort, usbPort])
    let listsBluetooth = Locked(false)
    /// The retained microphone session's input (nil: a playback session).
    let microphoneInput = Locked<MicrophoneSelection?>(nil)
    let idleReads = Locked(0)
    /// `currentRoute.outputs`, and `OutputChoices.available` of the saved output.
    let route = Locked<[RouteOutput]>([speaker])
    let outputAvailable = Locked(false)

    /// A playback session following iPhone media output by default (a Windows output choice applies live).
    let live = Locked<PhoneLiveSettings?>(PhoneControlFixture.playback)
    let liveReads = Locked(0)
    let applied = Locked<[PhoneLiveSettings]>([])
    /// Replaces the default live apply (which sets the requested values).
    let applyOverride = Locked<(@Sendable (PhoneLiveSettings) throws -> Void)?>(nil)
    /// Every `applyOutput` call, in order.
    let appliedOutputs = Locked<[OutputSelection]>([])
    /// Replaces the default output apply (which makes the request the session's output).
    let applyOutputOverride = Locked<(@Sendable (OutputSelection) throws -> Void)?>(nil)
    let changes = Locked(0)
    /// Store writes in order: `audio`, `input`, `output`, `connection`, `advanced`.
    let writes = Locked<[String]>([])

    let clock = Clock()
    let closed = Locked(false)
    let wait: SessionWorkerWait
    let binding: PhoneControlBinding
    let environment: PhoneControlAdapter.Environment

    /// Production wiring (`AppEnvironment.phoneControlEnvironment`): Windows selections and Advanced audio edits are
    /// saved for the next connection, except an output choice for a session with an output, which reaches the binding's
    /// `applyOutput`. `keepAliveForNextConnection: false` models an Advanced store without the latch, which must not
    /// advertise `audio.keep_microphone_active`.
    @MainActor
    init(_ test: XCTestCase, keepAliveForNextConnection: Bool = true) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MicDropPhoneControl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audio = AudioPreferencesStore(directory: directory)
        let connection = ConnectionPreferencesStore(directory: directory)
        let advanced = AdvancedAudioPreferencesStore(directory: directory)
        let optIn = PhoneControlPreferenceStore(directory: directory)
        try optIn.setAllowWindows(true)
        self.directory = directory
        self.audio = audio
        self.connection = connection
        self.advanced = advanced
        self.optIn = optIn

        let ports = self.ports
        let listsBluetooth = self.listsBluetooth
        let microphoneInput = self.microphoneInput
        let idleReads = self.idleReads
        let inventory = MicrophoneInventory(
            sources: MicrophoneInventory.Sources(
                currentInputs: { ports.value },
                currentCategoryListsBluetooth: { listsBluetooth.value },
                idleInputs: {
                    idleReads.withLock { $0 += 1 }
                    return ports.value
                }))
        inventory.sessionState = {
            MicrophoneInventory.SessionState(retained: true, microphoneInput: microphoneInput.value)
        }
        self.inventory = inventory

        let closed = self.closed
        wait = SessionWorkerWait(isCancelled: { closed.value })

        let live = self.live
        let liveReads = self.liveReads
        let applied = self.applied
        let applyOverride = self.applyOverride
        let appliedOutputs = self.appliedOutputs
        let applyOutputOverride = self.applyOutputOverride
        let changes = self.changes
        binding = PhoneControlBinding(
            current: {
                liveReads.withLock { $0 += 1 }
                return live.value
            },
            apply: { requested in
                applied.withLock { $0.append(requested) }
                if let override = applyOverride.value {
                    try override(requested)
                    return
                }
                live.withLock { current in
                    if let enabled = requested.outputEnabled { current?.outputEnabled = enabled }
                    if let muted = requested.microphoneMuted { current?.microphoneMuted = muted }
                }
            },
            applyOutput: { requested in
                appliedOutputs.withLock { $0.append(requested) }
                if let override = applyOutputOverride.value {
                    try override(requested)
                    return
                }
                live.withLock { $0?.output = requested }
            },
            changed: { changes.withLock { $0 += 1 } })

        let writes = self.writes
        let route = self.route
        let outputAvailable = self.outputAvailable
        environment = PhoneControlAdapter.Environment(
            allowWindows: { optIn.allowWindows() },
            audio: { audio.load() },
            updateAudio: { change in
                writes.withLock { $0.append("audio") }
                _ = audio.update(change)
            },
            savedInput: { audio.restoredMicrophoneSelection() },
            savedOutput: { audio.restoredOutputSelection() },
            rememberInput: { selection in
                writes.withLock { $0.append("input") }
                audio.saveInputForNextConnection(selection)
            },
            rememberOutput: { selection in
                writes.withLock { $0.append("output") }
                audio.saveOutputForNextConnection(selection)
            },
            connection: { connection.load() },
            saveConnection: { preferences in
                writes.withLock { $0.append("connection") }
                try connection.save(preferences)
            },
            advanced: { advanced.load() },
            saveAdvanced: { preferences in
                writes.withLock { $0.append("advanced") }
                try advanced.saveForNextConnection(preferences)
            },
            keepAliveForNextConnection: keepAliveForNextConnection,
            inputs: { inventory.sessionChoices() },
            outputs: {
                OutputChoice.list(
                    route: route.value.map { (output: $0, name: "Synthetic output") }, speakerPinnable: false)
            },
            outputAvailable: { _ in outputAvailable.value })
    }

    /// `environment` replaces the fixture's (for example to force a saved selection the stores never restore);
    /// `binding` replaces the recording one (a real controller's, in the controller tests).
    func adapter(
        hopTimeoutMs: Int = PhoneControlAdapter.hopTimeoutMs, environment: PhoneControlAdapter.Environment? = nil,
        binding: PhoneControlBinding? = nil
    ) -> PhoneControlAdapter {
        let closed = self.closed
        return PhoneControlAdapter(
            binding: binding ?? self.binding, environment: environment ?? self.environment, wait: wait, clock: clock,
            hopTimeoutMs: hopTimeoutMs, closed: { closed.value })
    }

    /// Stop: the closed flag first, then the wait.
    func close() {
        closed.value = true
        wait.cancel()
    }

    /// A Windows command (`phonecontrol.Update`) against `base`.
    static func command(_ number: Int, base: String, _ changes: [(String, ControlJSON.Value)]) -> ControlJSON {
        ControlJSON(members: [
            ControlJSON.Member("id", .string(id(number))), ControlJSON.Member("base_revision", .string(base)),
            ControlJSON.Member("changes", .object(changes.map { ControlJSON.Member($0.0, $0.1) })),
        ])
    }

    /// 32 lowercase hex characters.
    static func id(_ number: Int) -> String {
        let hex = String(number, radix: 16)
        return String(repeating: "0", count: 32 - hex.count) + hex
    }
}

/// `AppPhoneControl` on the iPhone (D046): the advertised key table and mapping (`PhoneControlKeys`), enabled state,
/// choice tokens, de-duplication, the current-category input list, application with its re-checks, the omitted keys,
/// the session's live output and the worker's main-actor hop.
final class PhoneControlAdapterTests: XCTestCase {
    private typealias Fixture = PhoneControlFixture
    private typealias Key = PhoneControlAdapter.Key

    /// The Audio and Advanced keys of `PhoneControlKeys.advertised` (Android's keys, `AppPhoneControl.kt:96-136`, in
    /// order, without `audio.le_stereo` and `live.volume`; pinned against Android in `PhoneControlKeysTests`).
    private static let savedKeys = PhoneControlKeys.advertised.filter { $0.group != .live }.map(\.key)

    private static func field(_ snapshot: PhoneSettingsSnapshot, _ key: String) throws -> PhoneSetting {
        try XCTUnwrap(snapshot.settings.first { $0.key == key }, key)
    }

    /// Every field of `snapshot` has the group, kind and bounds of its `PhoneControlKeys.advertised` entry, and the
    /// fields keep that table's order (key parity).
    private static func assertMatchesTheKeyTable(
        _ snapshot: PhoneSettingsSnapshot, file: StaticString = #filePath, line: UInt = #line
    ) {
        let table = PhoneControlKeys.advertised
        let keys = snapshot.settings.map(\.key)
        XCTAssertEqual(keys, table.map(\.key).filter(keys.contains), "table order", file: file, line: line)
        for setting in snapshot.settings {
            guard let field = table.first(where: { $0.key == setting.key }) else {
                XCTFail("not in the key table: \(setting.key)", file: file, line: line)
                continue
            }
            XCTAssertEqual(setting.group, field.group, setting.key, file: file, line: line)
            XCTAssertEqual(setting.kind, field.kind, setting.key, file: file, line: line)
            XCTAssertEqual(setting.minimum, field.range?.lowerBound, setting.key, file: file, line: line)
            XCTAssertEqual(setting.maximum, field.range?.upperBound, setting.key, file: file, line: line)
        }
    }

    /// Runs `body` on a background thread (the session worker's role) while the main run loop keeps serving.
    private func onWorker<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Locked<Result<T, Error>?>(nil)
        let done = expectation(description: "worker")
        Thread {
            result.value = Result { try body() }
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result.value).get()
    }

    // MARK: - Key table

    @MainActor
    func testPlaybackSnapshotUsesAndroidKeysIPhoneLabelsAndNoVolumeOrLEStereo() throws {
        let fixture = try Fixture(self)
        let snapshot = fixture.adapter().current()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.settings.map(\.key), Self.savedKeys + ["live.output_enabled"])
        XCTAssertFalse(snapshot.settings.contains { $0.key.contains("volume") || $0.key == "audio.le_stereo" })
        XCTAssertNil(snapshot.hostValidationError())

        let labels = Dictionary(uniqueKeysWithValues: snapshot.settings.map { ($0.key, $0.label) })
        XCTAssertEqual(labels["audio.fast_recovery"], "Faster recovery after audio interruptions")
        XCTAssertEqual(labels["audio.echo_cancellation"], "Reduce microphone echo (experimental)")
        XCTAssertEqual(labels["audio.noise_reduction"], "Reduce microphone background noise")
        XCTAssertEqual(labels["audio.keep_microphone_active"], "Keep microphone active while muted in background")
        XCTAssertEqual(labels["audio.input"], "Microphone input")
        XCTAssertEqual(labels["audio.output"], "Media output")
        XCTAssertEqual(labels["advanced.initial_order"], "Initial connection order")
        XCTAssertEqual(labels["advanced.recovery_order"], "Recovery connection order")
        XCTAssertEqual(labels["advanced.max_restarts"], "Maximum ICE restarts per interruption")
        XCTAssertEqual(labels["advanced.lan_status"], "LAN status request (ms)")
        XCTAssertEqual(labels["advanced.recovery_answer"], "Recovery SDP / answer operation (ms)")
        XCTAssertEqual(labels["advanced.bluetooth_recovery"], "Bluetooth route recovery (ms)")
        XCTAssertEqual(labels["live.output_enabled"], "Audio output enabled")

        Self.assertMatchesTheKeyTable(snapshot)
        for setting in snapshot.settings {
            let live = setting.group == .live || setting.key == Key.output
            XCTAssertEqual(setting.effect, live ? .live : .nextConnection, setting.key)
        }
        let media = try Self.field(snapshot, Key.output)
        XCTAssertEqual(media.choices.map(\.label), ["iPhone media output", "iPhone speaker 1"])
        XCTAssertEqual(media.value.stringValue, media.choices.first?.value, "the session's output (E9)")
        let fast = try Self.field(snapshot, "audio.fast_recovery")
        XCTAssertEqual(fast.kind, .bool)
        XCTAssertEqual(fast.value, .bool(true))
        let order = try Self.field(snapshot, "advanced.initial_order")
        XCTAssertEqual(order.kind, .choice)
        XCTAssertEqual(order.value, .string("LAN_FIRST"))
        XCTAssertEqual(
            order.choices,
            [
                PhoneSetting.Choice(value: "LAN_FIRST", label: "LAN → rendezvous"),
                PhoneSetting.Choice(value: "RENDEZVOUS_FIRST", label: "Rendezvous → LAN"),
            ])
        XCTAssertEqual(try Self.field(snapshot, "advanced.recovery_order").value, .string("RENDEZVOUS_FIRST"))
        let restarts = try Self.field(snapshot, "advanced.max_restarts")
        XCTAssertEqual([restarts.minimum, restarts.maximum, restarts.value.intValue], [1, 10, 2])
        for timeout in ConnectionPreferences.Timeout.allCases {
            let setting = try Self.field(snapshot, Key.timeout(timeout))
            XCTAssertEqual(setting.kind, .int, setting.key)
            XCTAssertEqual(setting.minimum, timeout.limits.minimumMs, setting.key)
            XCTAssertEqual(setting.maximum, timeout.limits.maximumMs, setting.key)
            XCTAssertEqual(setting.value, .int(timeout.limits.defaultMs), setting.key)
        }
        let bluetooth = try Self.field(snapshot, "advanced.bluetooth_recovery")
        XCTAssertEqual([bluetooth.minimum, bluetooth.maximum, bluetooth.value.intValue], [5_000, 120_000, 20_000])
        let output = try Self.field(snapshot, "live.output_enabled")
        XCTAssertEqual(output.kind, .bool)
        XCTAssertEqual(output.value, .bool(true))
        XCTAssertEqual(fixture.idleReads.value, 0, "the snapshot never switched to the inventory category")
    }

    /// Microphone-only advertises only the mute field, duplex both, and a binding without a live session (pausing,
    /// stopping, superseded) none, which also disables Windows control.
    @MainActor
    func testEachModeAdvertisesOnlyItsLiveFields() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let cases: [(PhoneLiveSettings?, [String])] = [
            (PhoneLiveSettings(outputEnabled: true), ["live.output_enabled"]),
            (PhoneLiveSettings(microphoneMuted: false), ["live.microphone_muted"]),
            (
                PhoneLiveSettings(outputEnabled: false, microphoneMuted: true),
                ["live.output_enabled", "live.microphone_muted"]
            ),
            (PhoneLiveSettings(), []),
            (nil, []),
        ]
        for (live, keys) in cases {
            fixture.live.value = live
            let snapshot = adapter.current()
            XCTAssertEqual(snapshot.settings.map(\.key), Self.savedKeys + keys, String(describing: live))
            Self.assertMatchesTheKeyTable(snapshot)
            XCTAssertEqual(snapshot.enabled, live != nil, String(describing: live))
            XCTAssertNil(snapshot.hostValidationError(), String(describing: live))
            XCTAssertFalse(snapshot.settings.contains { $0.key.contains("volume") || $0.key == "audio.le_stereo" })
        }
        fixture.live.value = PhoneLiveSettings(microphoneMuted: true)
        let muted = try Self.field(adapter.current(), "live.microphone_muted")
        XCTAssertEqual([muted.label, muted.effect.rawValue], ["Microphone muted", "live"])
        XCTAssertEqual(muted.value, .bool(true))
    }

    /// `enabled` = a live session and the phone-local opt-in; flipping either changes the revision, so the next
    /// snapshot clears a pending Windows edit.
    @MainActor
    func testEnabledFollowsTheOptInAndTheBinding() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let on = adapter.current()
        XCTAssertTrue(on.enabled)
        try fixture.optIn.setAllowWindows(false)
        let off = adapter.current()
        XCTAssertFalse(off.enabled)
        XCTAssertNotEqual(off.revision, on.revision)
        try fixture.optIn.setAllowWindows(true)
        XCTAssertEqual(adapter.current().revision, on.revision)
        fixture.live.value = nil
        XCTAssertFalse(adapter.current().enabled)
    }

    /// `audio.keep_microphone_active` is offered only when Windows edits of it wait for the next connection: the edit
    /// reaches the file and `load()` (the next Connect, the Connection settings sheet), never the live value a running
    /// session reads, so Windows cannot start a muted background capture in this session.
    @MainActor
    func testKeepAliveIsAdvertisedOnlyWithTheNextConnectionLatch() throws {
        let unlatched = try Fixture(self, keepAliveForNextConnection: false)
        let adapter = unlatched.adapter()
        let snapshot = adapter.current()
        XCTAssertNil(snapshot.settings.first { $0.key == Key.keepMicrophoneActive })
        adapter.receiveOnMain(Fixture.command(1, base: snapshot.revision, [(Key.keepMicrophoneActive, .bool(false))]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.invalidValueText)
        XCTAssertTrue(unlatched.writes.value.isEmpty)

        let latched = try Fixture(self)
        let off = try AdvancedAudioPreferences(keepMicrophoneActiveWhileMuted: false)
        try latched.advanced.save(off)
        XCTAssertFalse(latched.advanced.liveKeepMicrophoneActive(), "a local Save applies at once")
        let next = latched.adapter()
        let offered = next.current()
        let keys = offered.settings.map(\.key)
        XCTAssertEqual(
            keys.firstIndex(of: Key.keepMicrophoneActive), keys.firstIndex(of: Key.noiseReduction).map { $0 + 1 })
        let field = try Self.field(offered, Key.keepMicrophoneActive)
        XCTAssertEqual(field.label, "Keep microphone active while muted in background")
        XCTAssertEqual(field.value, .bool(false))
        XCTAssertEqual(field.effect, .nextConnection)
        next.receiveOnMain(Fixture.command(1, base: offered.revision, [(Key.keepMicrophoneActive, .bool(true))]))
        XCTAssertEqual(next.acknowledgment?.status, .applied)
        XCTAssertEqual(next.acknowledgment?.message, PhoneControlSession.savedText)
        XCTAssertEqual(latched.writes.value, ["advanced"])
        XCTAssertTrue(latched.advanced.load().keepMicrophoneActiveWhileMuted, "saved for the next connection")
        XCTAssertTrue(
            AdvancedAudioPreferencesStore(directory: latched.directory).load().keepMicrophoneActiveWhileMuted,
            "written to the file")
        XCTAssertFalse(latched.advanced.liveKeepMicrophoneActive(), "the running session keeps its keep-alive")
        XCTAssertEqual(try Self.field(next.current(), Key.keepMicrophoneActive).value, .bool(true))
        XCTAssertTrue(latched.applied.value.isEmpty, "no live change")
        latched.advanced.reloadLive()
        XCTAssertTrue(latched.advanced.liveKeepMicrophoneActive(), "the next Connect uses it")
    }

    // MARK: - Choices

    /// Tokens are 64 hex characters, salted per session, distinct per device, and never contain the uid; the
    /// identity is the `sameDevice` / `sameEndpoint` fields only.
    @MainActor
    func testChoiceTokensAreOpaquePerDeviceAndPerSession() throws {
        let fixture = try Fixture(self)
        fixture.route.value = [Fixture.bluetooth]
        let first = try Self.field(fixture.adapter().current(), Key.input)
        let second = try Self.field(fixture.adapter().current(), Key.input)
        XCTAssertEqual(first.choices.map(\.label), ["Built-in phone microphone", "USB microphone 1 · Synthetic USB"])
        XCTAssertEqual(Set(first.choices.map(\.value)).count, 2, "one token per device")
        XCTAssertTrue(
            Set(first.choices.map(\.value)).isDisjoint(with: second.choices.map(\.value)), "salted per session")
        let outputs = try Self.field(fixture.adapter().current(), Key.output)
        for token in first.choices.map(\.value) + second.choices.map(\.value) + outputs.choices.map(\.value) {
            XCTAssertEqual(token.utf8.count, 64)
            XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) }, token)
            for uid in [Fixture.usbPort.uid, Fixture.bluetooth.uid, Fixture.builtInPort.uid] {
                XCTAssertFalse(token.contains(uid))
            }
        }
        XCTAssertEqual(first.value.stringValue, first.choices.first?.value, "the saved built-in microphone is listed")

        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))
        var unpinned = headset
        unpinned.headsetEndpoint = nil
        XCTAssertEqual(PhoneControlAdapter.identity(headset), PhoneControlAdapter.identity(unpinned))
        var other = headset
        other.portUID = "another-synthetic-uid"
        XCTAssertNotEqual(PhoneControlAdapter.identity(headset), PhoneControlAdapter.identity(other))
        XCTAssertNotEqual(
            PhoneControlAdapter.identity(MicrophoneSelection(kind: .usb, portUID: "", portType: nil)),
            PhoneControlAdapter.identity(MicrophoneSelection(kind: .usb, portUID: nil, portType: nil)))
        XCTAssertNotEqual(
            PhoneControlAdapter.identity(OutputSelection.fallbackSpeaker()),
            PhoneControlAdapter.identity(OutputSelection.restored(.phone)))
    }

    /// A saved headset that is listed in a Bluetooth microphone session appears once; when HFP inputs are hidden
    /// (any other session) it is "(saved)", a saved USB microphone that is not attached is "(saved; unavailable)",
    /// and in a microphone-only session, which has no output of its own, the saved output follows `available`.
    @MainActor
    func testSavedDevicesAreListedOnceOrMarkedSaved() throws {
        let fixture = try Fixture(self)
        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))
        fixture.audio.rememberInput(headset)
        fixture.ports.value = [Fixture.builtInPort, Fixture.headsetPort]
        fixture.microphoneInput.value = headset
        fixture.listsBluetooth.value = true
        let adapter = fixture.adapter()
        let listed = try Self.field(adapter.current(), Key.input)
        XCTAssertEqual(
            listed.choices.map(\.label),
            ["Built-in phone microphone", "Bluetooth SCO microphone 1 · Synthetic Headset"])
        XCTAssertEqual(listed.value.stringValue, listed.choices.last?.value)

        fixture.microphoneInput.value = nil
        let hidden = try Self.field(adapter.current(), Key.input)
        XCTAssertEqual(hidden.choices.map(\.label), ["Built-in phone microphone", "Bluetooth SCO microphone (saved)"])
        XCTAssertEqual(hidden.value.stringValue, hidden.choices.last?.value)

        fixture.audio.rememberInput(try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort)))
        let missing = try Self.field(adapter.current(), Key.input)
        XCTAssertEqual(missing.choices.last?.label, "USB microphone (saved; unavailable)")
        fixture.ports.value = nil
        let failed = try Self.field(adapter.current(), Key.input)
        XCTAssertEqual(
            failed.choices.map(\.label), ["Built-in phone microphone", "USB microphone (saved; unavailable)"],
            "a failed listing keeps the built-in row only")
        fixture.audio.rememberInput(.builtIn)
        let builtIn = try Self.field(adapter.current(), Key.input)
        XCTAssertEqual(builtIn.choices.map(\.label), ["Built-in phone microphone"], "never shown unavailable")

        fixture.live.value = Fixture.microphoneOnly
        fixture.audio.rememberOutput(Fixture.bluetoothPin)
        fixture.route.value = [Fixture.speaker]
        let unavailable = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(
            unavailable.choices.map(\.label),
            ["iPhone media output", "iPhone speaker 1", "Bluetooth media output (saved; unavailable)"])
        fixture.outputAvailable.value = true
        let available = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(available.choices.last?.label, "Bluetooth media output (saved)")
        fixture.route.value = [Fixture.bluetooth]
        let routed = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(
            routed.choices.map(\.label), ["iPhone media output", "Bluetooth media output 1 · Synthetic output"])
        XCTAssertEqual(routed.value.stringValue, routed.choices.last?.value)
        XCTAssertEqual(fixture.idleReads.value, 0)
    }

    /// Wired headphones and the wired headset microphone have only a port-wide uid on iOS and are never remembered,
    /// so the next Connect could not restore them: they are not offered, and a command naming one (forced here
    /// through the saved entry of a microphone-only session) is rejected before any write, so the saved selections
    /// and the idle rows keep theirs.
    @MainActor
    func testWiredDevicesAreNeitherOfferedNorSaved() throws {
        let fixture = try Fixture(self)
        fixture.ports.value = [Fixture.builtInPort, Fixture.wiredPort, Fixture.usbPort]
        fixture.route.value = [Fixture.headphones]
        XCTAssertTrue(fixture.environment.inputs().choices.contains { $0.selection.kind == .wired }, "iOS lists it")
        XCTAssertTrue(fixture.environment.outputs().contains { $0.selection.kind == .wired }, "the route has it")
        let snapshot = fixture.adapter().current()
        let input = try Self.field(snapshot, Key.input)
        XCTAssertEqual(input.choices.map(\.label), ["Built-in phone microphone", "USB microphone 1 · Synthetic USB"])
        XCTAssertEqual(try Self.field(snapshot, Key.output).choices.map(\.label), ["iPhone media output"])
        XCTAssertNil(snapshot.hostValidationError())

        let wiredInput = try XCTUnwrap(MicrophoneSelection(port: Fixture.wiredPort))
        let wiredOutput = OutputSelection(
            kind: .wired, portType: Fixture.headphones.portType, uid: Fixture.headphones.uid)
        XCTAssertFalse(PhoneControlAdapter.savable(wiredInput))
        XCTAssertFalse(PhoneControlAdapter.savable(wiredOutput))
        XCTAssertTrue(PhoneControlAdapter.savable(try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))))
        XCTAssertTrue(PhoneControlAdapter.savable(OutputSelection.restored(.phone)))
        XCTAssertFalse(PhoneControlAdapter.savable(OutputSelection.fallbackSpeaker()))
        fixture.live.value = Fixture.microphoneOnly
        var forced = fixture.environment
        forced.savedInput = { wiredInput }
        forced.savedOutput = { wiredOutput }
        let adapter = fixture.adapter(environment: forced)
        for (number, key) in [(1, Key.input), (2, Key.output)] {
            let current = adapter.current()
            let field = try Self.field(current, key)
            let token = try XCTUnwrap(field.value.stringValue)
            XCTAssertTrue(field.choices.contains { $0.value == token }, key)
            adapter.receiveOnMain(Fixture.command(number, base: current.revision, [(key, .string(token))]))
            XCTAssertEqual(adapter.acknowledgment?.status, .rejected, key)
            XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText, key)
        }
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertTrue(fixture.appliedOutputs.value.isEmpty)
        XCTAssertEqual(fixture.audio.selectionGeneration, 0)
        XCTAssertEqual(fixture.audio.load(), AudioPreferences())
    }

    /// Device labels lose control characters, fit 160 UTF-8 bytes on a scalar boundary and never come out blank;
    /// at most 31 listed devices plus the saved entry, and every snapshot passes the host rules.
    @MainActor
    func testDeviceListsStayWithinTheHostRules() throws {
        let fixture = try Fixture(self)
        let long = String(repeating: "é", count: 200)
        fixture.ports.value =
            [Fixture.builtInPort]
            + (0..<40).map {
                AudioPortDescriptor(
                    uid: "synthetic-usb-\($0)", type: MicrophoneKind.PortType.usbAudio, isInput: true,
                    name: "Mic\u{0007}\n\($0) \(long)")
            }
        fixture.audio.rememberInput(
            MicrophoneSelection(kind: .usb, portUID: "synthetic-missing", portType: MicrophoneKind.PortType.usbAudio))
        fixture.live.value = PhoneLiveSettings(outputEnabled: true, microphoneMuted: false)
        let snapshot = fixture.adapter().current()
        let input = try Self.field(snapshot, Key.input)
        XCTAssertEqual(input.choices.count, 32)
        XCTAssertEqual(input.choices.last?.label, "USB microphone (saved; unavailable)")
        for choice in input.choices {
            XCTAssertLessThanOrEqual(choice.label.utf8.count, 160)
            XCTAssertFalse(choice.label.unicodeScalars.contains { $0.value < 0x20 })
        }
        XCTAssertNil(snapshot.hostValidationError())
        XCTAssertEqual(PhoneControl.label("\u{0001}\u{0002}  "), "Audio device")
    }

    // MARK: - Inputs

    /// in a playback-only session (retained, no microphone input; `MicDropApp.swift:106-111`): `audio.input` lists only
    /// what iOS reports under the playback category plus the saved entry, and MicDrop never switches to the temporary
    /// inventory category to fill it. Whatever iOS reports (a failed query, nothing, only the built-in port, or every
    /// kind attached), **Built-in phone microphone** comes first; a reported USB microphone follows; a reported wired
    /// input and a Bluetooth headset input (hidden outside a Bluetooth microphone session, even when the category lists
    /// HFP) are not offered. The saved entry is added once when it is not listed: a headset that cannot be inspected is
    /// "(saved)", a USB microphone iOS does not report is "(saved; unavailable)", and after a failed query every saved
    /// input but the built-in one is unavailable. A saved wired microphone restores as the built-in one (it is never
    /// remembered), so it adds nothing.
    @MainActor
    func testPlaybackOnlyInputListShowsOnlyReportedInputsAndTheSavedEntry() throws {
        let fixture = try Fixture(self)
        XCTAssertEqual(fixture.live.value, Fixture.playback)
        XCTAssertNil(fixture.microphoneInput.value, "a playback session has no microphone input")
        fixture.listsBluetooth.value = true
        let adapter = fixture.adapter()
        let builtIn = MicrophoneChoice.builtInTitle
        let usbTitle = "USB microphone 1 · Synthetic USB"
        let usb = try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))
        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))
        let wired = try XCTUnwrap(MicrophoneSelection(port: Fixture.wiredPort))
        let listings: [(String, [AudioPortDescriptor]?, [String])] = [
            ("a failed query", nil, [builtIn]), ("no input reported", [], [builtIn]),
            ("the built-in port only", [Fixture.builtInPort], [builtIn]),
            (
                "every kind reported", [Fixture.builtInPort, Fixture.wiredPort, Fixture.usbPort, Fixture.headsetPort],
                [builtIn, usbTitle]
            ),
        ]
        for (listing, ports, listed) in listings {
            fixture.ports.value = ports
            let usbEntry = listed.contains(usbTitle) ? nil : "USB microphone (saved; unavailable)"
            let headsetEntry = "Bluetooth SCO microphone" + (ports == nil ? " (saved; unavailable)" : " (saved)")
            // (saved selection, its entry when not listed, the label of the field's value)
            let saved: [(String, MicrophoneSelection, String?, String)] = [
                ("built-in", .builtIn, nil, builtIn), ("USB", usb, usbEntry, usbEntry ?? usbTitle),
                ("headset", headset, headsetEntry, headsetEntry), ("wired", wired, nil, builtIn),
            ]
            for (name, selection, entry, value) in saved {
                fixture.audio.rememberInput(selection)
                let snapshot = adapter.current()
                let field = try Self.field(snapshot, Key.input)
                XCTAssertEqual(field.choices.map(\.label), listed + [entry].compactMap { $0 }, "\(listing), \(name)")
                XCTAssertEqual(
                    field.choices.first { $0.value == field.value.stringValue }?.label, value, "\(listing), \(name)")
                XCTAssertEqual(field.effect, .nextConnection)
                XCTAssertNil(snapshot.hostValidationError(), "\(listing), \(name)")
            }
        }
        XCTAssertEqual(fixture.idleReads.value, 0, "the inventory category was never used")
    }

    /// `MicrophoneInventory.sessionChoices()`, the source of every `audio.input` snapshot, reads only the current
    /// category's inputs in every session state: idle, a playback session, a USB microphone session and a Bluetooth
    /// headset microphone session never call `idleInputs()`, which would switch the audio session to the temporary
    /// inventory category and could reroute live audio. Headset inputs appear only in a Bluetooth microphone session
    /// whose category lists them. The phone's own idle selector does read the inventory category, which shows that the
    /// counter counts.
    @MainActor
    func testSessionChoicesNeverReadTheInventoryCategory() throws {
        let fixture = try Fixture(self)
        fixture.ports.value = [Fixture.builtInPort, Fixture.usbPort, Fixture.headsetPort]
        fixture.listsBluetooth.value = true
        let usb = try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))
        let headset = try XCTUnwrap(MicrophoneSelection(port: Fixture.headsetPort))
        let direct = [MicrophoneChoice.builtInTitle, "USB microphone 1 · Synthetic USB"]
        let cases: [(String, MicrophoneInventory.SessionState, [String])] = [
            ("idle", .idle, direct),
            ("playback", MicrophoneInventory.SessionState(retained: true), direct),
            ("USB microphone", MicrophoneInventory.SessionState(retained: true, microphoneInput: usb), direct),
            (
                "Bluetooth headset microphone",
                MicrophoneInventory.SessionState(retained: true, microphoneInput: headset),
                direct + ["Bluetooth SCO microphone 1 · Synthetic Headset"]
            ),
        ]
        let adapter = fixture.adapter()
        for (name, state, titles) in cases {
            fixture.inventory.sessionState = { state }
            let listing = fixture.inventory.sessionChoices()
            XCTAssertEqual(listing.choices.map(\.title), titles, name)
            XCTAssertEqual(listing.bluetoothVisible, state.microphoneInput?.isBluetooth == true, name)
            XCTAssertEqual(listing.inputs, fixture.ports.value, name)
            _ = adapter.current()
            XCTAssertEqual(fixture.idleReads.value, 0, name)
        }
        fixture.inventory.sessionState = { .idle }
        _ = try fixture.inventory.choices()
        XCTAssertEqual(fixture.idleReads.value, 1, "the idle selector's listing uses it")
    }

    // MARK: - Snapshot cadence

    /// Unchanged snapshots are skipped for 5 s; a change or any command (even an unknown one) resends at once, the
    /// command with its acknowledgment.
    @MainActor
    func testSnapshotsAreDeduplicatedForFiveSecondsAndResentAfterACommand() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let first = try XCTUnwrap(adapter.snapshotOnMain())
        XCTAssertEqual(first["version"], .int(1))
        XCTAssertNil(first["ack"])
        XCTAssertNil(adapter.snapshotOnMain())
        fixture.clock.advance(4_999)
        XCTAssertNil(adapter.snapshotOnMain())
        fixture.clock.advance(1)
        XCTAssertEqual(adapter.snapshotOnMain(), first)
        _ = fixture.audio.update { previous in
            var next = previous
            next.noiseReduction = true
            return next
        }
        XCTAssertNotNil(adapter.snapshotOnMain(), "a local change is sent at once")
        XCTAssertNil(adapter.snapshotOnMain())

        let base = adapter.current().revision
        adapter.receiveOnMain(Fixture.command(7, base: base, [(Key.fastRecovery, .bool(false))]))
        let acknowledged = try XCTUnwrap(adapter.snapshotOnMain())
        XCTAssertEqual(acknowledged["ack"]?["id"], .string(Fixture.id(7)))
        XCTAssertEqual(acknowledged["ack"]?["status"], .string("applied"))
        XCTAssertEqual(acknowledged["enabled"], .bool(true))
        XCTAssertNil(adapter.snapshotOnMain())
        adapter.receiveOnMain(Fixture.command(7, base: base, [(Key.fastRecovery, .bool(false))]))
        XCTAssertEqual(adapter.snapshotOnMain()?["ack"]?["id"], .string(Fixture.id(7)), "a repeat resends the ack")
        XCTAssertEqual(fixture.writes.value, ["audio"], "and is never applied twice")
        XCTAssertEqual(fixture.changes.value, 2)
    }

    // MARK: - Apply

    /// Each key reaches its store (or the binding) and the acknowledgment names the effect. In the playback session the
    /// output choice goes to the controller (`applyOutput`, live) and nothing is saved here for the next connection;
    /// in a microphone-only session it is saved for the next connection.
    @MainActor
    func testWindowsEditsReachEachStoreWithTheMatchingAcknowledgment() throws {
        let fixture = try Fixture(self)
        fixture.route.value = [Fixture.bluetooth]
        let adapter = fixture.adapter()
        func send(_ number: Int, _ key: String, _ value: ControlJSON.Value) -> PhoneControlAck? {
            adapter.receiveOnMain(Fixture.command(number, base: adapter.current().revision, [(key, value)]))
            return adapter.acknowledgment
        }
        let saved = PhoneControlSession.savedText
        XCTAssertEqual(send(1, Key.echoCancellation, .bool(true))?.message, saved)
        XCTAssertTrue(fixture.audio.load().echoCancellation)
        XCTAssertEqual(send(2, Key.recoveryOrder, .string("LAN_FIRST"))?.message, saved)
        XCTAssertEqual(fixture.connection.load().recoveryOrder, .lanFirst)
        XCTAssertEqual(send(3, Key.timeout(.lanStatus), .int(3_000))?.message, saved)
        XCTAssertEqual(fixture.connection.load()[.lanStatus], 3_000)
        XCTAssertEqual(fixture.connection.load().recoveryOrder, .lanFirst, "the other connection values are kept")
        XCTAssertEqual(send(4, Key.maxRestarts, .int(10))?.message, saved)
        XCTAssertEqual(fixture.connection.load().maxRestarts, 10)
        XCTAssertEqual(send(5, Key.bluetoothRecovery, .int(30_000))?.message, saved)
        XCTAssertEqual(fixture.advanced.load().bluetoothRecoveryMs, 30_000)
        XCTAssertTrue(fixture.advanced.load().keepMicrophoneActiveWhileMuted, "the keep-alive is untouched")

        XCTAssertEqual(fixture.audio.selectionGeneration, 0, "no saved selection changed yet")
        let input = try Self.field(adapter.current(), Key.input)
        let usb = try XCTUnwrap(input.choices.first { $0.label.hasPrefix("USB microphone") })
        XCTAssertEqual(send(6, Key.input, .string(usb.value))?.message, saved)
        let usbSelection = try XCTUnwrap(MicrophoneSelection(port: Fixture.usbPort))
        XCTAssertTrue(fixture.audio.restoredMicrophoneSelection().sameDevice(usbSelection))
        XCTAssertEqual(fixture.audio.selectionGeneration, 1, "the idle rows adopt it after the session")
        let output = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(output.effect, .live)
        let bluetooth = try XCTUnwrap(output.choices.last)
        XCTAssertEqual(send(7, Key.output, .string(bluetooth.value))?.message, PhoneControlSession.liveText)
        XCTAssertEqual(fixture.appliedOutputs.value, [Fixture.bluetoothPin], "the controller's switch, once")
        XCTAssertEqual(fixture.audio.restoredOutputSelection(), OutputSelection(), "nothing saved by the adapter")
        XCTAssertEqual(fixture.audio.selectionGeneration, 1)
        XCTAssertEqual(try Self.field(adapter.current(), Key.output).value.stringValue, bluetooth.value)

        XCTAssertEqual(send(8, Key.outputEnabled, .bool(false))?.message, PhoneControlSession.liveText)
        XCTAssertEqual(fixture.applied.value, [PhoneLiveSettings(outputEnabled: false)])

        fixture.live.value = Fixture.microphoneOnly
        let next = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(next.effect, .nextConnection)
        let routed = try XCTUnwrap(next.choices.last)
        XCTAssertEqual(routed.label, "Bluetooth media output 1 · Synthetic output")
        XCTAssertEqual(send(9, Key.output, .string(routed.value))?.message, saved)
        XCTAssertEqual(fixture.audio.restoredOutputSelection().uid, Fixture.bluetooth.uid)
        XCTAssertEqual(fixture.audio.load().preferredOutputKind, .bluetooth)
        XCTAssertEqual(fixture.audio.selectionGeneration, 2, "the idle rows adopt it after the session")
        XCTAssertEqual(fixture.appliedOutputs.value.count, 1, "a microphone-only session has no output to switch")
        XCTAssertEqual(
            fixture.writes.value, ["audio", "connection", "connection", "connection", "advanced", "input", "output"])
        XCTAssertEqual(fixture.changes.value, 9, "the controller republishes after every command")
        XCTAssertNil(adapter.current().hostValidationError())
    }

    // MARK: - Output

    /// `audio.output` shows the session's output and is `live` where a Windows choice switches the running route
    /// (playback, duplex with a phone, wired or USB microphone); a Bluetooth headset microphone keeps it for a later
    /// input switch and microphone-only saves it, both `next_connection`, the latter with the saved output as its
    /// value. Flipping the effect changes the revision, so a stale Windows editor reloads.
    @MainActor
    func testTheOutputFieldFollowsTheSessionsOutputAndRoute() throws {
        let fixture = try Fixture(self)
        fixture.audio.rememberOutput(Fixture.bluetoothPin)
        fixture.route.value = [Fixture.speaker, Fixture.bluetooth]
        let adapter = fixture.adapter()
        let cases: [(PhoneLiveSettings, PhoneSetting.Effect, String)] = [
            (Fixture.playback, .live, "iPhone media output"), (Fixture.duplex, .live, "iPhone media output"),
            (Fixture.headsetDuplex, .nextConnection, "iPhone media output"),
            (Fixture.microphoneOnly, .nextConnection, "Bluetooth media output 1 · Synthetic output"),
        ]
        var revisions: [String] = []
        for (live, effect, valueLabel) in cases {
            fixture.live.value = live
            let snapshot = adapter.current()
            let field = try Self.field(snapshot, Key.output)
            XCTAssertEqual(field.effect, effect, String(describing: live))
            XCTAssertEqual(
                field.choices.map(\.label), ["iPhone media output", "Bluetooth media output 1 · Synthetic output"],
                "no iPhone speaker while it cannot be pinned (F4)")
            XCTAssertEqual(
                field.choices.first { $0.value == field.value.stringValue }?.label, valueLabel,
                String(describing: live))
            XCTAssertNil(snapshot.hostValidationError(), String(describing: live))
            revisions.append(snapshot.revision)
        }
        XCTAssertNotEqual(revisions[1], revisions[2], "duplex to a headset microphone: the effect flips")

        fixture.live.value = PhoneLiveSettings(
            outputEnabled: true, output: Fixture.bluetoothPin, outputAppliesLive: true)
        let pinned = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(pinned.choices.last?.value, pinned.value.stringValue, "the session's pin is the value")
        fixture.route.value = [Fixture.speaker]
        let recovering = try Self.field(adapter.current(), Key.output)
        XCTAssertEqual(
            recovering.choices.map(\.label),
            ["iPhone media output", "iPhone speaker 1", "Bluetooth media output (saved; unavailable)"],
            "a pin the route lost (recovery) is still the session's value")
        XCTAssertEqual(recovering.choices.last?.value, recovering.value.stringValue)
        XCTAssertEqual(fixture.idleReads.value, 0)
    }

    /// A Windows output choice for a session with an output reaches the controller exactly once (a repeated command
    /// ID is answered from the history) and writes nothing for the next connection here: the controller saves it like
    /// a local choice. A Bluetooth headset duplex session hands it to its controller as well, acknowledged as saved.
    @MainActor
    func testALiveOutputChoiceUsesTheControllerOnceAndSavesNothingHere() throws {
        let fixture = try Fixture(self)
        fixture.route.value = [Fixture.speaker, Fixture.bluetooth]
        let adapter = fixture.adapter()
        let base = adapter.current()
        let bluetooth = try XCTUnwrap(try Self.field(base, Key.output).choices.last)
        let command = Fixture.command(1, base: base.revision, [(Key.output, .string(bluetooth.value))])
        adapter.receiveOnMain(command)
        XCTAssertEqual(adapter.acknowledgment?.status, .applied)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.liveText)
        adapter.receiveOnMain(command)
        XCTAssertEqual(adapter.acknowledgment?.id, Fixture.id(1))
        XCTAssertEqual(fixture.appliedOutputs.value, [Fixture.bluetoothPin], "never applied twice")
        XCTAssertTrue(fixture.applied.value.isEmpty, "mute and Play desktop audio untouched")
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertEqual(fixture.audio.selectionGeneration, 0)

        fixture.live.value = Fixture.headsetDuplex
        let held = adapter.current()
        let media = try XCTUnwrap(try Self.field(held, Key.output).choices.first)
        adapter.receiveOnMain(Fixture.command(2, base: held.revision, [(Key.output, .string(media.value))]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.savedText)
        XCTAssertEqual(fixture.appliedOutputs.value, [Fixture.bluetoothPin, OutputSelection()])
        XCTAssertTrue(fixture.writes.value.isEmpty, "the controller keeps it for a later non-Bluetooth input")
    }

    /// A controller that refuses the output (CONNECTING, SWITCHING, a route refresh that fails) rejects the command
    /// and nothing of it is written; a session that ends during the live keys never reaches the output.
    @MainActor
    func testARefusedOutputChoiceIsRejectedAndWritesNothing() throws {
        let fixture = try Fixture(self)
        fixture.route.value = [Fixture.bluetooth]
        let adapter = fixture.adapter()
        let token = try XCTUnwrap(try Self.field(adapter.current(), Key.output).choices.last).value
        fixture.applyOutputOverride.value = { _ in throw Fixture.Refused() }
        adapter.receiveOnMain(
            Fixture.command(
                1, base: adapter.current().revision, [(Key.fastRecovery, .bool(false)), (Key.output, .string(token))]))
        XCTAssertEqual(adapter.acknowledgment?.status, .rejected)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText)
        XCTAssertEqual(fixture.appliedOutputs.value.count, 1)
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertTrue(fixture.audio.load().fastRecovery)

        let live = fixture.live
        fixture.applyOverride.value = { _ in live.value = nil }
        adapter.receiveOnMain(
            Fixture.command(
                2, base: adapter.current().revision, [(Key.outputEnabled, .bool(false)), (Key.output, .string(token))]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText)
        XCTAssertEqual(fixture.appliedOutputs.value.count, 1, "Stop wins: the ended session gets no output")
        XCTAssertTrue(fixture.writes.value.isEmpty)
    }

    /// A session output the next Connect could not restore (wired headphones, the temporary iPhone speaker) is shown
    /// as "(in use)" so Windows displays what plays, and naming it is rejected before any live call (every token is
    /// resolved first); a savable choice in the same session applies.
    @MainActor
    func testAnUnsavableSessionOutputIsShownInUseAndRejectedBeforeAnyLiveCall() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let cases: [(OutputSelection, [RouteOutput], [String])] = [
            (
                Fixture.wiredOutput, [Fixture.headphones],
                ["iPhone media output", "wired headphones 1 · Synthetic output (in use)"]
            ),
            (
                OutputSelection.fallbackSpeaker(), [Fixture.speaker],
                ["iPhone media output", "iPhone speaker 1", "iPhone speaker (in use)"]
            ),
        ]
        for (number, (output, route, labels)) in cases.enumerated() {
            fixture.route.value = route
            fixture.live.value = PhoneLiveSettings(outputEnabled: true, output: output, outputAppliesLive: true)
            let snapshot = adapter.current()
            XCTAssertNil(snapshot.hostValidationError())
            let field = try Self.field(snapshot, Key.output)
            XCTAssertEqual(field.choices.map(\.label), labels)
            XCTAssertEqual(field.value.stringValue, field.choices.last?.value, "the in-use entry is the value")
            let inUse = try XCTUnwrap(field.value.stringValue)
            adapter.receiveOnMain(
                Fixture.command(
                    number * 2 + 1, base: snapshot.revision,
                    [(Key.outputEnabled, .bool(false)), (Key.output, .string(inUse))]))
            XCTAssertEqual(adapter.acknowledgment?.status, .rejected, labels.last ?? "")
            XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText)
            XCTAssertTrue(fixture.applied.value.isEmpty, "rejected before Play desktop audio changed")
            XCTAssertTrue(fixture.appliedOutputs.value.isEmpty)

            let media = try XCTUnwrap(field.choices.first).value
            adapter.receiveOnMain(
                Fixture.command(number * 2 + 2, base: adapter.current().revision, [(Key.output, .string(media))]))
            XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.liveText)
            XCTAssertEqual(fixture.appliedOutputs.value, [OutputSelection()])
            fixture.appliedOutputs.value = []
        }
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertEqual(fixture.audio.load(), AudioPreferences())
    }

    /// Unknown, stale, unsupported (`live.volume`, `audio.le_stereo`) and wrongly typed changes are rejected before
    /// any store or controller call.
    @MainActor
    func testInvalidCommandsChangeNothing() throws {
        let fixture = try Fixture(self)
        fixture.live.value = PhoneLiveSettings(outputEnabled: true, microphoneMuted: true)
        let adapter = fixture.adapter()
        let revision = adapter.current().revision
        let invalid: [(String, ControlJSON.Value)] = [
            ("live.volume", .int(4)), ("audio.le_stereo", .bool(false)),
            (Key.input, .string(String(repeating: "a", count: 64))), (Key.fastRecovery, .string("false")),
            (Key.timeout(.lanStatus), .int(16_000)), (Key.maxRestarts, .number("3.0")), (Key.microphoneMuted, .null),
            ("allowWindows", .bool(true)),
        ]
        for (index, change) in invalid.enumerated() {
            adapter.receiveOnMain(Fixture.command(index + 1, base: revision, [change]))
            XCTAssertEqual(adapter.acknowledgment?.status, .rejected, change.0)
            XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.invalidValueText, change.0)
        }
        let stale = String(repeating: "0", count: 64)
        adapter.receiveOnMain(Fixture.command(100, base: stale, [(Key.fastRecovery, .bool(false))]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.staleText)
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertTrue(fixture.applied.value.isEmpty)
        XCTAssertTrue(fixture.appliedOutputs.value.isEmpty)
        XCTAssertEqual(fixture.audio.load(), AudioPreferences())
    }

    /// With the opt-in off every command is refused, and a binding without a live session validates nothing (no
    /// acknowledgment at all), like Android's `binding.current() != null` gate.
    @MainActor
    func testCommandsNeedTheOptInAndALiveSession() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let revision = adapter.current().revision
        try fixture.optIn.setAllowWindows(false)
        adapter.receiveOnMain(Fixture.command(1, base: revision, [(Key.outputEnabled, .bool(false))]))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.disabledText)
        try fixture.optIn.setAllowWindows(true)
        fixture.live.value = nil
        adapter.receiveOnMain(Fixture.command(2, base: revision, [(Key.outputEnabled, .bool(false))]))
        XCTAssertEqual(adapter.acknowledgment?.id, Fixture.id(1), "no acknowledgment without a live session")
        XCTAssertTrue(fixture.applied.value.isEmpty)
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertEqual(fixture.changes.value, 2)
    }

    /// A live change the controller refuses, or a session that ends while it is applied, is rejected and leaves
    /// every store unchanged.
    @MainActor
    func testApplyRechecksTheSessionAndWritesNothingAfterAFailure() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let changes: [(String, ControlJSON.Value)] = [
            (Key.outputEnabled, .bool(false)), (Key.fastRecovery, .bool(false)),
        ]
        fixture.applyOverride.value = { _ in throw Fixture.Refused() }
        adapter.receiveOnMain(Fixture.command(1, base: adapter.current().revision, changes))
        XCTAssertEqual(adapter.acknowledgment?.status, .rejected)
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText)

        let live = fixture.live
        fixture.applyOverride.value = { _ in live.value = nil }
        adapter.receiveOnMain(Fixture.command(2, base: adapter.current().revision, changes))
        XCTAssertEqual(adapter.acknowledgment?.message, PhoneControlSession.failedText)
        XCTAssertEqual(fixture.applied.value.count, 2)
        XCTAssertTrue(fixture.writes.value.isEmpty)
        XCTAssertTrue(fixture.audio.load().fastRecovery)
    }

    // MARK: - Worker hop

    /// The worker's calls hop to the main actor and return the snapshot; a command from the worker is applied and
    /// acknowledged in the next snapshot.
    @MainActor
    func testWorkerCallsHopToTheMainActor() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let snapshot = try XCTUnwrap(try onWorker { try adapter.snapshot() })
        let revision = try XCTUnwrap(snapshot["revision"])
        guard case .string(let base) = revision else { return XCTFail("revision") }
        try onWorker { try adapter.receive(Fixture.command(1, base: base, [(Key.fastRecovery, .bool(false))])) }
        XCTAssertFalse(fixture.audio.load().fastRecovery)
        let next = try XCTUnwrap(try onWorker { try adapter.snapshot() })
        XCTAssertEqual(next["ack"]?["id"], .string(Fixture.id(1)))
    }

    /// A main actor that does not answer within the hop costs only this poll's snapshot; the late block finds its
    /// wait abandoned and does nothing.
    @MainActor
    func testAHopTimeoutYieldsNoSnapshotAndTheLateBlockDoesNothing() throws {
        XCTAssertEqual(PhoneControlAdapter.hopTimeoutMs, 1_500, "AppPhoneControl.kt:43")
        XCTAssertEqual(PhoneControlAdapter.refreshMs, 5_000, "AppPhoneControl.kt:54")
        let fixture = try Fixture(self)
        let adapter = fixture.adapter(hopTimeoutMs: 50)
        let result = Locked<Result<DiagnosticJSON?, Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            result.value = Result { try adapter.snapshot() }
            finished.signal()
        }.start()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "the main actor stays busy past the hop")
        XCTAssertNil(try XCTUnwrap(result.value).get())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fixture.liveReads.value, 0, "the abandoned block never built a snapshot")
        XCTAssertNotNil(try onWorker { try adapter.snapshot() })
    }

    /// Stop wakes the hop at once with `SessionStopped`, even while the main actor is blocked (as in
    /// `applicationWillTerminate`), and the late block of the closed session does nothing.
    @MainActor
    func testStopDuringTheHopThrowsSessionStoppedPromptly() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter(hopTimeoutMs: 30_000)
        let result = Locked<Result<DiagnosticJSON?, Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let started = Date()
        Thread {
            result.value = Result { try adapter.snapshot() }
            finished.signal()
        }.start()
        let wait = fixture.wait
        DispatchQueue.global().async {
            while !wait.isWaiting { usleep(1_000) }
            fixture.close()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertThrowsError(try XCTUnwrap(result.value).get()) { XCTAssertTrue($0 is SessionStopped, "\($0)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fixture.liveReads.value, 0)
        XCTAssertNil(try onWorker { try adapter.snapshot() }, "a closed session never hops")
    }

    /// A command beyond the host's 64 KiB bound is ignored without a hop; so is any command once closed.
    @MainActor
    func testOversizedCommandsAndClosedSessionsAreIgnored() throws {
        let fixture = try Fixture(self)
        let adapter = fixture.adapter()
        let base = adapter.current().revision
        let large = Fixture.command(1, base: base, [(Key.fastRecovery, .string(String(repeating: "x", count: 66_000)))])
        try onWorker { try adapter.receive(large) }
        XCTAssertNil(adapter.acknowledgment)
        XCTAssertEqual(fixture.changes.value, 0)
        fixture.close()
        try onWorker { try adapter.receive(Fixture.command(2, base: base, [(Key.fastRecovery, .bool(false))])) }
        XCTAssertNil(adapter.acknowledgment)
        XCTAssertTrue(fixture.audio.load().fastRecovery)
    }
}
