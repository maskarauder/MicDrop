// Routes audio-session events and media commands to the session owner.
//
// Android has two independent focus listeners (PlaybackService, MicrophoneService) but at most one live owner; iOS has
// one `AudioSessionEventMonitor`, one `NowPlayingPublisher` and one `RemoteCommandRouter`, owned here. Every event goes
// to the microphone controller while `microphone.view.ownsSession`, else to the playback controller. Now Playing and
// remote-command enablement are refreshed synchronously from both controllers' `observe(_:)` publishes (`publish()`).

import AVFoundation
import Foundation
import MediaPlayer
import MicDropCore

@MainActor
final class SessionCoordinator {
    let playback: PlaybackSessionController
    let microphone: MicrophoneSessionController
    let monitor: AudioSessionEventMonitor
    let nowPlaying: NowPlayingPublisher
    let commands: RemoteCommandRouter
    let controlLog: ControlEventLog

    private var started = false
    private var monitorSubscription: AudioSessionEventMonitor.Subscription?
    /// Observation registrations of both controllers (kept alive; types are the owners').
    private var observations: [Any] = []

    /// `init(playback:microphone:monitor:nowPlaying:commands:)` plus the shared controls log.
    init(
        playback: PlaybackSessionController,
        microphone: MicrophoneSessionController,
        monitor: AudioSessionEventMonitor = .shared,
        nowPlaying: NowPlayingPublisher,
        commands: RemoteCommandRouter,
        controlLog: ControlEventLog
    ) {
        self.playback = playback
        self.microphone = microphone
        self.monitor = monitor
        self.nowPlaying = nowPlaying
        self.commands = commands
        self.controlLog = controlLog
    }

    /// Launch wiring (before the first run-loop turn): installs the remote-command targets, tells the playback
    /// controller who owns audio, subscribes the main sink, starts the monitor, observes both controllers (which
    /// publishes the restored PAUSED card, if any). Idempotent.
    func start() {
        guard !started else { return }
        started = true
        commands.install(
            RemoteCommandRouter.Handlers(
                play: { [weak self] in self?.playCommand() ?? .commandFailed },
                pause: { [weak self] in self?.pauseCommand() ?? .commandFailed },
                togglePlayPause: { [weak self] in self?.togglePlayPauseCommand() ?? .commandFailed },
                stop: { [weak self] in self?.stopCommand() ?? .commandFailed }))
        playback.microphoneOwnsSession = { [weak self] in self?.microphoneOwnsSession ?? false }
        monitorSubscription = monitor.addMainSink { [weak self] event in self?.handle(event) }
        monitor.start()
        observations.append(playback.observe { [weak self] _ in self?.refreshPresentation() })
        observations.append(microphone.observe { [weak self] _ in self?.refreshPresentation() })
        refreshPresentation()
    }

    /// `MicrophoneSessionController.view.ownsSession` (`session.retained`).
    var microphoneOwnsSession: Bool { microphone.view.ownsSession }

    // MARK: - Audio-session events (main sink, FIFO)

    /// Records the iOS event names; the controllers record their Android lifecycle names.
    /// - `.began`: `.appWasSuspended` → `interruption_began_suspended_ignored` only;
    /// `.routeDisconnected` → recorded, left to the route-loss sinks; otherwise microphone owner →
    /// `handleInterruption(began: true, …)` (duplex Path B / mic-only `stop(.focus)`), else
    /// `playback.interruptionBegan()`.
    /// - `.ended`: `interruption_ended_resume` / `_no_resume`, routed the same way.
    /// - route change, noisy (`RouteChange.isNoisy`): `route_old_device_unavailable`, then the owner's
    /// noisy rule (playback; microphone).
    /// - media services reset: `media_services_reset`, media-reset handling.
    func handle(_ event: AudioSessionEventMonitor.Event) {
        playback.expireInterruptionIfNeeded()
        switch event {
        case .interruptionBegan(let reason):
            if reason == .appWasSuspended {
                controlLog.record(ControlEventLog.Event.interruptionBeganSuspendedIgnored)
                return
            }
            controlLog.record(ControlEventLog.Event.interruptionBegan)
            guard reason.isFocusLoss else { break }
            if microphoneOwnsSession {
                microphone.handleInterruption(
                    began: true, shouldResume: false,
                    suspended: false, routeDisconnected: false)
            } else {
                playback.interruptionBegan()
            }
        case .interruptionEnded(let shouldResume):
            controlLog.record(
                shouldResume
                    ? ControlEventLog.Event.interruptionEndedResume
                    : ControlEventLog.Event.interruptionEndedNoResume)
            if microphoneOwnsSession {
                microphone.handleInterruption(began: false, shouldResume: shouldResume)
            } else {
                playback.interruptionEnded(shouldResume: shouldResume)
            }
        case .routeChanged(let change):
            guard change.isNoisy else { break }
            controlLog.record(ControlEventLog.Event.routeOldDeviceUnavailable)
            if microphoneOwnsSession {
                microphone.outputDeviceUnavailable()
            } else {
                playback.outputDeviceUnavailable()
            }
        case .mediaServicesWereReset:
            controlLog.record(ControlEventLog.Event.mediaServicesReset)
            if microphoneOwnsSession {
                microphone.mediaServicesWereReset()
            } else {
                playback.mediaServicesWereReset()
            }
        case .mediaServicesWereLost, .playOrRecordStarted, .playOrRecordStopped, .canPlayOrRecordChanged,
            .audioUnitStartFailed, .failedToSetActive, .playoutGlitches:
            // Recorded nowhere (media services lost is record-only and has no vocabulary entry); the engine and output
            // sinks consume these synchronously.
            break
        }
        refreshPresentation()
    }

