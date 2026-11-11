// Sole owner of RTCAudioSession configuration and activation.
//
// Nothing else in the app calls `RTCAudioSession` (or `AVAudioSession`) category/mode/options/activation setters,
// `overrideOutputAudioPort` or `setPreferredInput`. The media engine (04) only toggles
// `RTCAudioSession.isAudioEnabled`; the session worker reaches the speaker override and the microphone route calls
// through this type.
//
// Threading: every RTCAudioSession call runs on one private serial queue (`setActive` can block). Main-actor callers
// use `prepare(_:completion:)` (completion hops back to main, FIFO) or the blocking `prepareNow(_:)` (local tools).
// Worker-side calls are synchronous `throws`.
//
// WebRTC header facts this file relies on (Shiguredo m155, `RTCAudioSession.h`):
// - `setActive:error:` is reference counted (`_activationCount`); deactivation always passes
//   `AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation`, and only the last balanced call
//   deactivates. Every `Activation` handed out here is therefore released exactly once.
// - The patched `setConfiguration:active:error:` always returns YES (the NSError cannot be seen from
// Swift), so this file applies the plan with the individual proxies (`setCategory:mode:options:`,
// `setPreferredSampleRate:`, `setPreferredIOBufferDuration:`, `setActive:`), which report errors, and verifies the
// result by read-back (`AudioSessionPlan.acceptsReadBack`).
// - `RTCAudioSessionConfiguration.setWebRTC(_:)` makes WebRTC's own `configureWebRTCSession` (run
//   by the ADM in `InitPlayOrRecord`) re-apply the same values instead of the patched Ambient default.

import AVFoundation
import Foundation
import MicDropCore
import WebRTC

final class AudioSessionArbiter: @unchecked Sendable {
    /// The process-wide arbiter (one `RTCAudioSession` singleton exists per process).
    static let shared = AudioSessionArbiter()

    // MARK: - Nested types

    /// One balanced activation taken by `prepare` / `prepareNow`. Release it exactly once with
    /// `deactivate(_:notifyOthers:)` (`releaseTransport`, `close`, local-tool).
    struct Activation: Equatable, Sendable {
        /// Monotonic activation number (process-local).
        let id: UInt64
        /// The plan that was applied and verified.
        let plan: AudioSessionPlan
    }

