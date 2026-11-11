import MicDropCore
import SwiftUI

/// Edits a snapshot; Save applies to the next connection and never changes a running session, except
/// "Keep microphone active while muted in background", which a running session reads at its next
/// background/foreground step after a local Save that changed it (a Windows edit of it waits for the next
/// connection, `AdvancedAudioPreferencesStore`). Save writes only the values changed in the sheet, merged onto the
/// stores' current values (`ConnectionPolicySave`), so it never reverts a Windows edit (phone settings exchange v1)
/// that landed while the sheet was open. Neither Advanced audio value starts a session or capture.
struct ConnectionPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var initialOrder: ConnectionPreferences.Order
    @State private var recoveryOrder: ConnectionPreferences.Order
    @State private var maxRestarts: Int
    @State private var seconds: [ConnectionPreferences.Timeout: String]
    @State private var bluetoothRecoverySeconds: String
    @State private var keepMicrophoneActive: Bool
    @State private var saveFailed = false
    /// The values loaded when the sheet opened; `State`, so a re-render of the presenting view keeps them.
    @State private var opened: ConnectionPreferences
    @State private var openedAudio: AdvancedAudioPreferences
    /// **Restore defaults** was used: Save then writes every shown value.
    @State private var restored = false
    private let store: ConnectionPreferencesStore
    private let audioStore: AdvancedAudioPreferencesStore

    init(store: ConnectionPreferencesStore = .shared, audioStore: AdvancedAudioPreferencesStore = .shared) {
        self.store = store
        self.audioStore = audioStore
        let preferences = store.load()
        let audio = audioStore.load()
        _initialOrder = State(initialValue: preferences.initialOrder)
        _recoveryOrder = State(initialValue: preferences.recoveryOrder)
        _maxRestarts = State(initialValue: preferences.maxRestarts)
        _seconds = State(initialValue: Self.seconds(for: preferences))
        _bluetoothRecoverySeconds = State(
            initialValue: AdvancedAudioPreferences.seconds(audio.bluetoothRecoveryWindowMs))
        _keepMicrophoneActive = State(initialValue: audio.keepMicrophoneActiveWhileMuted)
        _opened = State(initialValue: preferences)
        _openedAudio = State(initialValue: audio)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Initial connection", selection: $initialOrder) { orderOptions }
                    Picker("Recovery", selection: $recoveryOrder) { orderOptions }
                } header: {
                    Text("Connection order")
                } footer: {
                    Text(
                        "Applies to your next connection. Direct LAN is used only after verifying the saved Windows host."
                    )
                }
                ForEach(ConnectionPreferences.Timeout.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(ConnectionPreferences.Timeout.allCases.filter { $0.group == group }, id: \.self) {
                            timeout in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(timeout.label)
                                HStack {
                                    TextField(
                                        "Seconds",
                                        text: Binding(
                                            get: { seconds[timeout] ?? "" }, set: { seconds[timeout] = $0 })
                                    )
                                    .keyboardType(.decimalPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityLabel("\(timeout.label), seconds")
                                    Text("seconds").foregroundStyle(.secondary)
                                }
                                if timeout.parseUserSeconds(seconds[timeout] ?? "") == nil {
                                    Text(
                                        "Enter \(ConnectionPreferences.seconds(timeout.limits.minimumMs))–\(ConnectionPreferences.seconds(timeout.limits.maximumMs)) seconds, using a decimal point."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }
                        }
                        if group == .recovery {
                            Stepper("Maximum ICE restarts: \(maxRestarts)", value: $maxRestarts, in: 1...10)
                            Text(Self.recoveryFooter)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                audioRouteRecoverySection
                backgroundMicrophoneSection
                Section {
                    Button("Restore defaults") { restoreDefaults() }
                    if saveFailed { Text("Could not save settings. Try again.").foregroundStyle(.red) }
                }
            }
            .navigationTitle(Strings.connectionSettings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(preferences == nil || audioPreferences == nil)
                }
            }
        }
    }

    /// Advanced: the Bluetooth route recovery window (`AdvancedAudioPreferences` bounds), used at Connect.
    private var audioRouteRecoverySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluetooth route recovery")
                HStack {
                    TextField("Seconds", text: $bluetoothRecoverySeconds)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Bluetooth route recovery, seconds")
                    Text("seconds").foregroundStyle(.secondary)
                }
                if AdvancedAudioPreferences.parseBluetoothRecoverySeconds(bluetoothRecoverySeconds) == nil {
                    Text(Self.bluetoothRecoveryBounds)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Advanced audio: route recovery")
        } footer: {
            Text(Self.bluetoothRecoveryFooter)
        }
    }

    /// Advanced: the muted background microphone keep-alive, with the approved label and explanation.
    private var backgroundMicrophoneSection: some View {
        Section {
            Toggle("Keep microphone active while muted in background", isOn: $keepMicrophoneActive)
        } header: {
            Text("Advanced audio: background microphone")
        } footer: {
            Text(Self.backgroundMicrophoneFooter)
        }
    }

    /// The network recovery group caption: Android's `ConnectionSettingsDialog` RECOVERY text with iOS named
    /// instead of Android (the host's missing-heartbeat limit is the confirmed recovery window plus 5 s,
    /// `internal/session/recovery.go:30-31`), then the legacy-host rule (`ConnectionPreferences.legacy`).
    private static let recoveryFooter: String =
        "Windows must also be updated to extend its deadlines. Its missing-heartbeat limit follows the recovery "
        + "window plus 5 seconds. A longer window waits for connectivity; iOS still chooses when to leave Wi-Fi. "
        + "Custom recovery and setup windows apply only after Windows confirms them; older hosts keep their "
        + "existing limits."

    private static let bluetoothRecoveryBounds: String =
        "Enter \(ConnectionPreferences.seconds(AdvancedAudioPreferences.bluetoothRecoveryLimits.minimumMs))–"
        + "\(ConnectionPreferences.seconds(AdvancedAudioPreferences.bluetoothRecoveryLimits.maximumMs)) seconds, "
        + "using a decimal point."

    private static let bluetoothRecoveryFooter: String =
        "How long MicDrop waits for the selected Bluetooth output or Bluetooth headset microphone to return before "
        + "ending the session. Playback and microphone stay silenced until iOS verifies the route. Default "
        + "\(ConnectionPreferences.seconds(AdvancedAudioPreferences.bluetoothRecoveryLimits.defaultMs)) seconds; "
        + "separate from the network recovery window. It does not extend initial route verification or the time "
        + "allowed for a microphone change. Applies to your next connection."

    private static let backgroundMicrophoneFooter: String =
        "Helps keep microphone-only sessions connected while the screen is locked and makes unmuting quicker. "
        + "No microphone audio is sent while muted. The microphone indicator may stay on and battery use may "
        + "increase. Turning this off may allow iOS to suspend the session.\n\n"
        + "Applies immediately after Save, including to a running session the next time MicDrop goes to the "
        + "background. It never starts a session or replaces microphone permission. Changes made from Windows "
        + "apply at your next connection."

    private var orderOptions: some View {
        ForEach(ConnectionPreferences.Order.allCases, id: \.self) { order in Text(order.label).tag(order) }
    }

    private var preferences: ConnectionPreferences? {
        var values: [ConnectionPreferences.Timeout: Int] = [:]
        for timeout in ConnectionPreferences.Timeout.allCases {
            guard let value = timeout.parseUserSeconds(seconds[timeout] ?? "") else { return nil }
            values[timeout] = value
        }
        return try? ConnectionPreferences(
            initialOrder: initialOrder, recoveryOrder: recoveryOrder, timeouts: values, maxRestarts: maxRestarts)
    }

    private var audioPreferences: AdvancedAudioPreferences? {
        guard let window = AdvancedAudioPreferences.parseBluetoothRecoverySeconds(bluetoothRecoverySeconds) else {
            return nil
        }
        return try? AdvancedAudioPreferences(
            keepMicrophoneActiveWhileMuted: keepMicrophoneActive, bluetoothRecoveryMs: window)
    }

    /// `ConnectionPolicySave.commit`. The sheet closes only after both writes succeeded; a failure of either shows
    /// one message for the whole sheet, and the next Save merges and writes both again.
    private func save() {
        guard let preferences, let audioPreferences else { return }
        do {
            try ConnectionPolicySave.commit(
                connection: preferences, audio: audioPreferences, opened: opened, openedAudio: openedAudio,
                restored: restored, store: store, audioStore: audioStore)
            dismiss()
        } catch { saveFailed = true }
    }

    private func restoreDefaults() {
        let defaults = ConnectionPreferences()
        let audio = AdvancedAudioPreferences()
        initialOrder = defaults.initialOrder
        recoveryOrder = defaults.recoveryOrder
        maxRestarts = defaults.maxRestarts
        seconds = Self.seconds(for: defaults)
        bluetoothRecoverySeconds = AdvancedAudioPreferences.seconds(audio.bluetoothRecoveryWindowMs)
        keepMicrophoneActive = audio.keepMicrophoneActiveWhileMuted
        restored = true
        saveFailed = false
    }

    private static func seconds(for preferences: ConnectionPreferences) -> [ConnectionPreferences.Timeout: String] {
        Dictionary(
            uniqueKeysWithValues: ConnectionPreferences.Timeout.allCases.map {
                ($0, ConnectionPreferences.seconds(preferences[$0]))
            })
    }
}

