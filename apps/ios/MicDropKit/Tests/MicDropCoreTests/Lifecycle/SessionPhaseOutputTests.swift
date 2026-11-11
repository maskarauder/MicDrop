import MicDropCore
import XCTest

/// Output phase rules shared by the worker, both session controllers and the UI: recovery of an existing output
/// selection is ROUTE_RECOVERING, in which an output choice is accepted; only a newly requested output being verified
/// is SWITCHING.
final class SessionPhaseOutputTests: XCTestCase {
    private let pinA = OutputSelection(kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "a")
    private let pinB = OutputSelection(kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "b")

    func testOutputChoiceAcceptanceForEveryPhase() {
        let expected: [SessionPhase: Bool] = [
            .idle: false, .connecting: false, .playing: true, .recovering: true, .routeRecovering: true,
            .pausing: false, .paused: true, .interrupted: true, .switching: false, .stopping: false, .ended: false,
        ]
        XCTAssertEqual(Set(expected.keys), Set(SessionPhase.allCases))
        for phase in SessionPhase.allCases {
            XCTAssertEqual(phase.acceptsOutputChoice, expected[phase], "\(phase)")
        }
    }

    func testHeartbeatPhaseSeparatesANewOutputFromRecoveryOfTheSelection() {
        // (outputSwitchPending, selectedOutputRecovering, routeRecovering, healthy) -> phase
        let cases: [(Bool, Bool, Bool, Bool, SessionPhase)] = [
            (true, false, false, true, .switching),
            (true, false, true, false, .switching),
            (true, true, false, true, .routeRecovering),
            (true, true, false, false, .routeRecovering),
            (false, true, false, true, .routeRecovering),
            (false, false, true, true, .routeRecovering),
            (false, false, true, false, .routeRecovering),
            (false, false, false, true, .playing),
            (false, false, false, false, .recovering),
        ]
        for (pending, recovering, route, healthy, phase) in cases {
            XCTAssertEqual(
                SessionPhase.heartbeat(
                    outputSwitchPending: pending, selectedOutputRecovering: recovering, routeRecovering: route,
                    healthy: healthy),
                phase, "\((pending, recovering, route, healthy))")
        }
    }

    /// The phase a session publishes for `route` (`outputSwitchPending` = pending explicit selection).
    private func phase(_ route: OutputRouteChange, probing: Bool = false) -> SessionPhase {
        SessionPhase.heartbeat(
            outputSwitchPending: route.pending && route.selection.explicit, selectedOutputRecovering: route.recovering,
            routeRecovering: probing, healthy: true)
    }

