// Microphone section body (`MainActivity.kt:427-459`).

import MicDropCore
import SwiftUI

/// `Send microphone`, help, the input button and help, the LE stereo toggle (never visible on iOS: no
/// input is classified LE), echo reduction, noise reduction and the processing help.
struct MicrophoneSectionView: View {
    let model: MainViewModel

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 10) {
            // 1-2. Microphone toggle and help.
            Toggle(
                isOn: Binding(
                    get: { model.render.micChecked },
                    set: { model.changeMicrophone($0) })
            ) {
                Text(Strings.enableMicrophone)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            .disabled(!render.micToggleEnabled)
            HelpText(render.micToggleHelp)
            // 3-4. Input list and help.
            Button {
                model.microphoneInputTapped()
            } label: {
                WideButtonLabel(render.inputButtonLabel)
            }
            .buttonStyle(SurfaceButtonStyle())
            .disabled(!render.inputButtonEnabled)
            HelpText(render.inputHelp)
            // 5. LE Audio stereo playback (kept for parity; hidden unless the input is LE).
            if render.leStereoVisible {
                Toggle(
                    isOn: Binding(
                        get: { model.render.leStereoChecked },
                        set: { model.setLEStereo($0) })
                ) {
                    Text(Strings.leStereo)
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(minHeight: Theme.minimumTouchTarget)
                .disabled(!render.leStereoEnabled)
            }
            // 6-7. Processing toggles (persisted only while enabled).
            Toggle(
                isOn: Binding(
                    get: { model.render.echoChecked },
                    set: { model.setEchoCancellation($0) })
            ) {
                Text(Strings.microphoneEcho)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            .disabled(!render.echoEnabled)
            Toggle(
                isOn: Binding(
                    get: { model.render.noiseChecked },
                    set: { model.setNoiseReduction($0) })
            ) {
                Text(Strings.microphoneNoise)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            .disabled(!render.noiseEnabled)
            // 8. Processing help.
            HelpText(render.processingHelp)
        }
    }
}
