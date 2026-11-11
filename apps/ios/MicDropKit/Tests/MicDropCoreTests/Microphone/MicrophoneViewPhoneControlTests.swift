import MicDropCore
import XCTest

/// `MicrophoneView.offersPhoneControlMute` (phone settings exchange v1, D046): Android's `muted.takeIf { !changing &&
/// canSetMuted(!muted) }` (`MicrophoneService.kt:206`) plus (2026-10-27) for an unmute: record permission granted now,
/// capture the phone itself enabled in this session, and the iPhone condition (the foreground or a muted capture that
/// already runs).
final class MicrophoneViewPhoneControlTests: XCTestCase {
    private func view(
        _ phase: SessionPhase, muted: Bool, changing: Bool = false, mode: StreamMode = .microphone
    ) -> MicrophoneView {
        MicrophoneView(session: SessionView(phase: phase), muted: muted, changing: changing, mode: mode)
    }

    /// The four terms of one call, named for the failure messages.
    private struct Terms: CustomStringConvertible {
        var active: Bool
        var retained: Bool
        var permission: Bool
        var enabled: Bool

        /// All sixteen combinations.
        static let all: [Terms] = (0..<16).map { bits in
            Terms(active: bits & 1 != 0, retained: bits & 2 != 0, permission: bits & 4 != 0, enabled: bits & 8 != 0)
        }

        var description: String {
            "active: \(active), retained: \(retained), permission: \(permission), enabled: \(enabled)"
        }
    }

    private func offers(_ view: MicrophoneView, _ terms: Terms) -> Bool {
        view.offersPhoneControlMute(
            applicationActive: terms.active, captureRetainedWhileMuted: terms.retained,
            permissionGranted: terms.permission, captureEnabledThisSession: terms.enabled)
    }

    /// The whole table in every settled phase of both microphone modes: Mute ignores the four terms; Unmute needs
    /// permission, a capture the phone enabled this session, and the foreground or a running muted capture.
    func testTruthTable() {
        for mode in [StreamMode.microphone, .duplex] {
            for phase in [SessionPhase.playing, .recovering, .routeRecovering] {
                for terms in Terms.all {
                    XCTAssertTrue(
                        offers(view(phase, muted: false, mode: mode), terms), "Mute, \(mode) \(phase) \(terms)")
                    XCTAssertEqual(
                        offers(view(phase, muted: true, mode: mode), terms),
                        terms.permission && terms.enabled && (terms.active || terms.retained),
                        "Unmute, \(mode) \(phase) \(terms)")
                    for muted in [false, true] {
                        XCTAssertFalse(
                            offers(view(phase, muted: muted, changing: true, mode: mode), terms),
                            "changing, muted: \(muted), \(mode) \(phase) \(terms)")
                    }
                }
            }
        }
    }

    func testMuteIsOfferedWheneverASettledSessionIsUnmuted() {
        for mode in [StreamMode.microphone, .duplex] {
            for phase in [SessionPhase.playing, .recovering, .routeRecovering] {
                for active in [false, true] {
                    XCTAssertTrue(
                        view(phase, muted: false, mode: mode).offersPhoneControlMute(
                            applicationActive: active, captureRetainedWhileMuted: false, permissionGranted: false,
                            captureEnabledThisSession: false),
                        "\(mode) \(phase) active: \(active): Mute only withholds the microphone")
                }
            }
        }
    }

    func testUnmuteNeedsTheForegroundOrAMutedCaptureThatAlreadyRuns() {
        for mode in [StreamMode.microphone, .duplex] {
            let muted = view(.playing, muted: true, mode: mode)
            XCTAssertTrue(
                muted.offersPhoneControlMute(
                    applicationActive: true, captureRetainedWhileMuted: false, permissionGranted: true,
                    captureEnabledThisSession: true))
            XCTAssertTrue(
                muted.offersPhoneControlMute(
                    applicationActive: false, captureRetainedWhileMuted: true, permissionGranted: true,
                    captureEnabledThisSession: true))
            XCTAssertFalse(
                muted.offersPhoneControlMute(
                    applicationActive: false, captureRetainedWhileMuted: false, permissionGranted: true,
                    captureEnabledThisSession: true),
                "\(mode): an unmute in the background would have to start capture")
        }
    }

    /// Windows never starts the first capture (a Mute tapped while connecting) or acts without permission, even in the
    /// foreground with a muted capture running.
    func testUnmuteNeedsPermissionAndACaptureThePhoneEnabled() {
        for mode in [StreamMode.microphone, .duplex] {
            let muted = view(.playing, muted: true, mode: mode)
            XCTAssertFalse(
                muted.offersPhoneControlMute(
                    applicationActive: true, captureRetainedWhileMuted: true, permissionGranted: true,
                    captureEnabledThisSession: false),
                "\(mode): the phone never opened capture in this session")
            XCTAssertFalse(
                muted.offersPhoneControlMute(
                    applicationActive: true, captureRetainedWhileMuted: true, permissionGranted: false,
                    captureEnabledThisSession: true),
                "\(mode): record permission is not granted")
        }
    }

    func testAChangeInFlightOrAPhaseWithoutTheToggleHidesTheField() {
        let all = Terms(active: true, retained: true, permission: true, enabled: true)
        for muted in [false, true] {
            XCTAssertFalse(offers(view(.playing, muted: muted, changing: true), all), "changing, muted: \(muted)")
        }
        for phase in [SessionPhase.connecting, .switching, .idle, .paused, .ended] {
            XCTAssertFalse(offers(view(phase, muted: true), all), "\(phase): an unmute needs a settled live session")
        }
        XCTAssertFalse(offers(view(.playing, muted: false, mode: .playback), all), "playback has no microphone")
    }
}
