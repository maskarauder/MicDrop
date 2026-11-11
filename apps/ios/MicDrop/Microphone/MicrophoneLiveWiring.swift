import AVFoundation
import Foundation
import MicDropCore
import WebRTC

// Production wiring of the microphone subsystem to other app-target types. Every external
// signature this directory assumes is used only in this file: `AudioSessionArbiter` (+ nested
// `Activation`, `ActivationError`), `AudioPreferencesStore`, `BackgroundExecutionLease`,
// `MediaEngine`, `SessionController`/`SessionDependencies`, `SavedConnectionStore`, and
// `SystemMonotonicClock`. Top-level `ObservationToken` is used by
// `MicrophoneSessionController.observe(_:)`.

// MARK: - Route reads + arbiter writes

extension MicrophoneRouting {
    /// Live `SessionControl`: reads `RTCAudioSession`/`AVAudioSession` state directly (reads are not configuration) and
    /// sends the two writes through `AudioSessionArbiter`.
    final class LiveSession: SessionControl, @unchecked Sendable {
        private let arbiter: AudioSessionArbiter
        private let audioSession: RTCAudioSession

        init(arbiter: AudioSessionArbiter, audioSession: RTCAudioSession = RTCAudioSession.sharedInstance()) {
            self.arbiter = arbiter
            self.audioSession = audioSession
        }

        /// Portable descriptor of one AVFoundation port (identity values stay in memory only).
        static func descriptor(_ port: AVAudioSessionPortDescription, isInput: Bool) -> AudioPortDescriptor {
            AudioPortDescriptor(uid: port.uid, type: port.portType.rawValue, isInput: isInput, name: port.portName)
        }

        func availableInputs() -> [AudioPortDescriptor]? {
            audioSession.session.availableInputs?.map { LiveSession.descriptor($0, isInput: true) }
        }

        func currentInputs() -> [AudioPortDescriptor] {
            audioSession.currentRoute.inputs.map { LiveSession.descriptor($0, isInput: true) }
        }

        func currentOutputs() -> [AudioPortDescriptor] {
            audioSession.currentRoute.outputs.map { LiveSession.descriptor($0, isInput: false) }
        }

        var sampleRate: Double { audioSession.sampleRate }
        var outputNumberOfChannels: Int { audioSession.outputNumberOfChannels }
        var isActive: Bool { audioSession.isActive }
        var categoryRawValue: String { audioSession.category }
        var modeRawValue: String { audioSession.mode }
        var categoryOptionsRawValue: UInt { audioSession.categoryOptions.rawValue }

        /// `AudioSessionArbiter.setPreferredInput(uid:)` — synchronous, worker-safe; nil clears the preference.
        func setPreferredInput(uid: String?) throws {
            try arbiter.setPreferredInput(uid: uid)
        }

        /// `AudioSessionArbiter.reactivate()` — synchronous, worker-safe. A busy activation (insufficientPriority /
        /// cannotInterruptOthers / siriIsRecording) is iOS's "already in a call or communication mode" →
        /// `MicrophoneRouteError(.inUse)` (IN_USE row); other errors propagate.
        func reactivate() throws {
            do {
                try arbiter.reactivate()
            } catch let error as AudioSessionArbiter.ActivationError where error.isBusy {
                throw MicrophoneRouteError(.inUse)
            }
        }
    }

    /// Production routing for one session (created by the worker at INPUT_ROUTE with the session's clock;
    /// `lost` = the worker's `inputRouteLost()`).
    convenience init(
        selection: MicrophoneSelection, arbiter: AudioSessionArbiter,
        clock: any MonotonicClock = SystemMonotonicClock(), lost: @escaping @Sendable () -> Void
    ) {
        self.init(
            selection: selection, session: LiveSession(arbiter: arbiter), calls: SystemCallActivity(),
            clock: clock, lost: lost)
    }
}

// MARK: - Selector sources

