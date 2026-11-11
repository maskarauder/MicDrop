// Persistent action bar below the scroll view (`MainActivity.kt:320-329`).

import MicDropCore
import SwiftUI

/// `[Connect | Stop]` with equal widths, then a full-width `Pause playback` / `Keep paused` while
/// visible. Kept above the keyboard by the parent's `.safeAreaInset(edge: .bottom)`. Connect uses the gold
/// primary style (`button_primary.xml`), Stop and Pause the surface style (`button_surface.xml`).
struct ActionBarView: View {
    let model: MainViewModel

    var body: some View {
        let render = model.render
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.connectTapped()
                } label: {
                    WideButtonLabel(render.connectLabel)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!render.connectEnabled)

                Button {
                    model.stopTapped()
                } label: {
                    WideButtonLabel(Strings.stop)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!render.stopEnabled)
            }
            if render.pauseVisible {
                Button {
                    model.pauseTapped()
                } label: {
                    WideButtonLabel(render.pauseLabel)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(!render.pauseEnabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.appBackground)
    }
}
