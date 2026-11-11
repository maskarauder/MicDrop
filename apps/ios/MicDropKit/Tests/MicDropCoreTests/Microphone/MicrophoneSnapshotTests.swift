import Foundation
import MicDropCore
import XCTest

private let builtInMic = MicrophoneKind.PortType.builtInMic
private let headsetMic = MicrophoneKind.PortType.headsetMic
private let usbAudio = MicrophoneKind.PortType.usbAudio
private let hfp = MicrophoneKind.PortType.bluetoothHFP

private func routed(_ type: String, uid: String = "uid", isInput: Bool = true) -> AudioPortDescriptor {
    AudioPortDescriptor(uid: uid, type: type, isInput: isInput, name: "Port name")
}

private func reading(
    _ type: String?, rate: Int = 48000, channels: Int = 1, matches: Bool = true
) -> MicrophoneSnapshot.CaptureReading {
    MicrophoneSnapshot.CaptureReading(
        routedInput: type.map { routed($0) }, sampleRateHz: rate, channels: channels, inputMatches: matches)
}

/// The `/status` `microphone` object (`A/MicrophoneInput.kt:10-55`, `A/StreamReceiver.kt:710-713`) and the Go
/// acceptance rules it must always satisfy (`internal/diagnostics/report_test.go:45-66,113-217`).
final class MicrophoneSnapshotTests: XCTestCase {
    // MARK: - Report state (StreamReceiver.kt:710-713)

    func testReportStateTable() {
        typealias Row = (held: Bool, pending: Bool, applied: Bool?, started: Bool, state: String)
        let rows: [Row] = [
            (true, false, false, true, "waiting"), (false, true, false, true, "waiting"),
            (true, true, true, true, "waiting"), (false, false, true, true, "muted"),
            (false, false, true, false, "muted"), (false, false, false, true, "running"),
            (false, false, nil, true, "running"), (false, false, false, false, "waiting"),
            (false, false, nil, false, "waiting"),
        ]
        for row in rows {
            XCTAssertEqual(
                MicrophoneSnapshot.reportState(
                    networkHeld: row.held, recoveryPending: row.pending, appliedMuted: row.applied,
                    recordStarted: row.started),
                row.state, "\(row)")
        }
        XCTAssertEqual(MicrophoneSnapshot.State.allCases.map(\.rawValue), ["running", "muted", "waiting"])
    }

    // MARK: - Snapshot construction (MicrophoneInput.kt:42-55)

    func testWithoutCaptureTheInputIsUnavailableAndUnverified() {
        let selection = MicrophoneSelection(kind: .usb, portUID: "usb-1", portType: usbAudio)
        for (state, expected) in [("running", "waiting"), ("muted", "muted"), ("waiting", "waiting")] {
            let snapshot = MicrophoneSnapshot.make(state: state, selection: selection, capture: nil)
            XCTAssertEqual(
                snapshot,
                MicrophoneSnapshot(
                    state: expected, route: "unavailable", sampleRate: 0, channels: 0,
                    requestedRoute: "USB microphone", routeVerified: false))
        }
    }

    func testAVerifiedRunningInput() {
        let snapshot = MicrophoneSnapshot.make(
            state: "running", selection: MicrophoneSelection(), capture: reading(builtInMic))
        XCTAssertEqual(
            snapshot,
            MicrophoneSnapshot(
                state: "running", route: "built-in microphone", sampleRate: 48000, channels: 1,
                requestedRoute: "built-in microphone", routeVerified: true))
        let headset = MicrophoneSnapshot.make(
            state: "running", selection: MicrophoneSelection(port: routed(hfp))!, capture: reading(hfp, rate: 16000))
        XCTAssertEqual(headset.state, "running")
        XCTAssertEqual(headset.route, "Bluetooth SCO microphone")
        XCTAssertEqual(headset.sampleRate, 16000)
        XCTAssertEqual(headset.routeVerified, true)
    }

    func testAnUnmatchedRouteIsReportedAsWaitingWithTheActualLabel() {
        let selection = MicrophoneSelection(kind: .usb, portUID: "usb-1", portType: usbAudio)
        let snapshot = MicrophoneSnapshot.make(
            state: "running", selection: selection, capture: reading(builtInMic, matches: false))
        XCTAssertEqual(
            snapshot,
            MicrophoneSnapshot(
                state: "waiting", route: "built-in microphone", sampleRate: 48000, channels: 1,
                requestedRoute: "USB microphone", routeVerified: false))
    }