extension MicrophoneInventory {
    /// Production inventory: current inputs from the live session, idle inputs under the arbiter's
    /// temporary inventory category (refused while any session is retained or a local tool runs).
    static func live(arbiter: AudioSessionArbiter) -> MicrophoneInventory {
        let session = MicrophoneRouting.LiveSession(arbiter: arbiter)
        return MicrophoneInventory(
            sources: Sources(
                currentInputs: { session.availableInputs() },
                currentCategoryListsBluetooth: {
                    session.categoryRawValue == AudioSessionPlan.Category.playAndRecord.rawValue
                        && AudioSessionPlan.CategoryOptions(rawValue: session.categoryOptionsRawValue).contains(
                            .allowBluetooth)
                },
                idleInputs: {
                    // `withTemporaryInventoryCategory<T>(_ body: () throws -> T) throws -> T`; refused (nil here) while
                    // any activation is outstanding or `AudioSessionOwner` is held.
                    try? arbiter.withTemporaryInventoryCategory { session.availableInputs() }
                }))
    }
}

// MARK: - Capture engine

/// `MediaEngine` already offers the two capture primitives (`setMicrophoneSampleGate(open:)`, `setCaptureRunning(_:) ->
/// Int`).
extension MediaEngine: MicrophoneCapture.Engine {}

// MARK: - Background lease

/// `BackgroundExecutionLease(name:onExpire:)` with `isHeld`, `begin()`, `end()`.
extension BackgroundExecutionLease: MicrophoneSessionController.BackgroundLease {}

// MARK: - Controller dependencies

extension MicrophoneSessionController.Dependencies {
    /// Production collaborators. `outputAvailable`/`refreshOutput` come from the output provider (`OutputChoices`,:
    /// `speakerPinnable` is computed from the plan and the microphone input); `sessionDependencies` builds the
    /// per-session transport/engine/arbiter bundle. The arbiter `Activation` taken by `activateAudio` is kept and
    /// released by `deactivateAudio` with the handle form (never the handle-less form, which could release another
    /// owner's activation).
    @MainActor
    static func live(
        arbiter: AudioSessionArbiter,
        preferences: AudioPreferencesStore,
        savedConnections: SavedConnectionStore,
        inventory: MicrophoneInventory,
        outputAvailable: @escaping @MainActor (OutputSelection, MicrophoneSelection) -> Bool,
        refreshOutput: @escaping @MainActor (OutputSelection, MicrophoneSelection) -> OutputSelection?,
        sessionDependencies: @escaping @MainActor (SessionConfiguration) throws -> SessionDependencies,
        clock: any MonotonicClock = SystemMonotonicClock()
    ) -> MicrophoneSessionController.Dependencies {
        let handle = MicrophoneActivationHandle()
        return MicrophoneSessionController.Dependencies(
            clock: clock,
            permission: SystemMicrophonePermission(),
            inputAvailable: { inventory.available($0) },
            outputAvailable: outputAvailable,
            refreshOutput: refreshOutput,
            loadPreferences: { preferences.load() },
            updatePreferences: { change in _ = preferences.update(change) },
            activateAudio: { plan, completion in
                // `prepare(_:completion:)`: the completion already runs on the main actor (FIFO).
                arbiter.prepare(plan) { result in
                    switch result {
                    case .success(let activation):
                        // A replacement connection (live input change) activates while the previous
                        // activation is still held: keep the new one, release the old (reference counted).
                        let previous = handle.activation
                        handle.activation = activation
                        if let previous { arbiter.deactivate(previous, notifyOthers: true) }
                        completion(.success)
                    case .failure(let error):
                        completion(error.isBusy ? .busy : (error.isBackgroundStart ? .backgroundStart : .failed))
                    }
                }
            },
            deactivateAudio: {
                guard let activation = handle.activation else { return }
                handle.activation = nil
                arbiter.deactivate(activation, notifyOthers: true)
            },
            makeReceiver: { configuration, callbacks in
                SessionController(
                    configuration, callbacks: callbacks, dependencies: try sessionDependencies(configuration))
            },
            rememberConnection: { savedConnections.remember($0) },
            makeLease: { onExpire in BackgroundExecutionLease(name: "MicDrop microphone", onExpire: onExpire) },
            restoredOutput: { preferences.restoredOutputSelection() },
            rememberOutput: { _ = preferences.rememberOutput($0) },
            rememberInput: { _ = preferences.rememberInput($0) })
    }
}

/// The arbiter activation held by the microphone controller between `activateAudio` and
/// `deactivateAudio` (file-private helper of `Dependencies.live`).
@MainActor
private final class MicrophoneActivationHandle {
    var activation: AudioSessionArbiter.Activation?

    init() {}
}
