// Connection setup section body (order is significant, `MainActivity.kt:384-389`).

import MicDropCore
import SwiftUI

/// Saved-connection text, help, the invitation field, Scan pairing QR (+ status), Find Windows on LAN
/// (+ status and one row per discovered host), Cancel pairing, Change Windows address and Forget. The phone
/// settings opt-in and Connection settings are in Advanced (`AdvancedSectionView`).
struct ConnectionSectionView: View {
    let model: MainViewModel
    var invitationFocused: FocusState<Bool>.Binding

    init(model: MainViewModel, invitationFocused: FocusState<Bool>.Binding) {
        self.model = model
        self.invitationFocused = invitationFocused
    }

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 10) {
            // 1. Saved connection (selectable so the request ID can be read and copied).
            if !render.savedMessage.isEmpty {
                HelpText(render.savedMessage)
                    .textSelection(.enabled)
            }
            // 2. Connection help.
            HelpText(Strings.connectionHelp)
            // 3. Invitation field: never persisted, at most 4096 characters, no suggestions/autofill. Hint
            // `textSecondary`, or `textDisabled` while disabled (`setHintTextColor`, `MainActivity.kt:358-359`).
            TextField(
                Strings.invitationHint, text: invitationBinding,
                prompt: Text(Strings.invitationHint)
                    .foregroundStyle(render.invitationEnabled ? Theme.textSecondary : Theme.textDisabled),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .textContentType(nil)
            .privacySensitive()
            .submitLabel(.done)
            .focused(invitationFocused)
            .foregroundStyle(render.invitationEnabled ? Theme.textPrimary : Theme.textDisabled)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.surfaceBorder, lineWidth: 1)
            )
            .disabled(!render.invitationEnabled)
            // 4-5. Scan pairing QR and its status (+ Settings link after a camera denial).
            Button {
                model.scanTapped()
            } label: {
                WideButtonLabel(Strings.scanPairing)
            }
            .buttonStyle(SurfaceButtonStyle())
            .disabled(!render.scanEnabled)
            if !model.scanStatus.isEmpty {
                HelpText(model.scanStatus)
            }
            if model.scanSettingsVisible {
                SettingsLinkButton { model.openSettingsTapped() }
            }
            // 6-8. LAN discovery: button, status (+ Settings link while Local Network is blocked), rows.
            Button {
                model.findTapped()
            } label: {
                WideButtonLabel(render.discoveryButtonLabel)
            }
            .buttonStyle(SurfaceButtonStyle())
            .disabled(!render.discoveryEnabled)
            if !render.discoveryStatus.isEmpty {
                HelpText(render.discoveryStatus)
            }
            if render.discoverySettingsVisible {
                SettingsLinkButton { model.openSettingsTapped() }
            }
            ForEach(render.discoveryRows) { row in
                Button {
                    model.discoveredHostTapped(row.host)
                } label: {
                    WideButtonLabel(row.label)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!row.enabled)
            }
            // 9. Cancel pairing (only while pairing).
            if render.cancelPairingVisible {
                Button {
                    model.cancelPairingTapped()
                } label: {
                    WideButtonLabel(Strings.cancelPairing)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!render.cancelPairingEnabled)
            }
            // 10. Change Windows address (only when paired).
            if render.addressVisible {
                Button {
                    model.changeAddressTapped()
                } label: {
                    WideButtonLabel(Strings.changeAddress)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!render.addressEnabled)
            }
            // 11. Forget saved connection.
            Button {
                model.forgetTapped()
            } label: {
                WideButtonLabel(Strings.forgetConnection)
            }
            .buttonStyle(SurfaceButtonStyle())
            .disabled(!render.forgetEnabled)
        }
    }

    /// User edits go through the model (truncation to 4096 characters, re-derive on every change).
    private var invitationBinding: Binding<String> {
        Binding(
            get: { model.invitationText },
            set: { model.invitationChanged($0) })
    }
}
