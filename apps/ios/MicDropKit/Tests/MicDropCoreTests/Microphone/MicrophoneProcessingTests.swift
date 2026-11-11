import Foundation
import MicDropCore
import XCTest

/// `T/MicrophoneProcessingTest.kt` plus the iOS copy text and the report encodings.
final class MicrophoneProcessingTests: XCTestCase {
    private let requested = MicrophoneProcessing(echoCancellation: true, noiseReduction: true)

    func testPlaybackNeverEnablesVoiceProcessing() {
        XCTAssertEqual(requested.effective(mode: .playback, input: .builtIn), MicrophoneProcessing())
    }

    func testMicrophoneOnlyHasNoEchoReference() {
        XCTAssertEqual(
            requested.effective(mode: .microphone, input: .builtIn),
            MicrophoneProcessing(echoCancellation: false, noiseReduction: true))
    }

    func testBluetoothKeepsPlatformAndHeadsetProcessingPolicy() {
        for kind in [MicrophoneKind.sco, .le] {
            for mode in StreamMode.allCases {
                XCTAssertEqual(requested.effective(mode: mode, input: kind), MicrophoneProcessing(), "\(mode) \(kind)")
            }
        }
    }

    func testDuplexVoiceOptionsNeverEnableGainOrHighPass() {
        let effective = requested.effective(mode: .duplex, input: .builtIn)
        XCTAssertTrue(effective.echoCancellation)
        XCTAssertTrue(effective.noiseReduction)
        XCTAssertEqual(effective.constraints()["googAutoGainControl"], "false")
        XCTAssertEqual(effective.constraints()["googHighpassFilter"], "false")
        XCTAssertEqual(effective.constraints()["googEchoCancellation"], "true")
        XCTAssertEqual(effective.constraints()["googNoiseSuppression"], "true")
    }

    func testEffectivePolicyMatrixAndIdempotence() {
        for echo in [false, true] {
            for noise in [false, true] {
                let preference = MicrophoneProcessing(echoCancellation: echo, noiseReduction: noise)
                for mode in StreamMode.allCases {
                    for kind in MicrophoneKind.allCases {
                        let effective = preference.effective(mode: mode, input: kind)
                        let label = "\(echo) \(noise) \(mode) \(kind)"
                        XCTAssertEqual(effective.echoCancellation, echo && mode == .duplex && !kind.isBluetooth, label)
                        XCTAssertEqual(effective.noiseReduction, noise && mode != .playback && !kind.isBluetooth, label)
                        XCTAssertEqual(effective.effective(mode: mode, input: kind), effective, label)
                    }
                }
            }
        }
    }

    func testPreferencesDefaultOff() {
        let processing = MicrophoneProcessing()
        XCTAssertFalse(processing.echoCancellation)
        XCTAssertFalse(processing.noiseReduction)
        XCTAssertEqual(
            processing.constraints(),
            [
                "googEchoCancellation": "false", "googNoiseSuppression": "false", "googAutoGainControl": "false",
                "googHighpassFilter": "false",
            ])
        XCTAssertEqual(
            processing.fields(), ["echo_cancellation_requested": false, "noise_reduction_requested": false])
    }

    func testReportObjectEncodings() throws {
        let processing = MicrophoneProcessing(echoCancellation: false, noiseReduction: true)
        XCTAssertEqual(processing.fields(), ["echo_cancellation_requested": false, "noise_reduction_requested": true])
        XCTAssertEqual(
            processing.json().encodedString(),
            #"{"echo_cancellation_requested":false,"noise_reduction_requested":true}"#)
        XCTAssertEqual(processing.json().keys, ["echo_cancellation_requested", "noise_reduction_requested"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(MicrophoneProcessing(echoCancellation: true, noiseReduction: false))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"echo_cancellation_requested":true,"noise_reduction_requested":false}"#)
    }

    func testIOSCopyText() {
        XCTAssertEqual(
            MicrophoneProcessing().text(),
            "Microphone processing: iOS voice-processing echo cancellation off · Noise reduction off. "
                + "Acoustic effectiveness is unmeasured.")
        XCTAssertEqual(
            requested.text(voiceProcessingActive: false),
            "Microphone processing: iOS voice-processing echo cancellation requested · Noise reduction requested. "
                + "Acoustic effectiveness is unmeasured.")
        XCTAssertEqual(
            requested.text(voiceProcessingActive: true),
            "Microphone processing: iOS voice-processing echo cancellation requested · Noise reduction requested. "
                + "iOS voice processing also applies its own noise suppression and automatic gain control; "
                + "desktop playback is mono. Acoustic effectiveness is unmeasured.")
        XCTAssertFalse(requested.text(voiceProcessingActive: true).contains("WebRTC"))
    }

    func testUIStrings() {
        XCTAssertEqual(MicrophoneProcessing.UIText.echoToggle, "Reduce microphone echo (experimental)")
        XCTAssertEqual(MicrophoneProcessing.UIText.noiseToggle, "Reduce microphone background noise")
        XCTAssertEqual(
            MicrophoneProcessing.UIText.help,
            "Choose before connecting. Echo reduction can help with phone-speaker playback; headphones are still "
                + "recommended. These options process only the microphone. On iPhone, echo reduction uses iOS voice "
                + "processing: desktop audio plays in mono and iOS also applies its own noise suppression and gain "
                + "control.")
        XCTAssertEqual(
            MicrophoneProcessing.UIText.bluetoothHelp,
            "Bluetooth microphone processing is managed by iOS and the headset. "
                + "These options are retained for phone or wired/USB input.")
    }
}
