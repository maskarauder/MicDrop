import MicDropCore
import XCTest

/// `MediaPresentation`: the Kotlin vectors of
/// `SessionLifecycleTest.mediaCardShowsPlayBeforeCleanupAndKeepsTransientIntentCancellable`, every phase, the
/// `LiveMediaPlayer.kt:25-26` output-hold rule and the iOS Now Playing status line.
final class MediaPresentationTests: XCTestCase {
    // MARK: - SessionLifecycleTest.kt

    func testMediaCardShowsPlayBeforeCleanupAndKeepsTransientIntentCancellable() {
        for phase in [SessionPhase.pausing, .paused] {
            XCTAssertEqual(
                MediaPresentation.of(phase, automatic: false, queued: false), card(true, false, false, false))
        }
        XCTAssertEqual(MediaPresentation.of(.pausing, automatic: false, queued: true), card(true, true, true, false))
        for phase in [SessionPhase.pausing, .interrupted] {
            XCTAssertEqual(MediaPresentation.of(phase, automatic: true, queued: false), card(true, true, false, true))
        }
        for phase in [SessionPhase.idle, .stopping, .ended] {
            XCTAssertEqual(
                MediaPresentation.of(phase, automatic: false, queued: false), card(false, false, false, false))
        }
    }

    // MARK: - Every phase

    func testEveryPhaseWithoutPendingIntent() {
        let expected: [SessionPhase: MediaPresentation] = [
            .idle: card(false, false, false, false),
            .connecting: card(true, true, true, false),
            .playing: card(true, true, false, false),
            .recovering: card(true, true, true, false),
            .routeRecovering: card(true, true, true, false),
            .pausing: card(true, false, false, false),
            .paused: card(true, false, false, false),
            .interrupted: card(true, false, false, false),
            .switching: card(true, true, true, false),
            .stopping: card(false, false, false, false),
            .ended: card(false, false, false, false),
        ]
        XCTAssertEqual(Set(expected.keys), Set(SessionPhase.allCases))
        for phase in SessionPhase.allCases {
            XCTAssertEqual(MediaPresentation.of(phase, automatic: false, queued: false), expected[phase], "\(phase)")
        }
    }

    func testAutomaticIntentOnlyAffectsPausingAndInterrupted() {
        for phase in SessionPhase.allCases {
            let plain = MediaPresentation.of(phase, automatic: false, queued: false)
            let automatic = MediaPresentation.of(phase, automatic: true, queued: false)
            if phase == .pausing || phase == .interrupted {
                XCTAssertEqual(automatic, card(true, true, false, true), "\(phase)")
            } else {
                XCTAssertEqual(automatic, plain, "\(phase)")
            }
        }
    }

    func testQueuedPlayShowsPauseWithBufferingAndBufferingIsNotGatedByVisibility() {
        XCTAssertEqual(MediaPresentation.of(.paused, automatic: false, queued: true), card(true, true, true, false))
        XCTAssertEqual(MediaPresentation.of(.playing, automatic: false, queued: true), card(true, true, true, false))
        XCTAssertEqual(MediaPresentation.of(.idle, automatic: false, queued: true), card(false, false, true, false))
        XCTAssertEqual(MediaPresentation.of(.ended, automatic: false, queued: true), card(false, false, true, false))
        XCTAssertEqual(MediaPresentation.of(.pausing, automatic: true, queued: true), card(true, true, true, true))
    }

    func testPlayWhenReadyImpliesVisible() {
        for phase in SessionPhase.allCases {
            for automatic in [false, true] {
                for queued in [false, true] {
                    let presentation = MediaPresentation.of(phase, automatic: automatic, queued: queued)
                    if presentation.playWhenReady { XCTAssertTrue(presentation.visible, "\(phase)") }
                    if presentation.suppressed { XCTAssertTrue(presentation.playWhenReady, "\(phase)") }
                }
            }
        }
    }

    // MARK: - LiveMediaPlayer.kt:25-26 output hold

