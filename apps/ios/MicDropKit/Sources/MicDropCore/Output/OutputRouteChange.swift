import Foundation

/// Ticketed selection/verification state (`OutputSelection.kt:85-149`).
///
/// "Serialized with StreamReceiver's audio lock. A stale route callback or native track
/// verification cannot release a newer selection's gate, or defeat Stop."
/// Not internally synchronized: the owning `OutputRouteController` mutates it only under its
/// session audio lock (`NSLock`), from the worker and from route callbacks.
public final class OutputRouteChange: @unchecked Sendable {
    /// Default selected Bluetooth restore window (`OutputSelection.kt:88`); a session passes its configured
    /// Advanced window (`AdvancedAudioPreferences.bluetoothRecoveryMs`) as `bluetoothRecoveryMs`.
    public static let bluetoothRecoveryMs: Int64 = 20_000
    /// Initial/explicit verification and speaker-repair window (`OutputSelection.kt:87`).
    public static let defaultLimitMs: Int64 = 5_000

    public let limitMs: Int64
    /// This session's selected Bluetooth restore window: one fixed deadline per episode.
    public let bluetoothRecoveryLimitMs: Int64
    public private(set) var selection: OutputSelection
    public private(set) var ticket: Int64 = 0
    public private(set) var pending: Bool
    public private(set) var invalid = false
    public private(set) var recovering = false
    private var deadline: Int64?
    private var stopped = false

    public init(
        _ initial: OutputSelection, limitMs: Int64 = OutputRouteChange.defaultLimitMs,
        bluetoothRecoveryMs: Int64 = OutputRouteChange.bluetoothRecoveryMs
    ) {
        self.limitMs = limitMs
        self.bluetoothRecoveryLimitMs = bluetoothRecoveryMs
        self.selection = initial
        self.pending = initial.explicit
    }

    /// New selection: new ticket, pending, recovery and deadline cleared. False after `stop()`.
    @discardableResult
    public func request(_ value: OutputSelection) -> Bool {
        if stopped { return false }
        selection = value
        ticket += 1
        pending = true
        invalid = false
        recovering = false
        deadline = nil
        return true
    }

    /// Temporary speaker -> DEFAULT once Bluetooth returned, for the current ticket only.
    public func returnToDefault(_ id: Int64, bluetoothReturned: Bool) -> Bool {
        if stopped || id != ticket || !selection.temporarySpeaker || !bluetoothReturned { return false }
        return request(OutputSelection())
    }

    /// Playout (re)started: re-verify with a new ticket; a recovery keeps its deadline.
    public func trackStarted() {
        if stopped { return }
        ticket += 1
        pending = true
        invalid = false
        if !recovering { deadline = nil }
    }

    /// Start the one selected-Bluetooth episode with the fixed deadline `now + bluetoothRecoveryLimitMs`
    /// (default 20 s); repeated route callbacks during the episode are refused and never extend it.
    @discardableResult
    public func recoverBluetooth(_ id: Int64, nowMs: Int64) -> Bool {
        if stopped || id != ticket || !selection.kind.isBluetooth || recovering { return false }
        ticket += 1
        pending = true
        invalid = false
        recovering = true
        deadline = nowMs + bluetoothRecoveryLimitMs
        return true
    }

    /// Speaker repair starts only from a verified PHONE pin (`pending == false`), window `limitMs`.
    @discardableResult
    public func recoverSpeaker(_ id: Int64, nowMs: Int64) -> Bool {
        if stopped || id != ticket || selection.kind != .phone || pending || recovering { return false }
        ticket += 1
        pending = true
        invalid = false
        recovering = true
        deadline = nowMs + limitMs
        return true
    }

    /// Same endpoint, possibly a new value: retains the original recovery/selection deadline.
    @discardableResult
    public func rebind(_ id: Int64, _ value: OutputSelection) -> Bool {
        if stopped || id != ticket || !pending || !selection.sameEndpoint(value) { return false }
        if selection != value {
            selection = value
            ticket += 1
        }
        return true
    }

    /// Arms the verification deadline once (`now + limitMs`); repeated calls never extend it.
    @discardableResult
    public func beginCheck(_ id: Int64, nowMs: Int64) -> Bool {
        if stopped || id != ticket || !pending { return false }
        if deadline == nil { deadline = nowMs + limitMs }
        return true
    }

    /// Verification for the current ticket; impossible after `lost` until a new request.
    public func verified(_ id: Int64) -> Bool {
        if stopped || id != ticket || !pending || invalid { return false }
        pending = false
        recovering = false
        deadline = nil
        return true
    }

