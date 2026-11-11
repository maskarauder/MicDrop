import Foundation
import MicDropCore
import MicDropTestSupport
import XCTest

/// `StopReason`, `StreamEnd` and the mode-specific end messages. Ports
/// `SessionLifecycleTest.preciseReasonsFallBackForPreviouslyReleasedHosts` and checks every wire label against the host
/// allow-list (`internal/session/server.go`) and the end-reason map asserted by `internal/session/reliability_test.go`
/// (`TestStopDuringRecoveryPreservesReceiverReason`).
final class StopReasonTests: XCTestCase {
    /// Wire label → host end reason (`server.go:389-393`, `reliability_test.go:77-80`).
    private let hostEndReasons: [(StopReason, String, String)] = [
        (.user, "user_stop", "receiver_stop"),
        (.pause, "user_pause", "receiver_pause"),
        (.focus, "focus_loss", "receiver_focus_lost"),
        (.focusTransient, "focus_loss_transient", "receiver_focus_lost_transient"),
        (.focusPermanent, "focus_loss_permanent", "receiver_focus_lost_permanent"),
        (.output, "output_lost", "receiver_output_lost"),
        (.service, "service_stopped", "receiver_service_stopped"),
        (.failure, "connection_failed", "receiver_failure"),
    ]

    func testPreciseReasonsFallBackForPreviouslyReleasedHosts() {
        XCTAssertEqual(StopReason.pause.wire(forLifecycleVersion: 1), "user_stop")
        XCTAssertEqual(StopReason.pause.wire(forLifecycleVersion: 2), "user_pause")
        for reason in [StopReason.focusTransient, .focusPermanent] {
            XCTAssertEqual(reason.wire(forLifecycleVersion: 1), "focus_loss")
            XCTAssertEqual(reason.wire(forLifecycleVersion: 2), reason.wire)
        }
        XCTAssertEqual(StopReason.output.wire(forLifecycleVersion: 1), "output_lost")
    }

    func testWireLabelsAreTheProtocolConstants() {
        XCTAssertEqual(StopReason.allCases, hostEndReasons.map { $0.0 })
        for (reason, wire, _) in hostEndReasons {
            XCTAssertEqual(reason.wire, wire)
            XCTAssertEqual(reason.rawValue, wire)
            XCTAssertEqual(StopReason(rawValue: wire), reason)
            XCTAssertFalse(wire.isEmpty)
        }
        XCTAssertNil(StopReason(rawValue: ""))
        XCTAssertNil(StopReason(rawValue: "USER_STOP"))
    }

    func testOlderLifecycleVersionsReceiveTheLegacyLabels() {
        // `session_lifecycle_version` is read with default 1; a worker that never received an offer keeps 1.
        for version in [Int.min, -1, 0, 1] {
            for reason in StopReason.allCases {
                let expected: String
                switch reason {
                case .pause: expected = "user_stop"
                case .focusTransient, .focusPermanent: expected = "focus_loss"
                default: expected = reason.wire
                }
                XCTAssertEqual(reason.wire(forLifecycleVersion: version), expected, "\(reason) v\(version)")
            }
        }
        for version in [2, 3, Int.max] {
            for reason in StopReason.allCases {
                XCTAssertEqual(reason.wire(forLifecycleVersion: version), reason.wire, "\(reason) v\(version)")
            }
        }
    }

    func testPlaybackMessagesUseTheIOSWording() {
        let expected: [StopReason: String] = [
            .user: "Stopped.",
            .pause: "Paused.",
            .focus: "Stopped after another app took audio. Use Reconnect when ready.",
            .focusTransient: "Temporarily interrupted by another audio source.",
            .focusPermanent: "Another app took over audio. Tap Play to resume.",
            .output: "Stopped because the audio output was disconnected. Choose an output and reconnect.",
            .service: "Playback stopped by iOS. Use Reconnect when ready.",
            .failure: "Connection ended. Use Reconnect when ready.",
        ]
        XCTAssertEqual(expected.count, StopReason.allCases.count)
        for reason in StopReason.allCases {
            XCTAssertEqual(reason.message, expected[reason], "\(reason)")
            XCTAssertFalse(reason.message.contains("Android"), "\(reason)")
            XCTAssertFalse(reason.message.contains("audio focus"), "\(reason)")
        }
    }

