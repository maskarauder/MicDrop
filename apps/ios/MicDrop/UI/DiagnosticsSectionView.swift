// Diagnostics section body (Android `diagnosticsSection.body`, `MainActivity.kt:512-519`).

import MicDropCore
import SwiftUI

/// Help, the build label, copy report / crash report, the local output test, Play click (only while the test runs), the
/// selectable diagnostics text and the open-source notices button (last item).
struct DiagnosticsSectionView: View {
    let model: MainViewModel

    var body: some View {
        let render = model.render
        VStack(alignment: .leading, spacing: 10) {
            // 1. Help (`diagnostics_help`, iPhone wording).
            HelpText(Strings.diagnosticsHelp)
            // 2. "Build <revision>" (lowercase hex or "local").
            HelpText(render.buildLabel)
            // 3-4. Copy reports (local-only pasteboard).
            diagnosticsButton(Strings.copyDiagnostics, enabled: render.copyEnabled) { model.copyReportTapped() }
            diagnosticsButton(Strings.copyCrashDiagnostics, enabled: render.copyCrashEnabled) {
                model.copyCrashReportTapped()
            }
            // 5-6. Local output test (foreground only) and Play click, shown only while the test runs
            // (`clickButton.visibility`, `MainActivity.kt:1368`).
            diagnosticsButton(Strings.localOutputTest, enabled: render.localTestEnabled) {
                model.localOutputTestTapped()
            }
            if render.clickVisible {
                diagnosticsButton(Strings.playClick, enabled: render.clickEnabled) { model.playClickTapped() }
            }
            // 7. Diagnostics text (12 pt monospaced, selectable).
            Text(render.diagnosticsText)
                .font(Theme.diagnosticsFont)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // 8. Open-source notices (sheet).
            diagnosticsButton(Strings.notices, enabled: true) { model.noticesTapped() }
        }
    }

    private func diagnosticsButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            WideButtonLabel(title)
        }
        .buttonStyle(SurfaceButtonStyle())
        .disabled(!enabled)
    }
}