    /// `verified = captureRunning && state in ("running", "muted") && matchesInput` (`MicrophoneInput.kt:49`):
    /// a capture kept open while muted reports its verified route; muted describes transmission only.
    func testMutedCaptureIsVerifiedOnlyWhenItsRouteMatches() throws {
        let builtIn = MicrophoneSnapshot.make(
            state: "muted", selection: MicrophoneSelection(), capture: reading(builtInMic))
        XCTAssertEqual(
            builtIn,
            MicrophoneSnapshot(
                state: "muted", route: "built-in microphone", sampleRate: 48000, channels: 1,
                requestedRoute: "built-in microphone", routeVerified: true))
        let headsetSelection = try XCTUnwrap(MicrophoneSelection(port: routed(hfp)))
        let headset = MicrophoneSnapshot.make(
            state: "muted", selection: headsetSelection, capture: reading(hfp, rate: 16000))
        XCTAssertEqual(headset.state, "muted")
        XCTAssertEqual(headset.route, "Bluetooth SCO microphone")
        XCTAssertEqual(headset.sampleRate, 16000)
        XCTAssertEqual(headset.routeVerified, true)
        for snapshot in [builtIn, headset] {
            XCTAssertNil(snapshot.hostValidationProblem(audioDirection: ""), "\(snapshot)")
            XCTAssertNil(snapshot.hostValidationProblem(audioDirection: "duplex"), "\(snapshot)")
        }

        let unverified: [MicrophoneSnapshot.CaptureReading] = [
            reading(builtInMic, matches: false), reading(headsetMic), reading(builtInMic, rate: 7999),
            reading(builtInMic, channels: 2),
        ]
        for capture in unverified {
            let snapshot = MicrophoneSnapshot.make(state: "muted", selection: MicrophoneSelection(), capture: capture)
            XCTAssertEqual(snapshot.state, "muted", "\(capture)")
            XCTAssertEqual(snapshot.routeVerified, false, "\(capture)")
        }
        for capture in unverified + [reading(builtInMic)] {
            let snapshot = MicrophoneSnapshot.make(
                state: "waiting", selection: MicrophoneSelection(), capture: capture)
            XCTAssertEqual(snapshot.state, "waiting", "\(capture)")
            XCTAssertEqual(snapshot.routeVerified, false, "\(capture)")
        }
        let paused = MicrophoneSnapshot.make(state: "muted", selection: headsetSelection, capture: nil)
        XCTAssertEqual(paused.state, "muted")
        XCTAssertEqual(paused.route, "unavailable")
        XCTAssertEqual(paused.routeVerified, false)
    }

    func testHostConsistencyGuards() {
        let selection = MicrophoneSelection()
        // Never `running` with two channels or below 8000 Hz.
        for capture in [
            reading(builtInMic, channels: 2), reading(builtInMic, channels: 0), reading(builtInMic, rate: 7999),
            reading(builtInMic, rate: 0),
        ] {
            let snapshot = MicrophoneSnapshot.make(state: "running", selection: selection, capture: capture)
            XCTAssertEqual(snapshot.state, "waiting", "\(capture)")
            XCTAssertEqual(snapshot.routeVerified, false, "\(capture)")
        }
        // An inconsistent `inputMatches` cannot verify a route other than the requested one.
        let mismatch = MicrophoneSnapshot.make(state: "running", selection: selection, capture: reading(headsetMic))
        XCTAssertEqual(mismatch.state, "waiting")
        XCTAssertEqual(mismatch.route, "wired headset microphone")
        XCTAssertEqual(mismatch.routeVerified, false)
        // Out-of-range readings are reported as unknown (0), never invented.
        let wild = MicrophoneSnapshot.make(
            state: "running", selection: selection, capture: reading(builtInMic, rate: 384_001, channels: 3))
        XCTAssertEqual(wild.sampleRate, 0)
        XCTAssertEqual(wild.channels, 0)
        XCTAssertEqual(wild.state, "waiting")
        let negative = MicrophoneSnapshot.make(
            state: "muted", selection: selection, capture: reading(builtInMic, rate: -1, channels: -1))
        XCTAssertEqual(negative.sampleRate, 0)
        XCTAssertEqual(negative.channels, 0)
        let edge = MicrophoneSnapshot.make(
            state: "running", selection: selection, capture: reading(builtInMic, rate: 384_000))
        XCTAssertEqual(edge.sampleRate, 384_000)
        XCTAssertEqual(edge.state, "running")
        XCTAssertEqual(MicrophoneSnapshot.maximumSampleRateHz, 384_000)
        XCTAssertEqual(MicrophoneSnapshot.maximumChannels, 2)
        XCTAssertEqual(MicrophoneSnapshot.minimumRunningSampleRateHz, 8000)
    }