    func testMicrophoneModesUseTheirOwnEndMessages() {
        let expected: [StopReason: String] = [
            .user: "Stopped.",
            .pause: "Paused.",
            .focus: "Stopped after another app took audio. Tap Connect when ready.",
            .focusTransient: "Temporarily interrupted by another audio source.",
            .focusPermanent: "Another app took over audio. Tap Play to resume.",
            .output: "Stopped because the audio output was disconnected. Choose an output. Tap Connect when ready.",
            .service: "Microphone session stopped by iOS. Tap Connect when ready.",
            .failure: "Connection ended. Tap Connect when ready.",
        ]
        for reason in StopReason.allCases {
            XCTAssertEqual(
                reason.endedMessage(microphone: true, reconnectAction: "Connect"), expected[reason], "\(reason)")
        }
    }

    func testEndedMessageUsesTheGivenReconnectAction() {
        XCTAssertEqual(
            StopReason.failure.endedMessage(microphone: true, reconnectAction: "Reconnect"),
            "Connection ended. Tap Reconnect when ready.")
        XCTAssertEqual(StopReason.user.endedMessage(microphone: true, reconnectAction: "Reconnect"), "Stopped.")
    }

    func testPlaybackEndedMessageIsTheReasonMessage() {
        for reason in StopReason.allCases {
            for action in ["Reconnect", "Connect"] {
                XCTAssertEqual(reason.endedMessage(microphone: false, reconnectAction: action), reason.message)
            }
        }
    }

    func testStreamModeEndedMessageUsesTheLifecycleStrings() {
        for reason in StopReason.allCases {
            XCTAssertEqual(StreamMode.playback.endedMessage(reason), reason.message, "\(reason)")
            for mode in [StreamMode.microphone, .duplex] {
                XCTAssertEqual(
                    mode.endedMessage(reason), reason.endedMessage(microphone: true, reconnectAction: "Connect"),
                    "\(mode) \(reason)")
            }
        }
        XCTAssertEqual(
            StreamMode.duplex.endedMessage(.service), "Microphone session stopped by iOS. Tap Connect when ready.")
    }

    func testStreamEndCarriesReasonMessageAndOptionalDiagnostics() {
        let plain = StreamEnd(reason: .user, message: "Stopped.\nWindows acknowledged Stop.")
        XCTAssertEqual(plain.reason, .user)
        XCTAssertEqual(plain.message, "Stopped.\nWindows acknowledged Stop.")
        XCTAssertNil(plain.diagnostics)
        let failed = StreamEnd(reason: .failure, message: "Connection ended.", diagnostics: "terminal")
        XCTAssertEqual(failed.diagnostics, "terminal")
        XCTAssertNotEqual(plain, failed)
        XCTAssertEqual(
            plain, StreamEnd(reason: .user, message: "Stopped.\nWindows acknowledged Stop.", diagnostics: nil))
    }

    // MARK: - Go host contract

    func testEveryWireLabelIsAcceptedByTheHostWithItsEndReason() throws {
        let server = try RepositoryFixtures.text("internal/session/server.go").filter { !$0.isWhitespace }
        let reliability = try RepositoryFixtures.text("internal/session/reliability_test.go").filter {
            !$0.isWhitespace
        }
        for (reason, wire, hostReason) in hostEndReasons {
            let pair = "\"\(wire)\":\"\(hostReason)\""
            XCTAssertTrue(server.contains(pair), "server.go lacks \(pair) for \(reason)")
            XCTAssertTrue(reliability.contains(pair), "reliability_test.go lacks \(pair) for \(reason)")
        }
        for version in [1, 2] {
            for reason in StopReason.allCases {
                let wire = reason.wire(forLifecycleVersion: version)
                XCTAssertTrue(server.contains("\"\(wire)\":\"receiver_"), "\(wire) is not allow-listed")
            }
        }
    }
}