/// The Connection settings sheet's Save, apart from the view so it runs against temporary stores in tests.
///
/// The sheet edits values it loaded when it opened, while a Windows edit (phone settings exchange v1) can save a
/// connection or Advanced audio value at any time (`PhoneControlAdapter`). So Save writes only what the user
/// changed: every shown value that differs from the opened one replaces that value of the store's current
/// preferences, and every other value keeps the current one (`merged(onto:since:)`). After **Restore defaults**
/// every shown value is written, as the user asked for all defaults.
enum ConnectionPolicySave {
    /// Writes the Advanced audio file first, so a failure there changes nothing; if the connection file then fails,
    /// the audio values stay saved. The keep-alive applies to a running session at once
    /// (`AdvancedAudioPreferencesStore.save`) only when the user changed it here or restored the defaults;
    /// otherwise the file is written with `saveForNextConnection`, so a Windows edit of it still waits for the next
    /// connection and saving other values does not make it live.
    static func commit(
        connection: ConnectionPreferences, audio: AdvancedAudioPreferences, opened: ConnectionPreferences,
        openedAudio: AdvancedAudioPreferences, restored: Bool, store: ConnectionPreferencesStore,
        audioStore: AdvancedAudioPreferencesStore
    ) throws {
        let keepAliveChosen =
            restored || audio.keepMicrophoneActiveWhileMuted != openedAudio.keepMicrophoneActiveWhileMuted
        let audioValue = try restored ? audio : audio.merged(onto: audioStore.load(), since: openedAudio)
        if keepAliveChosen {
            try audioStore.save(audioValue)
        } else {
            try audioStore.saveForNextConnection(audioValue)
        }
        try store.save(restored ? connection : connection.merged(onto: store.load(), since: opened))
    }
}
