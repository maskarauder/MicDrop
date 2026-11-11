import Foundation
import MicDropCore
import XCTest

/// Port of `apps/android/app/src/test/java/com/maskarauder/micdrop/AudioPreferencesTest.kt` plus the strict JSON coding
/// of `Application Support/MicDrop/audio-settings.json`: a Bool key is honored only for a JSON boolean, kind keys
/// distinguish absent from present-but-invalid, and a missing or unparsable file restores every default.
final class AudioPreferencesTests: XCTestCase {
    private typealias Stored = AudioPreferences.StoredValue

    private let allKeys: Set<String> = [
        "outputEnabled", "microphoneEnabled", "fastRecovery", "leStereo", "preferredInputKind", "preferredOutputKind",
        "echoCancellation", "noiseReduction",
    ]

    // MARK: - AudioPreferencesTest.kt

    func testTemporarySpeakerRemembersDefaultWithoutPersistingItsActiveOverride() {
        let temporary = OutputSelection.fallbackSpeaker()
        XCTAssertEqual(temporary.kind, .phone)
        XCTAssertEqual(temporary.preferenceKind, .default)
        let preferences = AudioPreferences(preferredOutputKind: temporary.preferenceKind)
        XCTAssertFalse(preferences.needsOutputSelection(temporary))
        let cold = OutputSelection.restored(AudioPreferences.from(preferences.fields()).preferredOutputKind)
        XCTAssertEqual(cold, OutputSelection())
        XCTAssertFalse(cold.temporarySpeaker)
        XCTAssertTrue(preferences.needsOutputSelection(OutputSelection.restored(.phone)))
    }

    func testTheNextExplicitConnectionUsesCurrentToggles() {
        let saved = AudioPreferences(outputEnabled: false, microphoneEnabled: true)
        XCTAssertEqual(saved.connectionMode, .microphone)
        XCTAssertEqual(saved.changing { $0.outputEnabled = true }.connectionMode, .duplex)
        let playback = saved.changing {
            $0.outputEnabled = true
            $0.microphoneEnabled = false
        }
        XCTAssertEqual(playback.connectionMode, .playback)
        let silent = saved.changing { $0.microphoneEnabled = false }
        XCTAssertEqual(silent.connectionMode, .playback)
        XCTAssertFalse(silent.outputEnabled)
        XCTAssertFalse(silent.connectionMode.hasMicrophone)
    }

    func testRememberedSettingsContainNoDeviceIdentityOrCaptureTicket() {
        let original = AudioPreferences(
            outputEnabled: false, microphoneEnabled: true, fastRecovery: false, leStereo: false,
            preferredInputKind: .sco, preferredOutputKind: .bluetooth)
        XCTAssertEqual(AudioPreferences.from(original.fields()), original)
        XCTAssertEqual(Set(original.fields().keys), allKeys)
        XCTAssertFalse(AudioPreferences().microphoneEnabled)
        XCTAssertEqual(AudioPreferences.from([:]).connectionMode, .playback)
    }

    func testAnExternalOutputPreferenceCannotBecomeTheSystemDefaultAfterProcessDeath() {
        let saved = AudioPreferences(preferredOutputKind: .bluetooth)
        let cold = OutputSelection.restored(saved.preferredOutputKind)
        XCTAssertTrue(saved.needsOutputSelection(cold))
        let phone = saved.changing { $0.preferredOutputKind = .phone }
        XCTAssertFalse(phone.needsOutputSelection(OutputSelection.restored(phone.preferredOutputKind)))
        XCTAssertFalse(AudioPreferences.from([:]).needsOutputSelection(OutputSelection()))
        let malformed = AudioPreferences.from(["preferredOutputKind": .string("unknown")])
        XCTAssertTrue(malformed.needsOutputSelection(OutputSelection()))
    }

