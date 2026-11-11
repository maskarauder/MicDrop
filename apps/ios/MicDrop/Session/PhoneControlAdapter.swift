import Foundation
import MicDropCore

/// The live part of one controller's session that Windows may change (`A/AppPhoneControl.kt:21-22`,
/// `PhoneLiveSettings`). A nil member is not advertised. There is no volume: iOS has no public API to set the system
/// or route volume, and D046 defines live volume as the phone's system volume.
struct PhoneLiveSettings: Equatable, Sendable {
    /// "Play desktop audio" of a playback or duplex session.
    var outputEnabled: Bool?
    /// Mute of an already authorized microphone or duplex session.
    var microphoneMuted: Bool?
    /// The session's media output (playback and duplex; nil for microphone-only), the `audio.output` value Windows sees
    /// and changes through `PhoneControlBinding.applyOutput`. Only `current` reports it; an `apply` request never
    /// carries it.
    var output: OutputSelection?
    /// A Windows output choice switches the running route (`StreamMode.usesMediaOutput`: playback, or duplex with a
    /// phone, wired or USB microphone), so `audio.output` is `live`. False with a Bluetooth headset microphone, whose
    /// controller keeps the choice for a later switch to a non-Bluetooth input (`next_connection`).
    var outputAppliesLive: Bool

    init(
        outputEnabled: Bool? = nil, microphoneMuted: Bool? = nil, output: OutputSelection? = nil,
        outputAppliesLive: Bool = false
    ) {
        self.outputEnabled = outputEnabled
        self.microphoneMuted = microphoneMuted
        self.output = output
        self.outputAppliesLive = outputAppliesLive
    }
}

/// A controller's hooks for one session (`A/AppPhoneControl.kt:23-24`, `PhoneControlBinding`), passed as
/// `SessionConfiguration.phoneControl`. Every closure runs on the main actor:
/// - `current`: the live settings, or nil while the session is not the controller's active, current session
///   (pausing, stopping, superseded or terminating). Nil rejects every command and removes the Live fields.
/// - `apply`: applies the requested live values through the controller's own guarded paths and throws unless the
///   result equals the request. It never starts a session or capture, requests permission, grants microphone
///   consent or unmutes a session that was not already authorized.
/// - `applyOutput`: a Windows `audio.output` choice for a session that reports an `output`, through the
///   controller's own `setOutputSelection` (the phone's output chooser: its phase rule, the route refresh, the
///   gated and verified switch, and the save of a local choice). It throws unless the session then uses exactly
///   that endpoint. It never reconnects, reloads the keep-alive, or touches mute, "Play desktop audio", consent or
///   capture.
/// - `changed`: republishes the controller's state after a command, so Windows edits appear on the phone.
struct PhoneControlBinding: Sendable {
    let current: @MainActor @Sendable () -> PhoneLiveSettings?
    let apply: @MainActor @Sendable (PhoneLiveSettings) throws -> Void
    let applyOutput: @MainActor @Sendable (OutputSelection) throws -> Void
    let changed: @MainActor @Sendable () -> Void

    init(
        current: @escaping @MainActor @Sendable () -> PhoneLiveSettings?,
        apply: @escaping @MainActor @Sendable (PhoneLiveSettings) throws -> Void,
        applyOutput: @escaping @MainActor @Sendable (OutputSelection) throws -> Void,
        changed: @escaping @MainActor @Sendable () -> Void
    ) {
        self.current = current
        self.apply = apply
        self.applyOutput = applyOutput
        self.changed = changed
    }
}

