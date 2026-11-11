import MicDropCore
import XCTest

private let pin = OutputSelection(
    kind: .bluetooth, portType: RouteOutput.PortType.bluetoothA2DP, uid: "synthetic-left")

/// Ticketed selection/verification (`OutputSelectionTest.kt:44-85`).
final class OutputRouteChangeTests: XCTestCase {
    func testConstantsAndInitialState() {
        XCTAssertEqual(OutputRouteChange.defaultLimitMs, 5_000)
        XCTAssertEqual(OutputRouteChange.bluetoothRecoveryMs, 20_000)
        let following = OutputRouteChange(OutputSelection())
        XCTAssertEqual(following.limitMs, 5_000)
        XCTAssertEqual(following.bluetoothRecoveryLimitMs, OutputRouteChange.bluetoothRecoveryMs)
        XCTAssertEqual(following.ticket, 0)
        XCTAssertFalse(following.pending)
        XCTAssertFalse(following.invalid)
        XCTAssertFalse(following.recovering)
        XCTAssertEqual(following.selection, OutputSelection())
        // An explicit initial selection starts pending: it must be verified before audio is released.
        let pinned = OutputRouteChange(pin)
        XCTAssertTrue(pinned.pending)
        XCTAssertEqual(pinned.ticket, 0)
        XCTAssertFalse(pinned.expired(Int64.max))
    }

    func testLateCallbacksAndVerificationCannotReleaseANewerChoiceOrStop() {
        let route = OutputRouteChange(pin)
        let old = route.ticket
        route.beginCheck(old, nowMs: 100)
        XCTAssertTrue(route.request(OutputSelection.restored(.phone)))
        XCTAssertFalse(route.verified(old))
        XCTAssertFalse(route.lost(old))
        XCTAssertTrue(route.pending)
        let current = route.ticket
        var gate = AudioOutputGate(enabled: false, held: true)
        if route.verified(current) { gate.verified() }
        XCTAssertTrue(gate.muted)  // Route completion preserves user silence.
        gate.stop()
        route.stop()
        XCTAssertFalse(route.request(pin))
        XCTAssertFalse(route.verified(current))
        gate.request(true)
        gate.verified()
        XCTAssertTrue(gate.muted)
    }

    func testRouteVerificationHasABoundedWindowAndDefaultClearsAPin() {
        let route = OutputRouteChange(pin, limitMs: 5_000)
        route.beginCheck(route.ticket, nowMs: 1_000)
        route.beginCheck(route.ticket, nowMs: 4_000)
        XCTAssertFalse(route.expired(5_999))
        XCTAssertTrue(route.expired(6_000))
        XCTAssertTrue(route.request(OutputSelection()))
        XCTAssertFalse(route.expired(9_000))
        XCTAssertTrue(route.pending)  // Explicitly clearing the old preference still needs an acknowledgment.
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertFalse(route.lost(route.ticket))  // Default delegates later media routing to iOS.
    }

