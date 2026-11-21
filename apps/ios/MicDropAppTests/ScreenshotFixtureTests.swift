#if DEBUG
    import MicDropCore
    import XCTest

    @testable import MicDrop

    final class ScreenshotFixtureTests: XCTestCase {
        func testParseArgumentsAndEnvironment() {
            XCTAssertNil(ScreenshotLaunch.parse(arguments: ["MicDrop"], environment: [:]))
            XCTAssertNil(
                ScreenshotLaunch.parse(
                    arguments: ["MicDrop", "--micdrop-screenshot-scene", "unknown"],
                    environment: [:]))

            let fromArgs = ScreenshotLaunch.parse(
                arguments: [
                    "MicDrop",
                    "--micdrop-screenshot-scene", "connected_output",
                    "--micdrop-screenshot-ready", "/tmp/nested/ready.txt",
                ],
                environment: [:])
            XCTAssertEqual(
                fromArgs,
                ScreenshotLaunch(scene: .connectedOutput, readyFileName: "ready.txt"))

            let fromEnv = ScreenshotLaunch.parse(
                arguments: ["MicDrop"],
                environment: [
                    "MICDROP_SCREENSHOT_SCENE": "diagnostics",
                    "MICDROP_SCREENSHOT_READY": "diag-ready.txt",
                ])
            XCTAssertEqual(
                fromEnv,
                ScreenshotLaunch(scene: .diagnostics, readyFileName: "diag-ready.txt"))
        }

        @MainActor
        func testAllScreenshotScenesDeriveExpectedStates() {
            let connection = ScreenshotEnvironment(
                launch: ScreenshotLaunch(scene: .connection, readyFileName: nil),
                revision: "abcdef123456",
                versionName: "0.1.0")
            connection.activateIfNeeded()
            XCTAssertEqual(connection.mainViewModel.render.statusTitle, Strings.statusReady)
            XCTAssertEqual(connection.mainViewModel.render.connectLabel, Strings.reconnect)
            XCTAssertTrue(connection.mainViewModel.render.connectEnabled)
            XCTAssertTrue(connection.mainViewModel.render.addressVisible)
            XCTAssertEqual(connection.mainViewModel.render.discoveryRows.count, 1)
            XCTAssertTrue(connection.mainViewModel.render.discoveryRows[0].savedCandidate)

            let connected = ScreenshotEnvironment(
                launch: ScreenshotLaunch(scene: .connectedOutput, readyFileName: nil),
                revision: "abcdef123456",
                versionName: "0.1.0")
            connected.activateIfNeeded()
            XCTAssertEqual(connected.mainViewModel.render.statusTitle, Strings.statusConnected)
            XCTAssertTrue(connected.mainViewModel.render.statusText.contains("Windows: 192.168.1.42:8443"))
            XCTAssertTrue(connected.mainViewModel.render.statusText.contains("Network: Wi-Fi"))
            XCTAssertTrue(connected.mainViewModel.render.outputChecked)
            XCTAssertEqual(connected.mainViewModel.render.volumeLabel, "Media volume · 75%")
            XCTAssertTrue(connected.mainViewModel.render.stopEnabled)

            let microphone = ScreenshotEnvironment(
                launch: ScreenshotLaunch(scene: .microphone, readyFileName: nil),
                revision: "abcdef123456",
                versionName: "0.1.0")
            microphone.activateIfNeeded()
            XCTAssertEqual(microphone.mainViewModel.render.statusTitle, Strings.statusReady)
            XCTAssertTrue(microphone.mainViewModel.render.micChecked)
            XCTAssertEqual(
                microphone.mainViewModel.render.inputButtonLabel,
                Strings.selectedMicrophone(MicrophoneChoice.builtInTitle))
            XCTAssertTrue(microphone.mainViewModel.render.echoChecked)
            XCTAssertTrue(microphone.mainViewModel.render.noiseChecked)

            let diagnostics = ScreenshotEnvironment(
                launch: ScreenshotLaunch(scene: .diagnostics, readyFileName: nil),
                revision: "abcdef123456",
                versionName: "0.1.0")
            diagnostics.activateIfNeeded()
            XCTAssertEqual(diagnostics.mainViewModel.render.statusTitle, Strings.statusLocalTest)
            XCTAssertEqual(diagnostics.mainViewModel.render.statusText, Strings.statusProbeRunning)
            XCTAssertTrue(diagnostics.mainViewModel.render.clickVisible)
            XCTAssertTrue(diagnostics.mainViewModel.render.clickEnabled)
            XCTAssertTrue(diagnostics.mainViewModel.render.copyEnabled)
            XCTAssertTrue(diagnostics.mainViewModel.render.stopEnabled)
            XCTAssertTrue(
                diagnostics.mainViewModel.render.diagnosticsText.contains("Actual iOS audio route: phone speaker"))
            XCTAssertEqual(diagnostics.mainViewModel.render.diagnosticsSummary, "MicDrop 0.1.0 · Reports and notices")
        }
    }
#endif