    func testHeldEnabledOutputBuffersWhileActive() {
        var view = SessionView(phase: .playing, outputPause: .bluetooth)
        XCTAssertEqual(MediaPresentation.of(view: view, automatic: false, queued: false), card(true, true, true, false))
        view.outputEnabled = false
        XCTAssertEqual(
            MediaPresentation.of(view: view, automatic: false, queued: false), card(true, true, false, false))
        view.outputEnabled = true
        view.phase = .paused
        XCTAssertEqual(
            MediaPresentation.of(view: view, automatic: false, queued: false), card(true, false, false, false))
        view.phase = .interrupted
        XCTAssertEqual(MediaPresentation.of(view: view, automatic: true, queued: false), card(true, true, false, true))
        view.phase = .pausing
        XCTAssertEqual(MediaPresentation.of(view: view, automatic: true, queued: false), card(true, true, true, true))
        view.phase = .stopping
        XCTAssertEqual(
            MediaPresentation.of(view: view, automatic: false, queued: false), card(false, false, true, false))
        view.phase = .playing
        view.outputPause = nil
        XCTAssertEqual(
            MediaPresentation.of(view: view, automatic: false, queued: false), card(true, true, false, false))
    }

    func testViewOverlayMatchesThePhaseRuleWithoutAHold() {
        for phase in SessionPhase.allCases {
            for automatic in [false, true] {
                for queued in [false, true] {
                    XCTAssertEqual(
                        MediaPresentation.of(view: SessionView(phase: phase), automatic: automatic, queued: queued),
                        MediaPresentation.of(phase, automatic: automatic, queued: queued), "\(phase)")
                }
            }
        }
    }

    // MARK: - Now Playing status line

    func testNowPlayingStatusLine() {
        let cases: [(SessionView, Bool, Bool, String)] = [
            (SessionView(phase: .playing), false, false, "Live"),
            (SessionView(phase: .connecting), false, false, "Connecting"),
            (SessionView(phase: .recovering), false, false, "Recovering connection"),
            (SessionView(phase: .routeRecovering), false, false, "Restoring selected audio device"),
            (SessionView(phase: .switching), false, false, "Changing audio device"),
            (SessionView(phase: .playing, outputPause: .bluetooth), false, false, "Audio paused"),
            (SessionView(phase: .playing, outputPause: .route), false, false, "Audio paused"),
            (SessionView(phase: .recovering, outputPause: .route), false, false, "Recovering connection"),
            (SessionView(phase: .playing, outputEnabled: false, outputPause: .bluetooth), false, false, "Live"),
            (SessionView(phase: .pausing), true, false, "Waiting for interruption to end"),
            (SessionView(phase: .interrupted), true, false, "Waiting for interruption to end"),
            (SessionView(phase: .pausing, outputPause: .bluetooth), true, false, "Waiting for interruption to end"),
            (SessionView(phase: .pausing), false, false, "Paused"),
            (SessionView(phase: .paused), false, false, "Paused"),
            (SessionView(phase: .pausing), false, true, "Pausing"),
            (SessionView(phase: .paused), false, true, "Paused"),
        ]
        for (view, automatic, queued, status) in cases {
            XCTAssertEqual(
                MediaPresentation.nowPlayingStatus(view, automatic: automatic, queued: queued), status,
                "\(view.phase) automatic=\(automatic) queued=\(queued) pause=\(String(describing: view.outputPause))")
        }
    }

    func testSuppressedStatusIsTheInterruptedPhaseLabel() {
        XCTAssertEqual(
            MediaPresentation.nowPlayingStatus(SessionView(phase: .interrupted), automatic: true, queued: false),
            SessionPhase.interrupted.label)
    }

    func testMemberwiseInitializer() {
        let presentation = MediaPresentation(visible: true, playWhenReady: false, buffering: true, suppressed: false)
        XCTAssertTrue(presentation.visible)
        XCTAssertFalse(presentation.playWhenReady)
        XCTAssertTrue(presentation.buffering)
        XCTAssertFalse(presentation.suppressed)
    }

    private func card(_ visible: Bool, _ playWhenReady: Bool, _ buffering: Bool, _ suppressed: Bool)
        -> MediaPresentation
    {
        MediaPresentation(visible: visible, playWhenReady: playWhenReady, buffering: buffering, suppressed: suppressed)
    }
}