    func testARememberedHeadsetKindCannotSilentlyChooseThePhoneMicrophone() {
        let saved = AudioPreferences(microphoneEnabled: true, preferredInputKind: .sco)
        XCTAssertTrue(saved.needsInputSelection(MicrophoneSelection()))
        XCTAssertFalse(saved.changing { $0.microphoneEnabled = false }.needsInputSelection(MicrophoneSelection()))
        XCTAssertFalse(saved.needsInputSelection(MicrophoneSelection(kind: .sco)))
        XCTAssertTrue(saved.needsInputSelection(MicrophoneSelection(kind: .le)))
        XCTAssertFalse(saved.changing { $0.preferredInputKind = .builtIn }.needsInputSelection(MicrophoneSelection()))
    }

    func testMalformedSettingsNeverEnableMicrophoneByCoercion() {
        let restored = AudioPreferences.from([
            "microphoneEnabled": .string("true"), "outputEnabled": .number(0), "preferredInputKind": .string("unknown"),
        ])
        XCTAssertFalse(restored.microphoneEnabled)
        XCTAssertTrue(restored.outputEnabled)
        XCTAssertNil(restored.preferredInputKind)
        XCTAssertTrue(restored.changing { $0.microphoneEnabled = true }.needsInputSelection(MicrophoneSelection()))
        XCTAssertEqual(AudioPreferences.from(restored.fields()), restored)
    }

    // MARK: - Model rules

    func testDefaults() {
        let defaults = AudioPreferences()
        XCTAssertTrue(defaults.outputEnabled)
        XCTAssertFalse(defaults.microphoneEnabled)
        XCTAssertTrue(defaults.fastRecovery)
        XCTAssertTrue(defaults.leStereo)
        XCTAssertEqual(defaults.preferredInputKind, .builtIn)
        XCTAssertEqual(defaults.preferredOutputKind, .default)
        XCTAssertFalse(defaults.echoCancellation)
        XCTAssertFalse(defaults.noiseReduction)
        XCTAssertEqual(AudioPreferences.from([:]), defaults)
        XCTAssertEqual(defaults.connectionMode, .playback)
        XCTAssertEqual(AudioPreferences.fileName, "audio-settings.json")
    }

    func testConnectionModeTruthTable() {
        let cases: [(Bool, Bool, StreamMode)] = [
            (true, true, .duplex), (false, true, .microphone), (true, false, .playback), (false, false, .playback),
        ]
        for (output, microphone, mode) in cases {
            let preferences = AudioPreferences(outputEnabled: output, microphoneEnabled: microphone)
            XCTAssertEqual(preferences.connectionMode, mode, "output=\(output) microphone=\(microphone)")
        }
    }

    func testOutputSelectionCheckUsesThePreferenceKind() {
        for kind in OutputKind.allCases {
            let preferences = AudioPreferences(preferredOutputKind: kind)
            XCTAssertFalse(preferences.needsOutputSelection(OutputSelection(kind: kind)), "\(kind)")
            let other = OutputKind.allCases.first { $0 != kind } ?? .default
            XCTAssertTrue(preferences.needsOutputSelection(OutputSelection(kind: other)), "\(kind)")
        }
        let reselect = AudioPreferences(preferredOutputKind: nil)
        for kind in OutputKind.allCases {
            XCTAssertTrue(reselect.needsOutputSelection(OutputSelection(kind: kind)), "\(kind)")
        }
        XCTAssertTrue(reselect.needsOutputSelection(OutputSelection.fallbackSpeaker()))
    }

    func testInputSelectionIsCheckedOnlyWhenTheMicrophoneIsEnabled() {
        for kind in MicrophoneKind.allCases {
            let enabled = AudioPreferences(microphoneEnabled: true, preferredInputKind: kind)
            XCTAssertFalse(enabled.needsInputSelection(MicrophoneSelection(kind: kind)), "\(kind)")
            let disabled = AudioPreferences(microphoneEnabled: false, preferredInputKind: nil)
            XCTAssertFalse(disabled.needsInputSelection(MicrophoneSelection(kind: kind)), "\(kind)")
            let reselect = AudioPreferences(microphoneEnabled: true, preferredInputKind: nil)
            XCTAssertTrue(reselect.needsInputSelection(MicrophoneSelection(kind: kind)), "\(kind)")
        }
    }