/// Phone settings exchange v1 for one session: the iPhone port of `A/AppPhoneControl.kt` over the portable
/// `PhoneControlSession` (D046, `docs/PHONE_CONTROL_V1.md`).
///
/// Lifetime: one adapter per `SessionController` (one Windows session), created only when the controller passed a
/// binding, with a fresh choice-token salt and an empty command history. ICE restarts and LAN recovery keep it;
/// nothing is persisted, so no command, acknowledgment or token can carry into a later Connect or Play. It opens no
/// connection, background task or push of its own: the worker uses it only on the existing `/status` heartbeat of
/// a session that negotiated phone control.
///
/// Threading: `snapshot()` and `receive(_:)` run on the session worker. Each hops to the main actor and waits at
/// most `hopTimeoutMs` through `SessionWorkerWait` (`A/AppPhoneControl.kt:39-45`). That wait is interruptible, so
/// Stop's `workerWait.cancel()` wakes it with `SessionStopped` and the main thread can never deadlock against it
/// (`applicationWillTerminate` blocks in `awaitRemoteStop` only after `close`). A main block that starts after its
/// wait ended, or after the session closed, does nothing. Every other member is main-actor only.
///
/// Privacy: snapshots, commands, choice tokens and device labels never reach a log, the copy report, stored
/// reports or crash text. A snapshot that fails the host rules is withheld and only its fixed label is kept.
final class PhoneControlAdapter: @unchecked Sendable {
    /// The phone-local preferences and the read-only device lists (`A/AppPhoneControl.kt:88-170`). Production
    /// wires the shared stores and the app's device lists (`AppEnvironment`); tests inject temporary stores and
    /// fixed lists. Every member is called on the main actor only.
    struct Environment {
        /// "Allow Windows to change phone settings" (`PhoneControlPreferenceStore`), read for every snapshot and
        /// again before a command is applied.
        var allowWindows: @MainActor () -> Bool
        var audio: @MainActor () -> AudioPreferences
        /// `AudioPreferencesStore.update`: one locked read-modify-write of every key.
        var updateAudio: @MainActor (_ change: (AudioPreferences) -> AudioPreferences) -> Void
        /// `AudioPreferencesStore.restoredMicrophoneSelection` / `restoredOutputSelection`: the saved selections a
        /// later Connect would use.
        var savedInput: @MainActor () -> MicrophoneSelection
        var savedOutput: @MainActor () -> OutputSelection
        /// Saves a selection for the next connection; it never switches a live route or starts capture. Production:
        /// `AudioPreferencesStore.saveInputForNextConnection` / `saveOutputForNextConnection`, which also bump
        /// `selectionGeneration` so the idle rows adopt the choice once the session is gone. `rememberOutput` serves
        /// only a session without an output (microphone-only); any other output choice goes through
        /// `PhoneControlBinding.applyOutput`.
        var rememberInput: @MainActor (MicrophoneSelection) -> Void
        var rememberOutput: @MainActor (OutputSelection) -> Void
        var connection: @MainActor () -> ConnectionPreferences
        var saveConnection: @MainActor (ConnectionPreferences) throws -> Void
        var advanced: @MainActor () -> AdvancedAudioPreferences
        /// Writes Windows edits of the Advanced audio settings for the next connection (production:
        /// `AdvancedAudioPreferencesStore.saveForNextConnection`, which leaves the running session's keep-alive).
        var saveAdvanced: @MainActor (AdvancedAudioPreferences) throws -> Void
        /// True only when `saveAdvanced` holds the keep-alive for the next connection
        /// (`AdvancedAudioPreferencesStore.saveForNextConnection`). A running microphone session reads that
        /// preference live, and a live Windows write could start a muted background capture in the current
        /// session, which D046 and PHONE_CONTROL_V1 keep phone-local; without the latch
        /// `audio.keep_microphone_active` is not advertised.
        var keepAliveForNextConnection: Bool
        /// `MicrophoneInventory.sessionChoices()`: current inputs only, never the temporary inventory category.
        var inputs: @MainActor () -> MicrophoneInventory.SessionChoices
        /// `OutputChoices.choices()` and `available(_:)` over the current route (D042).
        var outputs: @MainActor () -> [OutputChoice]
        var outputAvailable: @MainActor (OutputSelection) -> Bool