    func testAnUnexpectedPinnedRouteLossCannotBeVerifiedAway() {
        let route = OutputRouteChange(pin)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.lost(route.ticket))
        XCTAssertTrue(route.invalid)
        XCTAssertFalse(route.verified(route.ticket))
        XCTAssertTrue(route.request(OutputSelection.restored(.phone)))
        XCTAssertFalse(route.invalid)
        XCTAssertTrue(route.pending)
    }

    func testRequestsAdvanceTheTicketAndResetEveryEpisodeField() {
        let route = OutputRouteChange(pin)
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.recoverBluetooth(route.ticket, nowMs: 0))
        let before = route.ticket
        XCTAssertTrue(route.request(pin))
        XCTAssertEqual(route.ticket, before + 1)
        XCTAssertTrue(route.pending)
        XCTAssertFalse(route.recovering)
        XCTAssertFalse(route.invalid)
        // The 20 s deadline was cleared; the new request has none until beginCheck.
        XCTAssertFalse(route.expired(1_000_000))
        XCTAssertTrue(route.beginCheck(route.ticket, nowMs: 100))
        XCTAssertTrue(route.expired(5_100))
        XCTAssertFalse(route.beginCheck(before, nowMs: 100))
    }

    func testABeginCheckNeedsAPendingCurrentTicket() {
        let route = OutputRouteChange(pin)
        XCTAssertFalse(route.beginCheck(route.ticket + 1, nowMs: 0))
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertFalse(route.beginCheck(route.ticket, nowMs: 0))  // Not pending.
        XCTAssertFalse(route.expired(10_000))
    }

    func testTrackStartRequiresAFreshVerificationWithAFreshWindow() {
        let route = OutputRouteChange(pin)
        route.beginCheck(route.ticket, nowMs: 0)
        XCTAssertTrue(route.verified(route.ticket))
        let verifiedTicket = route.ticket
        route.trackStarted()
        XCTAssertEqual(route.ticket, verifiedTicket + 1)
        XCTAssertTrue(route.pending)
        XCTAssertFalse(route.verified(verifiedTicket))
        XCTAssertFalse(route.expired(100_000))  // No deadline until the worker checks again.
        route.beginCheck(route.ticket, nowMs: 50_000)
        XCTAssertFalse(route.expired(54_999))
        XCTAssertTrue(route.expired(55_000))
        // A track start also clears a recorded loss.
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertTrue(route.lost(route.ticket))
        route.trackStarted()
        XCTAssertFalse(route.invalid)
        XCTAssertTrue(route.verified(route.ticket))
    }

    func testRebindRetainsTheDeadlineAndChangesTheTicketOnlyForANewValue() {
        let route = OutputRouteChange(OutputSelection.fallbackSpeaker())
        route.beginCheck(route.ticket, nowMs: 1_000)
        let ticket = route.ticket
        XCTAssertTrue(route.rebind(ticket, OutputSelection.fallbackSpeaker()))
        XCTAssertEqual(route.ticket, ticket)
        // Same endpoint, different value (the temporary flag is not part of the endpoint).
        XCTAssertTrue(route.rebind(ticket, OutputSelection.restored(.phone)))
        XCTAssertEqual(route.ticket, ticket + 1)
        XCTAssertEqual(route.selection, OutputSelection.restored(.phone))
        XCTAssertFalse(route.expired(5_999))
        XCTAssertTrue(route.expired(6_000))
        XCTAssertFalse(route.rebind(ticket, OutputSelection.restored(.phone)))  // Stale ticket.
        XCTAssertFalse(route.rebind(route.ticket, OutputSelection()))  // Different endpoint.
        XCTAssertTrue(route.verified(route.ticket))
        XCTAssertFalse(route.rebind(route.ticket, OutputSelection.restored(.phone)))  // Not pending.
    }

    func testOnlyAVerifiedExplicitPinCanBeLost() {
        let following = OutputRouteChange(OutputSelection())
        XCTAssertFalse(following.lost(following.ticket))
        let pinned = OutputRouteChange(pin)
        XCTAssertFalse(pinned.lost(pinned.ticket))  // Still pending.
        XCTAssertTrue(pinned.verified(pinned.ticket))
        XCTAssertFalse(pinned.lost(pinned.ticket + 1))
        XCTAssertTrue(pinned.lost(pinned.ticket))
        pinned.stop()
        XCTAssertFalse(pinned.lost(pinned.ticket))
    }

    func testStopIsPermanent() {
        let route = OutputRouteChange(pin)
        route.beginCheck(route.ticket, nowMs: 0)
        route.stop()
        XCTAssertFalse(route.pending)
        XCTAssertFalse(route.recovering)
        XCTAssertFalse(route.expired(1_000_000))
        let ticket = route.ticket
        route.trackStarted()
        XCTAssertEqual(route.ticket, ticket)
        XCTAssertFalse(route.request(OutputSelection()))
        XCTAssertEqual(route.selection, pin)
        XCTAssertFalse(route.beginCheck(ticket, nowMs: 0))
        XCTAssertFalse(route.verified(ticket))
        XCTAssertFalse(route.recoverBluetooth(ticket, nowMs: 0))
        XCTAssertFalse(route.returnToDefault(ticket, bluetoothReturned: true))
    }
}

/// iOS worker/status texts of the output subsystem.
final class OutputRouteChangeTextTests: XCTestCase {
    private typealias Text = OutputRouteChange.Text