    /// Activation failure, classified per "Activation error mapping".
    struct ActivationError: Error, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// `!pri` insufficientPriority, `!int` cannotInterruptOthers, `siri` siriIsRecording:
            /// a call/Siri holds audio → `focus_request_denied` + "Audio is busy. …".
            case busy
            /// `!pla` cannotStartPlaying, `!rec` cannotStartRecording: background start refused →
            /// `foreground_start_denied` + "iOS could not start background playback. …".
            case backgroundStart
            /// The read-back category/mode/options differ from the plan.
            case configurationMismatch
            /// `msrv` mediaServicesFailed and everything else → "Playback could not start. …".
            case other
        }

        let kind: Kind
        /// `NSError.code` of the failing call (an `AVAudioSession.ErrorCode` raw value, usually a
        /// four-character code), or nil for a read-back mismatch.
        let code: Int?

        init(kind: Kind, code: Int?) {
            self.kind = kind
            self.code = code
        }

        var isBusy: Bool { kind == .busy }
        var isBackgroundStart: Bool { kind == .backgroundStart }

        /// Label used in the controls log event `audio_session_activation_failed_<code>`: the four-character code (e.g.
        /// `!pri`) when printable, the decimal code otherwise, `mismatch` for a read-back failure.
        var codeLabel: String {
            guard let code else { return kind == .configurationMismatch ? "mismatch" : "unknown" }
            return AudioSessionArbiter.fourCharacterLabel(code) ?? String(code)
        }

        /// Classifies a thrown error by its `NSError.code` (table).
        static func classify(_ error: Error) -> ActivationError {
            let code = (error as NSError).code
            return ActivationError(kind: kind(forCode: code), code: code)
        }

        /// busy codes, background-start codes, everything else `.other`.
        static func kind(forCode code: Int) -> Kind {
            if AudioSessionArbiter.busyCodes.contains(code) { return .busy }
            if AudioSessionArbiter.backgroundStartCodes.contains(code) { return .backgroundStart }
            return .other
        }
    }

    /// Failures of the non-activation calls.
    enum ConfigurationError: Error, Equatable, Sendable {
        /// `withTemporaryInventoryCategory` while a session, a queued worker or a local tool holds audio (refused
        /// unless no session is retained and no local tool runs).
        case refused
        /// `setPreferredInput(uid:)` with a uid absent from `availableInputs`.
        case portUnavailable
        /// `reactivate()` without an outstanding activation.
        case notActivated
        /// The underlying call threw; `code` is its `NSError.code`.
        case failed(code: Int)
    }

    // MARK: - Error code constants (AVAudioSession.ErrorCode raw values, four-character codes)

    /// `'!pri'`, `'!int'`, `'siri'` (row 1).
    static let busyCodes: Set<Int> = [
        fourCharacterCode("!pri"), fourCharacterCode("!int"),
        fourCharacterCode("siri"),
    ]
    /// `'!pla'`, `'!rec'` (row 2).
    static let backgroundStartCodes: Set<Int> = [fourCharacterCode("!pla"), fourCharacterCode("!rec")]
    /// `'!act'` isBusy: deactivation while I/O runs (record, never fail).
    static let isBusyCode = fourCharacterCode("!act")

    /// Big-endian ASCII four-character code (`'!pri'` = 0x21707269).
    static func fourCharacterCode(_ text: String) -> Int {
        text.utf8.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Inverse of `fourCharacterCode` when all four bytes are printable ASCII.
    static func fourCharacterLabel(_ code: Int) -> String? {
        guard code > 0, code <= 0xFFFF_FFFF else { return nil }
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - State

    private let session: RTCAudioSession
    private let owner: AudioSessionOwner
    private let queue = DispatchQueue(label: "com.maskarauder.micdrop.audio-session", qos: .userInitiated)
    private let lock = NSLock()
    /// Outstanding activations → number of balanced `setActive(true)` calls they hold
    /// (1 from `prepare`, +1 per successful `reactivate`).
    private var outstanding: [UInt64: (plan: AudioSessionPlan, count: Int)] = [:]
    private var order: [UInt64] = []
    private var nextID: UInt64 = 0
    private var launchConfigured = false

    init(session: RTCAudioSession = RTCAudioSession.sharedInstance(), owner: AudioSessionOwner = .shared) {
        self.session = session
        self.owner = owner
    }

    // MARK: - Launch hygiene

    /// Call once at process start, before any factory, ADM or output probe exists. The single launch audio-hygiene
    /// entry (`AppLifecycle.prepareProcess`), delegating to the owners of each toggle:
    /// - `WebRTCRuntime.configureAtLaunch()` (its API note item 8): `useManualAudio = true`,
    ///   `isAudioEnabled = false`, so WebRTC never touches the unit unless a session permits it;
    /// - `MicrophoneCapture.setApplicationInputMuted(false)` (never inherit an
    ///   app-wide `AVAudioApplication` input mute from a previous run);
    /// - `AVAudioSession.setPrefersInterruptionOnRouteDisconnect(false)` (iOS 17 API, errors ignored).
    /// Idempotent.
    @MainActor
    func configureForLaunch() {
        lock.lock()
        let already = launchConfigured
        launchConfigured = true
        lock.unlock()
        guard !already else { return }
        WebRTCRuntime.configureAtLaunch()
        MicrophoneCapture.setApplicationInputMuted(false)
        try? session.session.setPrefersInterruptionOnRouteDisconnect(false)
    }

    // MARK: - Main-actor facade

    /// Applies `plan` and activates the session on the arbiter queue, then calls `completion` on the main queue (FIFO).
    /// Sequence: `RTCAudioSessionConfiguration.setWebRTC(plan)` → lock → `setCategory(_:mode:options:)` → preferred
    /// sample rate / IO buffer and `setPrefersInterruptionOnRouteDisconnect(false)` (errors ignored, they are
    /// preferences) → `setActive(true)` → unlock → read back category/mode/options (`plan.acceptsReadBack`) → on
    /// mismatch release the activation and fail `.configurationMismatch`. Activation errors are classified with
    /// `ActivationError.classify`.
    @MainActor
    func prepare(
        _ plan: AudioSessionPlan,
        completion: @escaping @MainActor (Result<Activation, ActivationError>) -> Void
    ) {
        queue.async { [self] in
            let result = apply(plan)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Blocking variant for main-actor local tools (`prepare(.localTool)` after `AudioSessionOwner.tryAcquire()`);
    /// never call from the session worker.
    @MainActor
    func prepareNow(_ plan: AudioSessionPlan) -> Result<Activation, ActivationError> {
        queue.sync { apply(plan) }
    }

    /// Releases one activation (`releaseTransport`, only after the worker's `onEnded`, never while its I/O runs).
    /// Idempotent per handle. Errors (`!act` isBusy etc.) are ignored: a session never fails because of deactivation.
    /// RTCAudioSession always deactivates with `.notifyOthersOnDeactivation`; `notifyOthers` documents the intent only.
    func deactivate(_ activation: Activation, notifyOthers: Bool = true) {
        lock.lock()
        let entry = outstanding.removeValue(forKey: activation.id)
        order.removeAll { $0 == activation.id }
        lock.unlock()
        guard let entry else { return }
        queue.async { [self] in
            session.lockForConfiguration()
            for _ in 0..<entry.count {
                try? session.setActive(false)
            }
            session.unlockForConfiguration()
        }
    }

    /// Handle-less form for owners that hold at most one activation at a time (app-mic's
    /// `deactivateAudio`): releases the most recent outstanding activation, if any. Prefer the
    /// handle form; a handle-less call after a failed activation would release another owner's.
    func deactivate(notifyOthers: Bool = true) {
        lock.lock()
        let latest = order.last.flatMap { id in outstanding[id].map { Activation(id: id, plan: $0.plan) } }
        lock.unlock()
        if let latest { deactivate(latest, notifyOthers: notifyOthers) }
    }

    // MARK: - Queries (any thread)

    /// Plan of the most recent outstanding activation (the route providers derive `speakerPinnable` from it; nil when
    /// nothing is activated).
    var currentPlan: AudioSessionPlan? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = order.last else { return nil }
        return outstanding[last]?.plan
    }

    /// `true` while any activation is outstanding.
    var hasActivation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !outstanding.isEmpty
    }

    /// `RTCAudioSession.isActive`.
    var isActive: Bool { session.isActive }

    /// `RTCAudioSession.isAudioEnabled` (local tools run only while it is false).
    var isAudioEnabled: Bool { session.isAudioEnabled }

    // MARK: - Worker-side calls (synchronous)

    /// Microphone route pin (`activate`/`restoreInput`/`close`): `uid == nil` clears the preference
    /// (`AVAudioSession.setPreferredInput(nil)`; the RTCAudioSession proxy does not take nil); otherwise the port with
    /// that uid in `availableInputs`, else `.portUnavailable`. Runs under `lockForConfiguration` on the arbiter queue.
    func setPreferredInput(uid: String?) throws {
        try queue.sync {
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            do {
                guard let uid else {
                    try session.session.setPreferredInput(nil)
                    return
                }
                guard let port = session.session.availableInputs?.first(where: { $0.uid == uid }) else {
                    throw ConfigurationError.portUnavailable
                }
                try session.setPreferredInput(port)
            } catch let error as ConfigurationError {
                throw error
            } catch {
                throw ConfigurationError.failed(code: (error as NSError).code)
            }
        }
    }

    /// Re-asserts activation after iOS idled the session outside an interruption (`restoreInput` step 3). No-op while
    /// `RTCAudioSession.isActive`; otherwise `setActive(true)`, counted against the most recent activation so
    /// `deactivate` stays balanced.
    func reactivate() throws {
        try queue.sync {
            lock.lock()
            let current = order.last
            lock.unlock()
            guard let current else { throw ConfigurationError.notActivated }
            guard !session.isActive else { return }
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            do {
                try session.setActive(true)
            } catch {
                throw ActivationError.classify(error)
            }
            lock.lock()
            if var entry = outstanding[current] {
                entry.count += 1
                outstanding[current] = entry
            }
            lock.unlock()
        }
    }

    /// iPhone speaker pin (`AudioRouteInspector.init(arbiter:)`): `overrideOutputAudioPort(.speaker)` when `speaker`,
    /// `(.none)` otherwise, under the configuration lock. Worker only, never from a callback. Valid only in
    /// `.playAndRecord` (`AudioSessionPlan.supportsSpeakerOverride`); the OS error is rethrown as `.failed(code:)`.
    func setSpeakerOverride(_ speaker: Bool) throws {
        try queue.sync {
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            let port: AVAudioSession.PortOverride = speaker ? .speaker : .none
            do {
                try session.overrideOutputAudioPort(port)
            } catch {
                throw ConfigurationError.failed(code: (error as NSError).code)
            }
        }
    }

    /// Idle microphone inventory: temporarily sets `.playAndRecord` with `[.allowBluetooth (HFP), .allowBluetoothA2DP]`
    /// **without activating**, runs `body` (which reads `availableInputs`), then restores the previous
    /// category/mode/options. Refused with `.refused` while any activation is outstanding or `AudioSessionOwner` is
    /// held (a session worker or local tool owns audio).
    func withTemporaryInventoryCategory<T>(_ body: () throws -> T) throws -> T {
        guard !hasActivation, !owner.isHeld else { throw ConfigurationError.refused }
        return try queue.sync {
            let previousCategory = AVAudioSession.Category(rawValue: session.category)
            let previousMode = AVAudioSession.Mode(rawValue: session.mode)
            let previousOptions = session.categoryOptions
            let inventoryOptions = AVAudioSession.CategoryOptions(
                rawValue: AudioSessionPlan.CategoryOptions([.allowBluetooth, .allowBluetoothA2DP]).rawValue)
            session.lockForConfiguration()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: inventoryOptions)
            } catch {
                session.unlockForConfiguration()
                throw ConfigurationError.failed(code: (error as NSError).code)
            }
            session.unlockForConfiguration()
            defer {
                session.lockForConfiguration()
                try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
                session.unlockForConfiguration()
            }
            return try body()
        }
    }

    // MARK: - Plan application (runs on `queue`)

    /// The `RTCAudioSessionConfiguration` WebRTC must re-apply in `configureWebRTCSession` (`AudioSessionPlan` mapping
    /// comment).
    static func webRTCConfiguration(for plan: AudioSessionPlan) -> RTCAudioSessionConfiguration {
        let configuration = RTCAudioSessionConfiguration()
        configuration.category = plan.category.rawValue
        configuration.mode = plan.mode.rawValue
        configuration.categoryOptions = AVAudioSession.CategoryOptions(rawValue: plan.options.rawValue)
        configuration.sampleRate = plan.sampleRate
        configuration.ioBufferDuration = plan.ioBufferDuration
        configuration.inputNumberOfChannels = plan.inputNumberOfChannels
        configuration.outputNumberOfChannels = plan.outputNumberOfChannels
        return configuration
    }

    /// Runs on the arbiter queue; see `prepare`.
    private func apply(_ plan: AudioSessionPlan) -> Result<Activation, ActivationError> {
        RTCAudioSessionConfiguration.setWebRTC(Self.webRTCConfiguration(for: plan))
        session.lockForConfiguration()
        do {
            try session.setCategory(
                AVAudioSession.Category(rawValue: plan.category.rawValue),
                mode: AVAudioSession.Mode(rawValue: plan.mode.rawValue),
                options: AVAudioSession.CategoryOptions(rawValue: plan.options.rawValue))
            try? session.setPreferredSampleRate(plan.sampleRate)
            try? session.setPreferredIOBufferDuration(plan.ioBufferDuration)
            try? session.session.setPrefersInterruptionOnRouteDisconnect(false)
            try session.setActive(true)
        } catch {
            session.unlockForConfiguration()
            return .failure(ActivationError.classify(error))
        }
        session.unlockForConfiguration()

        let accepted = plan.acceptsReadBack(
            category: AudioSessionPlan.Category(rawValue: session.category),
            mode: AudioSessionPlan.Mode(rawValue: session.mode),
            optionsRawValue: session.categoryOptions.rawValue)
        guard accepted else {
            session.lockForConfiguration()
            try? session.setActive(false)
            session.unlockForConfiguration()
            return .failure(ActivationError(kind: .configurationMismatch, code: nil))
        }

        lock.lock()
        nextID += 1
        let activation = Activation(id: nextID, plan: plan)
        outstanding[activation.id] = (plan: plan, count: 1)
        order.append(activation.id)
        lock.unlock()
        return .success(activation)
    }
}