    func testFieldsAreExactlyTheEightKeysWithEnumNamesAndEmptyStringsForMissingKinds() {
        let fields = AudioPreferences().fields()
        XCTAssertEqual(Set(fields.keys), allKeys)
        XCTAssertEqual(Set(AudioPreferences.Key.allCases.map { $0.rawValue }), allKeys)
        XCTAssertEqual(fields["outputEnabled"], .bool(true))
        XCTAssertEqual(fields["microphoneEnabled"], .bool(false))
        XCTAssertEqual(fields["fastRecovery"], .bool(true))
        XCTAssertEqual(fields["leStereo"], .bool(true))
        XCTAssertEqual(fields["preferredInputKind"], .string("BUILT_IN"))
        XCTAssertEqual(fields["preferredOutputKind"], .string("DEFAULT"))
        XCTAssertEqual(fields["echoCancellation"], .bool(false))
        XCTAssertEqual(fields["noiseReduction"], .bool(false))

        let reselect = AudioPreferences(preferredInputKind: nil, preferredOutputKind: nil)
        XCTAssertEqual(reselect.fields()["preferredInputKind"], .string(""))
        XCTAssertEqual(reselect.fields()["preferredOutputKind"], .string(""))
        XCTAssertEqual(AudioPreferences.from(reselect.fields()), reselect)
    }

    func testBoolKeysAreHonoredOnlyForBooleans() {
        let keys: [(AudioPreferences.Key, KeyPath<AudioPreferences, Bool>, Bool)] = [
            (.outputEnabled, \.outputEnabled, true),
            (.microphoneEnabled, \.microphoneEnabled, false),
            (.fastRecovery, \.fastRecovery, true),
            (.leStereo, \.leStereo, true),
            (.echoCancellation, \.echoCancellation, false),
            (.noiseReduction, \.noiseReduction, false),
        ]
        let invalid: [Stored] = [
            .number(0), .number(1), .string("true"), .string("false"), .string(""), .null, .other,
        ]
        for (key, path, fallback) in keys {
            XCTAssertEqual(AudioPreferences.from([key.rawValue: .bool(!fallback)])[keyPath: path], !fallback, "\(key)")
            XCTAssertEqual(AudioPreferences.from([key.rawValue: .bool(fallback)])[keyPath: path], fallback, "\(key)")
            for value in invalid {
                let decoded = AudioPreferences.from([key.rawValue: value])
                XCTAssertEqual(decoded[keyPath: path], fallback, "\(key) = \(value)")
            }
        }
    }

    func testKindKeysDistinguishAbsentFromPresentButInvalid() {
        for kind in MicrophoneKind.allCases {
            let name = AudioPreferences.storageName(of: kind)
            XCTAssertEqual(AudioPreferences.from(["preferredInputKind": .string(name)]).preferredInputKind, kind)
        }
        for kind in OutputKind.allCases {
            let name = AudioPreferences.storageName(of: kind)
            XCTAssertEqual(AudioPreferences.from(["preferredOutputKind": .string(name)]).preferredOutputKind, kind)
        }
        let invalid: [Stored] = [
            .string(""), .string("built_in"), .string(" BUILT_IN"), .string("hearing_aid"), .string("default"),
            .number(0), .bool(true), .null, .other,
        ]
        for value in invalid {
            XCTAssertNil(AudioPreferences.from(["preferredInputKind": value]).preferredInputKind, "\(value)")
            XCTAssertNil(AudioPreferences.from(["preferredOutputKind": value]).preferredOutputKind, "\(value)")
        }
        let absent = AudioPreferences.from(["unrelated": .string("BLUETOOTH")])
        XCTAssertEqual(absent.preferredInputKind, .builtIn)
        XCTAssertEqual(absent.preferredOutputKind, .default)
    }

