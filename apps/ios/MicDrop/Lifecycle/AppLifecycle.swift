// Application lifecycle hooks the App entry calls.
//
// Android `MicDropApplication` + `PlaybackService.onDestroy` / `MicrophoneService.onDestroy` + activity scene
// callbacks, reduced to what the lifecycle owns:
// - process launch hygiene (before any factory, ADM or output probe exists):
// `AudioSessionArbiter.configureForLaunch()` (`WebRTCRuntime.configureAtLaunch()`: useManualAudio, isAudioEnabled =
// false; `MicrophoneCapture.setApplicationInputMuted(false)`, `setPrefersInterruptionOnRouteDisconnect(false)`);
// - starting the coordinator before the first run-loop turn (remote-command targets, event
//   monitor; the playback controller already restored PAUSED from the ticket in its init);
// - `UIApplication.willTerminateNotification`: bounded best-effort `/stop service_stopped`;
// - `willResignActive` / `didBecomeActive` (microphone keep-alive) and scene-phase entries.
//
// Not here (other owners' launch hooks, called by the App entry before `start()`): crash capture
// (`CrashDiagnostics.install()`) and the install sentinel (applied by `SavedConnectionStore.shared`). No connection is
// ever started at launch.
//
// Composition (App entry / `AppEnvironment`, which builds `Dependencies(...)` directly):
// ```
// AppLifecycle.prepareProcess // App.init, first statement let log = ControlEventLog(clock: SystemMonotonicClock) let
// playback = PlaybackSessionController(dependencies:.live(
//     sessionDependencies: { configuration in try sessionDependencies(for: configuration) },
//     controlLog: log, clock: SystemMonotonicClock,
//     outputAvailable: { outputs.available($0) }, outputRefresh: { outputs.refresh($0) }))
// let coordinator = SessionCoordinator(playback: playback, microphone: microphoneController,
//     nowPlaying: NowPlayingPublisher, commands: RemoteCommandRouter, controlLog: log)
// let lifecycle = AppLifecycle(coordinator: coordinator); lifecycle.start
// ```

import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppLifecycle {
    /// The started instance (one per process), for code that has no reference to the environment.
    private(set) static var current: AppLifecycle?

    let arbiter: AudioSessionArbiter
    let coordinator: SessionCoordinator
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var terminating = false

    init(
        arbiter: AudioSessionArbiter = .shared, coordinator: SessionCoordinator,
        center: NotificationCenter = .default
    ) {
        self.arbiter = arbiter
        self.coordinator = coordinator
        self.center = center
    }

    /// call as the first statement of `App.init`, before any session, output probe or factory can exist. Idempotent.
    static func prepareProcess(arbiter: AudioSessionArbiter = .shared) {
        arbiter.configureForLaunch()
    }

    /// Launch wiring (idempotent): process hygiene (again, harmless), `coordinator.start()`
    /// (remote-command targets before the first run-loop turn, event monitor, controller
    /// observation), and the UIApplication notification observers. Sets `AppLifecycle.current`.
    func start() {
        guard !started else { return }
        started = true
        AppLifecycle.current = self
        AppLifecycle.prepareProcess(arbiter: arbiter)
        coordinator.start()
        // queue nil → the block runs synchronously on the posting (main) thread, so the bounded termination wait
        // happens inside the system's `willTerminate` window.
        observers.append(
            center.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationWillTerminate() }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationActiveChanged(false) }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationActiveChanged(true) }
            })
    }

    /// SwiftUI `scenePhase` forward (`screenVisible = phase != .background`, `screenResumed = phase == .active`).
    /// Session state never changes on scene transitions; the controllers only run their deadline checks. UI-flow
    /// cancellation on `.background` and local-tool stops on leaving `.active` stay in the UI.
    func scenePhaseChanged(_ phase: ScenePhase) {
        coordinator.sceneChanged(visible: phase != .background, active: phase == .active)
    }

    /// `false` on `willResignActive` (still allowed to start input), `true` on `didBecomeActive`.
    func applicationActiveChanged(_ active: Bool) {
        guard !terminating else { return }
        coordinator.applicationActiveChanged(active)
    }

    /// records `app_terminating` (once, in the coordinator), closes the live receiver with `.service`, blocks the main
    /// thread at most 2000 ms (LAN) / 3000 ms (remote) for the worker's `/stop` result (iOS kills the process ~5 s
    /// after `willTerminate`), keeps the resume ticket. Also callable from a
    /// `UIApplicationDelegate.applicationWillTerminate(_:)`; runs once.
    func applicationWillTerminate() {
        guard !terminating else { return }
        terminating = true
        coordinator.applicationWillTerminate()
    }
}