    func testSelectedBluetoothRecoveryAcceptsAReplacementThatIsVerifiedAsANewSwitch() {
        let route = OutputRouteChange(pinA)
        XCTAssertEqual(phase(route), .switching, "the initial pin verifies first")
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertEqual(phase(route), .playing)
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 1_000))
        XCTAssertEqual(phase(route), .routeRecovering)
        XCTAssertTrue(phase(route).acceptsOutputChoice)
        // Repeated route callbacks keep the one episode and its phase.
        XCTAssertFalse(route.recoverBluetooth(route.ticket, nowMs: 5_000))
        route.trackStarted()
        XCTAssertEqual(phase(route), .routeRecovering)

        let recovering = route.ticket
        XCTAssertTrue(route.request(pinB))
        XCTAssertEqual(phase(route), .switching)
        XCTAssertFalse(phase(route).acceptsOutputChoice)
        XCTAssertFalse(route.verified(recovering), "A's stale verification cannot release B")
        XCTAssertFalse(route.expired(21_000), "A's recovery deadline no longer applies")
        XCTAssertTrue(route.beginCheck(route.ticket, nowMs: 20_000))
        XCTAssertFalse(route.expired(24_999))
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertEqual(phase(route), .playing)
    }

    func testSpeakerRepairIsRecoveryAndDefaultProbingIsRouteRecovery() {
        let speaker = OutputRouteChange(OutputSelection.restored(.phone))
        XCTAssertTrue(speaker.verified(speaker.ticket))
        XCTAssertTrue(speaker.recoverSpeaker(speaker.ticket, nowMs: 0))
        XCTAssertEqual(phase(speaker), .routeRecovering)

        let following = OutputRouteChange(OutputSelection())
        XCTAssertEqual(phase(following), .playing)
        following.trackStarted()
        XCTAssertEqual(phase(following), .playing, "DEFAULT verification is never a switch")
        XCTAssertEqual(phase(following, probing: true), .routeRecovering)
    }

    func testOutputRecoveryInRouteRecoveringKeepsTheBackgroundLeaseThatSwitchingHeld() {
        for pause in [OutputPause.selectedBluetooth, .route, .bluetooth, .unavailable] {
            XCTAssertTrue(SessionPhase.routeRecovering.leasesOutputRecovery(pause: pause), "\(pause)")
        }
        XCTAssertFalse(SessionPhase.routeRecovering.leasesOutputRecovery(pause: nil), "headset microphone recovery")
        for phase in SessionPhase.allCases where phase != .routeRecovering {
            XCTAssertFalse(phase.leasesOutputRecovery(pause: .selectedBluetooth), "\(phase)")
            XCTAssertFalse(phase.leasesOutputRecovery(pause: nil), "\(phase)")
        }
        // The selected Bluetooth restore publishes ROUTE_RECOVERING with its pause, as SWITCHING did before.
        let route = OutputRouteChange(pinA)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 1_000))
        let pause = OutputPause.current(
            usesMediaOutput: true, focus: nil, route: route, policy: DefaultOutputPolicy(pinA, protectedSpeaker: false),
            bluetoothAvailable: true)
        XCTAssertEqual(pause, .selectedBluetooth)
        XCTAssertTrue(phase(route).leasesOutputRecovery(pause: pause))
    }

    func testRouteRecoveryKeepsThePlaybackPauseThatSwitchingOffered() {
        for phase in [SessionPhase.switching, .routeRecovering] {
            let render = PresentationFixtures.derive { input in
                input.saved = PresentationFixtures.pairedSaved
                input.session = PresentationFixtures.session(phase, outputSelection: pinA)
                input.selectedOutput = pinA
            }
            XCTAssertTrue(render.pauseVisible, "\(phase)")
            XCTAssertTrue(render.pauseEnabled, "\(phase)")
        }
    }

    func testOutputChooserFollowsTheSharedRuleInEveryRetainedPhase() {
        for phase in SessionPhase.allCases where SessionView(phase: phase).retained {
            for selection in [OutputSelection(), pinA] {
                let playback = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.session = PresentationFixtures.session(phase, outputSelection: selection)
                    input.selectedOutput = selection
                }
                XCTAssertEqual(playback.outputDeviceEnabled, phase.acceptsOutputChoice, "playback \(phase)")
                XCTAssertEqual(
                    playback.systemOutputPickerEnabled, phase.acceptsOutputChoice && !selection.explicit,
                    "a pinned output keeps the system picker off (\(phase))")
                let duplex = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.mic = PresentationFixtures.mic(phase, mode: .duplex, outputSelection: selection)
                    input.selectedOutput = selection
                }
                XCTAssertEqual(duplex.outputDeviceEnabled, phase.acceptsOutputChoice, "duplex \(phase)")
                let microphone = PresentationFixtures.derive { input in
                    input.saved = PresentationFixtures.pairedSaved
                    input.mic = PresentationFixtures.mic(phase, mode: .microphone, outputSelection: selection)
                }
                XCTAssertFalse(microphone.outputDeviceEnabled, "microphone-only \(phase)")
            }
        }
    }

    func testAPausedSessionKeepsThePickerOffForAnUnavailablePin() {
        // D042: before this change an idle-only rule enabled the picker for a Paused session whose pin was
        // not the route, so a car or headset Play could reconnect while the picker changed the route.
        let render = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.session = PresentationFixtures.session(.paused, outputSelection: pinA)
            input.selectedOutput = pinA
            input.outputAvailable = false
        }
        XCTAssertTrue(render.idle, "Paused is idle for the action bar")
        XCTAssertTrue(render.outputDeviceEnabled, "another output can still be chosen")
        XCTAssertFalse(render.systemOutputPickerEnabled)
        XCTAssertEqual(render.systemOutputPickerCaption, Strings.routePickerPinnedCaption)
    }
}