    func testStorageNamesAreTheAndroidEnumNames() {
        XCTAssertEqual(
            MicrophoneKind.allCases.map { AudioPreferences.storageName(of: $0) },
            ["BUILT_IN", "WIRED", "USB", "SCO", "LE"])
        XCTAssertEqual(
            OutputKind.allCases.map { AudioPreferences.storageName(of: $0) },
            ["DEFAULT", "PHONE", "WIRED", "USB", "BLUETOOTH", "LE", "HEARING_AID", "OTHER"])
        for kind in MicrophoneKind.allCases {
            XCTAssertEqual(AudioPreferences.storageName(of: kind), kind.rawValue)
        }
        for kind in OutputKind.allCases {
            XCTAssertEqual(AudioPreferences.storageName(of: kind), kind.persistedName)
            XCTAssertEqual(OutputKind(persistedName: AudioPreferences.storageName(of: kind)), kind)
        }
    }

    // MARK: - audio-settings.json decoding

    func testMissingOrUnparsableFileRestoresDefaults() {
        XCTAssertEqual(AudioPreferences.decodeJSON(nil), AudioPreferences())
        let unusable = [
            "", " ", "not json", "[]", "[{\"outputEnabled\":false}]", "null", "true", "0", "\"outputEnabled\"", "{",
            "{\"outputEnabled\":false", "{\"outputEnabled\":false} trailing",
            "{outputEnabled:false}", "{'outputEnabled':false}",
        ]
        for text in unusable {
            XCTAssertEqual(AudioPreferences.decodeJSON(Data(text.utf8)), AudioPreferences(), text)
        }
    }

    func testDecodingAppliesTheStrictKotlinRules() {
        let json = """
            {"microphoneEnabled":"true","outputEnabled":0,"preferredInputKind":"unknown","fastRecovery":1,
             "leStereo":null,"echoCancellation":"yes","noiseReduction":[true],"preferredOutputKind":{"kind":"PHONE"}}
            """
        let decoded = AudioPreferences.decodeJSON(Data(json.utf8))
        XCTAssertFalse(decoded.microphoneEnabled)
        XCTAssertTrue(decoded.outputEnabled)
        XCTAssertNil(decoded.preferredInputKind)
        XCTAssertTrue(decoded.fastRecovery)
        XCTAssertTrue(decoded.leStereo)
        XCTAssertFalse(decoded.echoCancellation)
        XCTAssertFalse(decoded.noiseReduction)
        XCTAssertNil(decoded.preferredOutputKind)
    }

    func testDecodingHonorsBooleansAndExactKindNames() {
        let json = """
            {"outputEnabled":false,"microphoneEnabled":true,"fastRecovery":false,"leStereo":false,
             "preferredInputKind":"USB","preferredOutputKind":"HEARING_AID","echoCancellation":true,
             "noiseReduction":true}
            """
        XCTAssertEqual(
            AudioPreferences.decodeJSON(Data(json.utf8)),
            AudioPreferences(
                outputEnabled: false, microphoneEnabled: true, fastRecovery: false, leStereo: false,
                preferredInputKind: .usb, preferredOutputKind: .hearingAid, echoCancellation: true,
                noiseReduction: true))
    }

