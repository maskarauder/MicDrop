// Status card (`MainActivity.kt:302-318`, `renderStatus` `:1411-1447`).

import MicDropCore
import SwiftUI

/// Status title (accent, heading), status text (wraps without a line limit, like Android dropped `maxLines = 5`), the
/// optional output action (`Use iPhone speaker` / `Follow iPhone media output`) and the iOS-only `Open Settings` link
/// shown after a denied permission or a Local Network block (iOS cannot re-prompt).
struct StatusCardView: View {
    let model: MainViewModel

    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = Theme.statusTitleSize

    init(model: MainViewModel) {
        self.model = model
    }

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 6) {
            Text(render.statusTitle)
                .font(.system(size: titleSize))
                .foregroundStyle(Theme.accent)
                .accessibilityAddTraits(.isHeader)
            Text(render.statusText)
                .font(Theme.statusTextFont)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if render.outputActionVisible {
                Button {
                    model.statusOutputActionTapped()
                } label: {
                    WideButtonLabel(render.outputActionLabel)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!render.outputActionEnabled)
                .padding(.top, 4)
            }
            if render.openSettingsVisible {
                SettingsLinkButton { model.openSettingsTapped() }
            }
        }
        // Padding 14/12/14/12 (left/top/right/bottom).
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}

/// The iOS-only `Open Settings` link (status card, scan status, discovery status): opens MicDrop's page
/// in Settings (`UIApplication.openSettingsURLString`).
struct SettingsLinkButton: View {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(Strings.openSettings, action: action)
            .buttonStyle(.borderless)
            .frame(minHeight: Theme.minimumTouchTarget)
    }
}
