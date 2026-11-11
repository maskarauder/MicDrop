import MicDropCore
import XCTest

/// `SessionView` and `SessionPhase`: defaults, the derived ownership flags for every phase, and the output-control
/// eligibility rules of `SessionLifecycle.kt:33-45`.
final class SessionViewTests: XCTestCase {
    func testDefaultsMatchKotlinWithTheIOSReadyMessage() {
        let view = SessionView()
        XCTAssertEqual(view.phase, .idle)
        XCTAssertEqual(view.message, "Ready. Choose your output in Control Center or with AirPlay.")
        XCTAssertEqual(SessionView.readyMessage, view.message)
        XCTAssertNil(view.diagnostics)
        XCTAssertEqual(view.destination, "")
        XCTAssertNil(view.failureId)
        XCTAssertTrue(view.outputEnabled)
        XCTAssertEqual(view.outputSelection, OutputSelection())
        XCTAssertNil(view.outputPause)
        XCTAssertEqual(view.networkStatus, "")
    }

    func testInitializerStoresEveryField() {
        let view = SessionView(
            phase: .recovering, message: "Recovering", diagnostics: "report", destination: "Windows: 10.0.0.2:47321",
            failureId: "token", outputEnabled: false, outputSelection: .restored(.phone), outputPause: .route,
            networkStatus: "Network: Cellular")
        XCTAssertEqual(view.phase, .recovering)
        XCTAssertEqual(view.message, "Recovering")
        XCTAssertEqual(view.diagnostics, "report")
        XCTAssertEqual(view.destination, "Windows: 10.0.0.2:47321")
        XCTAssertEqual(view.failureId, "token")
        XCTAssertFalse(view.outputEnabled)
        XCTAssertEqual(view.outputSelection, .restored(.phone))
        XCTAssertEqual(view.outputPause, .route)
        XCTAssertEqual(view.networkStatus, "Network: Cellular")
        XCTAssertNotEqual(view, SessionView())
    }

    func testDerivedOwnershipFlagsForEveryPhase() {
        // phase: (active, busy, retained, canSetOutput)
        let expected: [SessionPhase: (Bool, Bool, Bool, Bool)] = [
            .idle: (false, false, false, false),
            .connecting: (true, true, true, true),
            .playing: (true, true, true, true),
            .recovering: (true, true, true, true),
            .routeRecovering: (true, true, true, true),
            .pausing: (true, true, true, true),
            .paused: (false, false, true, true),
            .interrupted: (false, true, true, true),
            .switching: (true, true, true, true),
            .stopping: (true, true, true, false),
            .ended: (false, false, false, false),
        ]
        XCTAssertEqual(Set(expected.keys), Set(SessionPhase.allCases))
        for phase in SessionPhase.allCases {
            guard let flags = expected[phase] else { return XCTFail("missing \(phase)") }
            let view = SessionView(phase: phase)
            XCTAssertEqual(view.active, flags.0, "active \(phase)")
            XCTAssertEqual(view.busy, flags.1, "busy \(phase)")
            XCTAssertEqual(view.retained, flags.2, "retained \(phase)")
            XCTAssertEqual(view.canSetOutput, flags.3, "canSetOutput \(phase)")
        }
    }

    func testOutputPausedRequiresEnabledOutputAndAHold() {
        for pause in OutputPause.allCases {
            XCTAssertTrue(SessionView(phase: .playing, outputPause: pause).outputPaused, "\(pause)")
            XCTAssertFalse(SessionView(phase: .playing, outputEnabled: false, outputPause: pause).outputPaused)
        }
        XCTAssertFalse(SessionView(phase: .playing).outputPaused)
        XCTAssertTrue(SessionView(phase: .paused, outputPause: .route).outputPaused)
    }

    func testPhoneSpeakerFallbackIsOfferedOnlyForALiveDefaultSessionHeldForBluetooth() {
        for phase in SessionPhase.allCases {
            let view = SessionView(phase: phase, outputPause: .bluetooth)
            XCTAssertEqual(view.canUsePhoneSpeaker, phase == .playing || phase == .recovering, "\(phase)")
        }
        for pause in OutputPause.allCases where pause != .bluetooth {
            XCTAssertFalse(SessionView(phase: .playing, outputPause: pause).canUsePhoneSpeaker, "\(pause)")
        }
        XCTAssertFalse(SessionView(phase: .playing).canUsePhoneSpeaker)
        XCTAssertFalse(SessionView(phase: .playing, outputEnabled: false, outputPause: .bluetooth).canUsePhoneSpeaker)
        let explicitSelections = [
            OutputSelection.restored(.phone),
            OutputSelection.fallbackSpeaker(),
            OutputSelection(kind: .bluetooth, portType: "BluetoothA2DPOutput", uid: "headphones-uid"),
        ]
        for selection in explicitSelections {
            let view = SessionView(phase: .playing, outputSelection: selection, outputPause: .bluetooth)
            XCTAssertFalse(view.canUsePhoneSpeaker, "\(selection.kind)")
        }
    }

    func testFollowSystemOutputIsOfferedForALivePhoneSelection() {
        for phase in SessionPhase.allCases {
            let view = SessionView(phase: phase, outputSelection: .restored(.phone))
            XCTAssertEqual(view.canFollowSystemOutput, phase == .playing || phase == .recovering, "\(phase)")
        }
        XCTAssertTrue(SessionView(phase: .recovering, outputSelection: .fallbackSpeaker()).canFollowSystemOutput)
        XCTAssertFalse(SessionView(phase: .playing).canFollowSystemOutput)
        let bluetooth = OutputSelection(kind: .bluetooth, portType: "BluetoothA2DPOutput", uid: "headphones-uid")
        XCTAssertFalse(SessionView(phase: .playing, outputSelection: bluetooth).canFollowSystemOutput)
        XCTAssertFalse(
            SessionView(phase: .playing, outputEnabled: false, outputSelection: .restored(.phone)).canFollowSystemOutput
        )
    }

    func testDiagnosticSnapshotMarkerHidesPeriodicReportsFromTheStatusCard() {
        XCTAssertTrue(SessionView(message: "LAN snapshot: rtt 4 ms, loss 0.0%").messageIsDiagnosticSnapshot)
        XCTAssertTrue(SessionView(message: "Remote snapshot: relay").messageIsDiagnosticSnapshot)
        XCTAssertFalse(SessionView(message: "snapshot: leading marker without a space").messageIsDiagnosticSnapshot)
        XCTAssertFalse(SessionView(message: "Recovering connection").messageIsDiagnosticSnapshot)
        XCTAssertFalse(SessionView().messageIsDiagnosticSnapshot)
    }

    func testPhaseLabels() {
        let expected: [SessionPhase: String] = [
            .idle: "Ready",
            .connecting: "Connecting",
            .playing: "Playing",
            .recovering: "Recovering connection",
            .routeRecovering: "Restoring selected audio device",
            .pausing: "Pausing",
            .paused: "Paused",
            .interrupted: "Waiting for interruption to end",
            .switching: "Changing audio device",
            .stopping: "Stopping",
            .ended: "Stopped",
        ]
        XCTAssertEqual(Set(expected.keys), Set(SessionPhase.allCases))
        for phase in SessionPhase.allCases {
            XCTAssertEqual(phase.label, expected[phase], "\(phase)")
        }
    }

    func testPhaseOrderAndRawValuesAreTheCaseNames() {
        XCTAssertEqual(
            SessionPhase.allCases.map { $0.rawValue },
            [
                "idle", "connecting", "playing", "recovering", "routeRecovering", "pausing", "paused", "interrupted",
                "switching", "stopping", "ended",
            ])
    }
}