    func testStatusAndFailureTextsUseTheIOSWording() {
        XCTAssertEqual(Text.switching, "Changing playback device. Audio stays silenced until iOS verifies the route…")
        XCTAssertEqual(Text.bluetoothReturned, "Bluetooth output returned. Following iPhone media output…")
        XCTAssertEqual(
            Text.selectFailed,
            "iOS could not select the requested playback device. Choose an available output and Connect again.")
        XCTAssertEqual(
            Text.speakerRestoreTimeout,
            "iOS did not restore the iPhone speaker within 5 seconds. Audio stayed silenced. "
                + "Choose an available output and Connect again.")
        XCTAssertEqual(
            Text.verifyTimeout,
            "iOS did not verify the requested playback device within 5 seconds. Audio stayed silenced. "
                + "Choose an available output and Connect again.")
        XCTAssertEqual(
            Text.bluetoothRestoreTimeout(seconds: "20"),
            "iOS did not restore the selected Bluetooth output within 20 seconds. Playback stayed silenced. "
                + "Choose an available output and Connect again.")
        XCTAssertEqual(OutputRouteChange(pin).bluetoothRestoreTimeoutText, Text.bluetoothRestoreTimeout(seconds: "20"))
        XCTAssertEqual(
            Text.bluetoothVerifyTimeout,
            "iOS did not verify the selected Bluetooth output within 5 seconds. Playback stayed silenced. "
                + "Choose an available output and Connect again.")
        XCTAssertEqual(Text.outputInitFailed, "iOS audio output could not start.")
        XCTAssertEqual(Text.outputStartFailed, "iOS audio playback failed to start.")
        XCTAssertEqual(Text.outputRuntimeFailed, "iOS audio output stopped unexpectedly.")
        for text in [
            Text.switching, Text.bluetoothReturned, Text.selectFailed, Text.speakerRestoreTimeout,
            Text.verifyTimeout, Text.bluetoothRestoreTimeout(seconds: "20"), Text.bluetoothVerifyTimeout,
            Text.outputInitFailed,
            Text.outputStartFailed, Text.outputRuntimeFailed, Text.selectedIdentity, Text.systemBluetoothRoute,
        ] {
            XCTAssertFalse(text.contains("Android"), text)
        }
    }

    func testOutputRecoveryLineDependsOnTheSelection() {
        XCTAssertEqual(
            Text.outputRecovery(recreations: 0, selection: OutputSelection()),
            "Output recovery: playout recreations requested=0 · Actual matches iOS default: unavailable")
        XCTAssertEqual(
            Text.outputRecovery(recreations: 2, selection: OutputSelection.fallbackSpeaker()),
            "Output recovery: playout recreations requested=2")
        XCTAssertEqual(
            Text.outputRecovery(recreations: 1, selection: pin),
            "Output recovery: playout recreations requested=1\n"
                + "System Bluetooth route: not applicable on iOS (no transfer API)")
        let le = OutputSelection(kind: .le, portType: RouteOutput.PortType.bluetoothLE, uid: "le")
        XCTAssertTrue(Text.outputRecovery(recreations: 0, selection: le).hasSuffix(Text.systemBluetoothRoute))
        // Every line starts with a prefix the final copy report replaces (`StreamReceiver.kt:801-803`).
        for line in Text.outputRecovery(recreations: 1, selection: pin).split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("Output recovery:") || line.hasPrefix("System Bluetooth route:"), String(line))
        }
    }

    func testAppOutputSelectionLine() {
        XCTAssertEqual(
            Text.appOutputSelection(usesMediaOutput: false, selection: pin, recovering: true, pending: true),
            "App output selection: selected headset microphone")
        XCTAssertEqual(
            Text.appOutputSelection(
                usesMediaOutput: true, selection: OutputSelection(), recovering: false, pending: false),
            "App output selection: iPhone media output · iOS routing")
        XCTAssertEqual(
            Text.appOutputSelection(usesMediaOutput: true, selection: pin, recovering: true, pending: true),
            "App output selection: Bluetooth media output · restoring selected output")
        XCTAssertEqual(Text.selectedIdentity, "Selected output identity: current route device")
    }
}