        init(
            allowWindows: @escaping @MainActor () -> Bool,
            audio: @escaping @MainActor () -> AudioPreferences,
            updateAudio: @escaping @MainActor (_ change: (AudioPreferences) -> AudioPreferences) -> Void,
            savedInput: @escaping @MainActor () -> MicrophoneSelection,
            savedOutput: @escaping @MainActor () -> OutputSelection,
            rememberInput: @escaping @MainActor (MicrophoneSelection) -> Void,
            rememberOutput: @escaping @MainActor (OutputSelection) -> Void,
            connection: @escaping @MainActor () -> ConnectionPreferences,
            saveConnection: @escaping @MainActor (ConnectionPreferences) throws -> Void,
            advanced: @escaping @MainActor () -> AdvancedAudioPreferences,
            saveAdvanced: @escaping @MainActor (AdvancedAudioPreferences) throws -> Void,
            keepAliveForNextConnection: Bool,
            inputs: @escaping @MainActor () -> MicrophoneInventory.SessionChoices,
            outputs: @escaping @MainActor () -> [OutputChoice],
            outputAvailable: @escaping @MainActor (OutputSelection) -> Bool
        ) {
            self.allowWindows = allowWindows
            self.audio = audio
            self.updateAudio = updateAudio
            self.savedInput = savedInput
            self.savedOutput = savedOutput
            self.rememberInput = rememberInput
            self.rememberOutput = rememberOutput
            self.connection = connection
            self.saveConnection = saveConnection
            self.advanced = advanced
            self.saveAdvanced = saveAdvanced
            self.keepAliveForNextConnection = keepAliveForNextConnection
            self.inputs = inputs
            self.outputs = outputs
            self.outputAvailable = outputAvailable
        }
    }

    /// Advertised keys (`PhoneControlKeys.advertised`): Android's (`A/AppPhoneControl.kt:96-136`) without
    /// `audio.le_stereo` (the iPhone has no LE Audio input and never reads that preference) and without `live.volume`.
    /// `current()` lists them in that table's order with its groups, kinds and bounds.
    typealias Key = PhoneControlKeys

    /// Field labels. Audio and Advanced labels are the iPhone's own UI strings, so Windows names match the phone
    /// screen; the rest are Android's.
    enum Label {
        static let keepMicrophoneActive = "Keep microphone active while muted in background"
        static let input = "Microphone input"
        static let output = "Media output"
        static let initialOrder = "Initial connection order"
        static let recoveryOrder = "Recovery connection order"
        static let maxRestarts = "Maximum ICE restarts per interruption"
        static let bluetoothRecovery = "Bluetooth route recovery (ms)"
        static let outputEnabled = "Audio output enabled"
        static let microphoneMuted = "Microphone muted"
        /// Suffixes of a saved selection that is not listed (`A/AppPhoneControl.kt:108,117`).
        static let saved = PhoneOutputControl.savedSuffix
        static let savedUnavailable = PhoneOutputControl.savedUnavailableSuffix

        static func timeout(_ timeout: ConnectionPreferences.Timeout) -> String { "\(timeout.label) (ms)" }
    }

    /// The longest main-actor hop of one heartbeat (`A/AppPhoneControl.kt:43`).
    static let hopTimeoutMs = 1_500
    /// An unchanged snapshot (same revision and acknowledgment) is resent after this long, well inside Windows'
    /// 15 s settings freshness (`A/AppPhoneControl.kt:51-54`, `state.go:40`).
    static let refreshMs: Int64 = 5_000
    /// Listed devices per choice field; the saved entry may add one more (Go allows 32 choices).
    static let maxListedChoices = 31
    /// `ConnectionPreferences` accepts 1-10 ICE restarts (`A/AppPhoneControl.kt:127-128`).
    static let maxRestartsRange = ConnectionPreferences.maxRestartsRange

    /// A failed precondition or post-check inside `apply`: the command is acknowledged as rejected.
    struct ApplyFailure: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private let binding: PhoneControlBinding
    private let environment: Environment
    private let wait: SessionWorkerWait
    private let clock: any MonotonicClock
    private let closed: @Sendable () -> Bool
    private let hopTimeoutMs: Int
    /// Per-session salt of the opaque choice tokens (`A/AppPhoneControl.kt:33`).
    private let salt = UUID().uuidString

    // Main actor only.
    private let session = PhoneControlSession()
    private var inputs: [String: MicrophoneSelection] = [:]
    private var outputs: [String: OutputSelection] = [:]
    private var lastSnapshotKey = ""
    private var lastSnapshotAt: Int64 = 0
    /// The host rule the last built snapshot broke (a fixed label, never data); nil after a valid one.
    private(set) var withheld: PhoneControl.HostRuleViolation?
    /// The acknowledgment the next snapshot carries (main actor).
    var acknowledgment: PhoneControlAck? { session.acknowledgment }

    /// `closed` reads the session's closed flag; `wait` is the session worker's wait.
    init(
        binding: PhoneControlBinding, environment: Environment, wait: SessionWorkerWait, clock: any MonotonicClock,
        hopTimeoutMs: Int = PhoneControlAdapter.hopTimeoutMs, closed: @escaping @Sendable () -> Bool
    ) {
        self.binding = binding
        self.environment = environment
        self.wait = wait
        self.clock = clock
        self.hopTimeoutMs = hopTimeoutMs
        self.closed = closed
    }

