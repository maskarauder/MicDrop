// MPRemoteCommandCenter targets (replaces Media3 `LiveMediaPlayer` commands and `PlaybackLibraryCallback`).
//
// Targets are registered once at launch, before the first run-loop turn, so a background launch that delivers a command
// finds a target. Only play, pause, toggle and stop are ever enabled; every other command is disabled permanently and
// never repurposed (no fake lock-screen Stop). `SessionCoordinator` supplies the handlers and the enablement; handlers
// run on main.

import Foundation
import MediaPlayer

@MainActor
final class RemoteCommandRouter {
    /// Handlers for the four supported commands (table).
    struct Handlers {
        var play: @MainActor () -> MPRemoteCommandHandlerStatus
        var pause: @MainActor () -> MPRemoteCommandHandlerStatus
        var togglePlayPause: @MainActor () -> MPRemoteCommandHandlerStatus
        var stop: @MainActor () -> MPRemoteCommandHandlerStatus

        init(
            play: @escaping @MainActor () -> MPRemoteCommandHandlerStatus,
            pause: @escaping @MainActor () -> MPRemoteCommandHandlerStatus,
            togglePlayPause: @escaping @MainActor () -> MPRemoteCommandHandlerStatus,
            stop: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
        ) {
            self.play = play
            self.pause = pause
            self.togglePlayPause = togglePlayPause
            self.stop = stop
        }
    }

    /// Which supported commands are enabled.
    struct Enablement: Equatable, Sendable {
        var play: Bool
        var pause: Bool
        var togglePlayPause: Bool
        var stop: Bool

        static let none = Enablement(play: false, pause: false, togglePlayPause: false, stop: false)
        static let all = Enablement(play: true, pause: true, togglePlayPause: true, stop: true)
    }

    private let center: MPRemoteCommandCenter
    private var targets: [(command: MPRemoteCommand, target: Any)] = []
    private(set) var enablement: Enablement = .none
    private(set) var isInstalled = false

    init(center: MPRemoteCommandCenter = MPRemoteCommandCenter.shared()) {
        self.center = center
    }

    /// Registers the four targets once and disables every unsupported command (last row). Starts with
    /// `Enablement.none`; idempotent.
    func install(_ handlers: Handlers) {
        guard !isInstalled else { return }
        isInstalled = true
        register(center.playCommand, handlers.play)
        register(center.pauseCommand, handlers.pause)
        register(center.togglePlayPauseCommand, handlers.togglePlayPause)
        register(center.stopCommand, handlers.stop)
        for command in unsupportedCommands { command.isEnabled = false }
        apply(.none)
    }

    /// Sets `isEnabled` of the four supported commands (only when changed).
    func setEnabled(_ value: Enablement) {
        guard value != enablement else { return }
        apply(value)
    }

    /// Removes the targets (tests).
    func uninstall() {
        for entry in targets { entry.command.removeTarget(entry.target) }
        targets = []
        isInstalled = false
        apply(.none)
    }

    private func apply(_ value: Enablement) {
        enablement = value
        center.playCommand.isEnabled = value.play
        center.pauseCommand.isEnabled = value.pause
        center.togglePlayPauseCommand.isEnabled = value.togglePlayPause
        center.stopCommand.isEnabled = value.stop
    }

    /// MediaPlayer calls targets on the main thread; a call from any other thread is hopped
    /// synchronously to main (the handler result must be returned to MediaPlayer).
    private func register(
        _ command: MPRemoteCommand, _ handler: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget { _ in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { handler() }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { handler() }
            }
        }
        targets.append((command: command, target: target))
    }

    /// Every command MicDrop never supports ("`isEnabled = false` always").
    private var unsupportedCommands: [MPRemoteCommand] {
        [
            center.nextTrackCommand, center.previousTrackCommand,
            center.skipForwardCommand, center.skipBackwardCommand,
            center.seekForwardCommand, center.seekBackwardCommand,
            center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
            center.changeRepeatModeCommand, center.changeShuffleModeCommand,
            center.ratingCommand, center.likeCommand, center.dislikeCommand, center.bookmarkCommand,
            center.enableLanguageOptionCommand, center.disableLanguageOptionCommand,
        ]
    }
}
