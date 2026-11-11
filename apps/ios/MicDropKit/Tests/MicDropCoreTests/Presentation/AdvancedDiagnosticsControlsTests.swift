import Foundation
import MicDropCore
import XCTest

/// the Debugging section became Advanced (connection and host controls) and Diagnostics (reports and local tools), the
/// test tone was removed, and Play click shows only while the local output probe runs (`MainActivity.kt:499-519`,
/// `:1367-1368`, `:1388-1390`).
final class AdvancedDiagnosticsControlsTests: XCTestCase {
    func testTheSectionTextsAreAndroidsWithTheIPhoneAdaptation() {
        XCTAssertEqual(Strings.advanced, "Advanced")
        XCTAssertEqual(Strings.diagnostics, "Diagnostics")
        XCTAssertEqual(Strings.advancedHelp, "Connection order and timeouts apply the next time you connect.")
        XCTAssertEqual(
            Strings.diagnosticsHelp,
            "Copy a report when troubleshooting, or check playback on this iPhone without connecting to Windows.")
        XCTAssertEqual(Strings.connectionSettings, "Connection settings")
        XCTAssertEqual(
            Strings.advancedSummary(recoverySeconds: "30"),
            "Recovery window: 30 s \u{00B7} Connection and host controls")
        XCTAssertEqual(
            Strings.diagnosticsSummary(versionName: "0.1.0-dev"), "MicDrop 0.1.0-dev \u{00B7} Reports and notices")
        XCTAssertEqual(Strings.statusProbeRunning, "Tap Play click in Diagnostics. Stop ends the test.")
        XCTAssertEqual(Strings.stop, "Stop")
    }

    /// reworded pairing guidance (`strings.xml:55`, `:80`, `:83`, `:87`), keeping the iOS Cancel.
    func testThePairingGuidanceNamesTheWindowsApp() {
        XCTAssertEqual(
            Strings.connectionHelp,
            "In the Windows app, open Phones \u{2192} Pair a phone. Scan its QR code or paste the link, tap Connect, "
                + "then approve the request in Windows. Keep MicDrop open to connect after approval. If you leave "
                + "the app, tap Reconnect when you return.")
        XCTAssertEqual(
            Strings.discoveryPairFirst,
            "In the Windows app, open Phones \u{2192} Pair a phone. Scan its QR code or paste the link, then tap "
                + "Connect and approve the matching request in Windows. Finding a computer on your network does "
                + "not pair it automatically.")
        XCTAssertEqual(
            Strings.scanPrompt, "Scan the entire pairing QR in the Windows app. Cancel returns to manual entry.")
        XCTAssertEqual(
            Strings.scanExpired, "That pairing QR expired. Select Pair a phone in Windows and scan the new code.")
        XCTAssertEqual(
            Strings.pairingInvitationExpired,
            "That pairing invitation expired. In the Windows app, open Phones \u{2192} Pair a phone for a new one.")
        XCTAssertEqual(
            PairingClient.pendingText("0123456789ab"),
            "Waiting for Windows approval.\nRequest ID: 0123456789ab\n"
                + "In the Windows app, open Phones, check that this request ID matches, then select Approve.")
        XCTAssertEqual(
            PairingFailureText.cancelled,
            "Pairing cancelled. If Windows already approved this phone, remove it in the Windows app under Phones \u{2192} Remove selected phone."
        )
        XCTAssertEqual(
            PairingFailureText.windowEnded,
            "Pairing window ended, was rejected, or another phone is pending. In the Windows app, open Phones \u{2192} Pair a phone for a new invitation."
        )
        XCTAssertEqual(
            PairingFailureText.notSavedSuffix,
            "Pairing was not saved. Windows may already have approved the phone; retry the same invitation while it is valid, or select Pair a phone in Windows for a new one."
        )
        XCTAssertEqual(PairingFailureText.expiredInvitation, Strings.pairingInvitationExpired)
        for text in [
            Strings.connectionHelp, Strings.discoveryPairFirst, Strings.scanPrompt, Strings.scanExpired,
            Strings.pairingInvitationExpired, PairingClient.pendingText("0123456789ab"),
            PairingFailureText.cancelled, PairingFailureText.windowEnded, PairingFailureText.notSavedSuffix,
            PairingFailureText.expiredInvitation, ConnectionFailure.httpDetail(status: 403, action: "Reconnect"),
        ] {
            XCTAssertFalse(text.contains("console"), text)
            XCTAssertFalse(text.contains("Enter pair"), text)
            XCTAssertFalse(text.contains("enter: approve"), text)
            XCTAssertFalse(text.contains("use devices"), text)
        }
    }

