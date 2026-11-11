// Advanced section body (Android `advancedSection.body`, `MainActivity.kt:499-511`).

import MicDropCore
import SwiftUI

/// Help, the phone settings opt-in (+ help and save failure), Connection settings and fast recovery. Android shows
/// one button per `ConnectionSettingsGroup` plus the keep-microphone checkbox here; the iPhone keeps its single
/// Connection settings sheet, which also holds "Keep microphone active while muted in background" and Bluetooth
/// route recovery.
struct AdvancedSectionView: View {
    let model: MainViewModel
    @State private var policyPresented = false

    init(model: MainViewModel) {
        self.model = model
    }

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 10) {
            // 1. Help (`advanced_help`).
            HelpText(Strings.advancedHelp)
            // 2-3. "Allow Windows to change phone settings" and its help (`MainActivity.kt:463-468`, `:501-502`).
            // Saved at once and never disabled, so it can be turned off during a session. A new identity per save
            // attempt redraws the switch from the saved value even when a repeated failed save changed nothing
            // observable.
            Toggle(
                isOn: Binding(
                    get: { model.phoneControlOptIn.allowed },
                    set: { model.phoneControlOptIn.set($0) })
            ) {
                Text(Strings.allowWindowsSettings)
                    .foregroundStyle(Theme.textPrimary)
            }
            .id(model.phoneControlOptIn.saveAttempt)
            .frame(minHeight: Theme.minimumTouchTarget)
            HelpText(Strings.allowWindowsSettingsHelp)
            if model.phoneControlOptIn.saveFailed {
                HelpText(Strings.allowWindowsSettingsSaveFailed)
            }
            // 4. Connection settings (next connection; `ConnectionPolicyView`). Android re-renders after each
            // settings dialog (`MainActivity.kt:506`); dismissing the sheet re-derives, so the summary shows the
            // saved recovery window.
            Button {
                policyPresented = true
            } label: {
                WideButtonLabel(Strings.connectionSettings)
            }
            .buttonStyle(SurfaceButtonStyle())
            // 5. Faster recovery (`MainActivity.kt:451-456`, `:510`).
            Toggle(
                isOn: Binding(
                    get: { model.render.fastRecoveryChecked },
                    set: { model.setFastRecovery($0) })
            ) {
                Text(Strings.fastRecovery)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(minHeight: Theme.minimumTouchTarget)
            .disabled(!render.fastRecoveryEnabled)
        }
        .sheet(
            isPresented: $policyPresented, onDismiss: { model.connectionSettingsDismissed() },
            content: { ConnectionPolicyView() })
    }
}
