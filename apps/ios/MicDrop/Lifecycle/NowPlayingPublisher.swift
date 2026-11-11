// Lock-screen / Control Center "Now Playing" card.
//
// Port of Media3 `LiveMediaPlayer.update` (`LiveMediaPlayer.kt:23-31`) onto `MPNowPlayingInfoCenter`. The publisher
// never connects, activates audio or starts work (`PlaybackService.kt:266-267`); `SessionCoordinator` decides which
// controller it reflects. Local tools never publish. The `NowPlayingController` is superseded.

import Foundation
import MediaPlayer
import MicDropCore

@MainActor
final class NowPlayingPublisher {
    /// Lifecycle inputs of the playback card (`nowPlaying.update(view, token, resumeOnFocus, playAfterPause)`).
    struct PlaybackState: Equatable, Sendable {
        var view: SessionView
        var token: String?
        /// `SessionLifecycle.resumeOnFocus`.
        var automatic: Bool
        /// `SessionLifecycle.playAfterPause`.
        var queued: Bool
    }

    /// The published card in comparable form (the info dictionary is `[String: Any]`).
    struct Card: Equatable, Sendable {
        var title: String
        var artist: String
        /// Status line (`statusLine`): replaces the Media3 buffering spinner and the suppressed state.
        var album: String
        /// `MPNowPlayingInfoPropertyPlaybackRate`: `playWhenReady ? 1 : 0` (an automatic interruption shows Pause so
        /// pressing it cancels the automatic resume).
        var rate: Double
        /// `MPNowPlayingInfoPropertyExternalContentIdentifier`, `"live/<token>"` (Media3 mediaId).
        var contentIdentifier: String

        init(title: String, artist: String, album: String, rate: Double, contentIdentifier: String) {
            self.title = title
            self.artist = artist
            self.album = album
            self.rate = rate
            self.contentIdentifier = contentIdentifier
        }

        /// The `nowPlayingInfo` dictionary.
        var info: [String: Any] {
            [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: artist,
                MPMediaItemPropertyAlbumTitle: album,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: rate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyExternalContentIdentifier: contentIdentifier,
            ]
        }
    }

    /// Media3 item title (`LiveMediaPlayer.kt`).
    static let playbackTitle = "MicDrop live audio"
    /// Artist line when no output pause applies.
    static let defaultArtist = "Windows audio"

    private let center: MPNowPlayingInfoCenter
    /// The card currently set on the info center, nil when cleared.
    private(set) var current: Card?

    init(center: MPNowPlayingInfoCenter = MPNowPlayingInfoCenter.default()) {
        self.center = center
    }

    // MARK: - Publishing

    /// Playback card. Sets the info only when the card changed; clears it when the presentation is not visible
    /// (invariant 6: nil exactly when not visible).
    func update(_ state: PlaybackState) {
        apply(Self.playbackCard(state))
    }

    /// Microphone/duplex card: only for non-mixable plans while the microphone controller owns the session. `title` /
    /// `detail` are the texts (`MicrophoneSessionController.nowPlayingTitle` / `nowPlayingDetail`).
    func publishMicrophone(_ view: MicrophoneView?, title: String, detail: String) {
        apply(view.flatMap { Self.microphoneCard($0, title: title, detail: detail) })
    }

    /// Clears the card (`nowPlayingInfo = nil`, `playbackState = .stopped`).
    func clear() {
        apply(nil)
    }

    private func apply(_ card: Card?) {
        guard card != current else { return }
        current = card
        if let card {
            center.nowPlayingInfo = card.info
            center.playbackState = card.rate > 0 ? .playing : .paused
        } else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }

    // MARK: - Pure card construction (testable)

    /// `nowPlaying(view, token, automatic, queued)`: `MediaPresentation.of(view:…)` (includes the output-hold buffering
    /// rule, `LiveMediaPlayer.kt:25-26`); nil unless visible and a token exists; artist = `outputPauseDetail ??
    /// "Windows audio"` (the pause text, naming the session's selected-Bluetooth window); album =
    /// `MediaPresentation.nowPlayingStatus`; rate = `playWhenReady ? 1 : 0`.
    static func playbackCard(_ state: PlaybackState) -> Card? {
        let presentation = MediaPresentation.of(view: state.view, automatic: state.automatic, queued: state.queued)
        guard presentation.visible, let token = state.token else { return nil }
        return Card(
            title: playbackTitle,
            artist: state.view.outputPauseDetail ?? defaultArtist,
            album: MediaPresentation.nowPlayingStatus(
                state.view, automatic: state.automatic,
                queued: state.queued),
            rate: presentation.playWhenReady ? 1 : 0,
            contentIdentifier: "live/\(token)")
    }

    /// visible while `view.ownsSession`, phase ∉ {idle, stopping, ended} and the plan is not mixable (mic-only with a
    /// non-Bluetooth input is mixable). Title per mode (`MicDrop desktop audio + microphone` / `MicDrop microphone`,
    /// supplied by the caller), artist = `detail`, album = phase label, rate 1 while live (connecting, playing,
    /// recovering, route recovering, switching), else 0.
    static func microphoneCard(_ view: MicrophoneView, title: String, detail: String) -> Card? {
        guard view.ownsSession, view.mode != .playback else { return nil }
        let phase = view.session.phase
        guard phase != .idle, phase != .stopping, phase != .ended else { return nil }
        let mixable = view.mode == .microphone && !view.input.isBluetooth
        guard !mixable else { return nil }
        let live: Set<SessionPhase> = [.connecting, .playing, .recovering, .routeRecovering, .switching]
        return Card(
            title: title,
            artist: detail,
            album: phase.label,
            rate: live.contains(phase) ? 1 : 0,
            contentIdentifier: "live/microphone")
    }
}