    func testNullKindsArePresentButInvalid() {
        let decoded = AudioPreferences.decodeJSON(Data(#"{"preferredInputKind":null,"preferredOutputKind":null}"#.utf8))
        XCTAssertNil(decoded.preferredInputKind)
        XCTAssertNil(decoded.preferredOutputKind)
        XCTAssertTrue(decoded.outputEnabled)
    }

    func testEmptyObjectAndUnknownKeysKeepDefaults() {
        XCTAssertEqual(AudioPreferences.decodeJSON(Data("{}".utf8)), AudioPreferences())
        XCTAssertEqual(AudioPreferences.decodeJSON(Data(" \n{ }\n".utf8)), AudioPreferences())
        let future = #"{"future":{"nested":[1,2,{"deep":true}]},"outputEnabled":false,"leStereo":true}"#
        XCTAssertEqual(AudioPreferences.decodeJSON(Data(future.utf8)), AudioPreferences(outputEnabled: false))
    }

    func testEscapedStringsDecodeToTheirValue() {
        let json = #"{"preferredInputKind":"SCO","preferredOutputKind":"PHONE"}"#
        let decoded = AudioPreferences.decodeJSON(Data(json.utf8))
        XCTAssertEqual(decoded.preferredInputKind, .sco)
        XCTAssertEqual(decoded.preferredOutputKind, .phone)
    }

    // MARK: - audio-settings.json encoding

    func testEncodedJSONIsTheSortedEightKeyObject() throws {
        let text = String(decoding: try AudioPreferences().encodedJSON(), as: UTF8.self)
        XCTAssertEqual(
            text,
            #"{"echoCancellation":false,"fastRecovery":true,"leStereo":true,"microphoneEnabled":false,"#
                + #""noiseReduction":false,"outputEnabled":true,"preferredInputKind":"BUILT_IN","#
                + #""preferredOutputKind":"DEFAULT"}"#)
        let reselect = AudioPreferences(preferredInputKind: nil, preferredOutputKind: nil)
        let reselectText = String(decoding: try reselect.encodedJSON(), as: UTF8.self)
        XCTAssertTrue(reselectText.contains(#""preferredInputKind":"""#), reselectText)
        XCTAssertTrue(reselectText.contains(#""preferredOutputKind":"""#), reselectText)
    }

    func testEncodedJSONRoundTripsEveryPreference() throws {
        var samples: [AudioPreferences] = [
            AudioPreferences(),
            AudioPreferences(preferredInputKind: nil, preferredOutputKind: nil),
            AudioPreferences(
                outputEnabled: false, microphoneEnabled: true, fastRecovery: false, leStereo: false,
                preferredInputKind: .sco, preferredOutputKind: .bluetooth, echoCancellation: true,
                noiseReduction: true),
        ]
        for kind in MicrophoneKind.allCases { samples.append(AudioPreferences(preferredInputKind: kind)) }
        for kind in OutputKind.allCases { samples.append(AudioPreferences(preferredOutputKind: kind)) }
        for sample in samples {
            let data = try sample.encodedJSON()
            XCTAssertEqual(AudioPreferences.decodeJSON(data), sample)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), allKeys)
        }
    }

    // MARK: - StoredValue

    func testStoredValueDecodesScalarsWithoutCoercion() throws {
        let json = #"[true, false, 0, 1, 1.5, -2e3, "true", "", null, [1], {"a": 1}]"#
        let values = try JSONDecoder().decode([Stored].self, from: Data(json.utf8))
        XCTAssertEqual(
            values,
            [
                .bool(true), .bool(false), .number(0), .number(1), .number(1.5), .number(-2000), .string("true"),
                .string(""), .null, .other, .other,
            ])
    }

    func testStoredValueObjectKeepsNullMembers() throws {
        let json = #"{"id": null, "fast": true, "digest": "abc"}"#
        let fields = try JSONDecoder().decode([String: Stored].self, from: Data(json.utf8))
        XCTAssertEqual(fields, ["id": .null, "fast": .bool(true), "digest": .string("abc")])
    }

    func testStoredValueEncodingRoundTripsAndWritesOtherAsNull() throws {
        let values: [Stored] = [.bool(false), .string("x"), .number(2.5), .null, .other]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(
            try JSONDecoder().decode([Stored].self, from: data),
            [.bool(false), .string("x"), .number(2.5), .null, .null])
    }
}

extension AudioPreferences {
    /// Kotlin `copy(...)` for the ported tests.
    fileprivate func changing(_ change: (inout AudioPreferences) -> Void) -> AudioPreferences {
        var copy = self
        change(&copy)
        return copy
    }
}