    /// A verified explicit pin was lost (DEFAULT can never be lost).
    public func lost(_ id: Int64) -> Bool {
        if stopped || id != ticket || pending || !selection.explicit { return false }
        invalid = true
        return true
    }

    /// `!stopped && pending && deadline != nil && now >= deadline`.
    public func expired(_ nowMs: Int64) -> Bool {
        guard !stopped, pending, let deadline else { return false }
        return nowMs >= deadline
    }

    public func stop() {
        stopped = true
        pending = false
        recovering = false
        deadline = nil
    }

    /// `Text.bluetoothRestoreTimeout` for this session's window.
    public var bluetoothRestoreTimeoutText: String {
        Text.bluetoothRestoreTimeout(seconds: AdvancedAudioPreferences.seconds(bluetoothRecoveryLimitMs))
    }

    /// Worker/status texts of the output subsystem (iOS wording; Android originals `StreamReceiver.kt:289, 437-441,
    /// 939, 969, 998-999, 1071-1072, 1163-1167`).
    public enum Text {
        /// Status after `setOutputSelection` (`StreamReceiver.kt:289`).
        public static let switching = "Changing playback device. Audio stays silenced until iOS verifies the route…"
        /// Status after the temporary speaker returned to DEFAULT (`StreamReceiver.kt:939`).
        public static let bluetoothReturned = "Bluetooth output returned. Following iPhone media output…"
        /// `bind == false` outside speaker repair (`StreamReceiver.kt:969`), code `output_runtime`.
        public static let selectFailed = "iOS could not select the requested playback device. " + chooseAgain
        /// Speaker repair expiry (`StreamReceiver.kt:998`), code `output_runtime`.
        public static let speakerRestoreTimeout =
            "iOS did not restore the iPhone speaker within 5 seconds. Audio stayed silenced. " + chooseAgain
        /// Pinned (non-Bluetooth) verification expiry (`StreamReceiver.kt:999`), code `output_runtime`.
        public static let verifyTimeout =
            "iOS did not verify the requested playback device within 5 seconds. Audio stayed silenced. " + chooseAgain
        /// Selected Bluetooth restore expiry (`StreamReceiver.kt:1071`), code `output_runtime`. `seconds` is the
        /// session's configured window (`AdvancedAudioPreferences.seconds`), as Android's message names its
        /// configured `BLUETOOTH_RECOVERY` window (`StreamReceiver.kt:57-59,1142` on main `87b15af`).
        public static func bluetoothRestoreTimeout(seconds: String) -> String {
            "iOS did not restore the selected Bluetooth output within \(seconds) seconds. Playback stayed silenced. "
                + chooseAgain
        }
        /// Selected Bluetooth initial verification expiry (`StreamReceiver.kt:1072`), code `output_runtime`.
        public static let bluetoothVerifyTimeout =
            "iOS did not verify the selected Bluetooth output within 5 seconds. Playback stayed silenced. "
            + chooseAgain
        /// Shared last sentence of the selection/verification failures (`StreamReceiver.kt:969-1072`).
        private static let chooseAgain = "Choose an available output and Connect again."
        /// Track errors (`StreamReceiver.kt:437-441`): codes `output_init`, `output_start`, `output_runtime`.
        public static let outputInitFailed = "iOS audio output could not start."
        public static let outputStartFailed = "iOS audio playback failed to start."
        public static let outputRuntimeFailed = "iOS audio output stopped unexpectedly."
        /// Copy-report identity line for a Bluetooth pin (no permission clause on iOS).
        public static let selectedIdentity = "Selected output identity: current route device"
        /// Copy-report system-route line for a Bluetooth pin.
        public static let systemBluetoothRoute = "System Bluetooth route: not applicable on iOS (no transfer API)"

        /// `outputRecoveryText()` (`StreamReceiver.kt:1163-1167`, iOS wording): `Output recovery: playout recreations
        /// requested=<n>` + DEFAULT ` · Actual matches iOS default: unavailable` | Bluetooth `\n` +
        /// `systemBluetoothRoute` | "".
        public static func outputRecovery(recreations: Int, selection: OutputSelection) -> String {
            let head = "Output recovery: playout recreations requested=\(recreations)"
            if !selection.explicit { return head + " · Actual matches iOS default: unavailable" }
            if selection.kind.isBluetooth { return head + "\n" + systemBluetoothRoute }
            return head
        }

        /// `App output selection: ...` line (`StreamReceiver.kt:744-745`), only for playback modes.
        public static func appOutputSelection(
            usesMediaOutput: Bool, selection: OutputSelection,
            recovering: Bool, pending: Bool
        ) -> String {
            "App output selection: "
                + (usesMediaOutput
                    ? selection.reportState(recovering: recovering, pending: pending)
                    : "selected headset microphone")
        }
    }
}