    func testRoutesThatAreNotMicrophoneInputsAreUnavailable() {
        let selection = MicrophoneSelection()
        let noInput = MicrophoneSnapshot.make(state: "running", selection: selection, capture: reading(nil))
        XCTAssertEqual(noInput.route, "unavailable")
        XCTAssertEqual(noInput.state, "waiting")
        for type in ["LineIn", "CarAudio", "ContinuityMicrophone", "BluetoothLEOutput"] {
            let snapshot = MicrophoneSnapshot.make(state: "running", selection: selection, capture: reading(type))
            XCTAssertEqual(snapshot.route, "unavailable", type)
            XCTAssertEqual(snapshot.state, "waiting", type)
        }
        let outputPort = MicrophoneSnapshot.CaptureReading(
            routedInput: routed(builtInMic, isInput: false), sampleRateHz: 48000, inputMatches: true)
        XCTAssertEqual(outputPort.channels, 1)
        let snapshot = MicrophoneSnapshot.make(state: "running", selection: selection, capture: outputPort)
        XCTAssertEqual(snapshot.route, "unavailable")
        XCTAssertEqual(snapshot.state, "waiting")
    }

    func testProcessingIsCarriedAndReplaceable() {
        let processing = MicrophoneProcessing(echoCancellation: false, noiseReduction: true)
        let snapshot = MicrophoneSnapshot.make(
            state: "running", selection: MicrophoneSelection(), capture: reading(builtInMic), processing: processing)
        XCTAssertEqual(snapshot.processing, processing)
        XCTAssertNil(snapshot.with(processing: nil).processing)
        XCTAssertEqual(snapshot.with(processing: nil).with(processing: processing), snapshot)
        let stripped = snapshot.with(processing: nil)
        XCTAssertEqual(stripped.state, snapshot.state)
        XCTAssertEqual(stripped.route, snapshot.route)
        XCTAssertEqual(stripped.sampleRate, snapshot.sampleRate)
        XCTAssertEqual(stripped.channels, snapshot.channels)
        XCTAssertEqual(stripped.requestedRoute, snapshot.requestedRoute)
        XCTAssertEqual(stripped.routeVerified, snapshot.routeVerified)
    }

    // MARK: - Text and encodings

    func testCopyReportText() {
        XCTAssertEqual(
            MicrophoneSnapshot(state: "running", route: "USB microphone", sampleRate: 48000, channels: 1).text(),
            "Microphone: running · Input: USB microphone · 48000 Hz / 1 channels")
        XCTAssertEqual(
            MicrophoneSnapshot(
                state: "waiting", route: "unavailable", requestedRoute: "Bluetooth SCO microphone",
                routeVerified: false
            ).text(),
            "Microphone: waiting · Input: unavailable · 0 Hz / 0 channels\n"
                + "Selected input: Bluetooth SCO microphone · Route verified: false")
        XCTAssertEqual(
            MicrophoneSnapshot(
                state: "running", route: "built-in microphone", sampleRate: 48000, channels: 1,
                requestedRoute: "built-in microphone", routeVerified: true
            ).text(),
            "Microphone: running · Input: built-in microphone · 48000 Hz / 1 channels\n"
                + "Selected input: built-in microphone · Route verified: true")
        // Kotlin `routeVerified == true` prints false for a missing value.
        XCTAssertTrue(
            MicrophoneSnapshot(state: "muted", route: "unavailable", requestedRoute: "USB microphone").text()
                .hasSuffix("Route verified: false"))
    }