    func testTheAdvancedSummaryShowsTheSavedRecoveryWindowInSeconds() {
        let cases: [(Int, String)] = [
            (30_000, "30"), (5_500, "5.5"), (300_000, "300"), (5_000, "5"), (12_345, "12.345"), (30_250, "30.25"),
        ]
        for (milliseconds, seconds) in cases {
            let render = PresentationFixtures.derive { $0.recoveryWindowMs = milliseconds }
            XCTAssertEqual(
                render.advancedSummary, "Recovery window: \(seconds) s \u{00B7} Connection and host controls",
                "\(milliseconds) ms")
            XCTAssertEqual(
                render.advancedSummary,
                Strings.advancedSummary(recoverySeconds: ConnectionPreferences.seconds(milliseconds)))
        }
    }

    func testTheDiagnosticsSummaryShowsTheVersionNameAndTheBuildLabelTheRevision() {
        let render = PresentationFixtures.derive { input in
            input.versionName = "1.2.3"
            input.revision = "0123456789ab"
        }
        XCTAssertEqual(render.diagnosticsSummary, "MicDrop 1.2.3 \u{00B7} Reports and notices")
        XCTAssertEqual(render.buildLabel, "Build 0123456789ab")
    }

    func testDefaultsAreTheFallbackBuildAndTheDefaultRecoveryWindow() {
        let input = ControlsInput()
        XCTAssertEqual(input.versionName, BuildInfo.fallbackVersionName)
        XCTAssertEqual(input.recoveryWindowMs, 30_000)
        XCTAssertEqual(input.recoveryWindowMs, ConnectionPreferences()[.recovery])
        let render = ControlsDeriver.derive(input)
        XCTAssertEqual(render.advancedSummary, "Recovery window: 30 s \u{00B7} Connection and host controls")
        XCTAssertEqual(render.diagnosticsSummary, "MicDrop 0.1.0-dev \u{00B7} Reports and notices")
        XCTAssertEqual(render.buildLabel, "Build local")
    }

    /// `ControlsInput` is `Equatable` so a caller can skip an unchanged derive; a new recovery window or version
    /// must still re-derive the summaries.
    func testTheSummaryInputsTakePartInEquality() {
        XCTAssertNotEqual(ControlsInput(recoveryWindowMs: 30_000), ControlsInput(recoveryWindowMs: 45_000))
        XCTAssertNotEqual(ControlsInput(versionName: "0.1.0"), ControlsInput(versionName: "0.2.0"))
        XCTAssertEqual(ControlsInput(recoveryWindowMs: 45_000), ControlsInput(recoveryWindowMs: 45_000))
    }

    /// The old Debugging summary said whether a report existed; the new summaries do not, and the report still
    /// enables Copy last stream report.
    func testTheSummariesDoNotDependOnAReport() {
        let without = PresentationFixtures.derive()
        let with = PresentationFixtures.derive { $0.latestDiagnostics = "report" }
        XCTAssertEqual(without.advancedSummary, with.advancedSummary)
        XCTAssertEqual(without.diagnosticsSummary, with.diagnosticsSummary)
        XCTAssertFalse(without.copyEnabled)
        XCTAssertTrue(with.copyEnabled)
    }

    func testPlayClickIsShownAndEnabledOnlyWhileTheLocalOutputProbeRuns() {
        let idle = PresentationFixtures.derive()
        XCTAssertTrue(idle.idle)
        XCTAssertFalse(idle.clickVisible)
        XCTAssertFalse(idle.clickEnabled)
        XCTAssertTrue(idle.localTestEnabled)
        XCTAssertNotEqual(idle.statusText, Strings.statusProbeRunning)

        let probe = PresentationFixtures.derive { $0.localProbeRunning = true }
        XCTAssertFalse(probe.idle)
        XCTAssertTrue(probe.clickVisible)
        XCTAssertTrue(probe.clickEnabled)
        XCTAssertFalse(probe.localTestEnabled)
        XCTAssertFalse(probe.fastRecoveryEnabled)
        XCTAssertFalse(probe.connectEnabled)
        XCTAssertTrue(probe.stopEnabled)
        XCTAssertEqual(probe.statusTitle, Strings.statusLocalTest)
        XCTAssertEqual(probe.statusText, Strings.statusProbeRunning)

        let playing = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.session = PresentationFixtures.session(.playing)
        }
        let duplex = PresentationFixtures.derive { input in
            input.saved = PresentationFixtures.pairedSaved
            input.mic = PresentationFixtures.mic(.playing, mode: .duplex)
        }
        let connecting = PresentationFixtures.derive { $0.pendingConnect = true }
        let pairing = PresentationFixtures.derive { $0.saved = PresentationFixtures.pairingSaved }
        let others = [("playing", playing), ("duplex", duplex), ("pending Connect", connecting), ("pairing", pairing)]
        for (name, render) in others {
            XCTAssertFalse(render.clickVisible, name)
            XCTAssertFalse(render.clickEnabled, name)
            XCTAssertNotEqual(render.statusText, Strings.statusProbeRunning, name)
        }
    }
}