    // MARK: - Remote commands

    /// Play: microphone owner → `resume()` when `canResume` (`.success`), else `.commandFailed`;
    /// playback → `.noActionableNowPlayingItem` without a token, else `playFromMediaControls()`.
    func playCommand() -> MPRemoteCommandHandlerStatus {
        playback.expireInterruptionIfNeeded()
        if microphoneOwnsSession {
            guard microphone.view.canResume else { return .commandFailed }
            microphone.resume()
            return .success
        }
        guard playback.token != nil else { return .noActionableNowPlayingItem }
        playback.playFromMediaControls()
        return .success
    }

    /// Pause: microphone owner → `.commandFailed` (duplex has no media Pause); playback → `pause()`.
    func pauseCommand() -> MPRemoteCommandHandlerStatus {
        playback.expireInterruptionIfNeeded()
        if microphoneOwnsSession { return .commandFailed }
        guard playback.token != nil else { return .noActionableNowPlayingItem }
        playback.pause()
        return .success
    }

    /// Headset/AirPods click: `presentation.playWhenReady` → pause, else play.
    func togglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        playback.expireInterruptionIfNeeded()
        if microphoneOwnsSession { return .commandFailed }
        guard playback.token != nil else { return .noActionableNowPlayingItem }
        if playback.presentation.playWhenReady {
            playback.pause()
        } else {
            playback.playFromMediaControls()
        }
        return .success
    }

    /// Stop (accessories/Siri; no lock-screen Stop): microphone owner → `stop()`; playback → `stop()`.
    func stopCommand() -> MPRemoteCommandHandlerStatus {
        playback.expireInterruptionIfNeeded()
        if microphoneOwnsSession {
            microphone.stop()
            return .success
        }
        guard playback.token != nil else { return .noActionableNowPlayingItem }
        playback.stop()
        return .success
    }

    // MARK: - Presentation

    /// Now Playing + command enablement for the current owner. Microphone owner: the card for non-mixable plans, `play`
    /// iff `canResume`, `stop` enabled, pause/toggle disabled; nothing for a mixable mic-only plan. Playback: the card;
    /// all four commands enabled iff the presentation is visible. Local tools never publish.
    func refreshPresentation() {
        if microphoneOwnsSession {
            let view = microphone.view
            nowPlaying.publishMicrophone(
                view, title: microphone.nowPlayingTitle,
                detail: microphone.nowPlayingDetail)
            if nowPlaying.current != nil {
                commands.setEnabled(
                    RemoteCommandRouter.Enablement(
                        play: view.canResume, pause: false,
                        togglePlayPause: false, stop: true))
            } else {
                commands.setEnabled(.none)
            }
            return
        }
        nowPlaying.update(playback.nowPlayingState)
        commands.setEnabled(playback.presentation.visible ? .all : .none)
    }

    // MARK: - App lifecycle (forwarded by AppLifecycle)

    /// Scene-phase entry point (deadline check at every entry; visibility rules belong to the UI). No session
    /// transition.
    func sceneChanged(visible: Bool, active: Bool) {
        playback.expireInterruptionIfNeeded()
        refreshPresentation()
    }

    /// `UIApplication.willResignActive` / `didBecomeActive` (microphone keep-alive). The microphone controller may also
    /// observe these itself (`observesApplicationState`); its handler ignores repeats.
    func applicationActiveChanged(_ active: Bool) {
        playback.applicationActiveChanged(active)
        microphone.applicationActiveChanged(active)
        refreshPresentation()
    }

    /// `applicationWillTerminate`: records `app_terminating` once, then each owner closes its live receiver with
    /// `.service` and waits ≤ 2000 ms LAN / 3000 ms remote (at most one owner has a live session, so the total bound
    /// holds).
    func applicationWillTerminate() {
        controlLog.record(ControlEventLog.Event.appTerminating)
        microphone.applicationWillTerminate()
        playback.applicationWillTerminate()
    }
}