    // MARK: - Worker

    /// The `phone_control` member for this heartbeat (`A/AppPhoneControl.kt:47-59`), or nil when the session is
    /// closed, the main actor did not answer within `hopTimeoutMs`, nothing changed and the last one is younger
    /// than `refreshMs`, or the snapshot fails the host rules. Stop during the hop throws `SessionStopped`.
    func snapshot() throws -> DiagnosticJSON? {
        try onMain(DiagnosticJSON?.none) { self.snapshotOnMain() }
    }

    /// A `phone_control_command` from a 200 `/status` (`A/AppPhoneControl.kt:61-72`). The host repeats a pending
    /// command on every 200 until a snapshot acknowledges it or it expires, so a known ID is answered from the
    /// history and never applied twice. A command larger than the host's 64 KiB bound is ignored; one that misses
    /// the hop is dropped (Windows expires it after 15 s). Stop during the hop throws `SessionStopped`.
    func receive(_ command: ControlJSON) throws {
        guard command.encoded().count <= PhoneControl.maxBodyBytes else { return }
        _ = try onMain(false) {
            self.receiveOnMain(command)
            return true
        }
    }

    private enum Hop { case pending, running, abandoned }

    /// `onMain` (`A/AppPhoneControl.kt:39-45`): posts `body` to the main queue and waits at most `hopTimeoutMs`
    /// (expiry → `fallback`). A block that has not started when the wait ends is abandoned and does nothing
    /// (`FutureTask.cancel(false)`); a block of a closed session returns `fallback` without running `body`.
    private func onMain<T: Sendable>(_ fallback: T, _ body: @escaping @MainActor @Sendable () -> T) throws -> T {
        guard !closed() else { return fallback }
        let hop = Locked(Hop.pending)
        defer { hop.withLock { if $0 == .pending { $0 = .abandoned } } }
        let isClosed = closed
        return try wait.awaitCompletion(timeoutMs: hopTimeoutMs, orElse: fallback) { completion in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let started = hop.withLock { state -> Bool in
                        guard state == .pending else { return false }
                        state = .running
                        return true
                    }
                    guard started else { return }
                    completion.succeed(isClosed() ? fallback : body())
                }
            }
        }
    }

    // MARK: - Main actor

    /// `snapshot()` on the main actor: de-duplicated for `refreshMs` on revision + acknowledgment ID, then checked
    /// against the host rules (Go `Snapshot.Validate`, measured with Go's escaping) so a snapshot the host would
    /// answer with 400 on every heartbeat is withheld instead.
    @MainActor
    func snapshotOnMain() -> DiagnosticJSON? {
        let value = current()
        let ack = session.acknowledgment
        let key = value.revision + (ack?.id ?? "")
        let now = clock.nowMs()
        if key == lastSnapshotKey && now - lastSnapshotAt < Self.refreshMs { return nil }
        lastSnapshotKey = key
        lastSnapshotAt = now
        if let violation = value.hostValidationError(ack: ack) {
            withheld = violation
            return nil
        }
        withheld = nil
        return value.fields(ack: ack)
    }

    /// `receive(command)` on the main actor: validated only while the binding has a live session; the next poll
    /// then resends the acknowledgment at once and the controller republishes.
    @MainActor
    func receiveOnMain(_ command: ControlJSON) {
        if binding.current() != nil {
            session.receive(command, current: { self.current() }, apply: { try self.apply($0) })
        }
        lastSnapshotKey = ""
        binding.changed()
    }

    /// The current snapshot in Android's field order (`A/AppPhoneControl.kt:88-139`). `enabled` needs a live session
    /// and the opt-in. Audio and Advanced fields take effect at the next connection, except `audio.output` in a session
    /// that plays through a media output (`outputField`); Live fields exist only while the binding reports a live
    /// session. Rebuilds the choice-token maps that `apply` uses.
    @MainActor
    func current() -> PhoneSettingsSnapshot {
        let live = binding.current()
        let audio = environment.audio()
        let connection = environment.connection()
        let advanced = environment.advanced()
        var fields: [PhoneSetting] = [
            .bool(Key.fastRecovery, Strings.fastRecovery, group: .audio, value: audio.fastRecovery),
            .bool(Key.echoCancellation, Strings.microphoneEcho, group: .audio, value: audio.echoCancellation),
            .bool(Key.noiseReduction, Strings.microphoneNoise, group: .audio, value: audio.noiseReduction),
        ]
        if environment.keepAliveForNextConnection {
            fields.append(
                .bool(
                    Key.keepMicrophoneActive, Label.keepMicrophoneActive, group: .audio,
                    value: advanced.keepMicrophoneActiveWhileMuted))
        }
        fields.append(inputField())
        fields.append(outputField(live))
        let orders = ConnectionPreferences.Order.allCases.map { order in
            PhoneSetting.Choice(value: order.rawValue, label: order.label)
        }
        fields.append(
            .choice(
                Key.initialOrder, Label.initialOrder, group: .advanced, value: connection.initialOrder.rawValue,
                choices: orders))
        fields.append(
            .choice(
                Key.recoveryOrder, Label.recoveryOrder, group: .advanced, value: connection.recoveryOrder.rawValue,
                choices: orders))
        fields.append(
            .int(
                Key.maxRestarts, Label.maxRestarts, group: .advanced, value: connection.maxRestarts,
                range: Self.maxRestartsRange))
        for timeout in ConnectionPreferences.Timeout.allCases {
            fields.append(
                .int(
                    Key.timeout(timeout), Label.timeout(timeout), group: .advanced, value: connection[timeout],
                    range: timeout.limits.minimumMs...timeout.limits.maximumMs))
        }
        fields.append(
            .int(
                Key.bluetoothRecovery, Label.bluetoothRecovery, group: .advanced, value: advanced.bluetoothRecoveryMs,
                range: AdvancedAudioPreferences.bluetoothRecoveryRange))
        if let live {
            if let enabled = live.outputEnabled {
                fields.append(
                    .bool(Key.outputEnabled, Label.outputEnabled, group: .live, value: enabled, effect: .live))
            }
            if let muted = live.microphoneMuted {
                fields.append(
                    .bool(Key.microphoneMuted, Label.microphoneMuted, group: .live, value: muted, effect: .live))
            }
        }
        return PhoneSettingsSnapshot(enabled: live != nil && environment.allowWindows(), settings: fields)
    }

    /// `audio.input`: up to 31 current inputs the next Connect can restore (`savable`) plus the saved input when it
    /// is not listed, labelled `"<kind> (saved)"`, or `"<kind> (saved; unavailable)"` when the same listing shows
    /// it unavailable (a Bluetooth headset while HFP inputs are hidden is unknown, not unavailable).
    @MainActor
    private func inputField() -> PhoneSetting {
        let saved = environment.savedInput()
        let listing = environment.inputs()
        let savedToken = token(saved)
        let listed = listing.choices.filter { Self.savable($0.selection) }.prefix(Self.maxListedChoices)
        var entries = listed.map { (token: token($0.selection), choice: $0) }
        if !entries.contains(where: { $0.token == savedToken }) {
            let suffix = listing.availability(saved) == .unavailable ? Label.savedUnavailable : Label.saved
            let title = saved.kind.label + suffix
            entries.append((token: savedToken, choice: MicrophoneChoice(selection: saved, title: title)))
        }
        var map: [String: MicrophoneSelection] = [:]
        var choices: [PhoneSetting.Choice] = []
        for entry in entries where map[entry.token] == nil {
            map[entry.token] = entry.choice.selection
            choices.append(PhoneSetting.Choice(value: entry.token, label: PhoneControl.label(entry.choice.title)))
        }
        inputs = map
        return .choice(Key.input, Label.input, group: .audio, value: savedToken, choices: choices)
    }

    /// `audio.output` (`A/AppPhoneControl.kt:113-120`; `PhoneOutputControl.choices`): up to 31 current-route outputs
    /// the next Connect can restore (`savable`) plus one entry for the value when it is not listed. With a session
    /// output (playback and duplex) the value is that output, shown `"… (in use)"` when it is not savable (wired
    /// headphones, the temporary iPhone speaker; `apply` rejects it); otherwise it is the saved output, labelled
    /// `"<kind> (saved)"` when available now, else `"<kind> (saved; unavailable)"`. The effect is `live` while the
    /// session plays through a media output, otherwise `next_connection`.
    @MainActor
    private func outputField(_ live: PhoneLiveSettings?) -> PhoneSetting {
        let field = PhoneOutputControl.choices(
            route: environment.outputs(), session: live?.output, saved: environment.savedOutput(),
            maxListed: Self.maxListedChoices, available: { self.environment.outputAvailable($0) },
            token: { self.token($0) })
        outputs = Dictionary(field.entries.map { ($0.token, $0.selection) }, uniquingKeysWith: { first, _ in first })
        return .choice(
            Key.output, Label.output, group: .audio, value: field.value,
            choices: field.entries.map { PhoneSetting.Choice(value: $0.token, label: $0.label) },
            effect: PhoneOutputControl.effect(appliesLive: live?.output != nil && live?.outputAppliesLive == true))
    }

    /// `apply(changes)` (`A/AppPhoneControl.kt:141-170`), after `PhoneControlSession` validated the command against
    /// the snapshot of this same main-actor pass:
    /// 1. a live session, an open session and the opt-in are required;
    /// 2. every token is resolved and every saved value built before anything changes (an unknown token, a
    ///    selection that is not `savable`, such as the in-use entry, or an out-of-range value throws, and nothing is
    ///    applied or written);
    /// 3. Live keys go through the binding (the controller's own guarded paths);
    /// 4. `audio.output` of a session with an output goes through `binding.applyOutput` (the controller's
    ///    verified in-session switch, which saves it like a local choice), after a re-check that the session is
    ///    still open and live; a CONNECTING or SWITCHING session refuses it;
    /// 5. the session must still be open and live;
    /// 6. only the stores the command touches are written: audio preferences and selections (`audio.output` here
    ///    only for a session without an output: microphone-only), then connection settings, then Advanced audio
    ///    settings.
    /// Any throw becomes a `rejected` acknowledgment.
    @MainActor
    private func apply(_ changes: [String: PhoneSetting.Value]) throws {
        guard binding.current() != nil, !closed(), environment.allowWindows() else {
            throw ApplyFailure("session or opt-in unavailable")
        }
        let audioKeys = [Key.fastRecovery, Key.echoCancellation, Key.noiseReduction]
        let input = try changes[Key.input].map { value -> MicrophoneSelection in
            guard let token = value.stringValue, let selection = inputs[token] else {
                throw ApplyFailure("unknown input")
            }
            guard Self.savable(selection) else { throw ApplyFailure("selection not savable") }
            return selection
        }
        let output = try changes[Key.output].map { value -> OutputSelection in
            guard let token = value.stringValue, let selection = outputs[token] else {
                throw ApplyFailure("unknown output")
            }
            guard Self.savable(selection) else { throw ApplyFailure("selection not savable") }
            return selection
        }
        let connectionKeys =
            [Key.initialOrder, Key.recoveryOrder, Key.maxRestarts]
            + ConnectionPreferences.Timeout.allCases.map { Key.timeout($0) }
        var connection: ConnectionPreferences?
        if connectionKeys.contains(where: { changes[$0] != nil }) {
            let previous = environment.connection()
            func order(_ key: String, _ fallback: ConnectionPreferences.Order) throws -> ConnectionPreferences.Order {
                guard let value = changes[key] else { return fallback }
                guard let text = value.stringValue, let order = ConnectionPreferences.Order(rawValue: text) else {
                    throw ApplyFailure("unknown order")
                }
                return order
            }
            var timeouts: [ConnectionPreferences.Timeout: Int] = [:]
            for timeout in ConnectionPreferences.Timeout.allCases {
                timeouts[timeout] = changes[Key.timeout(timeout)]?.intValue ?? previous[timeout]
            }
            connection = try ConnectionPreferences(
                initialOrder: order(Key.initialOrder, previous.initialOrder),
                recoveryOrder: order(Key.recoveryOrder, previous.recoveryOrder), timeouts: timeouts,
                maxRestarts: changes[Key.maxRestarts]?.intValue ?? previous.maxRestarts)
        }
        var advanced: AdvancedAudioPreferences?
        if changes[Key.keepMicrophoneActive] != nil || changes[Key.bluetoothRecovery] != nil {
            let previous = environment.advanced()
            advanced = try AdvancedAudioPreferences(
                keepMicrophoneActiveWhileMuted: changes[Key.keepMicrophoneActive]?.boolValue
                    ?? previous.keepMicrophoneActiveWhileMuted,
                bluetoothRecoveryMs: changes[Key.bluetoothRecovery]?.intValue ?? previous.bluetoothRecoveryMs)
        }

        let live = PhoneLiveSettings(
            outputEnabled: changes[Key.outputEnabled]?.boolValue,
            microphoneMuted: changes[Key.microphoneMuted]?.boolValue)
        if live != PhoneLiveSettings() { try binding.apply(live) }
        var savedOutput: OutputSelection?
        if let output {
            guard !closed(), let session = binding.current() else { throw ApplyFailure("session ended") }
            if session.output != nil {
                try binding.applyOutput(output)
            } else {
                savedOutput = output
            }
        }
        guard !closed(), binding.current() != nil else { throw ApplyFailure("session ended") }

        if audioKeys.contains(where: { changes[$0] != nil }) {
            environment.updateAudio { previous in
                var next = previous
                next.fastRecovery = changes[Key.fastRecovery]?.boolValue ?? previous.fastRecovery
                next.echoCancellation = changes[Key.echoCancellation]?.boolValue ?? previous.echoCancellation
                next.noiseReduction = changes[Key.noiseReduction]?.boolValue ?? previous.noiseReduction
                return next
            }
        }
        if let input { environment.rememberInput(input) }
        if let savedOutput { environment.rememberOutput(savedOutput) }
        if let connection { try environment.saveConnection(connection) }
        if let advanced { try environment.saveAdvanced(advanced) }
    }

    // MARK: - Savable selections

    /// An input the next Connect can restore from the stores (`AudioPreferencesStore.restoredMicrophoneSelection`):
    /// the built-in microphone or a USB or Bluetooth microphone with a remembered identity. The wired headset
    /// microphone has only a port-wide uid on iOS and is never remembered (`RememberedAudioDevices.rememberable`),
    /// so a Windows choice of it would save only its kind: the next snapshot would show the built-in microphone and
    /// an enabled microphone would wait for reselection (`AudioPreferences.needsInputSelection`).
    static func savable(_ selection: MicrophoneSelection) -> Bool {
        selection.kind == .builtIn || RememberedAudioDevices.rememberable(input: selection) != nil
    }

    /// An output the next Connect can restore (`PhoneOutputControl.savable`): iPhone media output, the permanent
    /// iPhone speaker pin or an external output with a remembered identity. Wired headphones are never remembered
    /// (port-wide uid), so a Windows choice of them would restore iPhone media output and fail the next Connect
    /// with `output_reselect` (`AudioPreferences.needsOutputSelection`); the temporary iPhone speaker is saved as
    /// iPhone media output. A running session can still use either; Windows then sees it as the in-use entry.
    static func savable(_ selection: OutputSelection) -> Bool {
        PhoneOutputControl.savable(selection)
    }

    // MARK: - Choice tokens

    /// Opaque, per-session choice value: lowercase hex SHA-256 of the salt and the device identity
    /// (`A/AppPhoneControl.kt:81-86`). 64 characters; never contains a uid.
    private func token(_ selection: MicrophoneSelection) -> String {
        PhoneControl.sha256Hex(salt + Self.identity(selection))
    }

    private func token(_ selection: OutputSelection) -> String {
        PhoneControl.sha256Hex(salt + Self.identity(selection))
    }

    /// The `sameDevice` identity (kind, port type, uid; `MicrophoneSelection.sameDevice`), length-delimited. The
    /// headset pin is not part of it, so a listed saved headset is not offered twice. Built from the fields, never
    /// from `description` or the mirror, which are redacted and would merge devices.
    static func identity(_ selection: MicrophoneSelection) -> String {
        "input" + part(AudioPreferences.storageName(of: selection.kind)) + part(selection.portType)
            + (selection.portUID.map(part) ?? "-")
    }

    /// `sameEndpoint` (kind, port type, uid) plus the temporary-speaker flag, length-delimited.
    static func identity(_ selection: OutputSelection) -> String {
        "output" + part(selection.kind.persistedName) + part(selection.portType) + part(selection.uid)
            + (selection.returnOnBluetooth ? "1" : "0")
    }

    private static func part(_ text: String) -> String { "\(text.utf16.count):\(text)" }
}