    func testJSONObjectKeysOrderAndValues() {
        let full = MicrophoneSnapshot(
            state: "running", route: "built-in microphone", sampleRate: 48000, channels: 1,
            requestedRoute: "built-in microphone", routeVerified: true,
            processing: MicrophoneProcessing(echoCancellation: true, noiseReduction: false))
        XCTAssertEqual(
            full.json().encodedString(),
            #"{"state":"running","route":"built-in microphone","sample_rate_hz":48000,"channels":1,"#
                + #""requested_route":"built-in microphone","route_verified":true,"#
                + #""processing":{"echo_cancellation_requested":true,"noise_reduction_requested":false}}"#)
        XCTAssertEqual(
            MicrophoneSnapshot(state: "muted", route: "unavailable").json().encodedString(),
            #"{"state":"muted","route":"unavailable","sample_rate_hz":0,"channels":0}"#)
        XCTAssertEqual(
            full.json(),
            .object([
                (key: "state", value: .string("running")), (key: "route", value: .string("built-in microphone")),
                (key: "sample_rate_hz", value: .int(48000)), (key: "channels", value: .int(1)),
                (key: "requested_route", value: .string("built-in microphone")),
                (key: "route_verified", value: .bool(true)),
                (key: "processing", value: MicrophoneProcessing(echoCancellation: true).json()),
            ]))
    }

    func testEncodableUsesTheSameWireKeysAndOmitsMissingMembers() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let full = MicrophoneSnapshot(
            state: "waiting", route: "USB microphone", sampleRate: 44100, channels: 1,
            requestedRoute: "USB microphone", routeVerified: false,
            processing: MicrophoneProcessing(noiseReduction: true))
        XCTAssertEqual(
            String(decoding: try encoder.encode(full), as: UTF8.self),
            #"{"channels":1,"processing":{"echo_cancellation_requested":false,"noise_reduction_requested":true},"#
                + #""requested_route":"USB microphone","route":"USB microphone","route_verified":false,"#
                + #""sample_rate_hz":44100,"state":"waiting"}"#)
        XCTAssertEqual(
            String(
                decoding: try encoder.encode(MicrophoneSnapshot(state: "muted", route: "unavailable")), as: UTF8.self),
            #"{"channels":0,"route":"unavailable","sample_rate_hz":0,"state":"muted"}"#)
    }

    func testReportsNeverContainPortIdentity() throws {
        let port = AudioPortDescriptor(uid: "SECRET-UID", type: hfp, isInput: true, name: "Secret Headset")
        let selection = try XCTUnwrap(MicrophoneSelection(port: port))
        let capture = MicrophoneSnapshot.CaptureReading(routedInput: port, sampleRateHz: 16000, inputMatches: true)
        let snapshot = MicrophoneSnapshot.make(state: "running", selection: selection, capture: capture)
        let encoded = try JSONEncoder().encode(snapshot)
        for text in [snapshot.json().encodedString(), snapshot.text(), String(decoding: encoded, as: UTF8.self)] {
            XCTAssertFalse(text.contains("SECRET"), text)
            XCTAssertFalse(text.contains("Secret"), text)
        }
        let allowed: Set<String> = [
            "state", "route", "sample_rate_hz", "channels", "requested_route", "route_verified", "processing",
        ]
        XCTAssertTrue(Set(snapshot.json().keys ?? []).isSubset(of: allowed))
    }

    // MARK: - Go acceptance rules (report.go:163-184)

    func testProcessingRequiresItsSupportedDirectionAndRoute() {
        // TestMicrophoneProcessingReportsRequireTheirSupportedDirectionAndRoute
        var processing = MicrophoneProcessing(echoCancellation: true, noiseReduction: true)
        func snapshot(_ route: String) -> MicrophoneSnapshot {
            MicrophoneSnapshot(
                state: "running", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                routeVerified: true, processing: processing)
        }
        XCTAssertNil(snapshot("built-in microphone").hostValidationProblem(audioDirection: "duplex"))
        XCTAssertNotNil(snapshot("built-in microphone").hostValidationProblem(audioDirection: ""))
        processing.echoCancellation = false
        XCTAssertNil(snapshot("built-in microphone").hostValidationProblem(audioDirection: ""))
        XCTAssertNotNil(snapshot("Bluetooth SCO microphone").hostValidationProblem(audioDirection: ""))
        XCTAssertNotNil(snapshot("Bluetooth SCO microphone").hostValidationProblem(audioDirection: "duplex"))
        processing.noiseReduction = false
        XCTAssertNil(snapshot("Bluetooth SCO microphone").hostValidationProblem(audioDirection: "duplex"))
    }

    func testReportBounds() {
        // TestMicrophoneReportBoundsAndDirectionSpecificMetrics (microphone object part).
        let valid = MicrophoneSnapshot(state: "running", route: "built-in microphone", sampleRate: 48000, channels: 1)
        XCTAssertNil(valid.hostValidationProblem(audioDirection: ""))
        XCTAssertNil(MicrophoneSnapshot(state: "muted", route: "unavailable").hostValidationProblem(audioDirection: ""))
        XCTAssertNil(
            MicrophoneSnapshot(state: "waiting", route: "unavailable").hostValidationProblem(audioDirection: ""))
        let invalid: [MicrophoneSnapshot] = [
            MicrophoneSnapshot(state: "running", route: "secret-device-name", sampleRate: 48000, channels: 1),
            MicrophoneSnapshot(state: "running", route: "unavailable", sampleRate: 48000, channels: 1),
            MicrophoneSnapshot(state: "secret-error", route: "built-in microphone", sampleRate: 48000, channels: 1),
            MicrophoneSnapshot(state: "running", route: "built-in microphone", sampleRate: 0, channels: 1),
            MicrophoneSnapshot(state: "running", route: "built-in microphone", sampleRate: 384_001, channels: 1),
            MicrophoneSnapshot(state: "running", route: "built-in microphone", sampleRate: 48000, channels: 2),
            MicrophoneSnapshot(state: "waiting", route: "unavailable", sampleRate: -1, channels: 0),
            MicrophoneSnapshot(state: "waiting", route: "unavailable", sampleRate: 0, channels: 3),
            MicrophoneSnapshot(state: "waiting", route: "unavailable", sampleRate: 0, channels: -1),
            // Legacy objects without a selection may only name the built-in microphone.
            MicrophoneSnapshot(state: "waiting", route: "wired headset microphone"),
        ]
        for snapshot in invalid {
            XCTAssertNotNil(snapshot.hostValidationProblem(audioDirection: ""), "\(snapshot)")
        }
    }

    func testSelectedReportsRequireConsistentVerification() {
        // TestSelectedMicrophoneReportsRequireConsistentVerification, for every host label.
        for route in MicrophoneKind.routeLabels {
            let running = MicrophoneSnapshot(
                state: "running", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                routeVerified: true)
            XCTAssertNil(running.hostValidationProblem(audioDirection: "duplex"), route)
            let changes: [MicrophoneSnapshot] = [
                MicrophoneSnapshot(
                    state: "running", route: route, sampleRate: 48000, channels: 1,
                    requestedRoute: "secret-device-name", routeVerified: true),
                MicrophoneSnapshot(
                    state: "running", route: route, sampleRate: 48000, channels: 1, requestedRoute: "",
                    routeVerified: true),
                MicrophoneSnapshot(
                    state: "running", route: "unavailable", sampleRate: 48000, channels: 1, requestedRoute: route,
                    routeVerified: true),
                MicrophoneSnapshot(
                    state: "running", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                    routeVerified: nil),
                MicrophoneSnapshot(
                    state: "running", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                    routeVerified: false),
                MicrophoneSnapshot(
                    state: "waiting", route: route, sampleRate: 7999, channels: 1, requestedRoute: route,
                    routeVerified: true),
                MicrophoneSnapshot(
                    state: "waiting", route: "unavailable", sampleRate: 0, channels: 0, requestedRoute: "unavailable",
                    routeVerified: false),
            ]
            for snapshot in changes {
                XCTAssertNotNil(snapshot.hostValidationProblem(audioDirection: "duplex"), "\(route) \(snapshot)")
            }
            let muted = MicrophoneSnapshot(
                state: "muted", route: "unavailable", requestedRoute: route, routeVerified: false)
            XCTAssertNil(muted.hostValidationProblem(audioDirection: "duplex"), route)
            let gated = MicrophoneSnapshot(
                state: "waiting", route: "built-in microphone", requestedRoute: route, routeVerified: false)
            XCTAssertNil(gated.hostValidationProblem(audioDirection: "duplex"), route)
            // Muted describes transmission, not whether verified capture is retained (report.go:176-178).
            let retained = MicrophoneSnapshot(
                state: "muted", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                routeVerified: true)
            XCTAssertNil(retained.hostValidationProblem(audioDirection: "duplex"), route)
        }
    }

    func testMutedCaptureStillRequiresVerifiedRouteAndFormat() {
        // TestMutedCaptureReportsStillRequireVerifiedRouteAndFormat
        for direction in ["", "duplex"] {
            for route in MicrophoneKind.routeLabels {
                let retained = MicrophoneSnapshot(
                    state: "muted", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                    routeVerified: true)
                XCTAssertNil(retained.hostValidationProblem(audioDirection: direction), "\(direction) \(route)")
                let changes: [MicrophoneSnapshot] = [
                    MicrophoneSnapshot(
                        state: "muted", route: "unavailable", sampleRate: 48000, channels: 1, requestedRoute: route,
                        routeVerified: true),
                    MicrophoneSnapshot(
                        state: "muted", route: route, sampleRate: 48000, channels: 1, requestedRoute: "unavailable",
                        routeVerified: true),
                    MicrophoneSnapshot(
                        state: "muted", route: route, sampleRate: 0, channels: 1, requestedRoute: route,
                        routeVerified: true),
                    MicrophoneSnapshot(
                        state: "muted", route: route, sampleRate: 48000, channels: 0, requestedRoute: route,
                        routeVerified: true),
                    MicrophoneSnapshot(
                        state: "muted", route: route, sampleRate: 48000, channels: 2, requestedRoute: route,
                        routeVerified: true),
                    MicrophoneSnapshot(
                        state: "muted", route: route, sampleRate: 48000, channels: 1, requestedRoute: route,
                        routeVerified: nil),
                ]
                for snapshot in changes {
                    XCTAssertNotNil(snapshot.hostValidationProblem(audioDirection: direction), "\(snapshot)")
                }
            }
        }
    }

    /// Whatever the capture reports, a snapshot built for a session (processing already effective for its
    /// mode and input) is accepted by the host, so a microphone report can never disable uploads.
    func testEveryConstructedSnapshotIsAcceptedByTheHost() {
        let types: [String?] = [nil, builtInMic, headsetMic, usbAudio, hfp, "LineIn"]
        var captures: [MicrophoneSnapshot.CaptureReading?] = [nil]
        for type in types {
            for isInput in [true, false] {
                for rate in [-5, 0, 7999, 8000, 16000, 48000, 384_000, 384_001] {
                    for channels in [-1, 0, 1, 2, 3] {
                        for matches in [false, true] {
                            captures.append(
                                MicrophoneSnapshot.CaptureReading(
                                    routedInput: type.map { routed($0, isInput: isInput) }, sampleRateHz: rate,
                                    channels: channels, inputMatches: matches))
                        }
                    }
                }
            }
        }
        let selections = [
            MicrophoneSelection(), MicrophoneSelection(kind: .wired, portUID: "w", portType: headsetMic),
            MicrophoneSelection(kind: .usb, portUID: "u", portType: usbAudio),
            MicrophoneSelection(port: routed(hfp))!, MicrophoneSelection(kind: .le),
        ]
        let states = ["running", "muted", "waiting"]
        var checked = 0
        for mode in [StreamMode.microphone, .duplex] {
            let direction = mode == .duplex ? "duplex" : ""
            for selection in selections {
                let processings: [MicrophoneProcessing?] =
                    [nil]
                    + [false, true].flatMap { echo in
                        [false, true].map { noise in
                            MicrophoneProcessing(echoCancellation: echo, noiseReduction: noise)
                                .effective(mode: mode, input: selection.kind)
                        }
                    }
                for processing in processings {
                    for state in states {
                        for capture in captures {
                            let snapshot = MicrophoneSnapshot.make(
                                state: state, selection: selection, capture: capture, processing: processing)
                            let problem = snapshot.hostValidationProblem(audioDirection: direction)
                            if let problem {
                                XCTFail("\(problem): \(snapshot) from \(String(describing: capture))")
                                return
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }
}
